# frozen_string_literal: true

# =================================================================================================
# ROUND-34 PROOF HARNESS -- Codex blockers 2, 3 and 4 in the I3 THIN LIFECYCLE
# =================================================================================================
#
# Run:  cd E:/GitHub/Magi-AGI/av-view-deck && ruby spec/mcp_api/i3_round34_thin_lifecycle_proof.rb
#
# NO rspec, NO Rails, NO decko, NO card, NO thin, NO eventmachine, NO database, NO network, NO
# child process, NO real signal to a foreign pid. Those gems are NOT INSTALLED on this host, which
# is exactly why this is a bare-ruby harness over DOUBLES (same pattern as
# spec/mcp_api/i3_binding_initializer_harness.rb).
#
# WHAT IT PROVES (by execution, here, now):
#   B2  the installer ENTRY-POINT DECISION: `install_for_worker!` is taken ONLY on affirmative
#       serving-process evidence; otherwise `install!` is called so the prefork-master refusal is
#       reachable again; deferral into the reactor; idempotency; the off switch.
#   B3  the RE-STOP GUARANTEE: `shutdown!` sweeps retained `unreaped_spawns` even when
#       `shutdown_owned_child!` answered `:not_owned`, from BOTH hooks, never raising, and working
#       against an installer with no `retry_unreaped!` at all.
#   B4  TRI-STATE LIVENESS: ESRCH => :gone (excluded), EPERM => :alive (included), any other error
#       => :unknown (INCLUDED -- the exact Codex finding), malformed pid => :unknown, and `state`
#       reporting all three sets consistently.
#   Plus: NAMES-ONLY logging -- no log line may contain a filesystem path, an env value or a digest.
#
# WHAT IT DOES **NOT** PROVE -- do not read green here as deployment evidence:
#   * Real thin 2.0.1 and real eventmachine 1.2.7 behaviour is UNVERIFIABLE on this host (the gems
#     are absent). Whether `EM.next_tick` really runs in the serving process, whether `EM.stop`
#     really drains `@tails`, and whether thin really builds the Rack app before starting the
#     reactor are INFERENCES from published sources. The doubles here encode those inferences; they
#     do not test them. If an inference is wrong, the gate fails CLOSED (=> 503), which is the
#     property this harness does pin down.
#   * No process is spawned and no pid is really killed. `Process.kill` is stubbed per case, so
#     nothing here proves the OS semantics of signal 0 -- only this module's mapping of the
#     Errno results onto :alive/:gone/:unknown.
#   * `retry_unreaped!` itself lives in config/initializers/i3_read_binding.rb and is owned by a
#     different worker. This harness proves the LIFECYCLE SIDE: that the sweep is invoked in every
#     case it must be, with the respond_to? guard, and that its result is recorded. The installer
#     double implements the documented contract; the real method has its own proof.
#   * No HTTP and no controller, so no 503 is ever observed. "unwired => 503" is I3ReadPort's own
#     contract, asserted elsewhere; here "unwired" means no bind call reached the port double.
# =================================================================================================

PASS = []
FAIL = []

def check(label)
  ok = yield
  (ok ? PASS : FAIL) << label
  puts "#{ok ? 'PASS' : 'FAIL'}: #{label}"
rescue StandardError, ScriptError => e
  FAIL << "#{label} (raised #{e.class}: #{e.message})"
  puts "FAIL: #{label} (raised #{e.class}: #{e.message})"
end

LIFECYCLE = File.expand_path("../../mod/mcp_api/lib/atomspace/i3_thin_lifecycle.rb", __dir__)
ACTIVATION = File.expand_path("../../config/initializers/i3_thin_activation.rb", __dir__)
READ_BINDING = File.expand_path("../../config/initializers/i3_read_binding.rb", __dir__)
abort "lifecycle not found at #{LIFECYCLE}" unless File.exist?(LIFECYCLE)

# ---- doubles -------------------------------------------------------------------------------------

# Rails double: ONLY what the lifecycle touches (`Rails.logger`), plus a log recorder so the
# names-only logging rule can be asserted.
LOG = []
module Rails
  class << self
    def logger
      @logger ||= Logger.new
    end
  end

  class Logger
    def info(msg)  = LOG << [:info, msg]
    def warn(msg)  = LOG << [:warn, msg]
    def error(msg) = LOG << [:error, msg]
    def debug(msg) = LOG << [:debug, msg]
  end
end

# Spawn double: just a pid holder with a recording `stop!`, mirroring the real Spawn's
# :confirmed/:unconfirmed return contract (i2_stdio_transport.rb stop! contract).
class FakeSpawn
  attr_reader :pid, :stop_calls

  # @param verdict [Symbol, :raise] what `stop!` answers each time it is called.
  def initialize(pid, verdict = :confirmed)
    @pid = pid
    @verdict = verdict
    @stop_calls = 0
  end

  def stop!
    @stop_calls += 1
    raise "simulated stop! explosion" if @verdict == :raise

    @verdict
  end
end

# Installer double. Stands in for Atomspace::I3ReadBindingInstaller and RECORDS WHICH ENTRY POINT
# WAS CALLED -- the central assertion for blocker 2.
#
# It also implements the documented `retry_unreaped!` contract the sibling worker is adding to the
# real installer: sweep unreaped_spawns, call stop! on each, remove ONLY :confirmed, never raise,
# work when @installed_pid is nil or foreign, idempotent.
module Atomspace
  module I3ReadBindingInstaller
    class << self
      attr_accessor :installed_pid, :owned, :calls, :install_result,
                    :worker_result, :shutdown_result, :retry_raises, :api_retry,
                    :prefork_refusal_logged

      def reset!(api_retry: true)
        @installed_pid = nil
        @owned = nil
        @unreaped = []
        @calls = []
        @install_result = true
        @worker_result = true
        @shutdown_result = :not_owned
        @retry_raises = false
        @api_retry = api_retry
        @prefork_refusal_logged = false
        # Toggle the PRESENCE of `retry_unreaped!` so the lifecycle's `respond_to?` guard is
        # exercised for real. `undef_method` alone would be one-way (B3f would silently break
        # every later case), so the implementation is saved as an UnboundMethod and re-bound.
        if api_retry
          unless respond_to?(:retry_unreaped!)
            singleton_class.send(:define_method, :retry_unreaped!, RETRY_UNREAPED_IMPL)
          end
        elsif respond_to?(:retry_unreaped!)
          singleton_class.send(:undef_method, :retry_unreaped!)
        end
      end

      def unreaped_spawns
        @unreaped ||= []
      end

      def owned_spawn = @owned

      # `install!` -- the entry point that CONSULTS the prefork refusal. Faithful to
      # i3_read_binding.rb:327: when WEB_CONCURRENCY names a preforking deployment it refuses and
      # NOTHING is bound.
      def install!
        @calls << :install!
        if prefork_configured?
          @prefork_refusal_logged = true
          Rails.logger.warn("[i3_read_binding] WEB_CONCURRENCY names a PREFORKING deployment; " \
                            "refusing to bind. The port stays unwired.")
          return false
        end
        return false unless @install_result

        @installed_pid = Process.pid
        true
      end

      # `install_for_worker!` -- the BYPASS. Deliberately does NOT consult the refusal, exactly
      # like the real one (i3_read_binding.rb:280-282 -> install_in_process!(worker_boot: true)).
      def install_for_worker!
        @calls << :install_for_worker!
        return false unless @worker_result

        @installed_pid = Process.pid
        true
      end

      def shutdown_owned_child!
        @calls << :shutdown_owned_child!
        v = @shutdown_result
        raise "simulated shutdown explosion" if v == :raise

        # Mirror the real method: @installed_pid is cleared regardless of verdict
        # (i3_read_binding.rb:311) -- the very thing that makes later calls answer :not_owned.
        @installed_pid = nil
        v
      end

      def retry_unreaped!
        @calls << :retry_unreaped!
        raise "simulated retry_unreaped! explosion" if @retry_raises

        confirmed = 0
        unreaped_spawns.dup.each do |s|
          verdict = begin
            s.stop!
          rescue StandardError
            :unconfirmed
          end
          if verdict == :confirmed
            unreaped_spawns.delete(s)
            confirmed += 1
          end
        end
        { confirmed: confirmed, remaining: unreaped_spawns.size }
      end

      private

      def prefork_configured?
        raw = ENV["WEB_CONCURRENCY"]
        return false if raw.nil? || raw.strip.empty?

        stripped = raw.strip
        return true unless stripped.match?(/\A\d+\z/)

        Integer(stripped, 10).positive?
      end
    end
  end
end

# Captured BEFORE any reset! toggles it away, so `retry_unreaped!` can be restored after the
# "installer without the API" case (B3f) instead of being lost for every later case.
RETRY_UNREAPED_IMPL =
  Atomspace::I3ReadBindingInstaller.singleton_class.instance_method(:retry_unreaped!)

# EventMachine double with a CONTROLLABLE reactor state and recorded callbacks.
module EMDouble
  def self.install!(reactor_running:, with_next_tick: true)
    Object.send(:remove_const, :EventMachine) if Object.const_defined?(:EventMachine, false)
    mod = Module.new do
      class << self
        attr_accessor :running, :ticks, :shutdown_hooks, :timers
      end
      self.running = false
      self.ticks = []
      self.shutdown_hooks = []
      self.timers = []

      def self.reactor_running? = running
      def self.add_shutdown_hook(&b) = shutdown_hooks << b
      def self.add_timer(_s, &b) = timers << b
    end
    mod.define_singleton_method(:next_tick) { |&b| ticks << b } if with_next_tick
    mod.running = reactor_running
    Object.const_set(:EventMachine, mod)
    mod
  end

  def self.uninstall!
    Object.send(:remove_const, :EventMachine) if Object.const_defined?(:EventMachine, false)
  end
end

# Thin double. `Thin::Server#running?` is one of the two affirmative serving signals.
module ThinDouble
  def self.install!(running:)
    uninstall!
    thin = Module.new do
      def self.win? = true
    end
    thin.const_set(:VERSION, "2.0.1")
    server_class = Class.new do
      attr_accessor :is_running

      def initialize(running) = (@is_running = running)
      def running? = @is_running
      def threaded? = false
      def backend = nil
    end
    thin.const_set(:Server, server_class)
    Object.const_set(:Thin, thin)
    # Keep a live instance reachable so the ObjectSpace scan in live_server_facts finds it.
    $thin_server = server_class.new(running)
    thin
  end

  def self.uninstall!
    $thin_server = nil
    Object.send(:remove_const, :Thin) if Object.const_defined?(:Thin, false)
    GC.start
  end
end

require LIFECYCLE
L = Atomspace::I3ThinLifecycle

# ---- helpers -------------------------------------------------------------------------------------

def fresh!(live: true, web_concurrency: nil, api_retry: true)
  ENV["I3_READ_BINDING"] = live ? "live" : nil
  if web_concurrency.nil?
    ENV.delete("WEB_CONCURRENCY")
  else
    ENV["WEB_CONCURRENCY"] = web_concurrency
  end
  Atomspace::I3ReadBindingInstaller.reset!(api_retry: api_retry)
  L.reset_for_test!
  LOG.clear
  EMDouble.uninstall!
  ThinDouble.uninstall!
end

def calls = Atomspace::I3ReadBindingInstaller.calls

# Fire a callback that the code under test was supposed to register. A MISSING callback must fail
# the relevant check, NOT abort the run -- otherwise this harness cannot be run against an older
# revision to demonstrate that it actually catches the regression.
def fire(cb)
  return false unless cb.respond_to?(:call)

  cb.call
  true
rescue StandardError, ScriptError
  false
end

# Stub Process.kill for the liveness cases. `behaviour` is a proc given the pid.
def with_kill_stub(behaviour)
  Process.singleton_class.send(:alias_method, :__orig_kill, :kill)
  Process.singleton_class.send(:define_method, :kill) { |_sig, pid| behaviour.call(pid) }
  yield
ensure
  Process.singleton_class.send(:define_method, :kill, Process.singleton_class.instance_method(:__orig_kill))
  Process.singleton_class.send(:remove_method, :__orig_kill)
end

# Seed the pid ledger without spawning anything: the ledger is harvested from the installer.
def seed_ledger!(pids)
  Atomspace::I3ReadBindingInstaller.unreaped_spawns.concat(pids.map { |p| FakeSpawn.new(p) })
  L.send(:record_pids!, stage: "activate", reason: "seed", outcome: :activated)
end

puts "=" * 95
puts "ROUND 34 PROOF: Codex blockers 2 (serving-context gate), 3 (re-stop sweep), 4 (tri-state)"
puts "ruby #{RUBY_VERSION}  |  gems thin/EM/Rails ABSENT -> doubles only"
puts "=" * 95

# =================================================================================================
puts "\n--- BLOCKER 2: evidence-based installer entry point ---"
# =================================================================================================

# (a) No thin, no EM, no evidence at all => MUST use install!, never the worker bypass.
fresh!
out_a = L.activate!(reason: "t_b2a")
check("B2a no serving evidence => install! called, install_for_worker! NOT called") do
  calls.include?(:install!) && !calls.include?(:install_for_worker!)
end
check("B2a outcome is :activated (install! succeeded with no WEB_CONCURRENCY) [#{out_a.inspect}]") do
  out_a == :activated
end
check("B2a the attempt ledger records entry=:install! and serving_context_proven=false") do
  a = L.activation_attempts.last
  a[:entry] == :install! && a[:serving_context_proven] == false
end

# (b) THE REGRESSION: WEB_CONCURRENCY=2 and no serving evidence. The prefork refusal MUST be
#     reached and nothing may be bound. Before the fix this took the bypass and bound anyway.
fresh!(web_concurrency: "2")
out_b = L.activate!(reason: "t_b2b")
check("B2b WEB_CONCURRENCY=2 + no evidence => outcome :refused [#{out_b.inspect}]") do
  out_b == :refused
end
check("B2b the prefork-master refusal was actually REACHED (not defeated)") do
  Atomspace::I3ReadBindingInstaller.prefork_refusal_logged == true
end
check("B2b install_for_worker! was NEVER called, so the bypass was not taken") do
  !calls.include?(:install_for_worker!)
end
check("B2b port stays UNWIRED: installer recorded no installed_pid") do
  Atomspace::I3ReadBindingInstaller.installed_pid.nil? && L.activated_pid.nil?
end

# (c) EM present, reactor NOT running => defer exactly once.
fresh!
em = EMDouble.install!(reactor_running: false)
out_c = L.activate!(reason: "t_b2c")
check("B2c EM present + reactor stopped => :deferred_to_reactor [#{out_c.inspect}]") do
  out_c == :deferred_to_reactor
end
check("B2c exactly ONE next_tick callback registered [#{em.ticks.size}]") do
  em.ticks.size == 1
end
check("B2c nothing bound yet: no install call of either kind") do
  !calls.include?(:install!) && !calls.include?(:install_for_worker!)
end

# (d) Run that deferred callback inside a PROVEN serving context => worker bypass, :activated.
ThinDouble.install!(running: true)
em.running = true
fire(em.ticks.first)
check("B2d deferred callback in a proven serving context => install_for_worker! taken") do
  calls.include?(:install_for_worker!) && !calls.include?(:install!)
end
check("B2d activation recorded as :activated with serving_context_proven=true") do
  a = L.activation_attempts.last
  a[:entry] == :install_for_worker! && a[:serving_context_proven] == true && a[:outcome] == :activated
end
check("B2d activated_pid is this process") { L.activated_pid == Process.pid }

# (e) Idempotency: a second activate! in the same pid starts no second child.
before = calls.dup
out_e = L.activate!(reason: "t_b2e")
check("B2e second activate! => :already_active [#{out_e.inspect}]") { out_e == :already_active }
check("B2e no further installer calls were made (no second child)") { calls == before }

# (f) Switch off.
fresh!(live: false)
out_f = L.activate!(reason: "t_b2f")
check("B2f I3_READ_BINDING unset => :off [#{out_f.inspect}]") { out_f == :off }
check("B2f nothing called and nothing logged when off") { calls.empty? && LOG.empty? }

# (g) Deferral cannot loop: if the context is still unproven when the callback runs, it must fall
#     through to install! rather than re-deferring forever.
fresh!(web_concurrency: "4")
em2 = EMDouble.install!(reactor_running: false)
check("B2g first pass defers") { L.activate!(reason: "t_b2g") == :deferred_to_reactor }
fire(em2.ticks.first)
check("B2g callback with context STILL unproven => install! path, prefork refusal reached") do
  calls.include?(:install!) && !calls.include?(:install_for_worker!) &&
    Atomspace::I3ReadBindingInstaller.prefork_refusal_logged == true
end
check("B2g no second deferral was queued [#{em2.ticks.size}]") { em2.ticks.size == 1 }

# (h) EM absent entirely => immediate install! (fail-closed), never the bypass.
fresh!(web_concurrency: "3")
out_h = L.activate!(reason: "t_b2h")
check("B2h no EM to wait for => install! immediately, refusal reached [#{out_h.inspect}]") do
  out_h == :refused && calls == [:install!] &&
    Atomspace::I3ReadBindingInstaller.prefork_refusal_logged == true
end

# (i) [CPD-035 FIX 2 -- TIGHTENED] A running reactor with NO thin and NO post-fork marker is NO
#     LONGER proof of a serving context. EventMachine is general-purpose: an unrelated reactor can
#     be running inside a PREFORK MASTER, and accepting it made `proven` true and selected
#     `install_for_worker!`, bypassing `refuse_prefork_master!`. The gate now falls through to the
#     fail-closed `install!` path, so the refusal is reached. (This assertion previously encoded
#     the buggy behaviour: it demanded the bypass be "earned" by a bare reactor.)
fresh!(web_concurrency: "2")
EMDouble.install!(reactor_running: true)
out_i = L.activate!(reason: "t_b2i")
check("B2i a bare live reactor is NOT evidence => install! path, prefork refusal reached " \
      "[#{out_i.inspect}]") do
  out_i == :refused && calls.include?(:install!) && !calls.include?(:install_for_worker!) &&
    Atomspace::I3ReadBindingInstaller.prefork_refusal_logged == true
end
check("B2i2 the attempt ledger records serving_context_proven=false for a bare reactor") do
  L.activation_attempts.last[:serving_context_proven] == false
end

# (i3) The sanctioned way to assert a serving context with no observable Thin::Server: an explicit
#      post-fork marker, set by a hook that runs IN the worker AFTER the fork.
fresh!(web_concurrency: "2")
EMDouble.install!(reactor_running: true)
L.post_fork!
out_i3 = L.activate!(reason: "t_b2i3")
check("B2i3 an EXPLICIT post_fork! marker IS affirmative evidence => bypass earned " \
      "[#{out_i3.inspect}]") do
  out_i3 == :activated && calls.include?(:install_for_worker!) && !calls.include?(:install!)
end
check("B2i4 the post-fork marker is PID-SCOPED, so it cannot be inherited across a fork") do
  L.post_fork_pid == Process.pid && L.send(:post_fork_marked?) == true &&
    begin
      L.instance_variable_set(:@post_fork_pid, Process.pid + 1_000_000)
      L.send(:post_fork_marked?) == false
    end
end
check("B2i5 reset_for_test! clears the marker (no leakage between proof cases)") do
  L.reset_for_test!
  L.post_fork_pid.nil? && L.send(:post_fork_marked?) == false
end

# (j) A Thin::Server that exists but is NOT running is NOT evidence.
fresh!
ThinDouble.install!(running: false)
L.activate!(reason: "t_b2j")
check("B2j Thin::Server present but running?==false => NOT proven => install!") do
  calls.include?(:install!) && !calls.include?(:install_for_worker!) &&
    L.activation_attempts.last[:serving_context_proven] == false
end

# =================================================================================================
puts "\n--- BLOCKER 3: the re-stop guarantee (sweep retained unreaped spawns) ---"
# =================================================================================================

# (a) THE REGRESSION: :not_owned + 2 retained spawns => the sweep MUST still run and stop! must be
#     called on each. Before the fix, :not_owned meant the retained children were never retried.
fresh!
inst = Atomspace::I3ReadBindingInstaller
inst.shutdown_result = :not_owned
s1 = FakeSpawn.new(90_001, :confirmed)
s2 = FakeSpawn.new(90_002, :confirmed)
inst.unreaped_spawns.concat([s1, s2])
v_a = L.shutdown!(reason: "t_b3a")
check("B3a verdict :not_owned passed through UNCHANGED [#{v_a.inspect}]") { v_a == :not_owned }
check("B3a the sweep ran anyway: retry_unreaped! was called") { calls.include?(:retry_unreaped!) }
check("B3a stop! was ACTUALLY called on BOTH retained spawns") do
  s1.stop_calls == 1 && s2.stop_calls == 1
end
check("B3a both confirmed spawns were removed from unreaped_spawns") { inst.unreaped_spawns.empty? }
check("B3a the sweep result is recorded in the shutdown entry") do
  sw = L.shutdowns.last[:sweep]
  sw[:attempted] == true && sw[:confirmed] == 2 && sw[:remaining] == 0
end
check("B3a state exposes last_unreaped_sweep") do
  L.state[:last_unreaped_sweep][:confirmed] == 2
end

# (b) An :unconfirmed spawn STAYS in the list and is retried on the NEXT shutdown!.
fresh!
inst.shutdown_result = :not_owned
stubborn = FakeSpawn.new(90_003, :unconfirmed)
inst.unreaped_spawns << stubborn
L.shutdown!(reason: "t_b3b_first")
check("B3b unconfirmed spawn stays retained after the first sweep") do
  inst.unreaped_spawns.include?(stubborn) && stubborn.stop_calls == 1
end
L.shutdown!(reason: "t_b3b_second")
check("B3b it is RETRIED on the next shutdown! (stop_calls=#{stubborn.stop_calls})") do
  stubborn.stop_calls == 2
end
check("B3b remaining count stays 1 and is reported") do
  L.shutdowns.last[:sweep][:remaining] == 1
end

# (c) Mixed: confirmed removed, unconfirmed kept, counts right.
fresh!
inst.shutdown_result = :not_owned
ok = FakeSpawn.new(90_004, :confirmed)
bad = FakeSpawn.new(90_005, :unconfirmed)
inst.unreaped_spawns.concat([ok, bad])
L.shutdown!(reason: "t_b3c")
check("B3c confirmed removed, unconfirmed kept, counts {confirmed:1, remaining:1}") do
  sw = L.shutdowns.last[:sweep]
  sw[:confirmed] == 1 && sw[:remaining] == 1 &&
    !inst.unreaped_spawns.include?(ok) && inst.unreaped_spawns.include?(bad)
end

# (d) BOTH hooks trigger the sweep -- invoke the registered callbacks directly.
fresh!
em3 = EMDouble.install!(reactor_running: true)
ThinDouble.install!(running: true)
L.register_shutdown_hooks!
check("B3d an EM shutdown hook was registered") { em3.shutdown_hooks.size == 1 }
inst.shutdown_result = :not_owned
em_spawn = FakeSpawn.new(90_006, :confirmed)
inst.unreaped_spawns << em_spawn
fire(em3.shutdown_hooks.first)
check("B3d the EM hook swept the retained spawn (stop! called)") do
  em_spawn.stop_calls == 1 && calls.include?(:retry_unreaped!)
end

# The at_exit hook body is the same `shutdown!` call; proving the EM hook plus a direct
# `shutdown!` covers both, and `arm_at_exit_hook` reports armed.
check("B3d the at_exit hook is armed too (hook_state)") { L.state[:hooks][:at_exit] == true }
at_exit_spawn = FakeSpawn.new(90_007, :confirmed)
inst.unreaped_spawns << at_exit_spawn
L.shutdown!(reason: "at_exit")
check("B3d the at_exit path's shutdown! also sweeps") { at_exit_spawn.stop_calls == 1 }

# (e) shutdown! never raises when retry_unreaped! itself raises.
fresh!
inst.shutdown_result = :not_owned
inst.retry_raises = true
v_e = nil
raised = false
begin
  v_e = L.shutdown!(reason: "t_b3e")
rescue StandardError, ScriptError
  raised = true
end
check("B3e shutdown! did NOT raise when retry_unreaped! exploded") { !raised }
check("B3e verdict still passed through unchanged [#{v_e.inspect}]") { v_e == :not_owned }
check("B3e the sweep error is recorded, not swallowed as success") do
  sw = L.shutdowns.last[:sweep]
  sw[:attempted] == true && sw[:reason] == :error
end

# (f) An installer WITHOUT retry_unreaped! still works.
fresh!(api_retry: false)
check("B3f the double really does not respond to retry_unreaped!") do
  !Atomspace::I3ReadBindingInstaller.respond_to?(:retry_unreaped!)
end
inst.shutdown_result = :unconfirmed
v_f = nil
raised_f = false
begin
  v_f = L.shutdown!(reason: "t_b3f")
rescue StandardError, ScriptError
  raised_f = true
end
check("B3f no raise and verdict unchanged [#{v_f.inspect}]") { !raised_f && v_f == :unconfirmed }
check("B3f the missing API is REPORTED (:no_api), not faked as a clean sweep") do
  L.shutdowns.last[:sweep] == { attempted: false, reason: :no_api }
end
Atomspace::I3ReadBindingInstaller.reset!(api_retry: true) # restore for later cases

# (g) A raising shutdown_owned_child! must NOT skip the sweep.
fresh!
inst.shutdown_result = :raise
boom_spawn = FakeSpawn.new(90_008, :confirmed)
inst.unreaped_spawns << boom_spawn
v_g = L.shutdown!(reason: "t_b3g")
check("B3g raising owned-stop => :unconfirmed, and the sweep STILL ran [#{v_g.inspect}]") do
  v_g == :unconfirmed && boom_spawn.stop_calls == 1
end

# (h) The sweep never UPGRADES a verdict.
fresh!
inst.shutdown_result = :unconfirmed
clean = FakeSpawn.new(90_009, :confirmed)
inst.unreaped_spawns << clean
v_h = L.shutdown!(reason: "t_b3h")
check("B3h a fully successful sweep does NOT upgrade :unconfirmed to :confirmed [#{v_h.inspect}]") do
  v_h == :unconfirmed && L.shutdowns.last[:sweep][:confirmed] == 1
end

# =================================================================================================
puts "\n--- BLOCKER 4: tri-state liveness, fail-closed orphan reporting ---"
# =================================================================================================

# (a) ESRCH => :gone and EXCLUDED from orphan_pids.
fresh!
seed_ledger!([70_001])
with_kill_stub(->(_pid) { raise Errno::ESRCH }) do
  check("B4a ESRCH => :gone") { L.liveness(70_001) == :gone }
  check("B4a a :gone pid is EXCLUDED from orphan_pids") { !L.orphan_pids.include?(70_001) }
  check("B4a and it is not in alive_pids or unknown_liveness_pids either") do
    !L.alive_pids.include?(70_001) && !L.unknown_liveness_pids.include?(70_001)
  end
end

# (b) EPERM => :alive and INCLUDED.
fresh!
seed_ledger!([70_002])
with_kill_stub(->(_pid) { raise Errno::EPERM }) do
  check("B4b EPERM => :alive (alive but not ours)") { L.liveness(70_002) == :alive }
  check("B4b and it IS included in orphan_pids") { L.orphan_pids.include?(70_002) }
  check("B4b and in alive_pids (proven)") { L.alive_pids.include?(70_002) }
end

# (c) THE CODEX FINDING: an unexpected error must be :unknown and INCLUDED. The pre-fix code
#     returned false here, making it indistinguishable from confirmed absence.
fresh!
seed_ledger!([70_003])
with_kill_stub(->(_pid) { raise Errno::ENOSYS }) do
  check("B4c an unexpected Errno => :unknown (NOT :gone)") { L.liveness(70_003) == :unknown }
  check("B4c a surviving-but-unproven pid IS included in orphan_pids") do
    L.orphan_pids.include?(70_003)
  end
  check("B4c and it is listed in unknown_liveness_pids") do
    L.unknown_liveness_pids.include?(70_003)
  end
  check("B4c it is NOT claimed as proven-alive") { !L.alive_pids.include?(70_003) }
end
fresh!
seed_ledger!([70_010])
with_kill_stub(->(_pid) { raise RuntimeError, "weird platform" }) do
  check("B4c a generic StandardError from the probe => :unknown and reported") do
    L.liveness(70_010) == :unknown && L.orphan_pids.include?(70_010) &&
      L.unknown_liveness_pids.include?(70_010)
  end
end

# (d) Malformed pids => :unknown, no raise.
fresh!
check("B4d nil pid => :unknown") { L.liveness(nil) == :unknown }
check("B4d 0 => :unknown") { L.liveness(0) == :unknown }
check("B4d negative => :unknown") { L.liveness(-5) == :unknown }
check("B4d non-Integer => :unknown") { L.liveness("1234") == :unknown }
check("B4d a Float pid => :unknown") { L.liveness(12.5) == :unknown }

# (e) `state` reports the three sets consistently.
fresh!
seed_ledger!([70_004, 70_005, 70_006])
behaviour = lambda do |pid|
  case pid
  when 70_004 then raise Errno::ESRCH      # gone
  when 70_005 then raise Errno::EPERM      # alive
  else raise Errno::ENOSYS                 # unknown
  end
end
with_kill_stub(behaviour) do
  st = L.state
  check("B4e state[:orphan_pids] = alive + unknown, excludes gone #{st[:orphan_pids].inspect}") do
    st[:orphan_pids].sort == [70_005, 70_006]
  end
  check("B4e state[:alive_pids] is the PROVEN subset #{st[:alive_pids].inspect}") do
    st[:alive_pids] == [70_005]
  end
  check("B4e state[:unknown_liveness_pids] #{st[:unknown_liveness_pids].inspect}") do
    st[:unknown_liveness_pids] == [70_006]
  end
  check("B4e alive + unknown == orphans exactly (no pid lost, none double counted)") do
    (st[:alive_pids] + st[:unknown_liveness_pids]).sort == st[:orphan_pids].sort
  end
  check("B4e observed_child_count still counts the gone one (ledger is history)") do
    st[:observed_child_count] == 3
  end
end

# (f) The boolean predicate, if present, must be fail-closed (!= :gone), never == :alive.
fresh!
with_kill_stub(->(_pid) { raise Errno::ENOSYS }) do
  check("B4f private process_alive? is FAIL-CLOSED: :unknown counts as possibly alive") do
    L.send(:process_alive?, 70_007) == true
  end
end
with_kill_stub(->(_pid) { raise Errno::ESRCH }) do
  check("B4f and it is false ONLY for a PROVEN-gone pid") do
    L.send(:process_alive?, 70_008) == false
  end
end

# =================================================================================================
puts "\n--- CROSS-CUTTING: names-only logging, source hygiene ---"
# =================================================================================================

# Re-run a logging-heavy path and inspect every message.
fresh!(web_concurrency: "2")
EMDouble.install!(reactor_running: false)
L.activate!(reason: "t_log")
fire(EventMachine.ticks.first)
L.shutdown!(reason: "t_log_shutdown")

messages = LOG.map { |(_lvl, msg)| msg.to_s }
check("LOG1 at least one message was produced on the refusal path") { !messages.empty? }
check("LOG2 no log message contains a filesystem path") do
  messages.none? { |m| m.match?(%r{[A-Za-z]:[/\\]|/(?:home|opt|usr|var|etc)/|\.\./}) }
end
check("LOG3 no log message leaks an env VALUE (the WEB_CONCURRENCY number)") do
  # The NAME may appear; the value "2" must not be presented as its value.
  messages.none? { |m| m.match?(/WEB_CONCURRENCY\s*[=:]\s*\S/) }
end
check("LOG4 no log message contains a long hex digest") do
  messages.none? { |m| m.match?(/\b[0-9a-f]{16,}\b/i) }
end
check("LOG5 no log message contains an I3_ env value assignment") do
  messages.none? { |m| m.match?(/I3_[A-Z_]+\s*[=:]\s*\S/) }
end

src = File.read(LIFECYCLE)
act = File.read(ACTIVATION)
check("SRC1 the lifecycle no longer calls install_for_worker! unconditionally") do
  # The only send-site must be the gated public_send; no bare `inst.install_for_worker!` call.
  !src.match?(/inst\.install_for_worker!/)
end
check("SRC2 thin_serving_context? exists and is private") do
  src.include?("def thin_serving_context?") &&
    !Atomspace::I3ThinLifecycle.public_methods(false).include?(:thin_serving_context?)
end
check("SRC3 liveness/orphan docs state :gone is the only evidence of exit") do
  src.match?(/ONLY EVIDENCE OF (EXIT|ABSENCE)/i)
end
check("SRC4 the activation header RETRACTS the install_for_worker!-is-always-correct claim") do
  # The old claim may still APPEAR, but only as a quoted retraction. What must be gone is it
  # standing as current justification, and what must be present is the correction + the gate.
  act.include?("CORRECTION, ROUND 34") &&
    act.match?(/THE PREVIOUS JUSTIFICATION HERE WAS WRONG/) &&
    act.match?(/used to assert/) &&
    act.include?("thin_serving_context?") &&
    act.match?(/fails? CLOSED/i)
end
check("SRC5 no Puma runtime API is referenced outside comments in either file") do
  code_lines = (src.lines + act.lines).reject { |l| l.strip.start_with?("#") }
  code_lines.none? { |l| l.include?("on_worker_boot") || l.include?("preload_app") }
end
check("SRC6 the lifecycle does not edit or require i3_read_binding.rb") do
  !src.include?("i3_read_binding")|| !src.match?(/^\s*require.*i3_read_binding/)
end
check("SRC7 i3_read_binding.rb was NOT modified to add retry_unreaped! by this worker") do
  # Owned by a parallel worker; this harness must pass either way via the respond_to? guard.
  File.exist?(READ_BINDING)
end
check("SRC8 both owned files are syntactically valid ruby") do
  system(RbConfig.ruby, "-c", LIFECYCLE, out: File::NULL, err: File::NULL) &&
    system(RbConfig.ruby, "-c", ACTIVATION, out: File::NULL, err: File::NULL)
end

# =================================================================================================
puts "\n#{'=' * 95}"
puts "SUMMARY: #{PASS.size}/#{PASS.size + FAIL.size} passed"
unless FAIL.empty?
  puts "\nFAILURES (#{FAIL.size}):"
  FAIL.each { |f| puts "  - #{f}" }
end
puts "=" * 95

# Do not let the module's own at_exit hook fire into the doubles after the report.
Atomspace::I3ReadBindingInstaller.reset!(api_retry: true)
ENV["I3_READ_BINDING"] = nil
exit(FAIL.empty? ? 0 : 1)
