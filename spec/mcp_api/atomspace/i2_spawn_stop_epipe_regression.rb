# frozen_string_literal: true
#
# REGRESSION: `Spawn#stop!` must honour its own documented contract -- "Never raises on the
# shutdown path" (i2_stdio_transport.rb's @return tag on `stop!`) -- when the child is ALREADY
# DEAD and the write side of its stdin pipe has been broken.
#
# THE DEFECT THIS PINS. `stop!` begins by closing [@writer, @reader, @stderr] and rescues only
# `IOError`. On Windows (and on POSIX once a failed write has left the pipe in an error state),
# closing the write end of a pipe whose reader has exited raises `Errno::EPIPE` -- which is an
# `Errno`/`SystemCallError`, NOT a subclass of `IOError`. So it escaped the rescue and `stop!`
# raised, breaking the "never raises" promise that the documented rollback path depends on.
#
# WHY THIS TEST IS LOAD-BEARING AND NOT A MOCK. A double that simply raises `Errno::EPIPE` from
# `close` would prove only that Ruby's `rescue` works. This file spawns a REAL child process
# through the REAL `Atomspace::I2StdioTransport::Spawn`, KILLS it, then writes a line into the
# now-orphaned pipe so the OS actually marks the write side broken, and only then calls `stop!`.
# The exception, if any, comes from a genuine `IO#close` on a genuine broken pipe.
#
# WHAT IT ASSERTS, and nothing more:
#
#   1  `stop!` RETURNS a verdict (`:confirmed` or `:unconfirmed`) instead of raising, against a
#      real child that was killed and whose stdin write side is broken.
#   2  the verdict is one of the two documented symbols -- the fix must not invent a third state
#      nor return `self`/`nil`.
#   3  `stop!` is still IDEMPOTENT after that path: a second call also returns a verdict.
#   4  the rescue was NOT widened. TWO separate unrelated failures raised from `close` must STILL
#      propagate out of `stop!`:
#        * a `RuntimeError` -- which fails if the rescue became `StandardError` or `rescue nil`;
#        * an UNRELATED ERRNO (`Errno::EACCES`) -- which fails if the rescue became
#          `SystemCallError` (or `IOError, SystemCallError`). That second case matters more than
#          it looks: `Errno::EPIPE < SystemCallError`, so "rescue SystemCallError" is the single
#          most plausible WRONG fix for this exact bug, and the RuntimeError guard alone cannot
#          see it. `Errno::EACCES` is a `SystemCallError` and is NOT an `IOError`, so under the
#          correct narrow rescue it propagates and under the widened one it is swallowed.
#   5  the child really is dead afterwards (the fix must not have traded a raise for an orphan) --
#      and that is established from EVIDENCE, not from a pid probe. See the next paragraph.
#
# THE EXIT ASSERTION IS EVIDENCE-BASED AND CAN FAIL. An earlier version of this file probed
# liveness with `Process.kill(0, pid)` plus `Process.waitpid(..., WNOHANG)` and returned true from
# EVERY branch -- including its `rescue StandardError` branch and including the case where
# `waitpid` returned nil, i.e. "the child is STILL RUNNING". That check could not fail, so it
# proved nothing. Worse, a pid can be recycled by the OS, so even a truthful answer about a pid is
# not an answer about OUR child.
#
# It is replaced by `await_child_exit`, which asserts against the ACTUAL WAITER retained from
# `Open3.popen3` BEFORE `stop!` is called, and demands all of:
#   * the waiter thread COMPLETES within a bound (a still-running child leaves it un-joined);
#   * its value is a real `Process::Status`;
#   * that status's `pid` MATCHES the child we spawned.
# Anything else -- timeout, a raise from the waiter, a non-Status value, a pid mismatch -- is
# reported as `:running` or `:inconclusive` and FAILS the check with a printed reason. An
# inconclusive outcome must never pass. That the probe can fail is itself asserted every run, by
# pointing it at a child that is deliberately STILL ALIVE and requiring it to say `:running`.
#
# Run (interpreter is overridable; there is no discovery in the transport and none here):
#   ruby spec/mcp_api/atomspace/i2_spawn_stop_epipe_regression.rb \
#     [--interpreter C:/path/to/python.exe]
#
# Optionally also exercise STORE's REAL reader service as the child (same probe, real service):
#   ruby spec/mcp_api/atomspace/i2_spawn_stop_epipe_regression.rb \
#     --interpreter C:/path/to/python.exe \
#     --script E:/GitHub/Magi-AGI/av-store-sidecar/tools/i2_stdio_reader_service.py \
#     --sidecar E:/GitHub/Magi-AGI/av-store-sidecar

require "json"
require "tmpdir"
require "fileutils"

LIB = File.expand_path("../../../mod/mcp_api/lib/atomspace", __dir__)
require File.join(LIB, "errors")
require File.join(LIB, "i2_stdio_transport")

# ------------------------------------------------------------------------------------------------
# tiny harness (same shape as the sibling proofs in this directory)
# ------------------------------------------------------------------------------------------------
PASSED = []
FAILED = []

def check(name)
  ok = yield
  if ok
    PASSED << name
    puts "  PASS  #{name}"
  else
    FAILED << name
    puts "  FAIL  #{name}"
  end
rescue StandardError, SystemExit => e
  FAILED << name
  puts "  FAIL  #{name}"
  puts "        RAISED #{e.class}: #{e.message}"
  puts "        at #{e.backtrace&.first}"
end

def note(msg)
  puts "        #{msg}"
end

# ------------------------------------------------------------------------------------------------
# options
# ------------------------------------------------------------------------------------------------
def opt(flag)
  i = ARGV.index(flag)
  i && ARGV[i + 1]
end

INTERPRETER = opt("--interpreter") ||
              "C:/Users/Lake/AppData/Local/hermes/profiles/claudetriad/cache/scratch/" \
              "av-store-venv/Scripts/python.exe"
REAL_SCRIPT  = opt("--script")
REAL_SIDECAR = opt("--sidecar")

unless File.file?(INTERPRETER)
  warn "interpreter not found: #{INTERPRETER.inspect} -- pass --interpreter PATH"
  exit 2
end

# The I2 ceilings. The transport has no defaults, so the values are stated here; they are plain
# integers and carry no identity.
CONFIG = { "max_atoms" => 64, "max_depth" => 4, "max_bytes" => 65_536, "timeout_ms" => 2_000 }.freeze

# A minimal REAL child: it reads stdin forever and never writes. Enough to own a live pipe pair.
# Written to a scratch dir, never into any repository tree.
SCRATCH = Dir.mktmpdir("i2-epipe-regression-")
at_exit { FileUtils.remove_entry(SCRATCH) rescue nil }

STUB_CHILD = File.join(SCRATCH, "stdin_sink.py")
File.write(STUB_CHILD, <<~PY)
  import sys
  for line in sys.stdin:
      pass
PY

puts "I2 SPAWN stop! EPIPE REGRESSION"
puts "  ruby        : #{RUBY_VERSION} (#{RUBY_PLATFORM})"
puts "  interpreter : #{INTERPRETER}"
puts "  stub child  : #{STUB_CHILD}"
puts "  real script : #{REAL_SCRIPT || '(not supplied -- stub child only)'}"
puts

VERDICTS = %i[confirmed unconfirmed].freeze

# How long to allow the retained waiter to complete AFTER `stop!` has returned. `stop!`'s own
# budget is STOP_GRACE_SECONDS per escalation step, so this is deliberately looser than that: the
# bound exists to keep a hung test from hanging forever, not to re-test `stop!`'s timing.
EXIT_WAIT_SECONDS = 8.0

# How long to watch a child we EXPECT to still be alive. Short on purpose -- a child that is
# running will not exit in this window, and one that does is a real signal, not a flake.
LIVE_PROBE_SECONDS = 0.75

# Did OUR child actually exit? Answered from the retained `Open3.popen3` waiter thread, never from
# a pid probe (pids are recyclable; a `Process.kill(0, pid)` answer is about whatever holds that
# pid NOW, not about the process we started).
#
# @param waiter [Thread, nil] the wait_thr captured BEFORE `stop!` cleared `@wait`.
# @param expected_pid [Integer, nil] the pid `Spawn#start!` reported.
# @param bound [Float] seconds to allow the waiter to complete.
# @return [Array(Symbol, Object)] one of
#   [:exited, Process::Status]  -- the ONLY outcome that counts as proof of exit
#   [:running, nil]             -- the waiter did not complete in the bound: child still running
#   [:inconclusive, String]     -- no evidence either way; a reason is always supplied
#
# EVERY non-`:exited` outcome is a FAILURE at the call site. There is no branch here that
# manufactures a pass, which is the whole difference from the version this replaces.
def await_child_exit(waiter, expected_pid, bound)
  unless waiter.respond_to?(:join) && waiter.respond_to?(:value)
    return [:inconclusive, "no waiter was retained (got #{waiter.class}); exit cannot be evidenced"]
  end

  return [:running, nil] if waiter.join(bound).nil?

  status = begin
    waiter.value
  rescue StandardError => e
    return [:inconclusive, "the waiter itself raised #{e.class}: #{e.message}"]
  end

  unless status.is_a?(Process::Status)
    return [:inconclusive, "waiter produced #{status.class}, not a Process::Status"]
  end

  # A Status for some OTHER pid would be evidence about some other process. Refuse it.
  if expected_pid && status.pid != expected_pid
    return [:inconclusive, "status pid=#{status.pid} does not match the spawned pid=#{expected_pid}"]
  end

  [:exited, status]
end

# Describe a Process::Status without leaking anything but numbers.
def describe_status(status)
  "exitstatus=#{status.exitstatus.inspect} termsig=#{status.termsig.inspect} " \
    "signaled=#{status.signaled?} pid=#{status.pid}"
end

# Assert, at a call site, that OUR child exited -- failing loudly on `:running` and on
# `:inconclusive` alike.
def assert_exited(waiter, pid, label, bound: EXIT_WAIT_SECONDS)
  outcome, payload = await_child_exit(waiter, pid, bound)
  case outcome
  when :exited
    note "#{label}: child exit EVIDENCED by the retained waiter -- #{describe_status(payload)}"
    true
  when :running
    note "#{label}: child is STILL RUNNING -- the waiter did not complete within #{bound}s " \
         "(a raise was traded for an orphan)"
    false
  else
    note "#{label}: INCONCLUSIVE -- #{payload}. An inconclusive outcome does not pass."
    false
  end
end

# Start a real child and hand back both the spawn and the waiter we must keep, because `stop!`
# nils `@wait` on a confirmed exit and the waiter is the only honest witness afterwards.
def start_spawn(script:, sidecar:, label:)
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: INTERPRETER, script: script, sidecar_path: sidecar, config: CONFIG
  )
  spawn.start!
  waiter = spawn.instance_variable_get(:@wait)
  note "#{label}: spawned pid=#{spawn.pid} waiter=#{waiter.class}"
  [spawn, waiter, spawn.pid]
end

# Build a Spawn over a real child, kill the child, and break the write side for real.
#
# @return [Array(Spawn, Thread, Integer)] a started spawn whose child is dead and whose @writer is
#   in a broken-pipe state, plus the RETAINED waiter and the pid, for the exit assertion.
def dead_child_spawn(script:, sidecar:, label:)
  spawn, waiter, pid = start_spawn(script: script, sidecar: sidecar, label: label)

  # Let the child reach its read loop, then KILL it outright. Nothing graceful: the point is a
  # reader that is gone while the parent still holds the write end.
  sleep 0.6
  begin
    Process.kill("KILL", pid)
  rescue StandardError => e
    note "#{label}: kill raised #{e.class} (child may have already exited)"
  end
  sleep 0.6

  # Now WRITE. This is what actually breaks the pipe: the first write to a pipe with no reader
  # fails, and it is that failure which leaves `close` raising EPIPE afterwards. The write's own
  # failure is expected and is not what this file asserts.
  2.times do
    begin
      spawn.writer.puts(JSON.generate("op" => "noop"))
      spawn.writer.flush
    rescue StandardError => e
      note "#{label}: write failed as expected: #{e.class}"
    end
  end

  [spawn, waiter, pid]
end

# ------------------------------------------------------------------------------------------------
puts "1 -- stop! against a REAL killed child with a broken stdin write side (stub child)"
# ------------------------------------------------------------------------------------------------
stub, stub_waiter, stub_pid = dead_child_spawn(script: STUB_CHILD, sidecar: SCRATCH, label: "stub")
first_verdict = nil
first_error = nil
begin
  first_verdict = stub.stop!
rescue StandardError => e
  first_error = e
end

if first_error
  note "stop! RAISED #{first_error.class}: #{first_error.message}"
  note "at #{first_error.backtrace&.first}"
else
  note "stop! returned #{first_verdict.inspect}"
end

check "stub child: stop! did not raise (its documented 'never raises on the shutdown path')" do
  first_error.nil?
end

check "stub child: stop! returned one of the two documented verdicts" do
  VERDICTS.include?(first_verdict)
end

check "stub child: stop! is still idempotent -- a second call also returns a verdict" do
  second = begin
    stub.stop!
  rescue StandardError => e
    note "second stop! RAISED #{e.class}: #{e.message}"
    e
  end
  note "second stop! -> #{second.inspect}"
  VERDICTS.include?(second)
end

# The orphan check. Evidence only: the retained waiter must complete and yield a Process::Status
# for OUR pid. `:running` and `:inconclusive` both FAIL here.
check "stub child: the child is EVIDENCED gone via the retained waiter (no orphan)" do
  assert_exited(stub_waiter, stub_pid, "stub")
end

puts
# ------------------------------------------------------------------------------------------------
puts "1b -- the exit assertion is DISCRIMINATING: a LIVE child must NOT read as exited"
# ------------------------------------------------------------------------------------------------
# This is the load-bearing proof for the check above. The previous pid-probe passed unconditionally,
# so it would have passed here too -- against a child that is demonstrably still running. The
# replacement must report `:running`. If this check ever passes while the probe is broken, the
# probe is not a probe.
live, live_waiter, live_pid = start_spawn(script: STUB_CHILD, sidecar: SCRATCH, label: "live")
sleep 0.8 # let the interpreter boot and block on stdin

live_outcome, live_payload = await_child_exit(live_waiter, live_pid, LIVE_PROBE_SECONDS)
note "live child probe -> #{live_outcome.inspect}#{live_payload ? " (#{live_payload.is_a?(Process::Status) ? describe_status(live_payload) : live_payload})" : ''}"

check "a STILL-RUNNING child reports :running, not :exited (the probe can actually fail)" do
  if live_outcome == :running
    true
  elsif live_outcome == :exited
    note "the live child had already exited -- #{describe_status(live_payload)}. The probe is not " \
         "being exercised; treat this as a FAILURE rather than a pass."
    false
  else
    note "probe said #{live_outcome.inspect}: #{live_payload}. Inconclusive does not pass."
    false
  end
end

check "a STILL-RUNNING child FAILS assert_exited (an orphan cannot report success)" do
  # Same assertion the orphan check uses, pointed at a live child: it must return FALSE.
  assert_exited(live_waiter, live_pid, "live(expected-to-fail)", bound: LIVE_PROBE_SECONDS) == false
end

# Clean up the live child through the production path, then evidence ITS exit too.
live_cleanup_verdict = begin
  live.stop!
rescue StandardError => e
  note "live child stop! RAISED #{e.class}: #{e.message}"
  e
end
note "live child stop! -> #{live_cleanup_verdict.inspect}"

check "live child: stop! returned a verdict and the child is EVIDENCED gone afterwards" do
  VERDICTS.include?(live_cleanup_verdict) && assert_exited(live_waiter, live_pid, "live")
end

puts
# ------------------------------------------------------------------------------------------------
puts "2 -- MUTATION GUARD: the rescue must stay NARROW (unrelated errors still propagate)"
# ------------------------------------------------------------------------------------------------
# A spawn whose writer raises something that is NOT a closed/broken pipe. If a later edit widens
# the rescue to StandardError / SystemCallError / `rescue nil`, these checks FAIL -- which is the
# entire point of keeping them here.
class ExplodingIO
  def close
    raise RuntimeError, "unrelated failure that must not be swallowed"
  end
end

widened = Atomspace::I2StdioTransport::Spawn.new(
  interpreter: INTERPRETER, script: STUB_CHILD, sidecar_path: SCRATCH, config: CONFIG
)
widened.instance_variable_set(:@writer, ExplodingIO.new)

check "an UNRELATED error from close still propagates (rescue was not widened)" do
  begin
    widened.stop!
    note "stop! returned without raising -- the rescue is TOO WIDE"
    false
  rescue RuntimeError => e
    note "propagated as required: RuntimeError: #{e.message}"
    true
  rescue StandardError => e
    note "propagated but as #{e.class}: #{e.message}"
    false
  end
end

# THE SystemCallError GUARD. `Errno::EPIPE` descends from `SystemCallError`, so the most tempting
# wrong fix for this bug is `rescue SystemCallError` -- which silently swallows EVERY errno,
# including ones that mean a real defect. The RuntimeError guard above cannot detect that, because
# RuntimeError is not a SystemCallError. `Errno::EACCES` is: it is a `SystemCallError` subclass and
# is NOT an `IOError`, and it is unrelated to a broken pipe. So:
#   * narrow rescue (`IOError, Errno::EPIPE`)      -> EACCES PROPAGATES -> this check PASSES
#   * widened (`SystemCallError`, or with IOError) -> EACCES SWALLOWED  -> this check FAILS
# Verified present on this platform before being relied upon.
UNRELATED_ERRNO = Errno::EACCES
unless UNRELATED_ERRNO.ancestors.include?(SystemCallError) &&
       !UNRELATED_ERRNO.ancestors.include?(IOError)
  warn "#{UNRELATED_ERRNO} is not a non-IOError SystemCallError on this platform; the " \
       "SystemCallError mutation guard cannot be expressed with it"
  exit 2
end

class ErrnoIO
  def close
    raise UNRELATED_ERRNO, "unrelated errno that must not be swallowed"
  end
end

errno_widened = Atomspace::I2StdioTransport::Spawn.new(
  interpreter: INTERPRETER, script: STUB_CHILD, sidecar_path: SCRATCH, config: CONFIG
)
errno_widened.instance_variable_set(:@writer, ErrnoIO.new)

check "an UNRELATED ERRNO (#{UNRELATED_ERRNO}) still propagates (rescue is not SystemCallError)" do
  begin
    verdict = errno_widened.stop!
    note "stop! returned #{verdict.inspect} without raising -- the rescue swallowed " \
         "#{UNRELATED_ERRNO}, so it has been widened to SystemCallError (or broader)"
    false
  rescue UNRELATED_ERRNO => e
    note "propagated as required: #{e.class}: #{e.message}"
    true
  rescue IOError => e
    note "propagated as #{e.class} -- unexpected for an errno: #{e.message}"
    false
  rescue StandardError => e
    note "propagated but as #{e.class}: #{e.message}"
    false
  end
end

# A spawn whose writer raises IOError must still be tolerated (pre-existing behaviour preserved).
class IOErrorIO
  def close
    raise IOError, "closed stream"
  end
end

ioerr = Atomspace::I2StdioTransport::Spawn.new(
  interpreter: INTERPRETER, script: STUB_CHILD, sidecar_path: SCRATCH, config: CONFIG
)
ioerr.instance_variable_set(:@writer, IOErrorIO.new)

check "the pre-existing IOError tolerance is preserved" do
  verdict = begin
    ioerr.stop!
  rescue StandardError => e
    note "stop! RAISED #{e.class}: #{e.message}"
    e
  end
  note "stop! -> #{verdict.inspect}"
  VERDICTS.include?(verdict)
end

# ------------------------------------------------------------------------------------------------
if REAL_SCRIPT && REAL_SIDECAR
  puts
  puts "3 -- the SAME probe against STORE's REAL reader service as the child"
  real, real_waiter, real_pid = dead_child_spawn(
    script: REAL_SCRIPT, sidecar: REAL_SIDECAR, label: "real-reader"
  )
  real_error = nil
  real_verdict = nil
  begin
    real_verdict = real.stop!
  rescue StandardError => e
    real_error = e
  end

  if real_error
    note "stop! RAISED #{real_error.class}: #{real_error.message}"
    note "at #{real_error.backtrace&.first}"
  else
    note "stop! returned #{real_verdict.inspect}"
  end

  check "real reader: stop! did not raise" do
    real_error.nil?
  end

  check "real reader: stop! returned one of the two documented verdicts" do
    VERDICTS.include?(real_verdict)
  end

  check "real reader: the child is EVIDENCED gone via the retained waiter (no orphan)" do
    assert_exited(real_waiter, real_pid, "real-reader")
  end
else
  puts
  puts "3 -- SKIPPED (no --script/--sidecar supplied; stub-child probe above still covers the bug)"
end

# ------------------------------------------------------------------------------------------------
puts
puts "=" * 96
puts "PASSED: #{PASSED.size}   FAILED: #{FAILED.size}"
FAILED.each { |n| puts "  - #{n}" }
puts "=" * 96
exit(FAILED.empty? ? 0 : 1)
