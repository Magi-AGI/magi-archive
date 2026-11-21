# frozen_string_literal: true

# =================================================================================================
# I3 READ BINDING LIFECYCLE FOR **THIN 2.0.1** -- the server this deck actually runs
# =================================================================================================
#
# WHY THIS FILE REPLACES THE PUMA PLAN. `config/initializers/i3_read_binding.rb` documents a single
# operator remedy for preforking deployments:
#
#     on_worker_boot { Atomspace::I3ReadBindingInstaller.install_for_worker! }
#
# `on_worker_boot` is a **Puma DSL method**. It is defined nowhere in thin 2.0.1 and `config/puma.rb`
# is never read by `thin start` / `decko server`, so that hook CANNOT RUN on the real server and
# `install_for_worker!` had NO runtime caller outside spec/. The port therefore stayed unwired in
# production and every I3 route answered 503. This file is that missing runtime caller.
#
# -------------------------------------------------------------------------------------------------
# PROVENANCE WARNING -- READ BEFORE TRUSTING ANY (F*) CLAIM BELOW  [ROUND 34]
# -------------------------------------------------------------------------------------------------
# An earlier revision of this header asserted that the thin 2.0.1 and eventmachine 1.2.7 facts
# below were "read off the real gem on this host" and "verified empirically on this host". THAT
# PROVENANCE CLAIM WAS FALSE and Codex flagged it. The thin, eventmachine, rails, decko and card
# gems are NOT INSTALLED on this development host: they cannot be required, their source cannot be
# read here, and no reactor can be started to observe. Every (F1)-(F6) statement below is therefore
# an INFERENCE FROM THIN/EM DOCUMENTATION AND THE PUBLISHED SOURCE LAYOUT, retained because it is
# the design rationale -- NOT because it was executed or observed. The file:line citations are
# references into published sources, not transcripts of a local read.
#
# WHAT IS ACTUALLY PROVEN ON THIS HOST: only the pure control flow of this module, exercised by
# `spec/mcp_api/i3_round34_thin_lifecycle_proof.rb` against DOUBLES for Rails/Thin/EventMachine and
# the installer. Anything that depends on real gem behaviour (whether EM really drains `@tails`,
# whether thin really builds the app before starting the reactor, whether `next_tick` really runs
# inside the serving process) IS UNVERIFIED HERE and must be confirmed on a host that has the gems.
# The gate at `thin_serving_context?` is written so that if those inferences are WRONG, the failure
# mode is a refusal (503), never a bind in the wrong process.
#
# -------------------------------------------------------------------------------------------------
# INFERRED FACTS ABOUT THIN 2.0.1 (file:line = published-source references, NOT a local read)
# -------------------------------------------------------------------------------------------------
#
# (F1) THIN IS NOT DOCUMENTED TO PREFORK WORKERS. `Thin::Controllers::Controller#start` is
#      understood to run, IN THIS ORDER:
#
#        controller.rb:41  server = Server.new(...)
#        controller.rb:62  server.daemonize if @options[:daemonize]   # <== the only documented fork
#        controller.rb:65  server.config
#        controller.rb:72  server.app = load_rackup_config            # <== Rack/Rails app LOADS HERE
#        controller.rb:87  server.start
#
#      `daemonize` (daemonizing.rb:45-58) detaches BEFORE the app is built at controller.rb:72, so
#      the Rack app -- and therefore config/environment.rb and EVERY Rails initializer, including
#      this one -- is expected to load in the FINAL SERVING PROCESS.
#
#      WHY THIS IS NO LONGER TREATED AS A LICENCE TO BYPASS THE PREFORK REFUSAL: the statement is
#      an inference about ONE server under ONE deployment shape. The process this file actually
#      runs in is not knowable from documentation, and a Puma/preforking topology (or a future
#      thin mode) would make the inference false in exactly the direction that corrupts the line
#      protocol. The code now demands POSITIVE evidence of a serving process instead
#      (`thin_serving_context?`), and refuses when it cannot get it. See (F7).
#
# (F2) `WEB_CONCURRENCY` IS BELIEVED MEANINGLESS TO THIN. Thin's multi-process mode is documented
#      as a CLUSTER (`thin start -s N`, runner.rb:109) in which `Thin::Controllers::Cluster#run`
#      (cluster.rb:141-151) starts each member as a FULL SEPARATE process with its own `:port` and
#      `:pid` -- not a fork of a preloaded app. Each cluster member would boot its own Rails and so
#      run this initializer itself.
#
#      *** CORRECTED IN ROUND 34 (Codex blocker 2) *** The previous conclusion drawn from (F2) --
#      "therefore always call `install_for_worker!` and never `install!`" -- WAS WRONG, and this
#      file implemented it unconditionally. `install_for_worker!` BYPASSES the prefork-master
#      refusal (`refuse_prefork_master!`, i3_read_binding.rb:526-540, reached from
#      install_in_process! at i3_read_binding.rb:327 when `prefork_configured?`,
#      i3_read_binding.rb:546-554). Taking that bypass on a path that has NOT PROVEN it is a
#      post-fork serving process defeats a refusal that exists to prevent binding in a preforking
#      MASTER and leaking inherited pipes into every worker. A stray WEB_CONCURRENCY causing a
#      false 503 is an inconvenience; binding in a master is protocol corruption. The gate is now
#      evidence-based and fails CLOSED to `install!` (and hence to the refusal) whenever the
#      serving context is unproven.
#
# (F3) THREADING IS UNDERSTOOD TO BE IN-PROCESS ONLY, NEVER A FORK. `--threaded` sets
#      `server.threaded = true` (controller.rb:51), delegated to the backend (server.rb:86) and
#      applied per connection (base.rb:151); each `call` runs on EventMachine's threadpool IN THE
#      SAME PROCESS. "One child per process" therefore still holds, but activation must be
#      THREAD-SAFE -- hence the Mutex below.
#
# (F4) THE REACTOR / "NOW SERVING" POINT. `Backends::Base#start` (base.rb:62-77) is understood to
#      build `starter = proc { connect; yield if block_given?; @running = true }` (base.rb:64-68)
#      and then run `EventMachine.reactor_running? ? starter.call : (@started_reactor = true;
#      EM.run(&starter))` (base.rb:71-76). So the per-process serving point is INSIDE the reactor,
#      and `@started_reactor` records whether THIN owns that reactor (base.rb:74), which decides
#      whether thin may stop it (base.rb:96).
#
#      THIS IS THE BASIS OF DEFERRED ACTIVATION (F7): a Rails `after_initialize` block runs at
#      controller.rb:72 time, i.e. BEFORE the reactor exists at controller.rb:87, so a strict
#      serving-context gate evaluated at after_initialize time would ALWAYS fail. Activation is
#      therefore re-queued into the reactor via `EventMachine.next_tick`, where the evidence can
#      actually exist. INFERENCE, not observation: `next_tick` is documented to run its block on
#      the next reactor pass in the reactor's own process.
#
# (F5) THE REAL SHUTDOWN PATH. Signals are documented as trapped into a queue and drained by a
#      1-SECOND EM PERIODIC TIMER, never in trap context:
#        server.rb:235-237  %w(INT TERM).each { |s| trap(s) { @signal_queue.push s } }
#        server.rb:239-241  %w(QUIT HUP USR1) ... `unless Thin.win?`   # <== *nix only
#        server.rb:244      @signal_timer ||= EM.add_periodic_timer(1) { handle_signals }
#        server.rb:247-259  handle_signals: INT->stop!, TERM/QUIT->stop, HUP->restart
#      converging on the backend:
#        server.rb:171-181  #stop  -> @backend.stop  (graceful; base.rb:80-89 -> stop! when empty)
#        server.rb:187-197  #stop! -> @backend.stop!
#        base.rb:92-99      #stop! -> `EventMachine.stop if @started_reactor && reactor_running?`
#      `EventMachine.stop` is documented to drain the reactor's shutdown hooks
#      (eventmachine.rb:199-200), which `EventMachine.add_shutdown_hook` (eventmachine.rb:291-293)
#      appends to, and `@tails` is initialised at module load (eventmachine.rb:84) while `run` only
#      does `@tails ||= []` (eventmachine.rb:178) -- so a hook registered BEFORE the reactor starts
#      should survive into it. INFERENCE from source layout; NOT verified on this host (EM is not
#      installed). `at_exit` is registered as well precisely because this inference may be wrong.
#
# (F6) WINDOWS. `Thin.win?` gates the *nix-only signal set (server.rb:241), so on a Windows host
#      QUIT/HUP/USR1 would not be trapped and only INT/TERM would be. Shutdown coverage therefore
#      leans on at_exit as well as the EM hook -- both are registered.
#
# (F7) THE SERVING-CONTEXT GATE AND DEFERRED ACTIVATION  [ROUND 34, Codex blocker 2]
#      `install_for_worker!` is taken ONLY on AFFIRMATIVE, OBSERVED evidence that this process is
#      the serving process:
#        * `EventMachine.reactor_running?` is literally true (we are inside a live reactor), OR
#        * `::Thin` is defined AND an ObjectSpace scan finds a `::Thin::Server` whose `running?`
#          is literally true.
#      Absence of evidence, a `defined?` miss, a nil/false answer, or ANY raised error all mean
#      NOT PROVEN -- and NOT PROVEN routes to `install!`, which re-arms
#      `refuse_prefork_master!`. A preforking deployment therefore fails closed to 503 instead of
#      binding in a master. When EM exists but its reactor has not started yet (the normal
#      after_initialize case per F4), activation is deferred ONCE per process into
#      `EventMachine.next_tick`, where the gate can pass honestly.
#
# -------------------------------------------------------------------------------------------------
# WHAT THIS FILE GUARANTEES
# -------------------------------------------------------------------------------------------------
#   * NO PUMA API IS REFERENCED OR REQUIRED. The strings "on_worker_boot", "preload_app" and
#     "Puma::" appear in this file only inside this commentary.
#   * NO-OP unless `ENV['I3_READ_BINDING'] == 'live'` -- the same master switch, re-checked here so
#     this file cannot bind anything the switch did not authorise.
#   * IDEMPOTENT per process, under threads: a Mutex plus a pid-scoped `@activated_pid` guard, so a
#     double initializer run, a reloader, an eager-load, a deferred reactor callback or two
#     concurrent threaded requests cannot stack children.
#   * IT NEVER BYPASSES THE PREFORK REFUSAL WITHOUT EVIDENCE (F7).
#   * CHILD PIDS ARE COUNTED AND ATTRIBUTED, NEVER ASSUMED TO BE ONE. "At most one child per
#     process" holds per SUCCESSFUL install; a RETRY after a failed install can leave an earlier
#     child behind (i3_read_binding.rb:627-632 `abandon_child!` retains unconfirmed spawns in
#     `unreaped_spawns`, i3_read_binding.rb:647-650). So every pid this process has ever caused is
#     recorded in a LEDGER with its attribution and outcome, and `orphan_pids` PROBES liveness
#     instead of trusting a count -- and reports an UNPROVEN probe as a possible survivor.
#   * SHUTDOWN CALLS THE REAL STOP PATH: `I3ReadBindingInstaller.shutdown_owned_child!`
#     (i3_read_binding.rb:305-315) -> `Spawn#stop!`, whose `:confirmed` / `:unconfirmed` verdict is
#     propagated verbatim and never upgraded -- AND THEN ALWAYS SWEEPS RETAINED SPAWNS (see the
#     re-stop guarantee on `shutdown!`).
#   * IT NEVER SPAWNS ANYTHING ITSELF, so it cannot contradict the
#     `[interpreter, script]`-with-no-argv spawn contract.
# =================================================================================================

module Atomspace
  # Thin-2.0.1-compatible activation + shutdown for the I3 read binding.
  #
  # Deliberately a plain module with no Rails and no thin REQUIRE at load time: it is provable by a
  # bare-ruby harness, and it degrades to an explicit refusal (never an exception) when the
  # installer it drives is absent.
  module I3ThinLifecycle
    # The master switch's ONLY accepted value. Mirrors I3ReadBindingInstaller::LIVE
    # (i3_read_binding.rb:176); re-declared rather than referenced so this file is loadable and
    # testable before the installer exists.
    LIVE = "live"

    # Serialises activation and shutdown. Required because of (F3): under `--threaded` two
    # connections can run application code concurrently in ONE process.
    MUTEX = ::Mutex.new

    class << self
      # ---------------------------------------------------------------------------------------
      # ACTIVATION
      # ---------------------------------------------------------------------------------------

      # Install the binding for THIS serving process. This is the runtime caller
      # `install_for_worker!` never had.
      #
      # ENTRY-POINT SELECTION IS EVIDENCE-BASED (F7). This method does NOT assume it is running in
      # a post-fork serving process; it proves it or it fails closed.
      #
      # @param reason [String] free-text provenance for diagnostics (e.g. "after_initialize").
      # @return [Symbol] one of:
      #   :off                 -- master switch is not "live"; nothing was done, nothing logged.
      #   :already_active      -- this process already activated; NO new child was started.
      #   :activated           -- the installer reported a successful bind in this process.
      #   :refused             -- the installer declined (it already logged why; fail-closed =>
      #                           503). This INCLUDES the prefork-master refusal that is now
      #                           correctly reachable again, and the unproven-context case where
      #                           `install!` was deliberately chosen over the worker bypass.
      #   :deferred_to_reactor -- EventMachine exists but its reactor is not running yet, so the
      #                           serving context cannot be proven here (F4). Activation was
      #                           queued ONCE via `EventMachine.next_tick` and will re-enter this
      #                           method INSIDE the reactor, where the gate can pass. NOTHING is
      #                           bound yet; the port stays unwired (=> 503) until that callback
      #                           runs, and if it never runs the deployment stays fail-closed.
      #   :unavailable         -- the installer constant could not be loaded at all.
      def activate!(reason: "unspecified")
        return :off unless live?

        MUTEX.synchronize do
          return :already_active if @activated_pid == ::Process.pid

          outcome = perform_activation(reason)
          record_pids!(stage: "activate", reason: reason, outcome: outcome)
          outcome
        end
      end

      # ---------------------------------------------------------------------------------------
      # SHUTDOWN
      # ---------------------------------------------------------------------------------------

      # Stop the child this process owns, via the REAL stop path (F5 / i3_read_binding.rb:305),
      # AND THEN ALWAYS RE-STOP ANY RETAINED UNREAPED SPAWNS. Safe to call repeatedly, from an EM
      # shutdown hook, from at_exit, or by hand.
      #
      # THE RE-STOP GUARANTEE  [ROUND 34, Codex blocker 3]
      # `shutdown_owned_child!` returns `:not_owned` IMMEDIATELY whenever `@installed_pid` is not
      # this pid (i3_read_binding.rb:306) -- and `@installed_pid` is cleared by BOTH a failed
      # installation (`abandon_child!`, i3_read_binding.rb:630) and an UNCONFIRMED shutdown
      # (i3_read_binding.rb:311, which clears the pid regardless of verdict). In exactly those
      # cases the installer may still be holding live children in `unreaped_spawns`
      # (i3_read_binding.rb:647-650). Previously both hooks called ONLY
      # `shutdown_owned_child!`, so a `:not_owned` early return meant those retained children were
      # NEVER retried by either hook -- contradicting this method's own documented re-stop
      # guarantee. The sweep below therefore runs UNCONDITIONALLY, including when the verdict is
      # `:not_owned` and including when `shutdown_owned_child!` itself raised.
      #
      # The sweep is delegated to the installer's `retry_unreaped!` (owned by
      # config/initializers/i3_read_binding.rb, NOT implemented here). It is `respond_to?`-guarded
      # because this module must keep working against an installer that predates that API.
      #
      # @return [Symbol] :not_owned (nothing owned to stop / another pid owns it), :confirmed, or
      #   :unconfirmed. The installer's verdict is passed through UNCHANGED -- an unconfirmed stop
      #   is never reported as confirmed, and the sweep NEVER upgrades it either (a successful
      #   sweep of OTHER pids says nothing about THIS child's exit). Read `shutdowns` or `state`
      #   for the sweep result.
      def shutdown!(reason: "unspecified")
        inst = installer
        return :not_owned unless inst

        # NOT inside MUTEX#synchronize on purpose: this can run from an at_exit handler while
        # another thread holds the lock during activation, and deadlocking a process on its way out
        # is strictly worse than a racing stop -- `shutdown_owned_child!` is itself pid-guarded and
        # idempotent (i3_read_binding.rb:306), and `Spawn#stop!` is idempotent too.
        verdict =
          begin
            inst.shutdown_owned_child!
          rescue ::StandardError, ::ScriptError
            # Pass the fail-closed verdict through, but DO NOT skip the sweep below: a raising
            # owned-stop is precisely a case where children can be left behind.
            :unconfirmed
          end

        @activated_pid = nil if verdict == :confirmed

        # ALWAYS, and deliberately AFTER the owned stop so a newly-retained spawn from this very
        # shutdown is included in the sweep.
        sweep = sweep_unreaped!(inst)
        @last_sweep = sweep

        @shutdowns = shutdowns + [
          { pid: ::Process.pid, reason: reason, verdict: verdict, sweep: sweep }
        ]
        record_pids!(stage: "shutdown", reason: reason, outcome: verdict)
        verdict
      rescue ::StandardError, ::ScriptError
        # A shutdown path must never raise -- least of all out of an at_exit or an EM tail.
        :unconfirmed
      end

      # Register the shutdown hooks for this process. Idempotent, pid-scoped.
      #
      # TWO HOOKS, BOTH GROUNDED, BECAUSE NEITHER ALONE IS SUFFICIENT:
      #
      #   * `EventMachine.add_shutdown_hook` -- the in-reactor hook, drained by
      #     `EventMachine.stop` (eventmachine.rb:199-200), which is what thin's shutdown is
      #     understood to reach via `Backends::Base#stop!` (base.rb:96) from BOTH the graceful
      #     (server.rb:171) and forced (server.rb:187) paths (F5). Registering before the reactor
      #     boots should be safe (F5) -- INFERENCE, not verified here.
      #     It would NOT fire when thin was started inside someone else's reactor and
      #     `@started_reactor` is false (base.rb:96) -- which is why:
      #   * `at_exit` -- the backstop that also covers a non-signal exit, an exception unwinding
      #     boot, and the `@started_reactor == false` case. Pid-scoped because at_exit handlers are
      #     INHERITED by forked children.
      #
      # BOTH hooks call `shutdown!`, so BOTH now carry the re-stop guarantee (the retained-spawn
      # sweep), not just the owned-child stop.
      #
      # HONEST LIMIT (unchanged from the installer's own note): NEITHER hook runs on SIGKILL or a
      # hard crash, so the runbook's "check for a survivor" step stays necessary. `orphan_pids`
      # exists to make that check mechanical, and now errs toward reporting survivors.
      #
      # @return [Hash] which hooks are armed, e.g. {em: true, at_exit: true}
      def register_shutdown_hooks!
        MUTEX.synchronize do
          return hook_state if @hooks_pid == ::Process.pid

          @hooks_pid = ::Process.pid
          @em_hook = arm_em_hook
          @at_exit_hook = arm_at_exit_hook
          hook_state
        end
      end

      # ---------------------------------------------------------------------------------------
      # PID COUNTING AND ATTRIBUTION  (never "it is one child")
      # ---------------------------------------------------------------------------------------

      # Every reader-child pid this process has ever caused, with attribution.
      # @return [Array<Hash>] {pid:, owner_pid:, stage:, reason:, outcome:, source:, entry:}
      def pid_ledger
        @pid_ledger ||= []
      end

      # @return [Array<Integer>] distinct reader-child pids seen, in first-seen order.
      def observed_child_pids
        pid_ledger.map { |e| e[:pid] }.uniq
      end

      # @return [Integer] how many distinct reader children this process has caused. Can exceed 1
      #   legitimately: a failed install that could not confirm its child's exit is retained in
      #   `unreaped_spawns` and a RETRY starts another.
      def observed_child_count
        observed_child_pids.size
      end

      # WHICH OBSERVED PIDS MIGHT STILL BE RUNNING. This is a probe, not a belief, and it FAILS
      # CLOSED.  [ROUND 34, Codex blocker 4]
      #
      # Includes every pid whose liveness is `:alive` OR `:unknown`, and excludes ONLY `:gone`.
      # `:gone` is produced solely by `Errno::ESRCH`, which is the only EVIDENCE OF ABSENCE this
      # module accepts. An unexpected probe error (`:unknown`) is REPORTED AS A POSSIBLE SURVIVOR
      # ON PURPOSE: the previous boolean probe collapsed "the probe broke" into "the process is
      # gone", so a surviving child could be silently omitted from the orphan report with no
      # evidence that it had exited. Over-reporting costs an operator one `ps`; under-reporting
      # loses a live process.
      #
      # Use `alive_pids` for the PROVEN-alive subset and `unknown_liveness_pids` for the unproven
      # one when a runbook needs to tell them apart.
      #
      # @return [Array<Integer>] proven-alive plus unproven pids (fail-closed superset).
      def orphan_pids
        observed_child_pids.reject { |pid| liveness(pid) == :gone }
      end

      # @return [Array<Integer>] pids PROVEN alive by a successful `kill(0)` or an `EPERM`
      #   (alive but owned by another user). Strictly a subset of `orphan_pids`.
      def alive_pids
        observed_child_pids.select { |pid| liveness(pid) == :alive }
      end

      # @return [Array<Integer>] pids whose liveness could NOT be determined -- an unexpected
      #   probe error, or a pid that is not a positive Integer. These are counted as possible
      #   survivors in `orphan_pids`; there is NO evidence they exited.
      def unknown_liveness_pids
        observed_child_pids.select { |pid| liveness(pid) == :unknown }
      end

      # TRI-STATE LIVENESS PROBE. Signal 0 tests existence without delivering anything.
      #
      # @param pid [Object] the pid to probe; anything that is not a positive Integer is `:unknown`
      #   (NOT `:gone` -- a malformed pid is not evidence that a process exited).
      # @return [Symbol]
      #   :alive   -- `kill(0)` succeeded, or raised `EPERM` (the process exists but is not ours).
      #   :gone    -- `Errno::ESRCH`. THE ONLY EVIDENCE OF EXIT this module accepts.
      #   :unknown -- any other error (ENOSYS, EINVAL, a NotImplementedError on an exotic
      #               platform, a stubbed/odd `Process.kill`), or a non-positive / non-Integer pid.
      #               Callers MUST treat this as "may still be running".
      def liveness(pid)
        return :unknown unless pid.is_a?(::Integer) && pid.positive?

        ::Process.kill(0, pid)
        :alive
      rescue ::Errno::ESRCH
        :gone
      rescue ::Errno::EPERM
        :alive
      rescue ::StandardError, ::ScriptError
        :unknown
      end

      # @return [Array<Hash>] every shutdown verdict recorded in this process, each with the
      #   retained-spawn sweep result that accompanied it.
      def shutdowns
        @shutdowns ||= []
      end

      # @return [Array<Hash>] one row per activation attempt in this process:
      #   {pid:, reason:, entry:, serving_context_proven:, outcome:}. `entry` is the installer
      #   entry point actually used (`:install!`, `:install_for_worker!`, or `:none` when the
      #   attempt was deferred or short-circuited), which is the reviewable record that the
      #   prefork refusal was not bypassed without evidence (F7).
      def activation_attempts
        @activation_attempts ||= []
      end

      # ---------------------------------------------------------------------------------------
      # DIAGNOSTICS
      # ---------------------------------------------------------------------------------------

      # @return [Integer, nil] the pid that activated, or nil.
      def activated_pid
        @activated_pid
      end

      # @return [Integer, nil] the pid that queued a deferred reactor activation, or nil. Deferral
      #   happens at most ONCE per process, so a second unproven activate! cannot loop.
      def deferred_pid
        @deferred_pid
      end

      # DECLARE THIS PROCESS A POST-FORK SERVING WORKER  [CPD-035 FIX 2].
      #
      # The ONLY sanctioned way to assert a serving context when no live `Thin::Server` object can
      # be observed. Call it from an `on_worker_boot`-style hook, which by construction executes IN
      # the worker, AFTER the fork -- the one place where "this process will serve requests" is a
      # fact and not an inference. A bare running EventMachine reactor NO LONGER counts as proof
      # (see `thin_serving_context?`), because an unrelated reactor can be running in a prefork
      # MASTER and would have bypassed the installer's prefork refusal.
      #
      # Pid-scoped so it cannot be inherited: if this process later forks, the child's
      # `Process.pid` no longer matches and the child is unproven again.
      #
      # @return [Integer] the pid now marked.
      def post_fork!
        @post_fork_pid = ::Process.pid
      end

      # @return [Integer, nil] the pid explicitly marked as post-fork/serving, or nil.
      def post_fork_pid
        @post_fork_pid
      end

      # The ACTUAL process/thread model, read off the live thin objects rather than guessed from
      # WEB_CONCURRENCY (F2). All lookups are `defined?`-guarded so this works with no thin loaded.
      # @return [Hash]
      def thin_facts
        facts = {
          thin_loaded: defined?(::Thin) ? true : false,
          # In thin 2.0.1 `Thin::VERSION` is documented as a plain String (version.rb:6), NOT a
          # module with a ::STRING constant the way some servers define it. Handle both so this
          # probe cannot raise on a future layout.
          thin_version: thin_version_string,
          win: (::Thin.win? ? true : false if defined?(::Thin) && ::Thin.respond_to?(:win?)),
          em_loaded: defined?(::EventMachine) ? true : false,
          em_reactor_running: em_reactor_running?,
          # WEB_CONCURRENCY is reported ONLY so a reviewer can see which installer entry point the
          # gate selected and why. Nothing in this file branches on it; the REFUSAL it drives lives
          # in the installer (i3_read_binding.rb:546) and is now reachable again (F7).
          web_concurrency_env_present: !ENV["WEB_CONCURRENCY"].nil?,
          # [CPD-035 FIX 2] A running reactor is REPORTED but is no longer, on its own, proof.
          post_fork_marked: post_fork_marked?,
          serving_context_proven: thin_serving_context?
        }
        facts.merge(live_server_facts)
      rescue ::StandardError, ::ScriptError
        { thin_loaded: false, error: true }
      end

      # @return [Hash] everything a reviewer or a runbook needs, with no secrets in it.
      def state
        {
          live: live?,
          activated_pid: @activated_pid,
          deferred_pid: @deferred_pid,
          process_pid: ::Process.pid,
          hooks: hook_state,
          observed_child_count: observed_child_count,
          observed_child_pids: observed_child_pids,
          # FAIL-CLOSED SUPERSET: proven-alive + unproven. See `orphan_pids`.
          orphan_pids: orphan_pids,
          alive_pids: alive_pids,
          unknown_liveness_pids: unknown_liveness_pids,
          shutdowns: shutdowns,
          last_unreaped_sweep: @last_sweep,
          activation_attempts: activation_attempts,
          installer_installed_pid: (installer&.installed_pid),
          installer_unreaped: (installer ? installer.unreaped_spawns.size : nil),
          thin: thin_facts
        }
      end

      # Reset THIS module's bookkeeping. For harnesses only; never called by the initializer.
      def reset_for_test!
        @activated_pid = nil
        @deferred_pid = nil
        @post_fork_pid = nil
        @hooks_pid = nil
        @em_hook = nil
        @at_exit_hook = nil
        @pid_ledger = []
        @shutdowns = []
        @activation_attempts = []
        @last_sweep = nil
        nil
      end

      private

      def live?
        ENV["I3_READ_BINDING"] == LIVE
      end

      # @return [String, nil] thin's version, tolerating both the 2.0.1 String layout
      #   (version.rb:6) and a VERSION::STRING module layout.
      def thin_version_string
        return nil unless defined?(::Thin::VERSION)

        v = ::Thin::VERSION
        return v if v.is_a?(::String)

        v.const_get(:STRING) if v.respond_to?(:const_get) && v.const_defined?(:STRING)
      rescue ::StandardError, ::ScriptError
        nil
      end

      # @return [Module, nil] the installer, or nil when it is not loadable. Never raises: a
      #   missing installer must degrade to a refusal, not crash boot.
      def installer
        return ::Atomspace::I3ReadBindingInstaller if defined?(::Atomspace::I3ReadBindingInstaller)

        nil
      end

      # THE ACTIVATION ITSELF -- EVIDENCE-GATED (F7).
      #
      # Entry-point policy, in order:
      #   1. serving context PROVEN  -> `install_for_worker!` (the bypass is earned: we are
      #      demonstrably in a live serving/reactor process, so the child belongs to us alone).
      #   2. not proven, EM present, reactor not started yet -> DEFER once into the reactor, where
      #      the proof can exist (F4). Nothing is bound; the port stays unwired meanwhile.
      #   3. not proven and no reactor to wait for -> `install!`, WHICH RE-ARMS
      #      `refuse_prefork_master!` (i3_read_binding.rb:327/526). Under a preforking topology
      #      this refuses and the deployment stays at 503 -- the correct fail-closed outcome, and
      #      the whole point of Codex blocker 2.
      def perform_activation(reason)
        inst = installer
        return :unavailable unless inst
        return :unavailable unless inst.respond_to?(:install_for_worker!)
        return :unavailable unless inst.respond_to?(:install!)

        # Hooks are armed BEFORE the install so a child that starts and then fails its binding is
        # still covered by a shutdown path (the installer's own `abandon_child!` handles the normal
        # case, i3_read_binding.rb:627, but an unconfirmed stop leaves a live pid behind and this
        # module must still be able to report and re-stop it).
        arm_hooks_unlocked!

        proven = thin_serving_context?

        if !proven && defer_to_reactor!(reason)
          note_attempt!(reason: reason, entry: :none, proven: proven,
                        outcome: :deferred_to_reactor)
          return :deferred_to_reactor
        end

        entry = proven ? :install_for_worker! : :install!
        bound = inst.public_send(entry)
        outcome = bound ? :activated : :refused
        note_attempt!(reason: reason, entry: entry, proven: proven, outcome: outcome)

        if outcome == :activated
          @activated_pid = ::Process.pid
          log(:info,
              "[i3_thin_activation] I3 read binding ACTIVATED for this serving process " \
              "(pid=#{::Process.pid}, trigger=#{reason}, entry=#{entry}, " \
              "serving_context_proven=#{proven}).")
        else
          # The installer has ALREADY logged the specific fail-closed reason without leaking any
          # config value (i3_read_binding.rb:486-493 / 526-540). Do not restate or guess it here.
          log(:warn,
              "[i3_thin_activation] the installer DECLINED to bind on the #{entry} path " \
              "(serving_context_proven=#{proven}); the I3 read port is left UNWIRED and every I3 " \
              "route will answer 503. The installer has already logged the specific reason.")
        end
        outcome
      rescue ::StandardError, ::ScriptError => e
        # CLASS ONLY -- a message can echo an interpolated path or config value.
        log(:warn,
            "[i3_thin_activation] activation aborted by #{e.class}; the I3 read port is left " \
            "UNWIRED and every I3 route will answer 503.")
        :refused
      end

      # POSITIVE EVIDENCE that this process is the one serving requests (F7). Returns true ONLY on
      # an affirmative observation; absence, nil/false, a `defined?` miss or ANY raised error all
      # return false, because the consequence of a false positive is binding in a preforking
      # master and corrupting the line protocol.
      #
      # *** TIGHTENED IN CPD-035 (Codex blocker 2) *** This method USED TO return true on
      # `em_reactor_running? == true` ALONE. That was unsound: EventMachine is a general-purpose
      # reactor and ANY unrelated library can have one running -- including inside a PREFORK
      # MASTER that has not forked yet. A reactor owned by something that is not this app's HTTP
      # server is NOT evidence that this process serves requests, yet it made `proven` true at
      # :528, selected `install_for_worker!` at :536, and so bypassed the installer's
      # `refuse_prefork_master!` -- exactly the refusal that prevents binding in a master and
      # leaking inherited pipes into every worker.
      #
      # A BARE RUNNING REACTOR IS NO LONGER SUFFICIENT. Proof now requires one of:
      #   (a) a live `Thin::Server` that reports `running?` true -- an actual serving object, which
      #       also covers thin running inside someone else's already-running reactor; or
      #   (b) an EXPLICIT post-fork marker (`post_fork_marked!`, set by an `on_worker_boot`-style
      #       hook that by construction runs IN the worker, after the fork).
      #
      # STRICTLY NARROWER THAN BEFORE: every input that used to answer false still answers false,
      # and the only inputs whose answer CHANGED (reactor running, no serving object, no marker)
      # now answer FALSE -- i.e. they fall through to the fail-closed `install!` path at :536,
      # which keeps `refuse_prefork_master!` armed. No new path can reach the bypass. The reactor
      # probe is still used, but only by `defer_to_reactor!` (to decide WHEN to re-ask) and by the
      # diagnostics in `report`, never as authorization on its own.
      #
      # @return [Boolean]
      def thin_serving_context?
        # (b) An explicit post-fork/serving declaration from an integration hook. Affirmative by
        #     construction: only code that KNOWS it runs in the post-fork worker sets it, and it is
        #     scoped to the pid that set it so it cannot be inherited across a later fork.
        return true if post_fork_marked?

        # (a) A live Thin::Server object that reports `running?` true -- a real serving object in
        #     THIS process, not merely a reactor someone else is running.
        return false unless defined?(::Thin)

        facts = live_server_facts
        facts[:thin_server_found] == true && facts[:thin_running] == true
      rescue ::StandardError, ::ScriptError
        false # FAIL CLOSED: unproven is not proven.
      end

      # @return [Boolean] true ONLY when THIS pid was explicitly marked as post-fork/serving.
      #   Pid-scoped on purpose: a marker set in a master would otherwise be inherited by every
      #   forked worker (and vice versa), which is the same inheritance bug in a new place.
      def post_fork_marked?
        @post_fork_pid == ::Process.pid
      rescue ::StandardError, ::ScriptError
        false
      end

      # @return [Boolean, nil] true/false when EventMachine can answer, nil when EM is absent or
      #   the probe failed. Never raises.
      def em_reactor_running?
        return nil unless defined?(::EventMachine)
        return nil unless ::EventMachine.respond_to?(:reactor_running?)

        ::EventMachine.reactor_running? ? true : false
      rescue ::StandardError, ::ScriptError
        nil
      end

      # QUEUE ACTIVATION INTO THE REACTOR, AT MOST ONCE PER PROCESS (F4/F7).
      #
      # Called with MUTEX held. Registering a `next_tick` callback here is safe: the callback runs
      # later, on the reactor thread, with the lock released, and it re-enters `activate!` whose
      # own pid guard makes a double-activation impossible.
      #
      # The once-per-process `@deferred_pid` guard is what prevents an infinite defer loop: if the
      # callback runs and the context STILL cannot be proven, the second pass falls through to
      # `install!` and fails closed instead of re-queueing forever.
      #
      # @return [Boolean] true when a deferral was registered (caller should return
      #   :deferred_to_reactor); false when deferral is impossible or already used.
      def defer_to_reactor!(reason)
        return false if @deferred_pid == ::Process.pid
        return false unless defined?(::EventMachine)

        hook = %i[next_tick add_timer].find { |m| ::EventMachine.respond_to?(m) }
        return false unless hook
        # Only defer while the reactor has NOT started. If it is already running, the gate above
        # had its chance and we must not postpone a decision we can make now.
        return false unless em_reactor_running? == false

        owner = ::Process.pid
        @deferred_pid = owner
        callback = proc do
          begin
            if ::Process.pid == owner
              ::Atomspace::I3ThinLifecycle.activate!(reason: "em_deferred:#{reason}")
            end
          rescue ::StandardError, ::ScriptError
            nil # a deferred activation must never raise inside the reactor.
          end
        end

        if hook == :next_tick
          ::EventMachine.next_tick(&callback)
        else
          ::EventMachine.add_timer(0, &callback)
        end
        log(:info,
            "[i3_thin_activation] activation DEFERRED into the EventMachine reactor " \
            "(pid=#{::Process.pid}, trigger=#{reason}): a serving process cannot be proven at " \
            "initializer time, and binding without that proof would bypass the installer's " \
            "prefork-master refusal. The I3 read port stays UNWIRED (=> 503) until the reactor " \
            "callback runs.")
        true
      rescue ::StandardError, ::ScriptError
        @deferred_pid = nil # a failed registration must not consume the one deferral.
        false
      end

      # Record WHICH installer entry point an attempt used, so a reviewer can verify the bypass
      # was only taken on evidence (F7). Never raises.
      def note_attempt!(reason:, entry:, proven:, outcome:)
        activation_attempts << {
          pid: ::Process.pid, reason: reason, entry: entry,
          serving_context_proven: (proven ? true : false), outcome: outcome
        }
        @last_entry = entry
        nil
      rescue ::StandardError, ::ScriptError
        nil
      end

      # THE RETAINED-SPAWN SWEEP (the re-stop guarantee; Codex blocker 3).
      #
      # Delegates to the installer's `retry_unreaped!`, which is owned by
      # config/initializers/i3_read_binding.rb and documented to: sweep `unreaped_spawns`, call
      # `stop!` on each, remove ONLY the `:confirmed` ones, never raise, and work when
      # `@installed_pid` is nil or foreign. That last property is exactly why this sweep is safe
      # to run after a `:not_owned` verdict.
      #
      # `respond_to?`-guarded on purpose: this module must not break against an installer that
      # predates the API. A missing API is REPORTED (`attempted: false, reason: :no_api`), never
      # silently treated as a successful sweep.
      #
      # @return [Hash] a names-only record of what the sweep did; never raises.
      def sweep_unreaped!(inst)
        return { attempted: false, reason: :no_installer } unless inst
        unless inst.respond_to?(:retry_unreaped!)
          return { attempted: false, reason: :no_api }
        end

        result = inst.retry_unreaped!
        unless result.is_a?(::Hash)
          return { attempted: true, reason: :malformed_result }
        end

        { attempted: true, confirmed: result[:confirmed], remaining: result[:remaining] }
      rescue ::StandardError, ::ScriptError => e
        # CLASS ONLY, and the verdict above is NOT downgraded or upgraded because of this.
        { attempted: true, reason: :error, error_class: e.class.name }
      end

      # Called with MUTEX already held.
      def arm_hooks_unlocked!
        return hook_state if @hooks_pid == ::Process.pid

        @hooks_pid = ::Process.pid
        @em_hook = arm_em_hook
        @at_exit_hook = arm_at_exit_hook
        hook_state
      end

      # The in-reactor hook (F5). Returns false when EM is absent, which is a fact worth reporting
      # rather than an error worth raising.
      def arm_em_hook
        return false unless defined?(::EventMachine)
        return false unless ::EventMachine.respond_to?(:add_shutdown_hook)

        owner = ::Process.pid
        ::EventMachine.add_shutdown_hook do
          ::Atomspace::I3ThinLifecycle.shutdown!(reason: "em_shutdown_hook") if ::Process.pid == owner
        rescue ::StandardError, ::ScriptError
          nil
        end
        true
      rescue ::StandardError, ::ScriptError
        false
      end

      def arm_at_exit_hook
        owner = ::Process.pid
        at_exit do
          ::Atomspace::I3ThinLifecycle.shutdown!(reason: "at_exit") if ::Process.pid == owner
        rescue ::StandardError, ::ScriptError
          nil
        end
        true
      rescue ::StandardError, ::ScriptError
        false
      end

      def hook_state
        { em: (@em_hook || false), at_exit: (@at_exit_hook || false), pid: @hooks_pid }
      end

      # Harvest pids from the installer AFTER every activation or shutdown, from BOTH the owned
      # spawn and the retained-unconfirmed list, so a retry's leftovers are attributed too.
      def record_pids!(stage:, reason:, outcome:)
        inst = installer
        return unless inst

        harvest = []
        owned = (inst.owned_spawn if inst.respond_to?(:owned_spawn))
        harvest << [owned, "owned_spawn"] if owned
        if inst.respond_to?(:unreaped_spawns)
          inst.unreaped_spawns.each { |s| harvest << [s, "unreaped_spawns"] }
        end

        harvest.each do |spawn, source|
          pid = (spawn.pid if spawn.respond_to?(:pid))
          next unless pid.is_a?(::Integer)
          next if pid_ledger.any? { |e| e[:pid] == pid && e[:stage] == stage && e[:source] == source }

          pid_ledger << {
            pid: pid, owner_pid: ::Process.pid, stage: stage,
            reason: reason, outcome: outcome, source: source, entry: @last_entry
          }
        end
        nil
      rescue ::StandardError, ::ScriptError
        nil # bookkeeping must never break activation or shutdown.
      end

      # BOOLEAN VIEW of `liveness`, kept only for callers that genuinely need a predicate.
      # FAIL-CLOSED: anything that is not PROVEN gone counts as possibly alive, so `:unknown`
      # answers true. Never use `== :alive` here -- that is the Codex blocker 4 bug.
      # @return [Boolean] true unless the process is PROVEN gone (`Errno::ESRCH`).
      def process_alive?(pid)
        liveness(pid) != :gone
      end

      # Read the real model off any live Thin::Server (F1/F3/F4). ObjectSpace is used because thin
      # keeps no registry of servers; it is guarded and never required for correctness.
      #
      # `thin_running` is one of the two affirmative signals `thin_serving_context?` accepts, so
      # this method must keep returning literal true/false (never a truthy object) for it.
      def live_server_facts
        return { thin_server_found: false } unless defined?(::Thin::Server)
        return { thin_server_found: false } unless defined?(::ObjectSpace)

        server = nil
        ::ObjectSpace.each_object(::Thin::Server) { |s| server = s }
        return { thin_server_found: false } unless server

        backend = (server.backend if server.respond_to?(:backend))
        {
          thin_server_found: true,
          thin_threaded: (server.threaded? if server.respond_to?(:threaded?)),
          thin_running: (server.running? ? true : false if server.respond_to?(:running?)),
          thin_started_reactor: (backend.started_reactor? if backend.respond_to?(:started_reactor?)),
          thin_backend: backend.class.name
        }
      rescue ::StandardError, ::ScriptError
        { thin_server_found: false }
      end

      def log(level, message)
        logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
        logger&.public_send(level, message)
      rescue ::StandardError
        nil # logging must never be the thing that breaks boot.
      end
    end
  end
end
