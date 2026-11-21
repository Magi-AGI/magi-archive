# frozen_string_literal: true

# =================================================================================================
# PRODUCTION BOOT WIRING FOR THE I3 READ PORT  (the one real Decko-side gap)
# =================================================================================================
#
# WHAT THIS BINDS. Exactly one thing: `Atomspace::I3ReadPort`, with a
# `Atomspace::LocalI3ReadBinding` wrapping a `Atomspace::I2ReaderProcessClient` that speaks the I2
# line protocol over the stdin/stdout of ONE child process started by
# `Atomspace::I2StdioTransport::Spawn`. Origin stamped on every response is
# `LocalI3ReadBinding::ORIGIN_LIVE` ("live").
#
# WHY THIS FILE HAS TO EXIST. `LocalI3ReadBinding.install!`
# (mod/mcp_api/lib/atomspace/local_i3_read_binding.rb:117-131) had ZERO callers outside spec/.
# `I3ReadPort.impl` was therefore nil in every real boot, `I3ReadPort.readiness` returned
# not_ready("i3_read_port_unwired") (i3_read_port.rb:62) and every I3 route answered 503. This is
# an app-level initializer and NOT a mod initializer because Decko does NOT load files placed under
# mod/*/config/initializers (same constraint documented in config/initializers/
# atomspace_read_client.rb:3-6), and mod lib is not autoloaded -- hence the explicit requires below.
#
# REQUIRED ENV VARS -- ALL of them, NO defaults, NO discovery, NO PATH search:
#
#   I3_READ_BINDING        MASTER SWITCH. Must be exactly "live". Unset or any other value =>
#                          this file does NOTHING and the port stays unwired (=> 503).
#   I3_I2_INTERPRETER      ABSOLUTE path to a CPython interpreter that can import `hyperon` AND
#                          `atomspace_mirror_sidecar` (whose package __init__ imports `hyperon`
#                          transitively via .apply). THE REQUIREMENT IS THE IMPORT, NOT A VERSION:
#                          this file asserts NO version and performs NO version check, because the
#                          deployable interpreter differs per host and an equality pin on any one
#                          minor version would refuse a working deployment.
#                          THE CONTRACT IS `requires-python >= 3.10` WITH `hyperon == 0.2.10`.
#                          The BASELINE DEMONSTRATED for that pairing is Python 3.11.15 with
#                          hyperon 0.2.10. Any interpreter satisfying the contract whose
#                          environment carries hyperon is acceptable.
#                          NO HOST'S INTERPRETER VERSION IS ASSERTED AS VERIFIED HERE. A source
#                          comment is not evidence: an interpreter is only established as working
#                          by an actual import on that host, which this file neither performs nor
#                          records. Whatever the per-host path turns out to be, it must be supplied
#                          explicitly by the operator.
#                          Fail-closed is unchanged and is the ONLY gate: a blank, RELATIVE,
#                          missing, non-regular or unreadable path is refused by the canonical
#                          launcher guard below (`refuse_interpreter_reason`), and an interpreter
#                          that cannot import the package fails the spawn, which the rescue turns
#                          into an UNWIRED port (=> 503). Never a PATH search.
#   I3_I2_SCRIPT           ABSOLUTE path to STORE's OWN launcher, which is
#                          <I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py in the
#                          av-store-sidecar worktree. See "WHICH SCRIPT" below: it is NOT the
#                          deck's own tools/i2_stdio_reader_server.py.
#                          IDENTITY IS NOW ENFORCED ON BOTH AXES -- PATH **AND** CONTENT. The
#                          resolved realpath must be EXACTLY
#                          <realpath of I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py
#                          (`refuse_script_reason` / `containment_refusal_for`), so a readable file
#                          that merely SHARES the canonical basename but lives anywhere else -- an
#                          attacker-writable directory, a sibling checkout, a junction/symlink
#                          pointing out of the approved tree -- is REFUSED. Both sides of that
#                          comparison are realpaths, so link indirection cannot smuggle a path in.
#   I3_STORE_SIDECAR_PATH  ABSOLUTE path to the directory CONTAINING atomspace_mirror_sidecar/.
#                          It is ALSO the containment root for I3_I2_SCRIPT (see above): the only
#                          launcher this binding will start is <this>/tools/<canonical basename>.
#   I3_I2_SCRIPT_SHA256    MANDATORY content pin for I3_I2_SCRIPT: 64 LOWERCASE hex characters,
#                          the SHA-256 of the approved launcher file. ABSENT OR BLANK IS A
#                          REFUSAL -- it is no longer opt-in. Path containment alone cannot prove
#                          WHAT the approved path contains (a file inside the sidecar tree can be
#                          rewritten in place), so the content pin is the other half of launcher
#                          identity and both must hold.
#                          THE CURRENTLY-APPROVED VALUE, from the STORE lane's round-033 bundle
#                          MANIFEST.json entry `tools/i2_stdio_reader_service.py`, is
#                          46b0f687c02b8e5df078a3bea4b7322149019c79939782ca607528d09cd52f88 .
#                          IT IS DELIBERATELY NOT HARDCODED IN THIS FILE. It is cited here as
#                          documentation only and must be supplied by the OPERATOR via the env
#                          var, so that re-approving a new launcher build is an operator decision
#                          recorded in the deployment environment -- never an edit to this file
#                          that would silently re-bless whatever the tree happens to contain.
#   I3_I2_CONFIG           The AV_I2_STDIO_CONFIG JSON, VERBATIM. STORE's service closes the
#                          top-level document at exactly {"page-max":{...},"fanout-limit",
#                          "retention":{"positions","ms"},"store-projection"}
#                          (i2_stdio_service.py:116 CONFIG_KEYS), and "page-max" is STORE's own
#                          key tuple (i2_stdio_service.py:117). I2Config has no defaults
#                          (i2_read.py:120), so neither does this.
#   I3_I2_DEADLINE_MS      Positive Integer. This client's own wait budget.
#
# WHICH SCRIPT I3_I2_SCRIPT MUST NAME -- there are TWO stdio readers in this workspace and only one
# of them can project a card:
#
#   * av-store-sidecar/tools/i2_stdio_reader_service.py  <== THIS ONE. STORE's launcher
#     (i2_stdio_reader_service.py:1-16, :48 "hands over to i2_stdio_service.main()"). Its service
#     module `atomspace_mirror_sidecar/i2_stdio_service.py` is the ONLY one that implements the
#     projection: it accepts the `store-projection` config block and loads one real card from an
#     attested on-disk payload (i2_stdio_service.py:46-61, :116, :274-275, :301-315), and it
#     exposes the coverage disclosure through the STORE-local `store-projection` operation
#     (i2_stdio_service.py:113-114, :519). It is also the script the Spawn contract was written
#     against (i2_stdio_service.py:5-9) and the one the rollback runbook hunts for by name.
#   * av-view-deck/tools/i2_stdio_reader_server.py       <== NOT THIS ONE. It is VIEW's own MODEL
#     server (STORE calls it exactly that: "VIEW's model server",
#     i2_stdio_service.py:17, :31). It has NO `store-projection` support at all: its config is
#     passed straight to `I2Config.from_mapping` (i2_stdio_reader_server.py:112) and the only way
#     it ever gets state is the explicitly operator-only `--seed-from-golden-vectors` flag
#     (:289-339, "NOT DEV data"), which `Spawn#start!` CANNOT pass because it runs exactly
#     `[interpreter, script]` with no argv (i2_stdio_transport.rb:314-316). Pointed at by
#     I3_I2_SCRIPT it therefore serves an EMPTY store -- "not ready" forever.
#
#   The path is still the OPERATOR's to state. This file does no discovery and no PATH search; it
#   only refuses a relative path. Naming the wrong script is NOT guaranteed to produce a spawn
#   failure, a contract violation or a crash: the child can start and the binding can install, but
#   with no store-projection support and no way to pass --seed-from-golden-vectors, the reader is
#   permanently NOT READY over an EMPTY store -- i.e. UNSUITABLE FOR PROJECTION (reads answer 503),
#   not a crash that announces itself. That is exactly why it is spelled out here.
#
# FAIL-CLOSED IN EVERY FAILURE MODE. Switch unset/not "live", any missing or blank or RELATIVE
# path, unparseable or non-object I3_I2_CONFIG, a non-positive deadline, a preforking deployment
# that has not wired the per-worker hook, a spawn failure, a client that cannot be built, a
# declined binding, or ANY raised exception whatsoever => a warning is logged WITHOUT any config
# value in it, the port is left RESET (unwired, => 503), and boot CONTINUES. It never binds a
# partial or degraded impl, and it never re-raises so as to crash a worker into a restart loop --
# but it also never swallows an error into a BOUND state: every rescue path calls
# `I3ReadPort.reset!` before returning.
#
# IT NEVER FALLS BACK TO FIXTURES. `Atomspace::FixtureI3ReadPort` is not required, not referenced,
# not named and NOT REACHABLE from this file. There is no test/golden/fixture/sample/demo fallback
# of any kind, and no environment check that would select one. The string "Fixture" does not appear
# anywhere in this file outside this paragraph and the two assertions about it, and
# spec/mcp_api/i3_binding_initializer_harness.rb test 7 scans this file's own source text to keep
# that true. An absent or broken backend yields 503, never synthetic data.
#
# -------------------------------------------------------------------------------------------------
# OPERATOR STEPS REQUIRED -- THIS FILE CANNOT DO THEM AND DOES NOT PRETEND TO
# -------------------------------------------------------------------------------------------------
#
# (1) PUMA PREFORK. `config/puma.rb:1` is `workers Integer(ENV["WEB_CONCURRENCY"] || 0)` and
#     `config/puma.rb:6` is `preload_app!`. Under that pair, `after_initialize` runs in the Puma
#     MASTER and every forked worker INHERITS both the bound port and the master's pipe FDs without
#     ever calling `install!` -- so two or more workers would interleave newline-delimited frames on
#     ONE child's stdin and corrupt the protocol. The `@installed_pid` guard alone does NOT fix
#     this, because under preloading nothing in the worker calls `install!` at all.
#
#     So this file REFUSES to bind from the `after_initialize` path whenever WEB_CONCURRENCY names
#     a preforking deployment (anything other than an explicit 0 or unset -- an UNPARSEABLE value
#     is treated as preforking, the fail-closed direction). The result is an unwired port and a 503,
#     never a shared pipe. The operator must apply ONE of these TWO -- there is no third option:
#
#       (a) add the per-worker hook to config/puma.rb (NOT EDITED BY THIS CHANGE -- puma.rb is a
#           tracked deployment file and an operator applies it):
#
#               on_worker_boot do
#                 Atomspace::I3ReadBindingInstaller.install_for_worker!
#               end
#
#           `install_for_worker!` is the explicit per-worker entry point: it disowns any inherited
#           claim first (resetting the port rather than serving over the parent's pipes) and then
#           starts THIS worker's own child -- one child per worker, no sharing.
#
#       (b) or run single-process: `WEB_CONCURRENCY=0` (or leave it unset), in which case the
#           `after_initialize` path binds normally because there is no fork.
#
#     SUPERSEDED / INVALID -- DO NOT FOLLOW: "remove `preload_app!` so each worker boots the app
#     itself". That was once listed here as a third option (c) and it does NOT work: the refusal
#     above keys off WEB_CONCURRENCY (`prefork_configured?` reads only PREFORK_CONCURRENCY_ENV),
#     NOT off `preload_app!`. With WEB_CONCURRENCY>0 the `after_initialize` path still refuses even
#     with `preload_app!` removed, so the port stays UNWIRED and every I3 route keeps answering 503.
#     Only (a) and (b) above are valid. (The warning string in `refuse_prefork_master!` HAS NOW
#     BEEN CORRECTED to name exactly these two remedies and to state explicitly that dropping
#     preload_app! is not one of them; that message text is executable Ruby and was updated by the
#     change authorized to touch executable code.)
#
#     DEFENCE IN DEPTH, for the case where a binding is inherited anyway (an operator forks by some
#     other route): `ensure_owned_binding!` resets the port whenever the recorded installing pid is
#     not `Process.pid`. HONEST LIMIT: this file cannot arm that guard on the request path -- it
#     would have to be called from the serving code, which this change does not modify. It is
#     called by `install_for_worker!` and by `install!`, so (a) makes it effective; without (a),
#     option (b) is the safe configuration.
#
# (2) SHUTDOWN OF THE OWNED CHILD. `Spawn#stop!` (i2_stdio_transport.rb:358-401) is the real
#     shutdown API and it returns `:confirmed` / `:unconfirmed`. Nothing used to connect it to
#     process exit, so the rollback runbook's claim that "restarting Rails normally reaps it" was
#     not true of anything in this file. It is now: a successful bind registers an `at_exit` hook,
#     scoped to the installing pid (at_exit handlers are inherited by forks, so the hook is a no-op
#     in any process that does not own the child), which calls `shutdown_owned_child!`.
#     HONEST LIMIT: `at_exit` does NOT run on SIGKILL or a hard crash, so the runbook's
#     "check for a survivor" step remains necessary. A stop whose verdict is `:unconfirmed` keeps
#     the Spawn in `unreaped_spawns` rather than dropping the only reference to a live process.
#
#     RE-STOP OF AN UNCONFIRMED CHILD. Retaining the reference was only half the guarantee: until
#     `retry_unreaped!` existed, nothing ever stopped a retained Spawn a SECOND time. A failed
#     install clears `@installed_pid`, after which `shutdown_owned_child!` answers `:not_owned`
#     forever, so the retained child could never be re-stopped by any path in this file.
#     `retry_unreaped!` is the public sweep that closes that gap: it re-`stop!`s every retained
#     Spawn, drops only the ones that answer `:confirmed`, never raises, and is safe to call
#     repeatedly from `at_exit`, an EventMachine shutdown hook, or an operator console.
#
# REAL DATA: AN ATTESTED EXPORT NOW EXISTS, BUT READ THIS BEFORE BELIEVING A GREEN READINESS.
# Wiring this port is necessary but NOT sufficient to serve real card data. The Python child
# additionally requires a `store-projection` block in its config to project an actual card. That
# block's `attested-card-export` kind IS now satisfiable: an attested export captured from Magi DEV
# exists on disk and has been projected end-to-end through STORE's own launcher under the strict
# three-key env (self-check: status ok, readiness ready, 2 cards, source-sha256 verified against the
# declared raw-sha256). SUPERSEDED: this paragraph previously said "NO attested/captured card JSON
# exists on disk yet" -- that is no longer true. What is STILL true, and the reason this warning
# stays: the export is a BOUNDED snapshot of an explicit seed set, as-of is PERMANENTLY NULL, and a
# green readiness means only "these records were published and readiness was explicitly declared" --
# never full-corpus coverage and never a continuously updated view. Nothing in this repo is
# deployed by this file: it only wires a port when an operator sets the env vars above.
# =================================================================================================

module Atomspace
  # Boot-time installer for the I3 read binding. A module (not an initializer-body script) so the
  # logic is addressable, re-entrant, and provable by a plain-ruby harness with no Rails and no DB.
  module I3ReadBindingInstaller
    # The master switch's ONLY accepted value. Anything else is "off".
    LIVE = "live"

    # The env var config/puma.rb:1 reads to decide how many workers to FORK. Read here ONLY to
    # decide whether binding from `after_initialize` would hand one child's pipes to many workers.
    PREFORK_CONCURRENCY_ENV = "WEB_CONCURRENCY"

    # Every env var that must be present and non-blank for a bind to be attempted.
    #
    # I3_I2_SCRIPT_SHA256 IS A MEMBER OF THIS SET AS OF ROUND 34. It used to be an opt-in extra
    # read straight out of ENV inside `digest_refusal_for`, which made an ABSENT pin a PASS (the
    # residual half of the canonical-launcher identity gap). Listing it here does two things at
    # once: it makes the pin MANDATORY, and -- because `validated_launch` reads exactly this list
    # exactly once -- it puts the pin inside the SAME frozen snapshot as the three paths, so the
    # digest that is validated is the digest that was read. There is no second ENV read anywhere
    # on the validation path.
    REQUIRED_ENV = %w[
      I3_I2_INTERPRETER
      I3_I2_SCRIPT
      I3_STORE_SIDECAR_PATH
      I3_I2_CONFIG
      I3_I2_DEADLINE_MS
      I3_I2_SCRIPT_SHA256
    ].freeze

    # The two env vars that must name ABSOLUTE paths. Spawn's own `require_absolute!`
    # (i2_stdio_transport.rb:475-488) enforces this too; checking here lets the refusal be a logged
    # warning on the fail-closed path rather than an exception crossing boot.
    ABSOLUTE_PATH_ENV = %w[I3_I2_INTERPRETER I3_I2_SCRIPT I3_STORE_SIDECAR_PATH].freeze

    # THE ONLY SERVICE SCRIPT THIS BINDING WILL EVER LAUNCH: STORE's real-input service launcher,
    # <I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py in the av-store-sidecar worktree.
    # Its own docstring states the contract this file depends on -- it is "a plain runnable script,
    # because VIEW's I2StdioTransport::Spawn runs exactly [interpreter, script] (no -m)".
    CANONICAL_LAUNCHER_BASENAME = "i2_stdio_reader_service.py"

    # THE SCRIPT THAT MUST NEVER BE NAMEABLE IN I3_I2_SCRIPT: the deck's own golden/MODEL server,
    # <DECK>/tools/i2_stdio_reader_server.py. Note the one-letter difference (serv*er* vs
    # serv*ice*) -- that is precisely why this is a hard guard and not a comment. It has NO
    # store-projection support, and because the spawn argv is exactly [interpreter, script] it can
    # NEVER be passed --seed-from-golden-vectors, so a binding to it starts successfully and then
    # answers "not ready" FOREVER: a permanent, SILENT 503 with no error anywhere. There is no
    # condition under which this file falls back to it.
    REFUSED_MODEL_SERVER_BASENAME = "i2_stdio_reader_server.py"

    # MANDATORY content pin for I3_I2_SCRIPT, 64 lowercase hex. SUPERSEDED COMMENT, kept visible on
    # purpose: this used to read "OPTIONAL ... non-fatal BY CONFIGURATION (absent var => not
    # checked)", and that sentence described the defect. `digest_refusal_for` now REFUSES on an
    # absent or blank pin with its own distinct reason, so content identity can no longer be
    # skipped by simply not setting a variable. The currently-approved value is documented in the
    # header (round-033 bundle MANIFEST.json) and is NEVER hardcoded here.
    SCRIPT_DIGEST_ENV = "I3_I2_SCRIPT_SHA256"

    # THE ONE SUBDIRECTORY OF I3_STORE_SIDECAR_PATH THAT MAY CONTAIN THE LAUNCHER. The approved
    # launcher lives at <I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py in the
    # av-store-sidecar worktree, so the containment check reconstructs exactly that one path and
    # compares it to the script's realpath. A directory, not a prefix test: a prefix test would
    # accept <root>/tools-evil/... and <root>/tools/../../anything.
    LAUNCHER_SUBDIR = "tools"

    # Keys whose ABSENCE has a dedicated, more diagnosable refusal further down, and which are
    # therefore not folded into the generic "missing required env var(s)" list. They are still
    # members of REQUIRED_ENV -- so they are still read in the single snapshot read and are still
    # mandatory -- but the operator gets the specific message instead of a generic one.
    DEDICATED_PRESENCE_ENV = [SCRIPT_DIGEST_ENV].freeze

    # The subset of REQUIRED_ENV checked by the generic presence loop in `validated_launch`.
    GENERIC_PRESENCE_ENV = (REQUIRED_ENV - DEDICATED_PRESENCE_ENV).freeze

    # THE IMMUTABLE VALIDATED LAUNCH SNAPSHOT. Built ONCE, from ONE read of each env var, by
    # `validated_launch`; frozen; and the ONLY thing `bind!` is allowed to consume. It exists to
    # close a TOCTOU: `bind!` used to re-`ENV.fetch` I3_I2_INTERPRETER, I3_I2_SCRIPT and
    # I3_STORE_SIDECAR_PATH at SPAWN time, so every validation above was performed against values
    # that could have changed by the time the child was launched. ENV is now read exactly once.
    #
    # `script_digest` JOINED THE STRUCT IN ROUND 34 and is carried for exactly the same reason the
    # paths are: the pin is read in the single snapshot read in `validated_launch` and handed to
    # `refuse_script_reason` as an ARGUMENT, so `digest_refusal_for` performs NO ENV read of its
    # own. Without this member the mandatory-pin fix would have reopened the TOCTOU it closed --
    # ENV[SCRIPT_DIGEST_ENV] could differ between the presence check and the comparison.
    #
    # THE THREE PATHS ARE `File.realpath`-RESOLVED STRINGS, NOT THE RAW ENV VALUES  [CPD-035 FIX 1]
    # The snapshot used to store the raw ENV strings while validation hashed the RESOLVED file, so
    # `Open3.popen3` re-traversed the caller's symlinks at spawn time and a link swapped after
    # validation could execute different bytes than the ones that were hashed. `validated_launch`
    # now resolves all three with `File.realpath` and stores THOSE, so the hashed bytes are the
    # executed bytes and a realpath (which by construction contains no symlink component) has
    # nothing left to re-point.
    ValidatedLaunch = ::Struct.new(
      :interpreter, :script, :sidecar_path, :config, :deadline_ms, :script_digest,
      keyword_init: true
    )

    class << self
      # @return [Integer, nil] the pid that installed the CURRENTLY claimed binding, or nil.
      def installed_pid
        @installed_pid
      end

      # @return [Object, nil] the Spawn this process owns, if any.
      def owned_spawn
        @spawn
      end

      # Spawns whose exit could NOT be confirmed. Retained deliberately: dropping the reference
      # would lose the only handle on a process that may still be running.
      # @return [Array]
      def unreaped_spawns
        @unreaped ||= []
      end

      # PER-SPAWN CREATING-PROCESS IDENTITY  [CPD-035 FIX 3].
      #
      # Maps a retained Spawn to the pid of the process that CREATED it. Keyed by
      # `object_id` rather than by the Spawn itself so this bookkeeping can never resurrect an
      # object the retention list has already dropped, and so a Spawn double with an exotic
      # `hash`/`eql?` cannot corrupt the table.
      #
      # WHY IT IS NEEDED. `unreaped_spawns` SURVIVES A FORK (the array is copied into the child
      # with every element), and `disown_inherited!` deliberately clears ONLY `@installed_pid` and
      # `@spawn` -- never the retention list, because dropping a possibly-live handle is worse.
      # So a forked worker's retention list contains the MASTER's children. `retry_unreaped!` used
      # to call `stop!` on every entry regardless of origin, and `Spawn#stop!` closes the shared
      # pipe FDs and escalates to TERM/KILL -- i.e. a worker's sweep could tear down the parent's
      # reader child and break the real owner's binding. That is precisely what
      # `disown_inherited!` refuses to do on the install path, so the sweep must refuse it too.
      #
      # @return [Hash{Integer=>Integer}] spawn object_id => creating pid.
      def spawn_owner_pids
        @spawn_owner_pids ||= {}
      end

      # Retained entries whose creating pid is NOT this process. These are NEVER stopped by
      # `retry_unreaped!`; they are RECORDED so an operator (and the rollback runbook) can still
      # see that this process is holding foreign handles.
      #
      # An entry with NO recorded owner is also treated as foreign: an unknown origin cannot be
      # proven to be ours, and the fail-closed direction here is "do not signal it".
      #
      # @return [Array] the foreign/inherited retained spawns, newest last.
      def foreign_unreaped_spawns
        unreaped_spawns.select { |spawn| !own_spawn?(spawn) }
      rescue StandardError, ScriptError
        []
      end

      # @return [Integer] how many times an inherited (foreign-pid) claim was disowned here.
      def inherited_disowned_count
        @inherited_disowned || 0
      end

      # @return [Integer, nil] the pid whose at_exit shutdown hook is registered.
      def shutdown_hook_pid
        @shutdown_hook_pid
      end

      # @return [Boolean] true ONLY when a live binding was installed in THIS process.
      #
      # IDEMPOTENT, AND ONE CHILD PER PROCESS AT MOST. `@installed_pid` records the pid that
      # actually spawned. A second call in the same process returns immediately WITHOUT spawning,
      # so Rails eager-load, a double `after_initialize`, or a re-entrant boot cannot stack
      # children. The pid (not a bare boolean) is recorded deliberately: under a PREFORKING server
      # the flag would be inherited by every forked worker, and a boolean would make each worker
      # believe it already owned a child while actually sharing the PARENT's pipes -- which
      # interleaves two workers' frames on one stdin and corrupts the protocol.
      #
      # THE PID COMPARISON IS NOT SUFFICIENT ON ITS OWN, which is why this is the
      # `worker_boot: false` path: under `preload_app!` a forked worker never calls this method, so
      # nothing would ever notice the inherited binding. This path therefore REFUSES outright when
      # PREFORK_CONCURRENCY_ENV names a forking deployment. See operator step (1) in the header.
      def install!
        install_in_process!(worker_boot: false)
      end

      # THE PER-WORKER ENTRY POINT for `on_worker_boot` under `preload_app!` (header step 1a).
      #
      # Differs from `install!` in exactly one way: it is allowed to bind under a preforking
      # WEB_CONCURRENCY, because it runs IN the worker, after the fork, so the child it starts
      # belongs to that worker alone. It still disowns an inherited claim first, so a worker never
      # serves over the master's pipes.
      #
      # @return [Boolean]
      def install_for_worker!
        install_in_process!(worker_boot: true)
      end

      # FAIL-CLOSED OWNERSHIP GUARD. Idempotent, and safe to call from anywhere at any time.
      #
      # If the recorded installing pid is not this process's, the binding was INHERITED across a
      # fork: its reader writes to pipes the parent also writes to, and two writers on one
      # newline-delimited stdin corrupt the protocol. Rather than serve that, the port is RESET
      # (unwired => 503) and the inherited claim is dropped.
      #
      # @return [Boolean] true when this process may use the current binding (it owns it, or there
      #   is no claim at all); false when an inherited claim was found and disowned.
      def ensure_owned_binding!
        return true if @installed_pid.nil?
        return true if @installed_pid == Process.pid

        disown_inherited!
      end

      # Stop the child THIS process owns and leave the port unwired. The at_exit hook calls this,
      # and so does the master-switch-turned-off path.
      #
      # @return [Symbol] :not_owned when this process owns no binding, else :confirmed /
      #   :unconfirmed as reported by `Spawn#stop!`.
      def shutdown_owned_child!
        return :not_owned unless @installed_pid == Process.pid

        reset_port!
        verdict = stop_child!(@spawn)
        @spawn = nil if verdict == :confirmed
        @installed_pid = nil
        verdict
      rescue StandardError, ScriptError
        :unconfirmed # shutdown must never raise out of an at_exit handler.
      end

      # RE-STOP EVERY RETAINED (UNCONFIRMED) CHILD. This closes the RE-STOP GUARANTEE described in
      # header step (2): `stop_child!` RETAINS a Spawn whose exit could not be confirmed, but until
      # this method existed nothing ever called `stop!` on a retained Spawn a SECOND time, so the
      # retention was a reference with no recovery path attached.
      #
      # WHY `shutdown_owned_child!` CANNOT DO THIS JOB. Every path that retains a Spawn
      # (`abandon_child!`, the switch-off teardown, an unconfirmed `shutdown_owned_child!`) CLEARS
      # `@installed_pid`. After that, `shutdown_owned_child!` returns `:not_owned` on its very
      # first line and never touches the child again. A failed install is therefore exactly the
      # case where a possibly-live child existed and nothing could ever re-stop it. This method is
      # deliberately INDEPENDENT of `@installed_pid`: it must work when the claim is nil or belongs
      # to another pid, because that is the only state in which it is ever needed.
      #
      # SEMANTICS, all required by the callers (at_exit, an EM shutdown hook, an operator console):
      #   * iterates a SNAPSHOT (`dup`) of `unreaped_spawns`, so mutating the list during the
      #     sweep cannot skip entries or raise a concurrent-modification error;
      #   * calls `stop!` only on entries that `respond_to?(:stop!)` -- an object with no stop API
      #     stays retained, never silently dropped (same rule as `stop_child!`);
      #   * REMOVES ONLY entries whose `stop!` answered `:confirmed`. An `:unconfirmed`, a nil, any
      #     other value, or a raise keeps the entry, because dropping it would discard the only
      #     handle on a process that may still be alive;
      #   * NEVER RAISES. Each spawn is rescued individually so one bad object cannot abort the
      #     sweep, and the whole body is rescued again so this is safe inside `at_exit`;
      #   * IDEMPOTENT and repeatable: a second call simply retries whatever is still unconfirmed.
      #
      # HONEST LIMIT: a `:confirmed` verdict is the Spawn's own claim, not an independent proof
      # that the OS process is gone, and like `at_exit` this cannot run after SIGKILL -- so the
      # rollback runbook's "check for a survivor" step remains necessary.
      #
      # OWNERSHIP-SCOPED  [CPD-035 FIX 3]. The sweep signals ONLY the children THIS process
      # created. `unreaped_spawns` survives a fork -- `disown_inherited!` clears `@installed_pid`
      # and `@spawn` but deliberately never the retention list -- so a forked worker's list holds
      # the MASTER's children. `Spawn#stop!` closes the shared pipe FDs and escalates to TERM/KILL,
      # so an unscoped sweep in a worker could tear down the parent's reader and break the real
      # owner's binding. Each entry is therefore checked against `spawn_owner_pids`:
      #   * recorded owner == Process.pid  -> stop! (as before);
      #   * recorded owner is ANOTHER pid, or NO owner is recorded -> NEVER stopped. The entry is
      #     COUNTED as skipped and LEFT IN PLACE so `foreign_unreaped_spawns` and the rollback
      #     runbook can still enumerate it. An unknown origin cannot be proven ours, and the
      #     fail-closed direction is "do not signal it".
      #
      # @return [Hash] `{ confirmed: Integer, remaining: Integer, skipped_foreign: Integer }` --
      #   how many entries were newly confirmed and removed by THIS call, how many retained entries
      #   were skipped because they belong to another (or an unknown) pid, and the size of
      #   `unreaped_spawns` after the sweep.
      def retry_unreaped!
        confirmed = 0
        skipped_foreign = 0

        unreaped_spawns.dup.each do |spawn|
          begin
            # OWNERSHIP GATE FIRST: never signal a child this process did not create.
            unless own_spawn?(spawn)
              skipped_foreign += 1
              next
            end

            next unless spawn.respond_to?(:stop!)
            next unless spawn.stop! == :confirmed

            unreaped_spawns.delete(spawn)
            forget_spawn_owner!(spawn)
            confirmed += 1
          rescue StandardError, ScriptError
            next # retain this spawn and keep sweeping the rest.
          end
        end

        { confirmed: confirmed, remaining: unreaped_spawns.size, skipped_foreign: skipped_foreign }
      rescue StandardError, ScriptError
        # Default-deny shape: still answer the documented Hash, never raise into a shutdown hook.
        { confirmed: 0, remaining: (@unreaped || []).size, skipped_foreign: 0 }
      end

      private

      def install_in_process!(worker_boot:)
        return switch_off! unless ENV["I3_READ_BINDING"] == LIVE
        return true if @installed_pid == Process.pid

        # A claim from ANOTHER pid can only have arrived by fork. Drop it, fail closed, then build
        # this process's own child below.
        ensure_owned_binding!

        return refuse_prefork_master! if !worker_boot && prefork_configured?

        # ONE read of ENV, one validation, one frozen snapshot. Everything below -- including the
        # spawn -- consumes `launch` and NEVER touches ENV again.
        launch = validated_launch
        return false unless launch.is_a?(ValidatedLaunch)

        load_dependencies!
        bind!(launch: launch)
      rescue StandardError, ScriptError => e
        # ANY failure -- spawn, require, contract violation, JSON, NoMethodError -- lands here.
        # CLASS ONLY: a message can echo an interpolated path or config value.
        refuse!("binding aborted by #{e.class}")
      end

      # BUILD THE ONE IMMUTABLE VALIDATED SNAPSHOT, or refuse.
      #
      # Every env var is read EXACTLY ONCE, into a local, and only those locals are validated and
      # stored. That is the whole point: a value that passed validation is the same value that is
      # spawned, because there is no second read to disagree with the first.
      #
      # @return [ValidatedLaunch, false] a frozen snapshot on success; `false` after `refuse!` has
      #   already reset the port and logged (names only, never values).
      def validated_launch
        raw = REQUIRED_ENV.to_h { |key| [key, ENV[key]] } # THE SINGLE READ.

        # GENERIC_PRESENCE_ENV, not REQUIRED_ENV: SCRIPT_DIGEST_ENV is equally mandatory but gets
        # its own dedicated refusal in `digest_refusal_for` so the operator is told WHY a content
        # pin is now required rather than just that a variable is missing.
        missing = GENERIC_PRESENCE_ENV.reject { |key| present?(raw[key]) }
        return refuse!("missing required env var(s): #{missing.join(', ')}") unless missing.empty?

        relative = ABSOLUTE_PATH_ENV.reject { |key| absolute?(raw[key]) }
        unless relative.empty?
          # NAMES ONLY, never values: a path can carry a username or a deploy secret.
          return refuse!("these env vars must be ABSOLUTE paths: #{relative.join(', ')}")
        end

        deadline = integer_or_nil(raw["I3_I2_DEADLINE_MS"])
        return refuse!("I3_I2_DEADLINE_MS must be a positive Integer") unless deadline

        config = parsed_config(raw["I3_I2_CONFIG"])
        return refuse!("I3_I2_CONFIG must be parseable JSON naming an object") unless config

        # THE CANONICAL LAUNCHER GATE. nil means "validated"; anything truthy is the refusal.
        interpreter_reason = refuse_interpreter_reason(raw["I3_I2_INTERPRETER"])
        return refuse!(interpreter_reason) if interpreter_reason

        # BOTH IDENTITY AXES ARE DRIVEN FROM THE SNAPSHOT LOCALS, never from a fresh ENV read: the
        # containment root and the content pin are passed in as arguments alongside the script.
        script_reason = refuse_script_reason(
          raw["I3_I2_SCRIPT"],
          sidecar_root: raw["I3_STORE_SIDECAR_PATH"],
          digest_pin: raw[SCRIPT_DIGEST_ENV]
        )
        return refuse!(script_reason) if script_reason

        # ===========================================================================================
        # STORE THE **RESOLVED** PATHS, NOT THE RAW ENV STRINGS  [CPD-035 FIX 1]
        # ===========================================================================================
        # THE DEFECT THIS CLOSES (both reviewers converged on it). Validation above resolves each
        # path with `File.realpath` and hashes the RESOLVED file, but this struct used to store the
        # RAW ENV STRINGS. `Spawn#start!` then handed those raw strings to `Open3.popen3`
        # (i2_stdio_transport.rb:314-316), which RE-TRAVERSES every symlink/junction in them AT
        # SPAWN TIME. So an external link that pointed at the approved launcher while it was being
        # validated and hashed could be re-pointed before the spawn, and a DIFFERENT file would be
        # executed -- the digest check having proven nothing about the bytes that actually ran.
        #
        # THE FIX: the snapshot now carries the `File.realpath`-RESOLVED strings, so the bytes that
        # were hashed are the bytes that are executed. There is no link left to re-point between
        # validation and spawn: a realpath contains no symlink component by construction, so
        # re-resolving it at spawn time is an identity operation.
        #
        # RESOLUTION IS MANDATORY HERE, NOT BEST-EFFORT. If any of the three cannot be resolved at
        # this point the whole launch is REFUSED rather than silently falling back to the raw
        # string -- a fallback would quietly reopen exactly the hole this closes. (Reaching the
        # nil branch requires a path to disappear between its gate above and this line; that is a
        # TOCTOU race, and refusing is the fail-closed answer to it.)
        resolved_interpreter = realpath_or_nil(raw["I3_I2_INTERPRETER"])
        resolved_script      = realpath_or_nil(raw["I3_I2_SCRIPT"])
        resolved_sidecar     = realpath_or_nil(raw["I3_STORE_SIDECAR_PATH"])

        if resolved_interpreter.nil? || resolved_script.nil? || resolved_sidecar.nil?
          # NAMES ONLY, never values, same rule as every other refusal in this file.
          return refuse!(
            "one of I3_I2_INTERPRETER / I3_I2_SCRIPT / I3_STORE_SIDECAR_PATH stopped resolving " \
            "between validation and snapshot construction (a path changed underneath this " \
            "process). The spawn MUST use the same resolved bytes that were hashed, so refusing " \
            "by default (names only: no value is ever logged)."
          )
        end

        # RE-PIN THE RESOLVED SCRIPT. The digest was verified against the realpath above, but the
        # containment comparison is what proves this resolved path is the approved one, so assert
        # BOTH axes against the EXACT string that will be spawned. This is cheap and it makes the
        # "hashed bytes == executed bytes" claim hold against the stored value itself, not merely
        # against an intermediate local.
        spawn_identity_reason = refuse_script_reason(
          resolved_script,
          sidecar_root: resolved_sidecar,
          digest_pin: raw[SCRIPT_DIGEST_ENV]
        )
        return refuse!(spawn_identity_reason) if spawn_identity_reason

        ValidatedLaunch.new(
          # THE RESOLVED STRINGS ARE WHAT GET SPAWNED (see `bind!`).
          interpreter: resolved_interpreter.dup.freeze,
          script: resolved_script.dup.freeze,
          sidecar_path: resolved_sidecar.dup.freeze,
          config: config.freeze,
          deadline_ms: deadline,
          # Carried for completeness of the snapshot. NEVER LOGGED and never passed to Spawn.
          script_digest: raw[SCRIPT_DIGEST_ENV].dup.freeze
        ).freeze
      end

      # VALIDATE I3_I2_INTERPRETER AS A REAL, RESOLVABLE, READABLE REGULAR FILE.
      #
      # NO VERSION IS ASSERTED OR CHECKED. The contract is `requires-python >= 3.10` with
      # `hyperon == 0.2.10`; the baseline DEMONSTRATED on this workstation is Python 3.11.15 with
      # hyperon 0.2.10. A version equality pin would refuse a working host, and a source comment is
      # not evidence of any host's interpreter, so the only gate here is resolvability.
      #
      # @return [nil, String] nil ONLY when the interpreter resolved to a readable regular file.
      #   Every other outcome -- including any rescued exception -- is a TRUTHY refusal reason.
      def refuse_interpreter_reason(value)
        resolved = realpath_or_nil(value)
        return "I3_I2_INTERPRETER could not be resolved to an existing path (name only: the " \
               "value is never logged). Absolute, existing, readable; never PATH-searched." if resolved.nil?

        unless regular_readable_file?(resolved)
          return "I3_I2_INTERPRETER resolved to something that is not a readable regular file " \
                 "(a directory, a dead symlink, or an unreadable entry). Name only: the value " \
                 "is never logged."
        end

        nil
      rescue StandardError, ScriptError => e
        # DEFAULT-DENY ON EXCEPTION. An earlier draft rescued to `false`, which made a MISSING
        # interpreter a PASS. Only `nil` may ever mean success.
        "I3_I2_INTERPRETER could not be validated (#{e.class}); refusing by default."
      end

      # THE CANONICAL LAUNCHER IDENTITY GUARD for I3_I2_SCRIPT. Mandatory and non-bypassable.
      #
      # IDENTITY IS NOW THREE THINGS, ALL REQUIRED (round 34). The previous version checked only
      # the BASENAME, so -- per the review finding at the old :446 -- ANY readable file anywhere on
      # disk that happened to be called i2_stdio_reader_service.py passed, and the content pin was
      # opt-in, so an absent pin passed too. An attacker (or an honest misconfiguration) who could
      # place or name one file could therefore have an arbitrary Python program launched by this
      # binding. The three checks are now:
      #
      #   (1) RESOLVABILITY -- a realpath that is a readable REGULAR file (unchanged).
      #   (2) PATH CONTAINMENT -- the resolved realpath must be EXACTLY
      #       <realpath of I3_STORE_SIDECAR_PATH>/tools/<CANONICAL_LAUNCHER_BASENAME>. Both sides
      #       are realpaths, so a link into an attacker-controlled tree is caught: the link's
      #       TARGET is what gets compared, and a target outside the approved tree cannot equal the
      #       reconstructed approved path. See `containment_refusal_for`.
      #   (3) CONTENT PIN -- SCRIPT_DIGEST_ENV must be present and must match the file's SHA-256.
      #       See `digest_refusal_for`; an absent/blank pin is now a REFUSAL, not a skip.
      #
      # SYMLINK / JUNCTION SEMANTICS, STATED DELIBERATELY: resolution and stat FOLLOW THE TARGET
      # (`File.realpath` + `File.stat`, never `lstat`). A link whose NAME is canonical and which
      # sits inside <root>/tools is therefore judged by WHERE IT POINTS, not by where it sits: if
      # its target is outside <root>/tools it is REFUSED by check (2), and if its target is the
      # approved file itself it is ACCEPTED (it resolves to that exact path). That is the intended
      # behaviour -- the thing being launched is the target, so the target is what must be approved
      # -- and spec/mcp_api/i3_round34_launcher_identity_proof.rb case 8 asserts it explicitly.
      #
      # @param value [String, nil] the ALREADY-READ I3_I2_SCRIPT value.
      # @param sidecar_root [String, nil] the ALREADY-READ I3_STORE_SIDECAR_PATH value. Passed as
      #   an argument, never re-read from ENV, so the single-read snapshot invariant holds.
      # @param digest_pin [String, nil] the ALREADY-READ SCRIPT_DIGEST_ENV value, same rule.
      # @return [nil, String] nil ONLY when the script IS STORE's canonical real-input service
      #   launcher, resolved on disk, readable, located at the one approved path, and matching the
      #   pinned content digest. EVERY other outcome returns a distinct TRUTHY reason string: a
      #   missing file (ENOENT), an unreadable one (EACCES), a directory, a dead symlink, the
      #   deck's golden/MODEL server, any other basename, a file outside the approved directory, an
      #   absent/malformed/mismatched digest pin, or any rescued exception.
      #   Nothing here may return `false` or `nil` on a failure path.
      def refuse_script_reason(value, sidecar_root: nil, digest_pin: nil)
        resolved = realpath_or_nil(value)
        if resolved.nil?
          return "I3_I2_SCRIPT could not be resolved to an existing path. It must name STORE's " \
                 "#{CANONICAL_LAUNCHER_BASENAME} under <I3_STORE_SIDECAR_PATH>/tools/ " \
                 "(name only: the value is never logged)."
        end

        unless regular_readable_file?(resolved)
          return "I3_I2_SCRIPT resolved to something that is not a readable regular file (a " \
                 "directory, a dead symlink, or an unreadable entry). It must name STORE's " \
                 "#{CANONICAL_LAUNCHER_BASENAME} (name only: the value is never logged)."
        end

        basename = ::File.basename(resolved)

        # THE EXPLICIT GOLDEN/MODEL-SERVER REFUSAL, checked BEFORE the positive match so this
        # specific, high-consequence mistake gets its own diagnosable reason instead of a generic
        # "wrong name". There is NO fallback to it under any condition. It is also checked before
        # CONTAINMENT on purpose: the deck's own server copied into <root>/tools would otherwise be
        # reported as a mere path problem and lose its dedicated diagnosis.
        if basename.casecmp?(REFUSED_MODEL_SERVER_BASENAME)
          return "I3_I2_SCRIPT names the deck's golden/MODEL server " \
                 "(#{REFUSED_MODEL_SERVER_BASENAME}), which is REFUSED. It has no " \
                 "store-projection support and the spawn argv is exactly [interpreter, script], " \
                 "so --seed-from-golden-vectors can never be passed to it: binding to it would " \
                 "produce a permanent SILENT 503 (bound, never ready). The only permitted script " \
                 "is STORE's #{CANONICAL_LAUNCHER_BASENAME}."
        end

        unless basename.casecmp?(CANONICAL_LAUNCHER_BASENAME)
          return "I3_I2_SCRIPT does not name the canonical launcher. The ONLY permitted script " \
                 "is STORE's #{CANONICAL_LAUNCHER_BASENAME} under " \
                 "<I3_STORE_SIDECAR_PATH>/tools/ (name only: the value is never logged)."
        end

        # (2) PATH CONTAINMENT. A matching basename is NOT identity; the path must be the one
        # approved path. This is the check whose absence was the reported gap.
        containment_reason = containment_refusal_for(resolved, sidecar_root)
        return containment_reason if containment_reason

        # (3) MANDATORY content pin. Absent/blank => refusal; present => it must match.
        digest_refusal_for(resolved, digest_pin)
      rescue StandardError, ScriptError => e
        # DEFAULT-DENY ON EXCEPTION -- the defect this guard exists to prevent. An earlier draft
        # rescued SystemCallError to `false`, so a MISSING script PASSED validation. A rescue here
        # may ONLY ever produce a truthy reason.
        "I3_I2_SCRIPT could not be validated (#{e.class}); refusing by default."
      end

      # PATH CONTAINMENT: the resolved script must be the ONE approved launcher path.
      #
      # WHY AN EXACT EQUALITY AND NOT A PREFIX TEST. A `start_with?(root)` test accepts
      # "<root>-evil/tools/..." (no separator boundary) and tells you nothing about which
      # subdirectory or basename was used. The approved launcher has exactly one location, so the
      # cheapest correct check is to RECONSTRUCT that one path from the root's realpath and compare
      # strings. No globbing, no traversal, no normalisation surprises.
      #
      # BOTH SIDES ARE REALPATHS. The root is resolved too, so a deployment where the sidecar root
      # itself is reached through a junction/symlink still compares equal (the script's realpath
      # has the same resolution applied), while a script whose realpath leaves the approved tree
      # cannot possibly equal the reconstructed path. This is what makes "a symlink into an
      # attacker-controlled tree" a refusal rather than a bypass.
      #
      # CASE SENSITIVITY, DELIBERATELY SPLIT. The BASENAME check above keeps its historical
      # `casecmp?` behaviour (a case variant of the launcher name is still recognised as naming the
      # launcher, and is still subject to this check and the digest). The CONTAINMENT comparison
      # here is EXACT-STRING on realpaths -- `==`, never `casecmp?` -- because path segments are
      # case-sensitive on the POSIX hosts this deploys to and a case-insensitive comparison would
      # accept a path this process cannot prove is the same file.
      #
      # @param resolved [String] the script's realpath (already proven a readable regular file).
      # @param sidecar_root [String, nil] the ALREADY-READ I3_STORE_SIDECAR_PATH value.
      # @return [nil, String] nil ONLY when `resolved` IS the one approved path. Every other
      #   outcome -- including an unresolvable root and any rescued exception -- is a TRUTHY
      #   refusal naming the ENV VARS ONLY, never a path value.
      def containment_refusal_for(resolved, sidecar_root)
        root = realpath_or_nil(sidecar_root)
        if root.nil?
          return "I3_STORE_SIDECAR_PATH could not be resolved to an existing directory, so " \
                 "I3_I2_SCRIPT cannot be proven to live inside the approved sidecar tree. Both " \
                 "are refused by default (names only: no value is ever logged)."
        end

        unless ::File.directory?(root)
          return "I3_STORE_SIDECAR_PATH does not resolve to a directory, so the approved " \
                 "launcher path cannot be reconstructed from it (name only: no value is logged)."
        end

        # SEPARATOR-SAFE JOIN. `File.join` inserts File::SEPARATOR ("/"), which is also what
        # `File.realpath` produces on every platform Ruby supports (it normalises "\\" to "/" on
        # Windows), so the two sides are built with the same separator.
        approved = ::File.join(root, LAUNCHER_SUBDIR, CANONICAL_LAUNCHER_BASENAME)
        return nil if resolved == approved

        "I3_I2_SCRIPT resolves OUTSIDE the one approved launcher location. It must resolve " \
          "EXACTLY to <I3_STORE_SIDECAR_PATH>/#{LAUNCHER_SUBDIR}/" \
          "#{CANONICAL_LAUNCHER_BASENAME} with both sides compared as realpaths. A readable file " \
          "that merely shares the canonical basename is NOT the canonical launcher: matching the " \
          "name is not identity, and a link is judged by its TARGET. Refusing (env var names " \
          "only: neither the script path nor the sidecar root is ever logged)."
      rescue StandardError, ScriptError => e
        "I3_I2_SCRIPT containment under I3_STORE_SIDECAR_PATH could not be verified " \
          "(#{e.class}); refusing by default."
      end

      # MANDATORY CONTENT PIN for I3_I2_SCRIPT.
      #
      # SUPERSEDED BEHAVIOUR, named so nobody restores it: this method used to begin with
      # `pin = ENV[SCRIPT_DIGEST_ENV]; return nil unless present?(pin)` -- i.e. AN ABSENT PIN WAS A
      # PASS, which is precisely why the launcher's CONTENT was unenforced. The pin is now a member
      # of REQUIRED_ENV, it is passed in from the single frozen read (never re-read here), and an
      # absent or blank value is a REFUSAL with its own distinct reason.
      #
      # WHY CONTENT AS WELL AS PATH. Containment proves WHERE the file is; it cannot prove WHAT it
      # contains. A file inside the sidecar tree can be rewritten in place by anything that can
      # write there, so without a content pin the approved path is a mutable target. The approved
      # value is operator-supplied (documented in the header; round-033 MANIFEST.json) and is
      # deliberately not a constant in this file.
      #
      # @param resolved [String] the script's realpath.
      # @param pin [String, nil] the ALREADY-READ SCRIPT_DIGEST_ENV value.
      # @return [nil, String] nil ONLY when the pin is present, well-formed, and equals the file's
      #   SHA-256. Everything else is a TRUTHY reason. NEITHER the digest NOR the path is logged.
      def digest_refusal_for(resolved, pin)
        unless present?(pin)
          return "#{SCRIPT_DIGEST_ENV} is REQUIRED and was absent or blank. Launcher identity is " \
                 "path AND content: path containment proves where the file is but not what it " \
                 "contains, and a file inside the sidecar tree can be rewritten in place. Set " \
                 "#{SCRIPT_DIGEST_ENV} to the 64-lowercase-hex SHA-256 of the approved " \
                 "#{CANONICAL_LAUNCHER_BASENAME} (the operator supplies it; this file never " \
                 "hardcodes a digest and never logs one)."
        end

        # STRICT, NO NORMALISATION  [CPD-035]. The contract and the refusal below both advertise
        # exactly 64 LOWERCASE hex characters, so that is exactly what is accepted. Stripping
        # whitespace or down-casing first would silently admit values the contract rejects (and
        # would make a padded/upper-case pin in an env file "work" here but fail any other reader
        # that compares the raw string). `pin` is matched AS READ; mismatch = fail closed.
        unless pin.match?(/\A[0-9a-f]{64}\z/)
          return "#{SCRIPT_DIGEST_ENV} must be 64 lowercase hex characters."
        end

        require "digest"
        actual = ::Digest::SHA256.file(resolved).hexdigest
        return nil if actual == pin

        "I3_I2_SCRIPT does not match the pinned #{SCRIPT_DIGEST_ENV} content digest (neither " \
          "digest nor path is logged)."
      rescue StandardError, ScriptError => e
        "#{SCRIPT_DIGEST_ENV} could not be verified (#{e.class}); refusing by default."
      end

      # @return [String, nil] the ACTUAL resolved path, or nil when it cannot be resolved. Returns
      #   nil rather than raising so callers stay on their own refusal paths; a nil NEVER means ok.
      def realpath_or_nil(value)
        return nil unless present?(value)

        ::File.realpath(value)
      rescue StandardError
        nil
      end

      # @return [Boolean] true only for an existing REGULAR file that is readable. `File.stat`
      #   (not `lstat`) is used so a symlink is judged by its target, and a dead symlink has
      #   already failed `realpath` above.
      def regular_readable_file?(resolved)
        stat = ::File.stat(resolved)
        stat.file? && ::File.readable?(resolved)
      rescue StandardError
        false
      end

      # THE MASTER SWITCH WENT OFF. Not necessarily a boot: `install!` can run again in a process
      # that already installed (eager-load, a re-entrant hook, an operator calling it), and the
      # switch may have been cleared in between.
      #
      # If THIS process installed, the live binding must not survive the switch going off: reset
      # the port, stop the owned child, and clear the claim. If it did not (the overwhelmingly
      # common case -- every normal boot with the switch unset), stay completely SILENT. Warning
      # here would spam every boot of every deck that has not opted in, which is why the condition
      # is "did I install" and not "is the switch off".
      def switch_off!
        return false unless @installed_pid == Process.pid

        verdict = shutdown_owned_child!
        log(:warn,
            "[i3_read_binding] the master switch is no longer \"live\": the I3 read port this " \
            "process had bound is now RESET (unwired) and every I3 route will answer 503. The " \
            "reader child this process owned was stopped; its exit verdict was " \
            "#{verdict.inspect}. An :unconfirmed verdict means the process may still be running " \
            "and is still referenced (see unreaped_spawns).")
        false
      end

      # The preload+fork refusal. Names the env var and the required change, never the value.
      def refuse_prefork_master!
        refuse!(
          "#{PREFORK_CONCURRENCY_ENV} names a PREFORKING deployment and config/puma.rb uses " \
          "preload_app!, so a binding installed on this path would run in the Puma MASTER and be " \
          "INHERITED by every forked worker -- which would put two or more writers on ONE child's " \
          "stdin and corrupt the line protocol. Refusing to bind is the safe outcome. There are " \
          "exactly TWO valid remedies: (1) add " \
          "`on_worker_boot { Atomspace::I3ReadBindingInstaller.install_for_worker! }` to " \
          "config/puma.rb so each forked worker binds its own port, or (2) run single-process " \
          "with #{PREFORK_CONCURRENCY_ENV}=0 (or #{PREFORK_CONCURRENCY_ENV} unset). Dropping " \
          "preload_app! is NOT a remedy: this refusal is driven solely by " \
          "#{PREFORK_CONCURRENCY_ENV} and never inspects preload_app!, so removing it leaves " \
          "this path still refusing, the port UNWIRED, and every I3 route answering 503."
        )
      end

      # @return [Boolean] true when the deployment will FORK workers. Unset or an explicit 0 is
      #   single-process. An UNPARSEABLE value is reported as preforking on purpose: that is the
      #   fail-closed direction (503 instead of possibly-shared pipes), and `Integer()` in
      #   config/puma.rb:1 would itself reject the value anyway.
      def prefork_configured?
        raw = ENV[PREFORK_CONCURRENCY_ENV]
        return false unless present?(raw)

        stripped = raw.strip
        return true unless stripped.match?(/\A\d+\z/)

        Integer(stripped, 10).positive?
      end

      # An inherited claim is dropped WITHOUT stopping the inherited child, deliberately: that
      # process belongs to whoever started it, and closing its pipes or signalling it from here
      # would break the real owner's binding (and `stop!` closes the shared FDs). This process
      # simply refuses to use it.
      def disown_inherited!
        reset_port!
        @installed_pid = nil
        @spawn = nil
        @inherited_disowned = inherited_disowned_count + 1
        log(:warn,
            "[i3_read_binding] an I3 read binding installed by a DIFFERENT process was inherited " \
            "by this one (a fork under preload_app!). The port is RESET (unwired, => 503) rather " \
            "than served over the parent's inherited pipes, which two processes cannot share " \
            "without interleaving frames. The inherited child is NOT stopped from here: it " \
            "belongs to the process that started it. Operator: call install_for_worker! from " \
            "Puma's on_worker_boot, or run single-process.")
        false
      end

      # Build the child, the client, and the binding. Separated so the rescue above covers it
      # whole: a spawn that starts but whose client is rejected must not leave the port bound.
      #
      # TOCTOU CLOSED. This method reads NO environment variable. It used to re-`ENV.fetch`
      # I3_I2_INTERPRETER, I3_I2_SCRIPT and I3_STORE_SIDECAR_PATH here, at spawn time, which meant
      # the canonical-launcher validation above could be satisfied by one value and a DIFFERENT
      # value could be spawned -- including the refused golden/MODEL server. The frozen
      # `ValidatedLaunch` snapshot is now the ONLY source of the three paths, so mutating ENV after
      # validation cannot change what is launched.
      #
      # AND THE SNAPSHOT NOW HOLDS REALPATHS  [CPD-035 FIX 1]. Freezing the ENV read was necessary
      # but NOT sufficient: the raw strings it used to hold were re-traversed by `Open3.popen3`
      # (i2_stdio_transport.rb:314-316) at spawn time, so a symlink that pointed at the approved,
      # hashed launcher during validation could be re-pointed before this call and a different
      # file would execute. `validated_launch` now stores `File.realpath`-resolved strings and
      # this method passes them STRAIGHT THROUGH to `Spawn`, so the bytes that were hashed are the
      # bytes that run. Do NOT reintroduce any re-derivation of these paths here.
      #
      # @param launch [ValidatedLaunch] the frozen, already-validated snapshot. Its `interpreter`,
      #   `script` and `sidecar_path` are RESOLVED REALPATHS, and are used verbatim.
      def bind!(launch:)
        spawn = ::Atomspace::I2StdioTransport::Spawn.new(
          interpreter: launch.interpreter,
          script: launch.script,
          sidecar_path: launch.sidecar_path,
          config: launch.config
        ).start!

        # OWNERSHIP IS RECORDED THE INSTANT A CHILD EXISTS, before anything that can fail. This
        # assignment used to happen only after a successful install!, so a client constructor that
        # raised -- or a declined binding -- left a started process with nobody holding a reference
        # to it: a leaked child and a leaked pair of pipes, per failed boot attempt.
        @spawn = spawn

        begin
          client = ::Atomspace::I2ReaderProcessClient.new(
            writer: spawn.writer, reader: spawn.reader, deadline_ms: launch.deadline_ms
          )

          installed = ::Atomspace::LocalI3ReadBinding.install!(
            reader: client, origin: ::Atomspace::LocalI3ReadBinding::ORIGIN_LIVE
          )
        rescue StandardError, ScriptError => e
          # CLASS ONLY, same rule as the outer rescue.
          return abandon_child!(spawn, "the child started but the binding failed: #{e.class}")
        end

        # install! answers false ONLY for a nil reader, which it has already reset the port for.
        unless installed
          return abandon_child!(spawn, "LocalI3ReadBinding declined to install the reader")
        end

        @installed_pid = Process.pid
        register_shutdown_hook!
        log(:info, "[i3_read_binding] I3 read port bound to the live I2 reader child")
        true
      end

      # BOUNDED CLEANUP of a child that was started and then could not be used. Stops it EXACTLY
      # once, keeps the reference when the stop is unconfirmed, and still ends on the fail-closed
      # exit so the port is reset and boot continues.
      def abandon_child!(spawn, reason)
        verdict = stop_child!(spawn)
        @spawn = nil if verdict == :confirmed
        @installed_pid = nil
        refuse!("#{reason}; the started child was stopped with verdict #{verdict.inspect}")
      end

      # @return [Symbol] :confirmed only when the Spawn itself confirms the exit. Anything else --
      #   an unconfirmed verdict, a raise, or a Spawn that cannot stop -- is :unconfirmed AND the
      #   Spawn is retained in `unreaped_spawns`, because the alternative is to drop the only
      #   reference to a process that may still be alive.
      def stop_child!(spawn)
        return :confirmed if spawn.nil?
        return retain_unreaped!(spawn) unless spawn.respond_to?(:stop!)

        spawn.stop! == :confirmed ? :confirmed : retain_unreaped!(spawn)
      rescue StandardError, ScriptError
        retain_unreaped!(spawn)
      end

      def retain_unreaped!(spawn)
        unreaped_spawns.push(spawn) unless unreaped_spawns.include?(spawn)
        remember_spawn_owner!(spawn) # [CPD-035 FIX 3] record WHO created it, at retention time.
        :unconfirmed
      end

      # [CPD-035 FIX 3] Record the creating pid for a retained spawn. Keyed by `object_id` so this
      # table can never resurrect a dropped object and an exotic `hash`/`eql?` cannot corrupt it.
      # Called at the only moment the pid is knowable for certain: while the creating process is
      # still the one running.
      def remember_spawn_owner!(spawn)
        return if spawn.nil?

        spawn_owner_pids[spawn.object_id] ||= Process.pid
        nil
      rescue StandardError, ScriptError
        nil # bookkeeping must never fail a teardown; an unrecorded owner reads as FOREIGN below.
      end

      # [CPD-035 FIX 3] Drop the bookkeeping for an entry that has left `unreaped_spawns`, so the
      # table cannot grow without bound across repeated sweeps.
      def forget_spawn_owner!(spawn)
        return if spawn.nil?

        spawn_owner_pids.delete(spawn.object_id)
        nil
      rescue StandardError, ScriptError
        nil
      end

      # [CPD-035 FIX 3] THE OWNERSHIP PREDICATE used by `retry_unreaped!` and
      # `foreign_unreaped_spawns`.
      #
      # FAIL-CLOSED BY DEFAULT: true ONLY when a creating pid was recorded AND it equals
      # `Process.pid`. A foreign pid is not ours; an ABSENT record is not ours either, because an
      # unprovable origin must not be signalled (an inherited retention list arrives in a forked
      # child with its entries intact, and after `Marshal`/reload the table could be empty while
      # the array is not). Any error answers false for the same reason.
      def own_spawn?(spawn)
        return false if spawn.nil?

        spawn_owner_pids[spawn.object_id] == Process.pid
      rescue StandardError, ScriptError
        false
      end

      # Connect `Spawn#stop!` to process exit, which nothing did before (see header step 2).
      #
      # SCOPED TO THE INSTALLING PID because at_exit handlers are INHERITED by forked children: an
      # unguarded handler would let a worker's exit stop the MASTER's child. Registered at most
      # once per process.
      def register_shutdown_hook!
        return if @shutdown_hook_pid == Process.pid

        @shutdown_hook_pid = Process.pid
        owner = Process.pid
        at_exit do
          if Process.pid == owner
            ::Atomspace::I3ReadBindingInstaller.shutdown_owned_child!
            # [CPD-035] Also RE-STOP anything retained unconfirmed, so a standalone process that
            # never goes through I3ThinLifecycle still gets the sweep on the way out. Scoped by the
            # same `owner` guard, and `retry_unreaped!` itself only signals spawns THIS pid created.
            ::Atomspace::I3ReadBindingInstaller.retry_unreaped!
          end
        rescue StandardError, ScriptError
          nil
        end
      rescue StandardError, ScriptError
        nil # failing to register a shutdown hook must not fail the bind.
      end

      # THE ONE FAIL-CLOSED EXIT. Reset the port, warn without leaking, keep booting.
      #
      # Reset is UNCONDITIONAL on purpose: it guarantees the documented end state ("unwired => 503")
      # regardless of what a half-completed attempt left behind, and resetting an already-unwired
      # port is a no-op (i3_read_port.rb:52-54).
      def refuse!(reason)
        reset_port!
        log(:warn,
            "[i3_read_binding] NOT binding the I3 read port: #{reason}. The port stays UNWIRED " \
            "and every I3 route will answer 503. No fixture or synthetic reader is ever " \
            "substituted. (Set I3_READ_BINDING=live and all I3_* vars to enable.)")
        false
      end

      def reset_port!
        ::Atomspace::I3ReadPort.reset! if defined?(::Atomspace::I3ReadPort)
      rescue StandardError
        nil # a reset that itself fails must not escalate out of boot; the port cannot be bound.
      end

      # Mod lib is NOT autoloaded (see header). Guarded by `defined?` so a constant already loaded
      # by the app, by eager-load, or by a harness is not re-required -- which also keeps this file
      # loadable outside Rails.
      def load_dependencies!
        root = ::File.expand_path("../../mod/mcp_api/lib/atomspace", __dir__)
        require ::File.join(root, "i3_read_port") unless defined?(::Atomspace::I3ReadPort)
        unless defined?(::Atomspace::LocalI3ReadBinding)
          require ::File.join(root, "local_i3_read_binding")
        end
        unless defined?(::Atomspace::I2StdioTransport::Spawn)
          require ::File.join(root, "i2_stdio_transport")
        end
        return if defined?(::Atomspace::I2ReaderProcessClient)

        require ::File.join(root, "i2_reader_process_client")
      end

      # @param raw [String] the ALREADY-READ I3_I2_CONFIG value. Takes the value as an argument on
      #   purpose: re-reading ENV here would reopen the TOCTOU the snapshot exists to close.
      def parsed_config(raw)
        require "json"
        parsed = ::JSON.parse(raw)
        parsed.is_a?(::Hash) ? parsed : nil
      rescue ::JSON::ParserError, TypeError
        nil
      end

      def present?(value)
        value.is_a?(::String) && !value.strip.empty?
      end

      # STRICT integer parse. `String#to_i` is deliberately NOT used: "abc".to_i is 0 and
      # "5.5".to_i is 5, so a malformed deadline would silently become a plausible one. Only a
      # string that is ENTIRELY digits and positive is accepted; everything else is nil => refusal.
      def integer_or_nil(value)
        return nil unless present?(value)
        return nil unless value.strip.match?(/\A\d+\z/)

        parsed = Integer(value.strip, 10)
        parsed.positive? ? parsed : nil
      rescue ArgumentError, TypeError
        nil
      end

      def absolute?(value)
        return false unless present?(value)

        # POSIX root or a Windows drive-letter root. Matches Spawn#require_absolute!
        # (i2_stdio_transport.rb:483) so this pre-check cannot disagree with the real gate.
        value.start_with?("/") || value.match?(%r{\A[A-Za-z]:[\\/]})
      end

      def log(level, message)
        logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
        logger&.public_send(level, message)
      rescue StandardError
        nil # logging must never be the thing that breaks boot.
      end
    end
  end
end

# WHY `after_initialize` AND NOT `to_prepare`.
#
# `to_prepare` runs on EVERY code reload (each request in development with reloading on). This
# installer SPAWNS A CHILD PROCESS, so a to_prepare hook would start a new python child per reload
# and leak them without bound. `after_initialize` runs ONCE per booted process, after eager-load,
# which is exactly the lifecycle of "one child per process". The pid guard in `install!` makes a
# second invocation harmless regardless of which hook calls it.
#
# UNDER `preload_app!` THIS HOOK RUNS IN THE MASTER, which is why `install!` refuses when
# WEB_CONCURRENCY names a forking deployment and why `install_for_worker!` exists. See operator
# step (1) in the header: the `on_worker_boot` line lives in config/puma.rb and is NOT applied by
# this change.
#
# Also guarded on `Rails.application` responding to `config`, so requiring this file in a
# plain-ruby harness does not need a Rails stub at all.
if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application.respond_to?(:config)
  ::Rails.application.config.after_initialize do
    ::Atomspace::I3ReadBindingInstaller.install!
  end
end
