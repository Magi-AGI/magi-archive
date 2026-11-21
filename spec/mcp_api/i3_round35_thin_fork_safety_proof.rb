# frozen_string_literal: true

# =================================================================================================
# ROUND-35 PROOF HARNESS -- D2 (serving-context proof) AND D3 (foreign retained-child cleanup)
# =================================================================================================
#
# Run it with:
#
#     cd E:/GitHub/Magi-AGI/av-view-deck && ruby spec/mcp_api/i3_round35_thin_fork_safety_proof.rb
#
# NO rspec, NO Rails, NO decko, NO DB. Same bare-ruby shape as
# spec/mcp_api/i3_round34_thin_lifecycle_proof.rb -- but with ONE DELIBERATE DIFFERENCE:
#
#   *** THE THIN AND EVENTMACHINE SIGNALS ARE PROVEN AGAINST THE **REAL** GEMS, NOT DOUBLES. ***
#
# The round-34 harness used a `ThinDouble`/`EventMachine` double. Those doubles can only prove the
# module's branching, never that the branch reads the real objects correctly. Both gems ARE
# installed on this host --
#     thin 2.0.1   C:/Users/Lake/.local/share/gem/ruby/3.4.0/gems/thin-2.0.1
#     eventmachine (real, loaded by thin)
# -- so every serving-context case below runs a REAL `Thin::Server` inside a REAL
# `EventMachine.run` reactor, in a REAL child ruby process, and (case T) is proven to actually
# serve an HTTP request. Case R1 additionally proves the REAL Thin version string this ran against.
#
# Each scenario needs a DIFFERENT global reactor/Thin state, and a started EventMachine reactor
# cannot be cleanly un-started and re-started with different topology inside one process, so every
# scenario runs in its OWN child ruby process and reports a JSON verdict back. The child loads the
# REAL deck sources (mod/mcp_api/lib/atomspace/i3_thin_lifecycle.rb + the REAL
# config/initializers/i3_read_binding.rb) -- no installer double, so "which entry point was
# selected" is read off the real module's own `activation_attempts` ledger.
#
# -------------------------------------------------------------------------------------------------
# THE TWO FINDINGS THIS FILE PROVES CLOSED (cpd034, verbatim)
# -------------------------------------------------------------------------------------------------
# D2 "Insufficient serving-context proof - mod/mcp_api/lib/atomspace/i3_thin_lifecycle.rb:574. An
#     unrelated reactor running in a prefork master makes `proven` true and selects
#     install_for_worker!, bypassing the master refusal at :536. Minimal fix: reactor activity
#     alone must not authorize the worker bypass."
#
# D3 "Foreign retained-child cleanup - config/initializers/i3_read_binding.rb:418. The sweep calls
#     every retained object's stop! without checking its creating process. Retained entries
#     survive fork/disown because disown_inherited! clears only the current claim and spawn
#     (:804-808). Minimal fix: retain per-spawn owner identity and exclude inherited foreign-owned
#     entries from stopping."
#
# -------------------------------------------------------------------------------------------------
# WHAT THIS HARNESS DOES **NOT** PROVE -- read before treating green as deployment evidence
# -------------------------------------------------------------------------------------------------
# * `Process.fork` DOES NOT EXIST ON THIS HOST (ruby 3.4.7 x64-mingw-ucrt: `Process.fork` raises
#   NotImplementedError -- verified, and asserted by case F0 below). The post-fork state in the D3
#   cases is therefore reproduced EXACTLY as a fork would leave it -- a retained entry in
#   `unreaped_spawns` whose recorded creating pid is a DIFFERENT, REAL, LIVE process -- by using
#   the pid of a REAL child ruby process this harness starts. The branch under test compares a
#   recorded pid against `Process.pid`, which is precisely the comparison a fork changes, so this
#   is a faithful reproduction of the inherited state; it is NOT a real fork, and that limit is
#   recorded explicitly.
# * NO PREFORKING MASTER IS REALLY FORKED either. "prefork master" is expressed the only way the
#   code can observe it: `WEB_CONCURRENCY` naming a forking deployment (the installer's own
#   `prefork_configured?` input) while no post-fork marker and no live Thin::Server exist.
# * NO I2/python child is spawned by the D2 cases: the point is WHICH INSTALLER ENTRY POINT is
#   selected, and the prefork refusal fires before any spawn. The D1 proof
#   (i3_round35_launcher_substitution_proof.rb) is the one that spawns a real child.
# * No 503 is observed over HTTP. "unwired => 503" is `I3ReadPort`'s own contract.
# =================================================================================================

require "json"
require "fileutils"

PASS = []
FAIL = []
LIMITS = []

def check(label)
  ok = yield
  (ok ? PASS : FAIL) << label
  puts "#{ok ? 'PASS' : 'FAIL'}: #{label}"
rescue StandardError, ScriptError => e
  FAIL << "#{label} (raised #{e.class}: #{e.message})"
  puts "FAIL: #{label} (raised #{e.class}: #{e.message})"
end

def limit(label)
  LIMITS << label
  puts "LIMIT (not a pass, not a failure): #{label}"
end

DECK          = File.expand_path("../..", __dir__)
LIFECYCLE     = File.join(DECK, "mod/mcp_api/lib/atomspace/i3_thin_lifecycle.rb")
READ_BINDING  = File.join(DECK, "config/initializers/i3_read_binding.rb")
PRE_LIFECYCLE = File.join(DECK, "mod/mcp_api/lib/atomspace/i3_thin_lifecycle.rb.bak-cpd035-pre")
PRE_BINDING   = File.join(DECK, "config/initializers/i3_read_binding.rb.bak-cpd035-pre")
abort "lifecycle not found at #{LIFECYCLE}" unless File.exist?(LIFECYCLE)

SCRATCH_ROOT = ENV.fetch(
  "I3_PROOF_SCRATCH",
  "C:/Users/Lake/AppData/Local/hermes/profiles/claudetriad/cache/scratch"
)
RUN_DIR = File.join(SCRATCH_ROOT, "i3_round35_fork_proof_#{Process.pid}")
FileUtils.rm_rf(RUN_DIR)
FileUtils.mkdir_p(RUN_DIR)

puts "=" * 99
puts "I3 ROUND-35 THIN/FORK SAFETY PROOF  (D2 + D3 -- REAL thin + REAL EventMachine)"
puts "lifecycle under test : #{LIFECYCLE}"
puts "binding under test   : #{READ_BINDING}"
puts "pre-fix baselines    : #{File.basename(PRE_LIFECYCLE)} / #{File.basename(PRE_BINDING)}"
puts "scratch run dir      : #{RUN_DIR}"
puts "=" * 99

# =================================================================================================
# THE REAL GEMS ARE PRESENT -- asserted, not assumed. If these fail, every "real thin" claim below
# is void and the harness says so rather than silently proving a double's behaviour.
# =================================================================================================
# In thin 2.0.1 `Thin::VERSION` is a frozen String (NOT the 1.x `Thin::VERSION::STRING`
# namespace), so the probe reads the constant directly and JSON is used instead of eval.
THIN_INFO =
  begin
    # Written to a FILE, not passed with -e: backticks go through cmd.exe on this host and it
    # does not honour the single quotes a -e one-liner needs.
    gp = File.join(RUN_DIR, "gem_probe.rb")
    File.write(gp, <<~RB)
      require "json"
      require "thin"
      require "eventmachine"
      print JSON.generate(
        "v" => Thin::VERSION.to_s,
        "srv" => defined?(Thin::Server).to_s,
        "em" => defined?(EventMachine).to_s,
        "path" => $LOADED_FEATURES.grep(/thin/).first.to_s
      )
    RB
    out = `ruby -W0 #{gp.dump} 2>&1`
    JSON.parse(out.lines.grep(/^\{/).last.to_s)
  rescue StandardError
    nil
  end

REAL_THIN = THIN_INFO.is_a?(Hash) && THIN_INFO["srv"] == "constant"

check("R1 the REAL thin gem is installed and loadable, and Thin::Server is a real constant " \
      "(version #{THIN_INFO.is_a?(Hash) ? THIN_INFO["v"] : '?'})") do
  REAL_THIN && THIN_INFO["v"].to_s.start_with?("2.")
end
check("R2 the REAL eventmachine gem is loadable (thin's reactor)") do
  THIN_INFO.is_a?(Hash) && THIN_INFO["em"] == "constant"
end
check("R3 the thin that was loaded is the installed GEM, not a vendored stub") do
  THIN_INFO.is_a?(Hash) && THIN_INFO["path"].to_s.include?("gems/thin-")
end
unless REAL_THIN
  limit("the real thin gem could not be loaded, so cases T/S3 below could not use it")
end

# =================================================================================================
# THE SCENARIO RUNNER. Each scenario is a child ruby process so it gets a pristine reactor state.
#
# `mode` selects which sources the child loads:
#   :current  -> the live deck sources (the files under test)
#   :pre_fix  -> the untouched .bak-cpd035-pre baselines (the before-state)
# =================================================================================================
def run_scenario(name, mode:, web_concurrency:, reactor:, thin_server:, post_fork:, extra: "")
  lifecycle = mode == :pre_fix ? PRE_LIFECYCLE : LIFECYCLE
  binding_f = mode == :pre_fix ? PRE_BINDING : READ_BINDING
  return nil unless File.exist?(lifecycle) && File.exist?(binding_f)

  script = File.join(RUN_DIR, "scenario_#{name}.rb")
  File.write(script, <<~RB)
    require "json"
    require "eventmachine" if #{reactor.inspect} || #{thin_server.inspect}
    require "thin" if #{thin_server.inspect}

    # The deck's port + errors are real; only Rails is absent (by design -- see the header).
    $LOAD_PATH.unshift(#{File.join(DECK, 'mod/mcp_api/lib/atomspace').dump})
    load #{File.join(DECK, 'mod/mcp_api/lib/atomspace/errors.rb').dump}
    load #{File.join(DECK, 'mod/mcp_api/lib/atomspace/i3_read_port.rb').dump}
    load #{binding_f.dump}
    load #{lifecycle.dump}

    I = Atomspace::I3ReadBindingInstaller
    L = Atomspace::I3ThinLifecycle

    ENV["I3_READ_BINDING"] = "live"
    #{web_concurrency.nil? ? 'ENV.delete("WEB_CONCURRENCY")' : "ENV['WEB_CONCURRENCY'] = #{web_concurrency.to_s.dump}"}
    # NO I3_I2_* paths are set on purpose: the D2 question is WHICH ENTRY POINT is selected, and
    # both entry points refuse long before any spawn. Nothing is launched by these scenarios.
    %w[I3_I2_INTERPRETER I3_I2_SCRIPT I3_STORE_SIDECAR_PATH I3_I2_CONFIG I3_I2_DEADLINE_MS
       I3_I2_SCRIPT_SHA256].each { |k| ENV.delete(k) }

    #{extra}

    # `facts_at_activate` is captured INSIDE the reactor, at the instant activate! ran. Reading
    # thin_facts after `EventMachine.stop` would report a reactor that has already shut down and
    # would make the "a reactor really was running" assertion unprovable.
    $facts_at_activate = nil

    def emit(l, extra = {})
      attempt = l.activation_attempts.last || {}
      puts JSON.generate(
        {
          "attempts" => l.activation_attempts.size,
          "entry" => attempt[:entry].to_s,
          "proven" => attempt[:serving_context_proven],
          "outcome" => attempt[:outcome].to_s,
          "em_running" => (defined?(EventMachine) ? EventMachine.reactor_running? : nil),
          "thin_defined" => defined?(Thin::Server).to_s,
          "thin_version" => (defined?(Thin) ? Thin::VERSION.to_s : nil),
          "facts" => ($facts_at_activate || (l.respond_to?(:thin_facts) ? l.thin_facts.transform_keys(&:to_s) : {})),
          "installed_pid" => Atomspace::I3ReadBindingInstaller.installed_pid,
          "port_impl" => (!Atomspace::I3ReadPort.impl.nil?)
        }.merge(extra)
      )
    end

    if #{thin_server.inspect}
      app = ->(_env) { [200, { "content-type" => "text/plain" }, ["ok"]] }
      srv = nil
      served = nil
      t = Thread.new do
        begin
          EventMachine.run do
            srv = Thin::Server.new("127.0.0.1", #{30_000 + rand(2000)}, app)
            srv.silent = true if srv.respond_to?(:silent=)
            srv.start
          end
        rescue Exception => e
          puts JSON.generate("child_error" => e.class.to_s + ": " + e.message.to_s[0, 160])
        end
      end

      # Wait for the REAL server to report running, then issue the HTTP request FROM THE MAIN
      # THREAD. Doing it inside the reactor would deadlock: thin answers on the reactor thread, so
      # a blocking Net::HTTP call there waits for a reply the reactor cannot produce.
      100.times { break if srv && (srv.running? rescue false); sleep 0.05 }
      begin
        require "net/http"
        served = Net::HTTP.get(URI("http://127.0.0.1:" + srv.port.to_s + "/"))
      rescue Exception
        served = nil
      end

      # Activate ON the reactor thread, with the real Thin::Server live and serving.
      activated = false
      EventMachine.next_tick do
        begin
          L.activate!(reason: "proof_real_thin")
          $facts_at_activate = L.thin_facts.transform_keys(&:to_s)
        ensure
          activated = true
          EventMachine.stop
        end
      end
      100.times { break if activated; sleep 0.05 }
      t.join(10)
      emit(L, "served_http" => served, "thin_running_seen" => true)
    elsif #{reactor.inspect}
      # A REAL EventMachine reactor owned by SOMETHING THAT IS NOT THIN -- i.e. exactly the
      # "unrelated reactor running in a prefork master" the finding describes.
      done = false
      t = Thread.new do
        begin
          EventMachine.run do
            EventMachine.add_timer(0.1) do
              L.activate!(reason: "proof_foreign_reactor")
              $facts_at_activate = L.thin_facts.transform_keys(&:to_s)
              done = true
              EventMachine.stop
            end
          end
        rescue Exception => e
          puts JSON.generate("child_error" => e.class.to_s + ": " + e.message.to_s[0, 160])
        end
      end
      t.join(25)
      emit(L, "reactor_was_running_at_activate" => done)
    else
      L.activate!(reason: "proof_no_reactor")
      emit(L)
    end
  RB

  out = `ruby -W0 #{script.dump} 2>&1`
  json = out.lines.grep(/^\{/).map { |l| (JSON.parse(l) rescue nil) }.compact.last
  { raw: out, json: json }
end

# =================================================================================================
# D2 -- CASE S1: A REAL, RUNNING, NON-THIN EVENTMACHINE REACTOR IN A PREFORK-MASTER-LIKE PROCESS
#                MUST NOT SELECT THE WORKER BYPASS.
# =================================================================================================
s1 = run_scenario("s1_foreign_reactor_prefork", mode: :current, web_concurrency: 4,
                  reactor: true, thin_server: false, post_fork: false)
j1 = s1 && s1[:json]

check("S1a the scenario really ran with a REAL EventMachine reactor RUNNING at the moment " \
      "activate! was called") do
  j1 && j1["reactor_was_running_at_activate"] == true && j1["facts"]["em_reactor_running"] == true
end
check("S1b no Thin::Server exists in that process (so the ONLY signal available is the bare " \
      "reactor -- the exact D2 input)") do
  j1 && j1["facts"]["thin_server_found"] == false
end
check("S1c serving context is NOT proven by a bare running reactor") { j1 && j1["proven"] == false }
check("S1d >>> D2 CLOSED: the entry point selected is `install!`, NOT `install_for_worker!` " \
      "(the master refusal is NOT bypassed)") { j1 && j1["entry"] == "install!" }
check("S1e and the real installer REFUSED on that path (outcome :refused)") do
  j1 && j1["outcome"] == "refused"
end
check("S1f nothing was bound: the port has no impl and no installing pid is recorded " \
      "(fail-closed => 503)") do
  j1 && j1["port_impl"] == false && j1["installed_pid"].nil?
end
check("S1g the reactor fact is still REPORTED in diagnostics (it was narrowed, not deleted)") do
  j1 && j1["facts"].key?("em_reactor_running") && j1["facts"]["serving_context_proven"] == false
end
puts "     (S1 child verdict: #{j1.inspect[0, 420]})" if j1
check("S1z the S1 child produced a parseable verdict and no child_error") do
  j1 && !j1.key?("child_error")
end

# =================================================================================================
# D2 -- CASE S2: THE PRE-FIX LIFECYCLE, SAME INPUT, REALLY DID TAKE THE BYPASS.
# Without this the S1 result could be vacuous (e.g. if the reactor never ran).
# =================================================================================================
if File.exist?(PRE_LIFECYCLE)
  s2 = run_scenario("s2_prefix_foreign_reactor", mode: :pre_fix, web_concurrency: 4,
                    reactor: true, thin_server: false, post_fork: false)
  j2 = s2 && s2[:json]
  check("S2a the PRE-FIX scenario also ran with a REAL reactor running") do
    j2 && j2["facts"]["em_reactor_running"] == true
  end
  check("S2b NEGATIVE CONTROL: the PRE-FIX lifecycle judged the bare reactor PROVEN") do
    j2 && j2["proven"] == true
  end
  check("S2c NEGATIVE CONTROL: and it therefore selected `install_for_worker!` -- the bypass the " \
        "finding reported") { j2 && j2["entry"] == "install_for_worker!" }
  check("S2d so S1d is a real behaviour CHANGE on identical input, not a tautology") do
    j1 && j2 && j1["entry"] == "install!" && j2["entry"] == "install_for_worker!"
  end
  puts "     (S2 child verdict: #{j2.inspect[0, 300]})" if j2
else
  limit("S2 pre-fix lifecycle #{PRE_LIFECYCLE} is absent, so the before-state could not be re-run")
end

# =================================================================================================
# D2 -- CASE T: A REAL, RUNNING `Thin::Server` (REAL THIN 2.0.1, REAL REACTOR, REAL HTTP REQUEST
#               SERVED) **IS** proof, so the bypass is still reachable when it is earned.
#               This is what keeps the D2 fix from being "refuse everything".
# =================================================================================================
if REAL_THIN
  st = run_scenario("t_real_thin_serving", mode: :current, web_concurrency: 4,
                    reactor: false, thin_server: true, post_fork: false)
  jt = st && st[:json]
  check("T1 a REAL Thin::Server was running in that process (real gem #{THIN_INFO["v"]}), and it " \
        "really SERVED an HTTP request") do
    jt && jt["served_http"] == "ok" && jt["facts"]["thin_server_found"] == true &&
      jt["facts"]["thin_running"] == true
  end
  check("T2 the live-server facts were read off the REAL thin object (a real backend class, not " \
        "a double)") do
    jt && jt["facts"]["thin_backend"].to_s.start_with?("Thin::Backends::")
  end
  check("T3 serving context IS proven by a real running Thin::Server") { jt && jt["proven"] == true }
  check("T4 so the EARNED bypass still works: entry == install_for_worker! even under " \
        "WEB_CONCURRENCY=4") { jt && jt["entry"] == "install_for_worker!" }
  check("T5 and it still fails closed on the missing I3_I2_* config (outcome :refused, nothing " \
        "bound) -- the bypass grants the ENTRY POINT, never a binding") do
    jt && jt["outcome"] == "refused" && jt["port_impl"] == false
  end
  puts "     (T child verdict: #{jt.inspect[0, 420]})" if jt
else
  limit("T real-thin serving case SKIPPED because the thin gem could not be loaded")
end

# =================================================================================================
# D2 -- CASE S4: NO reactor at all, prefork configured => install! => refused. And the SANCTIONED
#                post-fork marker is the only other way to earn the bypass.
# =================================================================================================
s4 = run_scenario("s4_no_reactor_prefork", mode: :current, web_concurrency: 4,
                  reactor: false, thin_server: false, post_fork: false)
j4 = s4 && s4[:json]
check("S4a with no reactor and no server: not proven, entry install!, refused") do
  j4 && j4["proven"] == false && j4["entry"] == "install!" && j4["outcome"] == "refused"
end

s5 = run_scenario("s5_post_fork_marker", mode: :current, web_concurrency: 4,
                  reactor: false, thin_server: false, post_fork: true,
                  extra: 'L.post_fork!')
j5 = s5 && s5[:json]
check("S5a the EXPLICIT post_fork! marker (set by an on_worker_boot-style hook that runs IN the " \
      "worker) IS proof, with no reactor and no Thin at all") { j5 && j5["proven"] == true }
check("S5b and it selects install_for_worker!") { j5 && j5["entry"] == "install_for_worker!" }

s6 = run_scenario("s6_inherited_marker", mode: :current, web_concurrency: 4,
                  reactor: false, thin_server: false, post_fork: true,
                  extra: 'L.post_fork!; L.instance_variable_set(:@post_fork_pid, Process.pid + 100000)')
j6 = s6 && s6[:json]
check("S6a a post-fork marker belonging to ANOTHER pid (what a later fork would leave behind) is " \
      "NOT proof: not proven, entry install!, refused") do
  j6 && j6["proven"] == false && j6["entry"] == "install!" && j6["outcome"] == "refused"
end

# =================================================================================================
# D2 -- SOURCE INVARIANTS: the narrowed gate must not be widened back by a later edit.
# =================================================================================================
src = File.read(LIFECYCLE)
gate = src[/def thin_serving_context\?.*?^      end/m].to_s
check("S7a `thin_serving_context?` no longer returns true on `em_reactor_running?` alone") do
  !gate.match?(/return true if em_reactor_running\?/)
end
check("S7b the gate's only two affirmative returns are the post-fork marker and a live running " \
      "Thin::Server") do
  gate.include?("return true if post_fork_marked?") &&
    gate.include?("facts[:thin_server_found] == true && facts[:thin_running] == true") &&
    gate.scan(/return true/).size == 1
end
check("S7c the gate still FAILS CLOSED on any raise") do
  gate.include?("rescue ::StandardError, ::ScriptError") && gate.include?("false")
end
check("S7d `post_fork_marked?` is PID-SCOPED (a marker cannot be inherited across a fork)") do
  src[/def post_fork_marked\?.*?^      end/m].to_s.include?("@post_fork_pid == ::Process.pid")
end
check("S7e the PRE-FIX gate really did have the reactor-alone branch (so S7a is a change)") do
  if File.exist?(PRE_LIFECYCLE)
    File.read(PRE_LIFECYCLE)[/def thin_serving_context\?.*?^      end/m].to_s
        .match?(/return true if em_reactor_running\? == true/)
  else
    false
  end
end

# =================================================================================================
# D3 -- FOREIGN RETAINED-CHILD CLEANUP. Run IN THIS PROCESS against the REAL installer module.
# =================================================================================================
module Atomspace
  module I3ReadPort
    class << self
      def bind!(impl); @impl = impl; end
      def reset!; @impl = nil; end
      def impl; @impl; end
    end
  end
end
load READ_BINDING
INST = Atomspace::I3ReadBindingInstaller

check("F0 `Process.fork` genuinely does not exist on this host, which is WHY the inherited state " \
      "below is reproduced rather than forked") do
  !Process.respond_to?(:fork) ||
    begin
      Process.fork { exit!(0) }
      false
    rescue NotImplementedError
      true
    end
end
limit("F `Process.fork` is unavailable (NotImplementedError), so no real fork is performed. The " \
      "inherited post-fork state is reproduced EXACTLY as the branch under test observes it -- a " \
      "retained entry whose recorded creating pid is a DIFFERENT, REAL, LIVE process (a real " \
      "child ruby pid, case F1) -- but it is NOT a real fork")

# A REAL live foreign process, so "another pid" is not an invented integer.
foreign_io = IO.popen([RbConfig.ruby, "-e", "sleep 30"])
FOREIGN_PID = foreign_io.pid
check("F1 a REAL second process exists and its pid differs from ours (the 'foreign owner')") do
  FOREIGN_PID.is_a?(Integer) && FOREIGN_PID != Process.pid &&
    begin
      Process.kill(0, FOREIGN_PID)
      true
    rescue StandardError
      false
    end
end

# A Spawn double that RECORDS whether anything signalled it. Deliberately NOT a real Spawn: the
# property under test is "was stop! called at all", and calling a real Spawn#stop! on a foreign
# child is exactly the harm being prevented -- it must not be reproduced to test for it.
class RecordingSpawn
  attr_reader :stops, :label

  def initialize(label, verdict: :confirmed)
    @label = label
    @verdict = verdict
    @stops = 0
  end

  def stop!
    @stops += 1
    @verdict
  end
end

def reset_installer!
  INST.unreaped_spawns.clear
  INST.spawn_owner_pids.clear
  INST.instance_variable_set(:@installed_pid, nil)
  INST.instance_variable_set(:@spawn, nil)
end

# ---- F2: ours is stopped, foreign is not ---------------------------------------------------------
reset_installer!
mine    = RecordingSpawn.new("mine")
foreign = RecordingSpawn.new("foreign")
noowner = RecordingSpawn.new("no-owner")
INST.unreaped_spawns.concat([mine, foreign, noowner])
INST.spawn_owner_pids[mine.object_id]    = Process.pid
INST.spawn_owner_pids[foreign.object_id] = FOREIGN_PID
# `noowner` gets NO entry: an inherited array with no bookkeeping, which must read as foreign.

sweep = INST.retry_unreaped!

check("F2a >>> D3 CLOSED: the sweep stopped ONLY the spawn THIS pid created") do
  mine.stops == 1 && foreign.stops.zero? && noowner.stops.zero?
end
check("F2b the foreign-owned entry was NOT signalled and was LEFT IN PLACE (the handle is not " \
      "discarded, it is just never stopped)") do
  INST.unreaped_spawns.include?(foreign)
end
check("F2c an entry with NO recorded owner is treated as FOREIGN (unprovable origin fails " \
      "closed) and also left in place") do
  noowner.stops.zero? && INST.unreaped_spawns.include?(noowner)
end
check("F2d the confirmed OWN entry was removed and its bookkeeping forgotten") do
  !INST.unreaped_spawns.include?(mine) && !INST.spawn_owner_pids.key?(mine.object_id)
end
check("F2e the sweep REPORTS the skip count, so an operator can see foreign handles are held") do
  sweep[:confirmed] == 1 && sweep[:skipped_foreign] == 2 && sweep[:remaining] == 2
end
check("F2f `foreign_unreaped_spawns` enumerates exactly those two entries for the runbook") do
  INST.foreign_unreaped_spawns.map(&:label).sort == %w[foreign no-owner]
end
check("F2g the sweep is IDEMPOTENT and still never signals the foreign entries on a second pass") do
  s2 = INST.retry_unreaped!
  foreign.stops.zero? && noowner.stops.zero? && s2[:confirmed].zero? && s2[:skipped_foreign] == 2
end

# ---- F3: the owner record is written at retention time, by the creating process ------------------
reset_installer!
retained = RecordingSpawn.new("retained-unconfirmed", verdict: :unconfirmed)
verdict = INST.send(:stop_child!, retained)
check("F3a an unconfirmed stop RETAINS the spawn and records THIS pid as its creator") do
  verdict == :unconfirmed && INST.unreaped_spawns.include?(retained) &&
    INST.spawn_owner_pids[retained.object_id] == Process.pid
end
check("F3b so a later sweep in THIS process does re-stop it (the re-stop guarantee is intact)") do
  before = retained.stops
  INST.retry_unreaped!
  retained.stops == before + 1
end
check("F3c ...but if the recorded owner is rewritten to the foreign pid (what the child of a fork " \
      "sees), the same entry is never signalled again") do
  INST.spawn_owner_pids[retained.object_id] = FOREIGN_PID
  before = retained.stops
  s = INST.retry_unreaped!
  retained.stops == before && s[:skipped_foreign] == 1 && s[:confirmed].zero?
end

# ---- F4: disown_inherited! leaves the retention list intact (the fork path the finding names) ----
reset_installer!
inherited = RecordingSpawn.new("inherited")
INST.unreaped_spawns.concat([inherited])
INST.spawn_owner_pids[inherited.object_id] = FOREIGN_PID
INST.instance_variable_set(:@installed_pid, FOREIGN_PID)
INST.instance_variable_set(:@spawn, inherited)
owned = INST.ensure_owned_binding!
check("F4a a claim from another pid is DISOWNED (the fork path: @installed_pid != Process.pid)") do
  owned == false && INST.installed_pid.nil? && INST.owned_spawn.nil?
end
check("F4b and the retention list still holds the inherited entry (disown does not drop handles)") do
  INST.unreaped_spawns.include?(inherited)
end
check("F4c the at_exit-style sweep that follows a disown does NOT stop the inherited child") do
  s = INST.retry_unreaped!
  inherited.stops.zero? && s[:skipped_foreign] == 1
end
check("F4d `shutdown_owned_child!` also refuses to touch it (it answers :not_owned)") do
  INST.shutdown_owned_child! == :not_owned && inherited.stops.zero?
end

# ---- F5: the PRE-FIX sweep really did stop foreign entries ---------------------------------------
if File.exist?(PRE_BINDING)
  pre_probe = File.join(RUN_DIR, "pre_fix_sweep_probe.rb")
  File.write(pre_probe, <<~RB)
    require "json"
    module Atomspace
      module I3ReadPort
        def self.reset!; end
        def self.bind!(_i); end
      end
    end
    load #{PRE_BINDING.dump}
    I = Atomspace::I3ReadBindingInstaller
    class RS
      attr_reader :stops
      def initialize; @stops = 0; end
      def stop!; @stops += 1; :unconfirmed; end
    end
    foreign = RS.new
    I.unreaped_spawns.concat([foreign])
    # The pre-fix module has NO owner table at all -- which is the defect: there is nothing to
    # consult, so every entry is swept regardless of who created it.
    has_table = I.respond_to?(:spawn_owner_pids)
    sweep = I.retry_unreaped!
    puts JSON.generate(
      "stops" => foreign.stops,
      "has_owner_table" => has_table,
      "sweep_keys" => sweep.keys.map(&:to_s)
    )
  RB
  out = `ruby -W0 #{pre_probe.dump} 2>&1`
  pre = begin
    JSON.parse(out.lines.grep(/^\{/).last.to_s)
  rescue StandardError
    nil
  end
  check("F5a NEGATIVE CONTROL: the PRE-FIX sweep CALLED stop! on an entry with no proven owner") do
    pre && pre["stops"] == 1
  end
  check("F5b NEGATIVE CONTROL: the PRE-FIX module had no per-spawn owner table to consult") do
    pre && pre["has_owner_table"] == false
  end
  check("F5c NEGATIVE CONTROL: and its sweep Hash had no skipped_foreign key") do
    pre && !pre["sweep_keys"].include?("skipped_foreign")
  end
  puts "     (pre-fix sweep child output: #{out.strip.lines.last.to_s.strip})"
else
  limit("F5 pre-fix binding #{PRE_BINDING} is absent, so the before-state sweep could not be re-run")
end

# ---- F6: source invariants for D3 ----------------------------------------------------------------
bsrc = File.read(READ_BINDING)
check("F6a the sweep's FIRST action per entry is the ownership gate, before any stop!") do
  body = bsrc[/def retry_unreaped!.*?^      end/m].to_s
  gate_at = body.index("own_spawn?(spawn)")
  stop_at = body.index("spawn.stop!")
  gate_at && stop_at && gate_at < stop_at
end
check("F6b `own_spawn?` is true ONLY for a RECORDED pid equal to Process.pid (absent record " \
      "=> false)") do
  body = bsrc[/def own_spawn\?\(spawn\).*?^      end/m].to_s
  body.include?("spawn_owner_pids[spawn.object_id] == Process.pid") &&
    body.include?("return false if spawn.nil?") && body.include?("false")
end
check("F6c the owner is recorded at RETENTION time (while the creating process is still running)") do
  bsrc[/def retain_unreaped!\(spawn\).*?^      end/m].to_s.include?("remember_spawn_owner!(spawn)")
end
check("F6d the owner table is keyed by object_id (cannot resurrect a dropped object, immune to " \
      "an exotic hash/eql?)") do
  bsrc.include?("spawn_owner_pids[spawn.object_id] ||= Process.pid")
end
check("F6e `disown_inherited!` still deliberately does NOT clear the retention list") do
  bsrc[/def disown_inherited!.*?^      end/m].to_s.then do |b|
    !b.include?("unreaped") && b.include?("@installed_pid = nil") && b.include?("@spawn = nil")
  end
end
check("F6f both owned files are syntactically valid ruby") do
  system(RbConfig.ruby, "-c", LIFECYCLE, out: File::NULL, err: File::NULL) &&
    system(RbConfig.ruby, "-c", READ_BINDING, out: File::NULL, err: File::NULL)
end

# =================================================================================================
begin
  Process.kill("KILL", FOREIGN_PID)
rescue StandardError
  nil
end
foreign_io.close rescue nil
reset_installer!
ENV["I3_READ_BINDING"] = nil
FileUtils.rm_rf(RUN_DIR)

puts "\n#{'=' * 99}"
puts "PASS: #{PASS.size}   FAIL: #{FAIL.size}   TOTAL: #{PASS.size + FAIL.size}"
puts "REAL THIN USED: #{REAL_THIN ? "yes (thin #{THIN_INFO["v"]}, real Thin::Server in a real EventMachine reactor, real HTTP request served)" : 'NO'}"
unless FAIL.empty?
  puts "\nFAILURES (#{FAIL.size}):"
  FAIL.each { |f| puts "  - #{f}" }
end
unless LIMITS.empty?
  puts "LIMITS (explicitly unproven on this host): #{LIMITS.size}"
  LIMITS.each { |l| puts "  ~ #{l}" }
end
puts "=" * 99
exit(FAIL.empty? ? 0 : 1)
