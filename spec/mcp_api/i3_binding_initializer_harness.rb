# frozen_string_literal: true

# =================================================================================================
# PLAIN-RUBY HARNESS for config/initializers/i3_read_binding.rb
# =================================================================================================
#
# NO Rails, NO card, NO decko, NO database, NO network, NO child process. Run it with:
#
#     cd E:/GitHub/Magi-AGI/av-view-deck && ruby spec/mcp_api/i3_binding_initializer_harness.rb
#
# WHY A HARNESS AND NOT A SPEC. `card` (1.110.0), `decko` (0.20.0) and railties are not installed
# on this host and there is no Postgres, so a request spec cannot boot. The properties under test
# are pure control flow over ENV, so they are provable with stubs -- and a harness that needs no DB
# can be run by anyone reviewing this change.
#
# WHAT IS STUBBED, and why that does not weaken the proof. `Atomspace::I3ReadPort`,
# `LocalI3ReadBinding`, `I2StdioTransport::Spawn` and `I2ReaderProcessClient` are replaced by
# recording doubles, so the harness observes exactly WHICH collaborator the initializer called and
# with what -- including the thing that matters most: whether the port ended up BOUND or RESET on
# each failure path. The real classes' own contracts (absolute-path refusal, partial-reader
# refusal) are covered by their own specs; what was never covered before is the BOOT DECISION, and
# that is what this file pins down.
#
# The initializer is loaded with `Rails` UNDEFINED, so its `after_initialize` hook does not
# register and `install!` is driven directly -- which is also test 6's double-run mechanism.
#
# -------------------------------------------------------------------------------------------------
# WHAT THIS HARNESS DOES **NOT** PROVE -- read this before treating green as deployment evidence
# -------------------------------------------------------------------------------------------------
# * No real process is ever spawned. `Spawn` is a double, so NOTHING here proves the real
#   `Open3.popen3` call works, that the Python child starts, or that `stop!` really reaps a pid.
#   Tests 8-11 prove the initializer's OWNERSHIP BOOKKEEPING and the exact sequence of calls it
#   makes to `stop!`; they do not prove a process died.
# * No real fork happens. Tests 9a-9c simulate inheritance by WRITING a foreign pid into
#   `@installed_pid`, which is exactly the state a fork leaves behind but is not a fork. Real
#   prefork FD inheritance is not exercised.
# * No Rails, so the `after_initialize` registration at the bottom of the initializer is NEVER
#   EXECUTED here, and `on_worker_boot` (which lives in config/puma.rb and is NOT applied by this
#   change) is not executed either. Tests 12 and 13 assert on the DECISION and the DOCUMENTED
#   requirement, not on a hook firing.
# * No HTTP, no controller, no 503 is ever observed. "port unwired => 503" is `I3ReadPort`'s own
#   contract (i3_read_port.rb:62), asserted elsewhere; here "unwired" means `impl.nil?`.
# =================================================================================================

require "json"

PASS = []
FAIL = []

def check(label)
  ok = yield
  (ok ? PASS : FAIL) << label
  puts "#{ok ? 'PASS' : 'FAIL'}: #{label}"
rescue StandardError => e
  FAIL << "#{label} (raised #{e.class}: #{e.message})"
  puts "FAIL: #{label} (raised #{e.class}: #{e.message})"
end

INITIALIZER = File.expand_path("../../config/initializers/i3_read_binding.rb", __dir__)
abort "initializer not found at #{INITIALIZER}" unless File.exist?(INITIALIZER)

TRANSPORT = File.expand_path("../../mod/mcp_api/lib/atomspace/i2_stdio_transport.rb", __dir__)
PUMA_CONFIG = File.expand_path("../../config/puma.rb", __dir__)

# ---- recording doubles ---------------------------------------------------------------------------

module Atomspace
  # Stands in for the port. Records bind!/reset! so a failure path that leaves a BOUND port is
  # detectable (the exact bug class the fail-closed requirement is about).
  module I3ReadPort
    class << self
      attr_reader :impl, :reset_count, :bind_count

      def bind!(impl)
        @impl = impl
        @bind_count = (@bind_count || 0) + 1
      end

      def reset!
        @impl = nil
        @reset_count = (@reset_count || 0) + 1
      end

      def clear_counters!
        @impl = nil
        @reset_count = 0
        @bind_count = 0
      end
    end
  end

  class LocalI3ReadBinding
    ORIGIN_LIVE = "live"

    class << self
      attr_reader :calls

      # `$binding_behaviour` selects: :ok, :decline (the real method's nil-reader answer, which
      # resets the port itself -- local_i3_read_binding.rb:117-131), or :raise.
      def install!(reader:, origin: ORIGIN_LIVE)
        @calls ||= []
        @calls << { reader: reader, origin: origin }
        raise "simulated LocalI3ReadBinding.install! failure" if $binding_behaviour == :raise

        if $binding_behaviour == :decline
          Atomspace::I3ReadPort.reset!
          return false
        end

        Atomspace::I3ReadPort.bind!(new)
        true
      end

      def clear_calls!
        @calls = []
      end
    end
  end

  module I2StdioTransport
    # Spawn double. `$spawn_behaviour` selects: :ok (hand back fake pipes) or :raise.
    #
    # `stop!` MIRRORS THE REAL METHOD NAME AND RETURN CONTRACT deliberately
    # (i2_stdio_transport.rb:358-401: "@return [Symbol] :confirmed ... otherwise :unconfirmed").
    # Test 13d asserts the real file still defines `def stop!`, so this double cannot drift into
    # proving a method that does not exist.
    class Spawn
      attr_reader :writer, :reader, :stop_calls

      def initialize(interpreter:, script:, sidecar_path:, config:)
        $spawn_args = { interpreter: interpreter, script: script,
                        sidecar_path: sidecar_path, config: config }
        @writer = :fake_stdin
        @reader = :fake_stdout
        @stop_calls = 0
      end

      def start!
        $spawn_started = ($spawn_started || 0) + 1
        raise "simulated spawn failure (child could not be started)" if $spawn_behaviour == :raise

        $spawned_objects << self
        self
      end

      # `$stop_verdict` selects :confirmed / :unconfirmed, and `$stop_behaviour == :raise` makes
      # the shutdown path itself blow up (which must still be treated as UNCONFIRMED).
      def stop!
        @stop_calls += 1
        $spawn_stopped = ($spawn_stopped || 0) + 1
        raise "simulated stop! failure" if $stop_behaviour == :raise

        $stop_verdict || :confirmed
      end
    end

    # A Spawn-shaped object with NO stop! at all, to prove the initializer never assumes an API:
    # an unstoppable child must be reported UNCONFIRMED and RETAINED, not silently dropped.
    class StoplessSpawn < Spawn
      undef_method :stop!
    end
  end

  class I2ReaderProcessClient
    attr_reader :writer, :reader, :deadline_ms

    # `$client_behaviour == :raise` simulates the post-spawn client-construction failure that used
    # to orphan the started child.
    def initialize(writer:, reader:, deadline_ms: 5_000)
      raise "simulated client construction failure" if $client_behaviour == :raise

      @writer = writer
      @reader = reader
      @deadline_ms = deadline_ms
    end
  end
end

# Logger double: captures every line so tests can assert on the TEXT (no config values leaked).
class CapturingLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def warn(msg)  = @lines << [:warn, msg.to_s]
  def info(msg)  = @lines << [:info, msg.to_s]
  def error(msg) = @lines << [:error, msg.to_s]
end

# Load the initializer with Rails undefined so the after_initialize hook does NOT register.
load INITIALIZER

INSTALLER = Atomspace::I3ReadBindingInstaller

# Captured BEFORE any install so test 11a can prove the shutdown hook is registered BY a bind and
# was not merely pre-set.
HOOK_PID_AT_LOAD = INSTALLER.shutdown_hook_pid

# Define Rails AFTER loading, so `log` finds a logger but the hook never ran.
module Rails
  class << self
    attr_accessor :logger
  end
end

# Secret-ish sentinels: if any appears in a log line, the initializer leaked a config value.
SENTINELS = {
  "I3_I2_INTERPRETER" => "/opt/secret-sentinel-python/bin/python3.12",
  # STORE's launcher, which is the projection-capable service (see test 13a-13c).
  "I3_I2_SCRIPT" => "/opt/secret-sentinel-store/sidecar/tools/i2_stdio_reader_service.py",
  "I3_STORE_SIDECAR_PATH" => "/opt/secret-sentinel-store/sidecar",
  "I3_I2_CONFIG" => JSON.generate(
    "page-max" => { "page-max-entries" => 50, "page-max-connections" => 20,
                    "page-max-bytes" => 65_536, "per-neighbour-link-max" => 5,
                    "refresh-max-participants" => 10 },
    "fanout-limit" => 8,
    "retention" => { "positions" => 4, "ms" => 60_000 }
  ),
  "I3_I2_DEADLINE_MS" => "4242"
}.freeze

# WEB_CONCURRENCY is read by the initializer's prefork guard (and by config/puma.rb:1), so the
# harness must control it explicitly or an ambient value would make every test non-deterministic.
ALL_KEYS = (["I3_READ_BINDING", "WEB_CONCURRENCY"] + SENTINELS.keys).freeze

def reset_world!(live: true, overrides: {}, drop: [])
  ALL_KEYS.each { |k| ENV.delete(k) }
  ENV["I3_READ_BINDING"] = "live" if live
  SENTINELS.each { |k, v| ENV[k] = v }
  overrides.each { |k, v| ENV[k] = v }
  drop.each { |k| ENV.delete(k) }

  Atomspace::I3ReadPort.clear_counters!
  Atomspace::LocalI3ReadBinding.clear_calls!
  INSTALLER.instance_variable_set(:@installed_pid, nil)
  INSTALLER.instance_variable_set(:@spawn, nil)
  INSTALLER.instance_variable_set(:@unreaped, [])
  INSTALLER.instance_variable_set(:@inherited_disowned, 0)
  # @shutdown_hook_pid is deliberately NOT reset: at_exit handlers cannot be unregistered, so
  # clearing it would pile one handler up per successful install in this process.
  $spawn_behaviour = :ok
  $client_behaviour = :ok
  $binding_behaviour = :ok
  $stop_behaviour = :ok
  $stop_verdict = :confirmed
  $spawn_started = 0
  $spawn_stopped = 0
  $spawn_args = nil
  $spawned_objects = []
  Rails.logger = CapturingLogger.new
end

def log_text = Rails.logger.lines.map(&:last).join("\n")
def warned? = Rails.logger.lines.any? { |lvl, _| lvl == :warn }

def leaked_sentinel
  SENTINELS.values.find { |v| log_text.include?(v) }
end

def foreign_pid = Process.pid + 1_000_000

puts "=" * 95
puts "I3 READ BINDING INITIALIZER HARNESS  (no Rails, no card, no DB, no child process)"
puts "initializer under test: #{INITIALIZER}"
puts "=" * 95

# ---- TEST 1: switch unset => install! never called, port unwired ---------------------------------
reset_world!(live: false)
result1 = INSTALLER.install!
check("1a switch unset => install! returns false") { result1 == false }
check("1b switch unset => LocalI3ReadBinding.install! NEVER called") do
  Atomspace::LocalI3ReadBinding.calls.empty?
end
check("1c switch unset => port left unwired (impl nil)") { Atomspace::I3ReadPort.impl.nil? }
check("1d switch unset => nothing spawned") { $spawn_started.zero? }
check("1e switch unset => silent (no warning spam on every normal boot)") { !warned? }

reset_world!(live: false, overrides: { "I3_READ_BINDING" => "LIVE" })
check("1f switch 'LIVE' (wrong case) => refused, no bind") do
  INSTALLER.install! == false && Atomspace::I3ReadPort.impl.nil? &&
    Atomspace::LocalI3ReadBinding.calls.empty?
end

reset_world!(live: false, overrides: { "I3_READ_BINDING" => "true" })
check("1g switch 'true' (not 'live') => refused, no bind") do
  INSTALLER.install! == false && Atomspace::I3ReadPort.impl.nil?
end

# ---- TEST 2: switch live but a required env var missing ------------------------------------------
SENTINELS.each_key do |key|
  reset_world!(drop: [key])
  res = INSTALLER.install!
  check("2 missing #{key} => no bind, port reset, warning, no value leaked") do
    res == false &&
      Atomspace::I3ReadPort.impl.nil? &&
      Atomspace::I3ReadPort.bind_count.zero? &&
      Atomspace::I3ReadPort.reset_count.positive? &&
      warned? &&
      log_text.include?(key) &&          # names the var...
      leaked_sentinel.nil? &&            # ...but leaks no value
      $spawn_started.zero?
  end
end

reset_world!(overrides: { "I3_I2_SCRIPT" => "   " })
check("2z blank (whitespace) I3_I2_SCRIPT => treated as missing, no bind") do
  INSTALLER.install! == false && Atomspace::I3ReadPort.impl.nil? && warned? &&
    leaked_sentinel.nil?
end

# ---- TEST 3: relative interpreter/script path => refused, no bind --------------------------------
[["I3_I2_INTERPRETER", "python3.12"],
 ["I3_I2_INTERPRETER", "./venv/bin/python"],
 ["I3_I2_SCRIPT", "tools/i2_stdio_reader_service.py"],
 ["I3_STORE_SIDECAR_PATH", "../store/sidecar"]].each do |key, bad|
  reset_world!(overrides: { key => bad })
  res = INSTALLER.install!
  check("3 relative #{key}=#{bad.inspect} => refused, port reset, nothing spawned") do
    res == false &&
      Atomspace::I3ReadPort.impl.nil? &&
      Atomspace::I3ReadPort.bind_count.zero? &&
      Atomspace::I3ReadPort.reset_count.positive? &&
      warned? &&
      $spawn_started.zero? &&
      !log_text.include?(bad)            # the bad path itself is not echoed
  end
end

reset_world!(overrides: { "I3_I2_INTERPRETER" => "C:/Python312/python.exe" })
check("3z windows drive-letter path accepted as absolute (binds)") do
  INSTALLER.install! == true && !Atomspace::I3ReadPort.impl.nil?
end

# ---- TEST 4: malformed I3_I2_CONFIG JSON => refused, no bind -------------------------------------
["{not json", "", "   ", "[1,2,3]", "null", "42", '"a string"', "{\"page-max\":"].each do |bad|
  reset_world!(overrides: { "I3_I2_CONFIG" => bad })
  res = INSTALLER.install!
  check("4 malformed I3_I2_CONFIG #{bad.inspect} => refused, no bind, nothing spawned") do
    res == false &&
      Atomspace::I3ReadPort.impl.nil? &&
      Atomspace::I3ReadPort.bind_count.zero? &&
      Atomspace::I3ReadPort.reset_count.positive? &&
      warned? &&
      $spawn_started.zero?
  end
end

["0", "-1", "abc", "5.5", ""].each do |bad|
  reset_world!(overrides: { "I3_I2_DEADLINE_MS" => bad })
  check("4b bad I3_I2_DEADLINE_MS #{bad.inspect} => refused, no bind") do
    INSTALLER.install! == false && Atomspace::I3ReadPort.impl.nil? &&
      Atomspace::I3ReadPort.bind_count.zero?
  end
end

# ---- TEST 5: spawn raises => port left reset, boot continues -------------------------------------
reset_world!
$spawn_behaviour = :raise
res5 = nil
boot_survived = begin
  res5 = INSTALLER.install!
  true
rescue StandardError, ScriptError
  false
end
check("5a spawn raises => install! does NOT propagate (boot continues)") { boot_survived }
check("5b spawn raises => returns false") { res5 == false }
check("5c spawn raises => port left RESET (unwired, => 503)") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero? &&
    Atomspace::I3ReadPort.reset_count.positive?
end
check("5d spawn raises => warned, and no config value in the log") do
  warned? && leaked_sentinel.nil?
end
check("5e spawn raises => LocalI3ReadBinding.install! never reached") do
  Atomspace::LocalI3ReadBinding.calls.empty?
end
check("5f spawn raises => nothing to stop, so stop! is NOT called on a non-existent child") do
  $spawn_stopped.zero? && INSTALLER.unreaped_spawns.empty?
end

# ---- TEST 6: happy path -- install! called exactly once, ORIGIN_LIVE, once under double-run -------
reset_world!
res6 = INSTALLER.install!
calls = Atomspace::LocalI3ReadBinding.calls
check("6a happy path => install! returns true") { res6 == true }
check("6b happy path => LocalI3ReadBinding.install! called EXACTLY once") { calls.size == 1 }
check("6c happy path => origin is ORIGIN_LIVE ('live')") do
  calls.first[:origin] == Atomspace::LocalI3ReadBinding::ORIGIN_LIVE &&
    calls.first[:origin] == "live"
end
check("6d happy path => reader is the I2ReaderProcessClient (not a raw spawn/pipe)") do
  calls.first[:reader].is_a?(Atomspace::I2ReaderProcessClient)
end
check("6e happy path => client got the child's writer/reader and the configured deadline") do
  r = calls.first[:reader]
  r.writer == :fake_stdin && r.reader == :fake_stdout && r.deadline_ms == 4242
end
check("6f happy path => Spawn got the 3 absolute paths + parsed Hash config") do
  $spawn_args[:interpreter] == SENTINELS["I3_I2_INTERPRETER"] &&
    $spawn_args[:script] == SENTINELS["I3_I2_SCRIPT"] &&
    $spawn_args[:sidecar_path] == SENTINELS["I3_STORE_SIDECAR_PATH"] &&
    $spawn_args[:config].is_a?(Hash) &&
    $spawn_args[:config]["fanout-limit"] == 8 &&
    $spawn_args[:config]["page-max"]["page-max-bytes"] == 65_536
end
check("6g happy path => port is BOUND") { !Atomspace::I3ReadPort.impl.nil? }
check("6k happy path => ownership recorded for THIS pid, and the spawn is retained") do
  INSTALLER.installed_pid == Process.pid && !INSTALLER.owned_spawn.nil?
end
check("6l happy path => the owned child was NOT stopped") { $spawn_stopped.zero? }

# run the body a SECOND and THIRD time in the same process (eager-load / double after_initialize)
res6b = INSTALLER.install!
res6c = INSTALLER.install!
check("6h double/triple run => still returns true (idempotent)") { res6b == true && res6c == true }
check("6i double/triple run => LocalI3ReadBinding.install! STILL called only once") do
  Atomspace::LocalI3ReadBinding.calls.size == 1
end
check("6j double/triple run => AT MOST ONE child spawned per process") { $spawn_started == 1 }

# ---- TEST 7: FixtureI3ReadPort is never referenced -----------------------------------------------
src = File.read(INITIALIZER)
# Strip the header/doc comments: the file DOCUMENTS that it never falls back to fixtures, so the
# word legitimately appears in prose. What must not exist is executable reachability.
code_only = src.lines.reject { |l| l.strip.start_with?("#") }.join
# Also strip double-quoted string literals: the fail-closed WARNING TEXT deliberately tells the
# operator "No fixture or synthetic reader is ever substituted", which is a message, not a
# reference. What test 7b must prove is that no CONSTANT, METHOD CALL or REQUIRE can reach one.
executable_only = code_only.gsub(/"(?:[^"\\]|\\.)*"/m, '""')
check("7a initializer CODE contains no /Fixture/ reference") { code_only !~ /Fixture/ }
check("7b initializer EXECUTABLE code (strings stripped) has no fixture/golden token") do
  executable_only !~ /fixture|golden|sample/i
end
check("7b2 the word 'fixture' survives ONLY inside the operator warning string") do
  code_only =~ /fixture/i && executable_only !~ /fixture/i
end
check("7c initializer never requires a fixture file") { src !~ /require.*fixture/i }
check("7d FixtureI3ReadPort constant was never even defined by loading the initializer") do
  !Atomspace.const_defined?(:FixtureI3ReadPort, false)
end
check("7e no env/Rails.env branch could select a non-live reader") do
  code_only !~ /Rails\.env|RAILS_ENV|\.test\?|\.development\?/
end

# =================================================================================================
# TEST 8 -- BLOCKER 1 REGRESSION: INSTALL FIRST, **THEN** TURN THE SWITCH OFF
# =================================================================================================
# WHAT THE OLD CODE DID, and why test 1 could not catch it. The old line 91 was
# `return false unless ENV["I3_READ_BINDING"] == LIVE` -- an early return that NEVER called
# `reset_port!`. Test 1 starts from an already-unwired port, so "unwired afterwards" was true for
# the wrong reason and the bug was invisible. Here the port is BOUND FIRST. Against the old code
# 8c/8d/8e/8f all FAIL: the port kept the stale live impl, `@installed_pid` kept claiming this
# process, and the child was never stopped.
reset_world!
check("8a precondition: a successful install leaves the port BOUND and owned") do
  INSTALLER.install! == true && !Atomspace::I3ReadPort.impl.nil? &&
    INSTALLER.installed_pid == Process.pid
end
bound_spawn = INSTALLER.owned_spawn
resets_before_switch_off = Atomspace::I3ReadPort.reset_count
ENV.delete("I3_READ_BINDING")
res8 = INSTALLER.install!
check("8b switch turned off AFTER a successful install => returns false") { res8 == false }
check("8c switch off after install => the port is RESET (no stale live binding survives)") do
  Atomspace::I3ReadPort.impl.nil? &&
    Atomspace::I3ReadPort.reset_count > resets_before_switch_off
end
check("8d switch off after install => install state is CLEARED (installed_pid nil)") do
  INSTALLER.installed_pid.nil?
end
check("8e switch off after install => the owned child was stopped EXACTLY once") do
  $spawn_stopped == 1 && bound_spawn.stop_calls == 1
end
check("8f switch off after install => a confirmed stop drops the spawn reference") do
  INSTALLER.owned_spawn.nil? && INSTALLER.unreaped_spawns.empty?
end
check("8g switch off after install => warned (this one IS worth a warning), no value leaked") do
  warned? && leaked_sentinel.nil?
end
check("8h switch off after install => no NEW child was spawned") { $spawn_started == 1 }

# A SECOND call with the switch still off must be a silent no-op, not a second stop.
Rails.logger = CapturingLogger.new
res8i = INSTALLER.install!
check("8i switch off, second call => still false, and now SILENT (no warn spam per boot)") do
  res8i == false && !warned?
end
check("8j switch off, second call => does NOT stop anything a second time") { $spawn_stopped == 1 }

# And the switch-off teardown must survive an UNCONFIRMED stop without losing the reference.
reset_world!
INSTALLER.install!
unconf_spawn = INSTALLER.owned_spawn
$stop_verdict = :unconfirmed
ENV.delete("I3_READ_BINDING")
INSTALLER.install!
check("8k switch off + UNCONFIRMED stop => port still unwired and claim cleared") do
  Atomspace::I3ReadPort.impl.nil? && INSTALLER.installed_pid.nil?
end
check("8l switch off + UNCONFIRMED stop => the spawn reference is RETAINED, not dropped") do
  INSTALLER.unreaped_spawns.include?(unconf_spawn) && unconf_spawn.stop_calls == 1
end

# =================================================================================================
# TEST 9 -- BLOCKER 2(a) REGRESSION: AN INHERITED (FORKED) BINDING MUST NOT BE SERVED
# =================================================================================================
# config/puma.rb:1 is `workers Integer(ENV["WEB_CONCURRENCY"] || 0)` and :6 is `preload_app!`, so
# `after_initialize` runs in the MASTER and workers inherit the bound port and the master's pipe
# FDs without calling install! at all. Two writers on one newline-delimited stdin corrupts frames.
#
# WHAT THE OLD CODE DID: `install!` bound happily in the master regardless of WEB_CONCURRENCY, and
# nothing anywhere noticed an inherited claim -- so 9a/9b/9c/9d/9h all FAIL against it.
#
# HONEST LIMIT: no fork happens here. "Inherited" is simulated by writing a FOREIGN pid into
# `@installed_pid`, which is the exact state a fork leaves, but FD inheritance is not exercised.

# 9a-9d: the ownership guard disowns a foreign claim and fails closed.
reset_world!
INSTALLER.install!
inherited_spawn = INSTALLER.owned_spawn
INSTALLER.instance_variable_set(:@installed_pid, foreign_pid)   # <= simulate the fork
Rails.logger = CapturingLogger.new
resets_before_guard = Atomspace::I3ReadPort.reset_count
guard_answer = INSTALLER.ensure_owned_binding!
check("9a inherited binding => ensure_owned_binding! answers false (may NOT serve)") do
  guard_answer == false
end
check("9b inherited binding => the port is RESET rather than served on parent pipes") do
  Atomspace::I3ReadPort.impl.nil? &&
    Atomspace::I3ReadPort.reset_count > resets_before_guard
end
check("9c inherited binding => the foreign claim is dropped and counted") do
  INSTALLER.installed_pid.nil? && INSTALLER.inherited_disowned_count == 1
end
check("9d inherited binding => the PARENT's child is NOT stopped from here") do
  $spawn_stopped.zero? && inherited_spawn.stop_calls.zero?
end
check("9e inherited binding => warned, no config value leaked") { warned? && leaked_sentinel.nil? }
check("9f ensure_owned_binding! is idempotent and true when there is no claim at all") do
  INSTALLER.ensure_owned_binding! == true
end
check("9g ensure_owned_binding! is true for a claim this process owns") do
  INSTALLER.instance_variable_set(:@installed_pid, Process.pid)
  INSTALLER.ensure_owned_binding! == true
end

# 9h-9k: install! REFUSES on the after_initialize path under a preforking WEB_CONCURRENCY, and
# install_for_worker! is the entry point that is allowed to bind there.
reset_world!(overrides: { "WEB_CONCURRENCY" => "2" })
res9h = INSTALLER.install!
check("9h WEB_CONCURRENCY=2 => install! (the after_initialize path) REFUSES to bind") do
  res9h == false && Atomspace::I3ReadPort.impl.nil? &&
    Atomspace::I3ReadPort.bind_count.zero? &&
    Atomspace::I3ReadPort.reset_count.positive?
end
check("9i WEB_CONCURRENCY=2 => nothing is spawned in the master") { $spawn_started.zero? }
check("9j the refusal names the env var and the required on_worker_boot fix, leaks no value") do
  warned? && log_text.include?("WEB_CONCURRENCY") &&
    log_text.include?("on_worker_boot") &&
    log_text.include?("install_for_worker!") &&
    leaked_sentinel.nil?
end

reset_world!(overrides: { "WEB_CONCURRENCY" => "2" })
check("9k WEB_CONCURRENCY=2 => install_for_worker! DOES bind (it runs after the fork)") do
  INSTALLER.install_for_worker! == true && !Atomspace::I3ReadPort.impl.nil? &&
    INSTALLER.installed_pid == Process.pid && $spawn_started == 1
end

# 9l: a worker that inherited a claim disowns it and then starts ITS OWN child.
reset_world!(overrides: { "WEB_CONCURRENCY" => "2" })
INSTALLER.install_for_worker!
parent_spawn = INSTALLER.owned_spawn
INSTALLER.instance_variable_set(:@installed_pid, foreign_pid)   # <= simulate the fork
res9l = INSTALLER.install_for_worker!
check("9l forked worker => disowns the inherited claim, then spawns its OWN child") do
  res9l == true &&
    INSTALLER.inherited_disowned_count == 1 &&
    $spawn_started == 2 &&
    INSTALLER.owned_spawn != parent_spawn &&
    INSTALLER.installed_pid == Process.pid
end
check("9m forked worker => never stops the child it inherited (not its process)") do
  parent_spawn.stop_calls.zero?
end

# =================================================================================================
# TEST 10 -- BLOCKER 3 REGRESSION: A POST-SPAWN FAILURE MUST NOT ORPHAN THE STARTED CHILD
# =================================================================================================
# WHAT THE OLD CODE DID: `bind!` started the child at :122-127 but only retained it at :141, AFTER
# LocalI3ReadBinding.install!. A client constructor that raised, or a declined install, went to the
# rescue -- which reset the port and returned false WITHOUT any reference to the started child. One
# leaked process and one leaked pipe pair per failed attempt. 10a4/10b4/10c4/10d4 all FAIL against
# the old code, because `$spawn_stopped` stayed 0.
#
# The stop API used is `Spawn#stop!` -- the REAL method (i2_stdio_transport.rb:358), asserted to
# still exist by test 13d.

# 10a: the client constructor raises.
reset_world!
$client_behaviour = :raise
res10a = INSTALLER.install!
failed_spawn_a = $spawned_objects.first
check("10a1 client ctor raises => install! returns false and does not propagate") { res10a == false }
check("10a2 client ctor raises => the port is left UNWIRED") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero? &&
    Atomspace::I3ReadPort.reset_count.positive?
end
check("10a3 client ctor raises => the child HAD been started") { $spawn_started == 1 }
check("10a4 client ctor raises => the started child is stopped EXACTLY once (no orphan)") do
  $spawn_stopped == 1 && failed_spawn_a.stop_calls == 1
end
check("10a5 client ctor raises => a confirmed stop clears ownership completely") do
  INSTALLER.installed_pid.nil? && INSTALLER.owned_spawn.nil? &&
    INSTALLER.unreaped_spawns.empty?
end
check("10a6 client ctor raises => warned with the exception CLASS only, no value leaked") do
  warned? && log_text.include?("RuntimeError") && leaked_sentinel.nil? &&
    !log_text.include?("simulated client construction failure")
end
check("10a7 client ctor raises => LocalI3ReadBinding.install! never reached") do
  Atomspace::LocalI3ReadBinding.calls.empty?
end

# 10b: LocalI3ReadBinding.install! returns FALSEY.
reset_world!
$binding_behaviour = :decline
res10b = INSTALLER.install!
failed_spawn_b = $spawned_objects.first
check("10b1 binding declines => install! returns false") { res10b == false }
check("10b2 binding declines => the port is left UNWIRED") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero?
end
check("10b3 binding declines => the child HAD been started") { $spawn_started == 1 }
check("10b4 binding declines => the started child is stopped EXACTLY once (no orphan)") do
  $spawn_stopped == 1 && failed_spawn_b.stop_calls == 1
end
check("10b5 binding declines => ownership cleared, nothing retained") do
  INSTALLER.installed_pid.nil? && INSTALLER.owned_spawn.nil? &&
    INSTALLER.unreaped_spawns.empty?
end
check("10b6 binding declines => warned, no config value leaked") { warned? && leaked_sentinel.nil? }

# 10c: LocalI3ReadBinding.install! RAISES.
reset_world!
$binding_behaviour = :raise
res10c = INSTALLER.install!
failed_spawn_c = $spawned_objects.first
check("10c1 binding raises => install! returns false and does not propagate") { res10c == false }
check("10c2 binding raises => the port is left UNWIRED") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero?
end
check("10c3 binding raises => the started child is stopped EXACTLY once (no orphan)") do
  $spawn_started == 1 && $spawn_stopped == 1 && failed_spawn_c.stop_calls == 1
end
check("10c4 binding raises => class named, message NOT echoed") do
  warned? && log_text.include?("RuntimeError") &&
    !log_text.include?("simulated LocalI3ReadBinding.install! failure") &&
    leaked_sentinel.nil?
end

# 10d: the stop itself is UNCONFIRMED => ownership is RETAINED, not dropped.
reset_world!
$client_behaviour = :raise
$stop_verdict = :unconfirmed
INSTALLER.install!
unconfirmed_spawn = $spawned_objects.first
check("10d1 unconfirmed stop => the port is STILL left unwired") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero?
end
check("10d2 unconfirmed stop => stop! was attempted exactly once") do
  $spawn_stopped == 1 && unconfirmed_spawn.stop_calls == 1
end
check("10d3 unconfirmed stop => the reference is RETAINED in unreaped_spawns") do
  INSTALLER.unreaped_spawns.include?(unconfirmed_spawn)
end
check("10d4 unconfirmed stop => the spawn is not silently dropped from ownership") do
  !INSTALLER.owned_spawn.nil? && INSTALLER.installed_pid.nil?
end
check("10d5 unconfirmed stop => the verdict is reported in the warning") do
  warned? && log_text.include?("unconfirmed")
end

# 10e: stop! itself RAISES => still unconfirmed, still retained, still no raise out of boot.
reset_world!
$client_behaviour = :raise
$stop_behaviour = :raise
raising_stop_survived = begin
  INSTALLER.install! == false
rescue StandardError, ScriptError
  false
end
raising_spawn = $spawned_objects.first
check("10e1 stop! raises => install! still returns false without propagating") do
  raising_stop_survived
end
check("10e2 stop! raises => treated as UNCONFIRMED and the reference is retained") do
  INSTALLER.unreaped_spawns.include?(raising_spawn) && raising_spawn.stop_calls == 1
end
check("10e3 stop! raises => the port is still left unwired") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero?
end

# 10f: a child with NO stop! API at all must be retained, never assumed reaped.
reset_world!
$client_behaviour = :raise
stopless = nil
Atomspace::I2StdioTransport::Spawn.singleton_class.send(:alias_method, :orig_new, :new)
Atomspace::I2StdioTransport::Spawn.singleton_class.send(:define_method, :new) do |**kwargs|
  stopless = Atomspace::I2StdioTransport::StoplessSpawn.allocate
  stopless.send(:initialize, **kwargs)
  stopless
end
INSTALLER.install!
Atomspace::I2StdioTransport::Spawn.singleton_class.send(:alias_method, :new, :orig_new)
check("10f1 a child with no stop! API => NOT assumed reaped; retained as unreaped") do
  !stopless.respond_to?(:stop!) && INSTALLER.unreaped_spawns.include?(stopless)
end
check("10f2 a child with no stop! API => the port is still left unwired") do
  Atomspace::I3ReadPort.impl.nil? && Atomspace::I3ReadPort.bind_count.zero?
end

# =================================================================================================
# TEST 11 -- OWNED-CHILD SHUTDOWN PATH (the ROLLBACK claim that "restarting Rails reaps it")
# =================================================================================================
# WHAT THE OLD CODE DID: nothing connected `Spawn#stop!` to process exit, so the runbook's claim
# was false of this file. 11a FAILS against the old code (there was no shutdown hook at all) and
# 11b-11e FAIL because `shutdown_owned_child!` did not exist.
#
# HONEST LIMIT: `at_exit` is REGISTERED here but this harness does not kill the process to watch it
# fire, and at_exit never runs on SIGKILL or a hard crash -- so the runbook's "check for a
# survivor" step is still required. 11a proves registration; 11b-11e drive the hook's body
# directly.
check("11a a shutdown hook was NOT pre-set at load, and IS registered after a bind") do
  HOOK_PID_AT_LOAD.nil? && INSTALLER.shutdown_hook_pid == Process.pid
end

reset_world!
INSTALLER.install!
shutdown_spawn = INSTALLER.owned_spawn
verdict11 = INSTALLER.shutdown_owned_child!
check("11b shutdown_owned_child! reports the Spawn's own verdict") { verdict11 == :confirmed }
check("11c shutdown_owned_child! leaves the port UNWIRED and the claim cleared") do
  Atomspace::I3ReadPort.impl.nil? && INSTALLER.installed_pid.nil? &&
    INSTALLER.owned_spawn.nil?
end
check("11d shutdown_owned_child! stopped the child exactly once") do
  $spawn_stopped == 1 && shutdown_spawn.stop_calls == 1
end
check("11e shutdown_owned_child! is idempotent: a second call owns nothing and stops nothing") do
  INSTALLER.shutdown_owned_child! == :not_owned && $spawn_stopped == 1
end

reset_world!
INSTALLER.install!
foreign_owned = INSTALLER.owned_spawn
INSTALLER.instance_variable_set(:@installed_pid, foreign_pid)
check("11f shutdown_owned_child! refuses to stop a child owned by ANOTHER pid") do
  INSTALLER.shutdown_owned_child! == :not_owned && foreign_owned.stop_calls.zero?
end

# =================================================================================================
# TEST 12 -- the prefork decision is exactly "will puma fork?", and fails CLOSED when unreadable
# =================================================================================================
[[nil, true,  "unset => single process => the after_initialize path may bind"],
 ["0", true,  "explicit 0 => single process => may bind"],
 [" 0 ", true, "whitespace-padded 0 => single process => may bind"],
 ["1", false, "1 worker => puma forks => after_initialize path must refuse"],
 ["8", false, "8 workers => puma forks => after_initialize path must refuse"],
 ["abc", false, "UNPARSEABLE => treated as preforking (fail-closed), never as 0"],
 ["-1", false, "negative => unparseable by this guard => fail-closed refusal"],
 ["2x", false, "trailing garbage => fail-closed refusal"]].each do |value, may_bind, why|
  if value.nil?
    reset_world!
    ENV.delete("WEB_CONCURRENCY")
  else
    reset_world!(overrides: { "WEB_CONCURRENCY" => value })
  end
  res = INSTALLER.install!
  check("12 WEB_CONCURRENCY=#{value.inspect}: #{why}") do
    if may_bind
      res == true && !Atomspace::I3ReadPort.impl.nil?
    else
      res == false && Atomspace::I3ReadPort.impl.nil? &&
        Atomspace::I3ReadPort.bind_count.zero? && $spawn_started.zero?
    end
  end
end

# =================================================================================================
# TEST 13 -- BLOCKER 4: the initializer must name the PROJECTION-CAPABLE script, and the operator
#            requirements it cannot apply itself must be stated
# =================================================================================================
# GROUNDING (all read-only, all in this workspace):
#   * av-store-sidecar/tools/i2_stdio_reader_service.py:48 hands over to
#     `i2_stdio_service.main()`; av-store-sidecar/atomspace_mirror_sidecar/i2_stdio_service.py:116
#     has `store-projection` in CONFIG_KEYS and :274-275 loads the attested partial card. That is
#     the projection-capable service.
#   * av-view-deck/tools/i2_stdio_reader_server.py has NO store-projection: grep finds the token
#     only at :312 inside `--seed-from-golden-vectors` (a different, operator-only, argv-driven
#     path that Spawn cannot trigger -- i2_stdio_transport.rb:314-316 passes no argv).
check("13a initializer names the STORE service script i2_stdio_reader_service.py") do
  src.include?("i2_stdio_reader_service.py")
end
check("13b initializer explicitly marks the deck's i2_stdio_reader_server.py as NOT the target") do
  src =~ /i2_stdio_reader_server\.py\s+<==\s+NOT THIS ONE/
end
check("13c the OLD wording ('ABSOLUTE path to the deck's tools/...') is gone") do
  src !~ /ABSOLUTE path to the deck's tools/
end
check("13d grounding: Spawn really does define `stop!` (the API this file now calls)") do
  File.read(TRANSPORT) =~ /^\s*def stop!\s*$/
end
check("13e grounding: config/puma.rb really does prefork + preload (why 9h/9j exist)") do
  puma = File.read(PUMA_CONFIG)
  puma.include?("WEB_CONCURRENCY") && puma.include?("preload_app!")
end
check("13f initializer documents the exact on_worker_boot snippet the operator must apply") do
  src.include?("on_worker_boot") && src.include?("install_for_worker!") &&
    src.include?("WEB_CONCURRENCY=0")
end
check("13g initializer states plainly that config/puma.rb is NOT edited by this change") do
  src =~ /NOT EDITED BY THIS CHANGE/
end
check("13h initializer documents the at_exit shutdown path AND its SIGKILL limit") do
  src.include?("at_exit") && src =~ /SIGKILL/
end
check("13i the projection-capable script's own source confirms store-projection support") do
  service = File.expand_path("../../../av-store-sidecar/atomspace_mirror_sidecar/i2_stdio_service.rb",
                             __dir__).sub(/\.rb\z/, ".py")
  launcher = File.expand_path("../../../av-store-sidecar/tools/i2_stdio_reader_service.py", __dir__)
  next true unless File.exist?(service) && File.exist?(launcher) # read-only sibling repo may be absent

  File.read(service).include?("store-projection") &&
    File.read(launcher).include?("i2_stdio_service")
end

# ---- summary -------------------------------------------------------------------------------------
puts "=" * 95
puts "PASS: #{PASS.size}   FAIL: #{FAIL.size}   TOTAL: #{PASS.size + FAIL.size}"
unless FAIL.empty?
  puts "FAILURES:"
  FAIL.each { |f| puts "  - #{f}" }
end
puts "=" * 95

# Leave no claim behind: the at_exit hook registered by a successful bind would otherwise run
# against the doubles after this summary.
INSTALLER.instance_variable_set(:@installed_pid, nil)

exit(FAIL.empty? ? 0 : 1)
