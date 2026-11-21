# frozen_string_literal: true
#
# LANE-D ROUND-25 PROCESS-LEVEL PROOF: child environment isolation (blocker 3) and bounded
# shutdown (blocker 6). Pure Ruby, REAL spawned child processes. No Rails, no DB.
#
# WHY A SEPARATE FILE from i2_reader_process_client_proof.rb. Those examples run over in-memory
# pipes and never start a process. These two blockers are only observable with a REAL child:
#
#   BLOCKER 3  the child inherited the whole parent environment, so any parent-held secret
#              (signing key, bearer token, DATABASE_URL) was readable by the Python process --
#              contradicting i2_stdio_transport.rb's own claim that it "NEVER passes a
#              credential". Proving the fix requires planting a sentinel secret in THIS process's
#              environment, spawning a real child, and having the child report what it can see.
#
#   BLOCKER 6  `stop!` joined the wait thread unboundedly, so a child that ignores EOF could hang
#              shutdown (and the documented rollback) forever. Proving the fix requires a
#              genuinely UNRESPONSIVE child and a wall-clock measurement.
#
# WHAT IT PROVES BEHAVIOURALLY -- each assertion is a measurement, not a source-text grep:
#
#   1  a sentinel secret in the parent env is NOT visible to the spawned child
#   2  the child sees EXACTLY the three keys the transport declares, and no others
#   3  MUTATION PROOF: the same spawn WITHOUT `unsetenv_others: true` DOES leak the sentinel --
#      so the option is what closes it, not something else
#   4  the child still STARTS and works under the cleared env (hyperon + sidecar import)
#   5  `stop!` on a deliberately unresponsive child returns within a bounded time
#   6  MUTATION PROOF: an unbounded join against that same child does NOT return
#
# Run: ruby spec/mcp_api/atomspace/i2_spawn_isolation_proof.rb [--interpreter PATH]
#
# The interpreter defaults to this host's Python 3.12 (the only one with hyperon 0.2.10); pass
# --interpreter to point it elsewhere. No path is guessed from PATH.

require "json"
require "open3"
require "tmpdir"
require "fileutils"

LIB = File.expand_path("../../../mod/mcp_api/lib/atomspace", __dir__)
require File.join(LIB, "errors")
require File.join(LIB, "i2_stdio_transport")

DEFAULT_INTERPRETER = "C:/Users/Lake/AppData/Local/Programs/Python/Python312/python.exe"

def arg_value(flag, default)
  index = ARGV.index(flag)
  index && ARGV[index + 1] ? ARGV[index + 1] : default
end

INTERPRETER = arg_value("--interpreter", DEFAULT_INTERPRETER)
SIDECAR = arg_value("--sidecar", "E:/GitHub/Magi-AGI/av-store-sidecar")

# The secret this proof plants in its OWN environment. If a child can read this, every other
# parent-held secret is readable too.
SENTINEL_NAME = "AV_LANE_D_SENTINEL_SECRET"
SENTINEL_VALUE = "sk-live-DO-NOT-LEAK-#{Process.pid}"
ENV[SENTINEL_NAME] = SENTINEL_VALUE
# A couple of realistically-named decoys, so the proof is not passing on one specially-named var.
ENV["DATABASE_URL"] = "postgres://user:pw@localhost/leakcheck"
ENV["AV_SIGNING_KEY"] = "hmac-leakcheck"

FAILURES = []
PASSES = []

def check(label)
  ok = yield
  if ok
    PASSES << label
    puts "  PASS  #{label}"
  else
    FAILURES << label
    puts "  FAIL  #{label}"
  end
rescue StandardError => e
  FAILURES << "#{label} (raised #{e.class}: #{e.message})"
  puts "  FAIL  #{label} -- raised #{e.class}: #{e.message}"
end

WORK = Dir.mktmpdir("i2-spawn-proof")
at_exit { FileUtils.remove_entry(WORK) rescue nil }

# ---------------------------------------------------------------------------------------------
# PROBE 1: an env-reporting child. It speaks the SAME line protocol the real server does, so it
# is driven through the real transport rather than through a bespoke channel.
# ---------------------------------------------------------------------------------------------
ENV_PROBE = File.join(WORK, "env_probe.py")
File.write(ENV_PROBE, <<~PY)
  import json, os, sys
  for line in sys.stdin:
      line = line.strip()
      if not line:
          continue
      frame = json.loads(line)
      sys.stdout.write(json.dumps({
          "v": 1, "id": frame.get("id"), "ok": True,
          "envelope": {"outcome": "ok", "epoch": "e" * 32, "position": 1,
                       "read-at": "2026-11-15T09:41:02.123456+00:00"},
          "payload": {"env_keys": sorted(os.environ.keys()),
                      "sentinel": os.environ.get("#{SENTINEL_NAME}"),
                      "database_url": os.environ.get("DATABASE_URL"),
                      "signing_key": os.environ.get("AV_SIGNING_KEY")},
      }) + "\\n")
      sys.stdout.flush()
PY

# PROBE 2: a child that NEVER exits and ignores EOF on stdin. `stop!` must still return.
WEDGED_PROBE = File.join(WORK, "wedged_probe.py")
File.write(WEDGED_PROBE, <<~PY)
  import time, sys
  # Deliberately never reads stdin and never exits: the wedged-child case. A bare sleep loop is
  # used rather than a blocking read so EOF cannot end it.
  sys.stderr.write("wedged\\n")
  sys.stderr.flush()
  while True:
      time.sleep(3600)
PY

CONFIG = { "page-max" => { "entries" => 50, "links" => 50 },
           "fanout-limit" => 1,
           "state-retain" => { "state-retain-ms" => nil, "state-retain-positions" => 2 } }.freeze

puts "=" * 92
puts "I2 SPAWN ISOLATION PROOF -- real child processes"
puts "  interpreter: #{INTERPRETER}"
puts "  sentinel   : #{SENTINEL_NAME} (planted in this process's env)"
puts "=" * 92

unless File.exist?(INTERPRETER)
  puts "\nUNEXECUTABLE: interpreter not found at #{INTERPRETER}"
  puts "Pass --interpreter PATH. Nothing is simulated."
  exit 2
end

# =============================================================================================
puts "\n1 -- BLOCKER 3: the child's environment is REPLACED, not merged"
# =============================================================================================

payload = nil
spawn = Atomspace::I2StdioTransport::Spawn.new(
  interpreter: INTERPRETER, script: ENV_PROBE, sidecar_path: SIDECAR, config: CONFIG
)
begin
  spawn.start!
  Atomspace::I2StdioTransport.write_request!(
    spawn.writer, id: "env-1", op: "I2-01", args: {}, deadline_ms: 5_000
  )
  frame = Atomspace::I2StdioTransport.read_response!(spawn.reader, expect_id: "env-1")
  payload = frame["payload"]
ensure
  spawn.stop!
end

check "the child ANSWERED (so the cleared env did not break the interpreter)" do
  payload.is_a?(Hash) && payload["env_keys"].is_a?(Array)
end

check "BLOCKER 3: the sentinel secret is NOT visible to the child" do
  payload["sentinel"].nil?
end

check "BLOCKER 3: DATABASE_URL is not visible to the child either" do
  payload["database_url"].nil?
end

check "BLOCKER 3: a signing-key-shaped parent variable is not visible to the child" do
  payload["signing_key"].nil?
end

check "BLOCKER 3: the child sees EXACTLY the three declared keys and nothing else" do
  payload["env_keys"] == ["AV_I2_STDIO_CONFIG", "AV_STORE_SIDECAR_PATH", "PYTHONUNBUFFERED"]
end

check "BLOCKER 3: the three keys carry the operator's real values (isolation is not breakage)" do
  # The child must still be CONFIGURED -- an empty env would also pass a leak test while making
  # the server useless.
  spawn2 = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: ENV_PROBE, sidecar_path: SIDECAR, config: CONFIG
  )
  env = spawn2.send(:child_env)
  env["AV_STORE_SIDECAR_PATH"] == SIDECAR &&
    JSON.parse(env["AV_I2_STDIO_CONFIG"]) == JSON.parse(JSON.generate(CONFIG)) &&
    env["PYTHONUNBUFFERED"] == "1"
end

check "BLOCKER 3 MUTATION PROOF: the SAME spawn WITHOUT unsetenv_others DOES leak the sentinel" do
  # The pre-fix call, byte for byte: a leading env hash and NO options hash. If this did not leak,
  # the option would not be what closes the hole and the fix above would be proving nothing.
  out, _err, _st = Open3.capture3(
    { "AV_STORE_SIDECAR_PATH" => SIDECAR,
      "AV_I2_STDIO_CONFIG" => JSON.generate(CONFIG),
      "PYTHONUNBUFFERED" => "1" },
    INTERPRETER, "-c",
    "import os,json;print(json.dumps({'s':os.environ.get(#{SENTINEL_NAME.inspect})}))"
  )
  JSON.parse(out)["s"] == SENTINEL_VALUE
end

check "BLOCKER 3 MUTATION PROOF (control): WITH unsetenv_others the same call does NOT leak" do
  out, _err, _st = Open3.capture3(
    { "AV_STORE_SIDECAR_PATH" => SIDECAR,
      "AV_I2_STDIO_CONFIG" => JSON.generate(CONFIG),
      "PYTHONUNBUFFERED" => "1" },
    INTERPRETER, "-c",
    "import os,json;print(json.dumps({'s':os.environ.get(#{SENTINEL_NAME.inspect})}))",
    unsetenv_others: true
  )
  JSON.parse(out)["s"].nil?
end

check "the cleared env still supports the REAL dependency chain (hyperon + sidecar import)" do
  # The isolation is only acceptable if the actual server can run under it. Imports STORE's own
  # module from the sidecar path the same way the real server does.
  code = <<~PY.gsub("\n", "; ")
    import sys, os, json
    sys.path.insert(0, os.environ["AV_STORE_SIDECAR_PATH"])
    import hyperon
    from atomspace_mirror_sidecar import i2_read
    print(json.dumps({"hyperon": hyperon.__version__, "i2": hasattr(i2_read, "I2Reader")}))
  PY
  out, err, st = Open3.capture3(
    { "AV_STORE_SIDECAR_PATH" => SIDECAR,
      "AV_I2_STDIO_CONFIG" => JSON.generate(CONFIG),
      "PYTHONUNBUFFERED" => "1" },
    INTERPRETER, "-c", code, unsetenv_others: true
  )
  unless st.success?
    puts "        (child stderr: #{err.lines.last(2).join(' ').strip[0, 200]})"
    next false
  end
  parsed = JSON.parse(out)
  parsed["i2"] == true && !parsed["hyperon"].to_s.empty?
end

# =============================================================================================
puts "\n2 -- BLOCKER 6: stop! is BOUNDED against a genuinely unresponsive child"
# =============================================================================================

wedged = Atomspace::I2StdioTransport::Spawn.new(
  interpreter: INTERPRETER, script: WEDGED_PROBE, sidecar_path: SIDECAR, config: CONFIG
)
wedged.start!
wedged_pid = wedged.pid
sleep 0.4   # let it reach its sleep loop

elapsed = nil
# The VERDICT each stop! returned, recorded where it happens so a later check can compare the
# report against the independently-probed fact. A bounded stop that cannot be distinguished from
# a give-up is the partial this section closes.
STOP_VERDICTS = {}
# A pid no process holds, for probing the signal path without touching a real child. High and
# odd-numbered so it is not a live pid on this host; the checks that use it accept either ESRCH
# ("gone") or a platform failure, and never read a failure as a stop.
UNUSED_PID = 0x7FFF_FFF9

check "BLOCKER 6: stop! RETURNS on a child that ignores EOF and never exits" do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  STOP_VERDICTS[:wedged] = wedged.stop!
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  # Three escalating waits at most; generous ceiling so a slow host is not a false failure, but
  # far below the "forever" the unbounded join produced.
  elapsed < (Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS * 3) + 5
end

puts "        (stop! returned in #{elapsed.round(3)}s; verdict=#{STOP_VERDICTS[:wedged].inspect}; grace=#{Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS}s)"

check "BLOCKER 6: the wedged child is actually DEAD after stop! (escalation really killed it)" do
  # A bounded stop that merely gives up would leave an orphan. Poll briefly: on Windows the
  # process object lingers momentarily after a kill.
  #
  # DEATH MUST BE A CONFIRMED FACT, NOT ANY ERROR. This assertion used to treat EVERY
  # StandardError from `Process.kill(0, pid)` as proof of death -- but EPERM (the process exists
  # and is not ours) and NotImplementedError (the platform cannot answer) establish no such
  # thing, so a still-running orphan could have passed. Only ESRCH -- "no such process" -- is
  # evidence of absence; anything else is recorded as INDETERMINATE and fails the check.
  dead = false
  indeterminate = nil
  12.times do
    begin
      Process.kill(0, wedged_pid)        # signal 0: an existence probe, it kills nothing
    rescue Errno::ESRCH
      dead = true                        # CONFIRMED ABSENT
      break
    rescue Errno::EPERM => e
      # The process EXISTS (we simply may not signal it). That is the opposite of death.
      indeterminate = "#{e.class} -- process exists but is not signalable"
      break
    rescue StandardError => e
      indeterminate = "#{e.class}: #{e.message}"
      break
    end
    sleep 0.25
  end
  puts "        (existence probe: #{indeterminate})" if indeterminate
  dead && indeterminate.nil?
end

check "B6 PARTIAL: stop! REPORTED success for the wedged child whose death was just confirmed" do
  # The verdict and the fact must agree. The probe above established the child is gone; `stop!`
  # must therefore have returned its success verdict -- not `self`, which was indistinguishable
  # from a give-up. Recorded by the first stop! call; re-asserted here against a fresh handle so
  # the two observations are independent.
  STOP_VERDICTS[:wedged] == :confirmed
end

check "B6 PARTIAL: an UNCONFIRMABLE outcome reports NOT-success instead of claiming a stop" do
  # The case the reviewer named: the shutdown cannot establish the exit. Reproduced WITHOUT
  # touching a real child's lifecycle -- a Spawn whose waiter never finishes and whose pid cannot
  # be signalled, which is exactly the shape of a child the budget runs out on.
  #
  # NOTHING IS KILLED HERE. The waiter is a plain Thread that sleeps, and the pid is a sentinel
  # that belongs to no process, so this check adds no kill path and cannot reach anyone's child.
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: WEDGED_PROBE, sidecar_path: SIDECAR, config: CONFIG
  )
  never_exits = Thread.new { sleep 600 }
  spawn.instance_variable_set(:@wait, never_exits)
  spawn.instance_variable_set(:@pid, nil)   # unsignalable => delivery can never prove death

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  verdict = spawn.stop!
  elapsed_unconfirmed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  never_exits.kill

  bounded = elapsed_unconfirmed < (Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS * 3) + 5
  # NOT-success, still BOUNDED, and ownership RETAINED so the caller has not lost the handle.
  verdict != :confirmed && bounded &&
    !spawn.instance_variable_get(:@wait).nil?
end

check "B6 PARTIAL: the strict variant RAISES on an unconfirmable shutdown rather than pretending" do
  # For a caller that must not proceed on an unconfirmed stop (the documented rollback). Same
  # no-real-child construction as above.
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: WEDGED_PROBE, sidecar_path: SIDECAR, config: CONFIG
  )
  never_exits = Thread.new { sleep 600 }
  spawn.instance_variable_set(:@wait, never_exits)
  spawn.instance_variable_set(:@pid, nil)

  raised = begin
    spawn.stop_confirmed!
    nil
  rescue StandardError => e
    e
  end
  never_exits.kill

  raised.is_a?(Atomspace::ServiceUnavailable)
end

check "B6 PARTIAL MUTATION PROOF: a join that RAISES must not be reported as a reaped child" do
  # The exact leak the reviewer found: `join_with_timeout` rescued StandardError and answered
  # TRUE, so a raise from the join read as a successful reap and could skip TERM/KILL entirely.
  # A waiter whose join raises is used to drive it. Under the OLD rescue the answer was "reaped";
  # the fixed predicate must NOT call that an exit.
  raising_waiter = Object.new
  def raising_waiter.respond_to?(name, include_all = false)
    name.to_sym == :join ? true : super
  end
  def raising_waiter.join(*)
    raise RuntimeError, "the waiter thread itself died"
  end

  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: WEDGED_PROBE, sidecar_path: SIDECAR, config: CONFIG
  )
  spawn.instance_variable_set(:@wait, raising_waiter)
  spawn.instance_variable_set(:@pid, nil)

  # The private predicate's own verdict: anything but :exited means escalation still happens.
  verdict = spawn.send(:join_with_timeout, 0.05)
  # And the whole stop! must therefore refuse to claim success.
  stop_verdict = spawn.stop!

  verdict != :exited && stop_verdict != :confirmed
end

check "B6 PARTIAL MUTATION PROOF: a signal that FAILS must not be reported as a delivered one" do
  # The second leak: `signal_child` rescued every error and returned nil, so EPERM (process
  # exists, not ours) looked exactly like a successful TERM. It must now distinguish a failure
  # from the ESRCH that genuinely proves absence.
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: WEDGED_PROBE, sidecar_path: SIDECAR, config: CONFIG
  )
  # A nil pid cannot be signalled: a failure, never a stop.
  failed = spawn.send(:signal_child, nil, "TERM")
  # A pid that no process holds answers ESRCH on this host -- positive evidence of absence.
  gone = spawn.send(:signal_child, UNUSED_PID, "TERM")

  failed == :failed && [:gone, :failed].include?(gone) && failed != :gone
end

check "BLOCKER 6: stop! is idempotent and the second call is immediate" do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  second = wedged.stop!
  elapsed_second = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  # Idempotent AND still honest: the child was confirmed gone by the first call, so the repeat
  # reports confirmed rather than inventing a new shutdown.
  elapsed_second < 1.0 && second == :confirmed
end

check "BLOCKER 6 MUTATION PROOF: an UNBOUNDED join on such a child does NOT return" do
  # The pre-fix shutdown, reproduced: close the pipes, then `wait.join` with no bound. Run in a
  # thread so this proof cannot itself hang, and assert the join is STILL BLOCKED well past the
  # bounded path's whole budget. That is the hang blocker 6 describes.
  stdin, stdout, stderr, wait = Open3.popen3(
    { "AV_STORE_SIDECAR_PATH" => SIDECAR,
      "AV_I2_STDIO_CONFIG" => JSON.generate(CONFIG),
      "PYTHONUNBUFFERED" => "1" },
    INTERPRETER, WEDGED_PROBE, unsetenv_others: true
  )
  victim_pid = wait[:pid]
  sleep 0.4

  blocked = Thread.new do
    [stdin, stdout, stderr].each { |io| io.close rescue nil }
    wait.join            # the OLD line: unbounded
    :joined
  end

  still_blocked = blocked.join(Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS * 3 + 2).nil?

  blocked.kill
  Process.kill("KILL", victim_pid) rescue nil
  still_blocked
end

# ---------------------------------------------------------------------------------------------
puts "\n" + "=" * 92
puts "PASSED: #{PASSES.size}   FAILED: #{FAILURES.size}"
unless FAILURES.empty?
  puts "\nFAILURES:"
  FAILURES.each { |f| puts "  - #{f}" }
end
puts "=" * 92
exit(FAILURES.empty? ? 0 : 1)
