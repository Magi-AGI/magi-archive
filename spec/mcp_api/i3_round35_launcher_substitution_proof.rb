# frozen_string_literal: true

# =================================================================================================
# ROUND-35 PROOF HARNESS -- D1: LAUNCHER SUBSTITUTION AFTER VALIDATION (realpath identity)
# =================================================================================================
#
# Run it with:
#
#     cd E:/GitHub/Magi-AGI/av-view-deck && ruby spec/mcp_api/i3_round35_launcher_substitution_proof.rb
#
# NO rspec, NO Rails, NO decko, NO DB, NO network. Same bare-ruby shape and same rationale as
# spec/mcp_api/i3_round34_launcher_identity_proof.rb (card/decko/railties are not installed on this
# host, and the property under test is pure control flow over ENV + the filesystem + the spawn
# boundary).
#
# -------------------------------------------------------------------------------------------------
# THE FINDING THIS FILE PROVES CLOSED (cpd034 D1, verbatim)
# -------------------------------------------------------------------------------------------------
#   "Launcher substitution after validation - config/initializers/i3_read_binding.rb:505, :833.
#    The resolved file is hashed, but the original alias is executed. A replaceable external
#    symlink can redirect execution after validation. Minimal fix: launch the verified canonical
#    target and preserve validated content identity through execution; freezing the original path
#    string is insufficient."
#
# -------------------------------------------------------------------------------------------------
# WHY THIS IS A REAL PROOF AND NOT A COMMENT CHECK
# -------------------------------------------------------------------------------------------------
# The current source carries comments claiming "[CPD-035 FIX 1]". Comments are not evidence, so
# this harness ignores them and instead:
#
#   1. Builds REAL directories and REAL files under the scratch dir, reached through a REAL NTFS
#      DIRECTORY JUNCTION (`mklink /J`) -- the substitutable external alias. `File.realpath`
#      resolves a junction exactly as it resolves a symlink (proven by case J below, which
#      re-points the junction and observes realpath change).
#   2. REPOINTS THE JUNCTION IN THE EXACT TOCTOU WINDOW -- from inside `Spawn#initialize`, i.e.
#      AFTER `validated_launch` has validated + hashed and BEFORE `start!` reaches
#      `Open3.popen3`. That is precisely the attacker's window the finding describes.
#   3. CAPTURES THE ARGV AT THE OS BOUNDARY by wrapping `Open3.popen3` itself, so the assertion is
#      about what was really handed to `Process.spawn`, not about what a double was told.
#   4. SPAWNS A REAL CHILD PROCESS which writes a MARKER FILE identifying WHICH bytes executed.
#      "GOOD" means the validated/hashed file ran; "EVIL" means the substituted file ran.
#   5. Runs the PRE-FIX source (config/initializers/i3_read_binding.rb.bak-cpd035-pre) in a CHILD
#      RUBY PROCESS under the SAME attack to show the substitution DID land before the change. A
#      regression test that cannot distinguish old code from new code is not evidence.
#
# The child is a REAL ruby process launched through the REAL `Atomspace::I2StdioTransport::Spawn`
# and the REAL `Open3.popen3` with `unsetenv_others: true`. The fixture "launcher" is named
# `i2_stdio_reader_service.py` (the canonical basename the guard requires) but contains ruby, and
# is executed by the ruby interpreter: this harness is about PATH/BYTE IDENTITY at the spawn
# boundary, and python + the hyperon sidecar are not installed here.
#
# -------------------------------------------------------------------------------------------------
# WHAT THIS HARNESS DOES **NOT** PROVE
# -------------------------------------------------------------------------------------------------
# * NATIVE FILE SYMLINKS CANNOT BE CREATED ON THIS HOST (`File.symlink` => Errno::EACCES without
#   SeCreateSymbolicLinkPrivilege / Developer Mode). The substitutable alias is therefore an NTFS
#   DIRECTORY JUNCTION. Case J proves the junction really is late-binding for `File.realpath`
#   (re-pointing it changes what realpath answers), which is the only property the attack needs.
#   The native-file-symlink variant is attempted and reported as an explicit LIMIT when it fails.
# * No python, no hyperon, no AtomSpace, no HTTP, no 503 observed. "unwired => 503" is
#   `I3ReadPort`'s own contract, asserted elsewhere.
# * A `:confirmed` stop verdict remains the Spawn's own claim, not independent proof of exit.
# =================================================================================================

require "digest"
require "fileutils"
require "json"
require "open3"

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

DECK         = File.expand_path("../..", __dir__)
INITIALIZER  = File.join(DECK, "config/initializers/i3_read_binding.rb")
PRE_FIX_FILE = File.join(DECK, "config/initializers/i3_read_binding.rb.bak-cpd035-pre")
abort "initializer not found at #{INITIALIZER}" unless File.exist?(INITIALIZER)

SCRATCH_ROOT = ENV.fetch(
  "I3_PROOF_SCRATCH",
  "C:/Users/Lake/AppData/Local/hermes/profiles/claudetriad/cache/scratch"
)
RUN_DIR = File.join(SCRATCH_ROOT, "i3_round35_sub_proof_#{Process.pid}")

CANON = "i2_stdio_reader_service.py"

FileUtils.rm_rf(RUN_DIR)
FileUtils.mkdir_p(File.join(RUN_DIR, "real_good", "tools"))
FileUtils.mkdir_p(File.join(RUN_DIR, "real_evil", "tools"))

REAL_GOOD = File.realpath(File.join(RUN_DIR, "real_good"))
REAL_EVIL = File.realpath(File.join(RUN_DIR, "real_evil"))
MARKER    = File.join(RUN_DIR, "which_ran.txt")

# The two candidate launchers. Both are named CANON and both sit at <root>/tools/, so BOTH would
# satisfy the path-containment guard once the root they are reached through is substituted. They
# differ only in the bytes they execute -- which is the whole point.
GOOD_BODY = <<~RB
  File.write(#{MARKER.dump}, "GOOD")
  $stdout.puts("good-launcher-online")
  $stdout.flush
  sleep 5
RB
EVIL_BODY = <<~RB
  File.write(#{MARKER.dump}, "EVIL")
  $stdout.puts("evil-launcher-online")
  $stdout.flush
  sleep 5
RB

GOOD_PATH = File.join(REAL_GOOD, "tools", CANON)
EVIL_PATH = File.join(REAL_EVIL, "tools", CANON)
File.write(GOOD_PATH, GOOD_BODY)
File.write(EVIL_PATH, EVIL_BODY)
GOOD_DIGEST = Digest::SHA256.file(GOOD_PATH).hexdigest
EVIL_DIGEST = Digest::SHA256.file(EVIL_PATH).hexdigest

# THE SUBSTITUTABLE EXTERNAL ALIAS. Every env var below names paths THROUGH this junction, so the
# operator's configuration never mentions REAL_GOOD directly -- exactly the deployment shape the
# finding is about (a sidecar root reached through a link).
LINK = File.join(RUN_DIR, "sidecar_link")

def junction!(link, target)
  system("cmd", "/c", "rmdir", link.tr("/", "\\"), out: File::NULL, err: File::NULL)
  system("cmd", "/c", "mklink", "/J", link.tr("/", "\\"), target.tr("/", "\\"),
         out: File::NULL, err: File::NULL)
  Dir.exist?(link)
end

JUNCTION_OK = junction!(LINK, REAL_GOOD)
abort "cannot create an NTFS junction on this host; the substitution attack cannot be staged" unless JUNCTION_OK

LINK_ROOT   = LINK
LINK_SCRIPT = File.join(LINK, "tools", CANON)
INTERPRETER = File.realpath(RbConfig.ruby)

puts "=" * 99
puts "I3 ROUND-35 LAUNCHER SUBSTITUTION PROOF  (D1 -- real junction, real spawn, real child bytes)"
puts "file under test : #{INITIALIZER}"
puts "pre-fix baseline: #{PRE_FIX_FILE}"
puts "scratch run dir : #{RUN_DIR}"
puts "good digest     : #{GOOD_DIGEST}"
puts "evil digest     : #{EVIL_DIGEST}"
puts "=" * 99

# =================================================================================================
# CASE J -- THE JUNCTION REALLY IS A LATE-BINDING ALIAS (the attack's only prerequisite)
# =================================================================================================
before = File.realpath(LINK_SCRIPT)
junction!(LINK, REAL_EVIL)
after = File.realpath(LINK_SCRIPT)
junction!(LINK, REAL_GOOD)
restored = File.realpath(LINK_SCRIPT)

check("J1 the junction resolves to the GOOD tree while it points there") { before == GOOD_PATH }
check("J2 RE-POINTING the junction changes what File.realpath answers (late binding: the alias " \
      "is substitutable at any instant)") { after == EVIL_PATH }
check("J3 and it can be restored, so every case below starts from the same state") { restored == GOOD_PATH }
check("J4 the two candidate launchers have DIFFERENT bytes, so 'which ran' is observable") do
  GOOD_DIGEST != EVIL_DIGEST && File.read(GOOD_PATH) != File.read(EVIL_PATH)
end

if (File.symlink(GOOD_PATH, File.join(RUN_DIR, "symlink_probe")) rescue false)
  check("J5 a native FILE symlink was also creatable on this host") { true }
else
  limit("J5 native FILE symlink not created (File.symlink => Errno::EACCES without " \
        "SeCreateSymbolicLinkPrivilege/Developer Mode). The substitutable-alias property is " \
        "proven with the NTFS JUNCTION instead (cases J1-J3); the native-symlink variant is " \
        "UNPROVEN on this host")
end

# =================================================================================================
# PORT DOUBLE -- `refuse!` calls `reset_port!`, which is `defined?`-guarded. Counting resets lets
# a refusal be distinguished from a silent no-op. The REAL I3ReadPort is loaded later by
# `load_dependencies!` only if this constant is absent, so defining it here keeps the harness
# independent of the port's own behaviour.
# =================================================================================================
module Atomspace
  module I3ReadPort
    class << self
      attr_reader :impl, :reset_count

      def bind!(impl)
        @impl = impl
      end

      def reset!
        @impl = nil
        @reset_count = (@reset_count || 0) + 1
      end

      def clear_counters!
        @impl = nil
        @reset_count = 0
      end
    end
  end
end

# Load with Rails UNDEFINED so the after_initialize hook at the bottom never registers.
load INITIALIZER
INSTALLER = Atomspace::I3ReadBindingInstaller

# Pull in the REAL Spawn / client so the spy below can subclass the real class.
#
# NOTE: `load_dependencies!` requires the deck's REAL mod/mcp_api/lib/atomspace/i3_read_port.rb
# (via local_i3_read_binding.rb's `require_relative`), which REDEFINES `bind!`/`reset!` on the
# `Atomspace::I3ReadPort` module declared above -- so the pre-load double's counters are gone by
# this line. That is a better outcome, not a worse one: from here on the harness drives the REAL
# port. A counting WRAPPER is installed around the REAL `reset!` (it still calls the real one via
# `super`-style alias), so refusals can be counted without changing port behaviour.
INSTALLER.send(:load_dependencies!)

module Atomspace
  module I3ReadPort
    class << self
      alias_method :__r35_real_reset!, :reset!

      def reset!
        @r35_reset_count = (@r35_reset_count || 0) + 1
        __r35_real_reset!
      end

      def reset_count
        @r35_reset_count || 0
      end

      def clear_counters!
        @r35_reset_count = 0
        __r35_real_reset!
      end
    end
  end
end

REAL_SPAWN = Atomspace::I2StdioTransport::Spawn
check("S0 the REAL Atomspace::I2StdioTransport::Spawn was loaded from the deck source") do
  REAL_SPAWN.is_a?(Class) &&
    REAL_SPAWN.instance_method(:start!).source_location.to_a.first.to_s
             .end_with?("i2_stdio_transport.rb")
end

# =================================================================================================
# ARGV CAPTURE AT THE OS BOUNDARY. `Open3.popen3` is wrapped, not replaced: the real one still
# runs, so a real child is still spawned. This is the strongest available evidence of what was
# handed to `Process.spawn` -- it is read off the call itself, not off a double's bookkeeping.
# =================================================================================================
POPEN3_CALLS = []
Open3.singleton_class.send(:alias_method, :__r35_real_popen3, :popen3)
Open3.singleton_class.send(:define_method, :popen3) do |*args, &blk|
  POPEN3_CALLS << args.map { |a| a.is_a?(Hash) ? a.dup : a.dup }
  __r35_real_popen3(*args, &blk)
end

# =================================================================================================
# THE ATTACK ITSELF. `SpySpawn#initialize` runs AFTER `validated_launch` has finished validating
# and hashing, and BEFORE `start!` reaches `Open3.popen3`. Re-pointing the junction here IS the
# TOCTOU window described in the finding. Nothing else about Spawn is changed: `super` runs the
# real constructor and `start!` is the real method.
# =================================================================================================
SPAWN_ARGS = []
REPOINTED  = []

class SpySpawn < REAL_SPAWN
  def initialize(interpreter:, script:, sidecar_path:, config:)
    SPAWN_ARGS << { interpreter: interpreter, script: script, sidecar_path: sidecar_path }
    # ---- THE SUBSTITUTION, in the exact window between validation and spawn ----
    REPOINTED << junction!(LINK, REAL_EVIL)
    super
  end
end

Atomspace::I2StdioTransport.send(:remove_const, :Spawn)
Atomspace::I2StdioTransport.const_set(:Spawn, SpySpawn)

def set_env!
  ENV["I3_READ_BINDING"]      = "live"
  ENV["I3_I2_INTERPRETER"]    = INTERPRETER
  ENV["I3_I2_SCRIPT"]         = LINK_SCRIPT
  ENV["I3_STORE_SIDECAR_PATH"] = LINK_ROOT
  ENV["I3_I2_CONFIG"]         = JSON.generate("max_results" => 10)
  ENV["I3_I2_DEADLINE_MS"]    = "4000"
  ENV["I3_I2_SCRIPT_SHA256"]  = GOOD_DIGEST
  ENV.delete("WEB_CONCURRENCY")
end

FileUtils.rm_f(MARKER)
junction!(LINK, REAL_GOOD)
set_env!
Atomspace::I3ReadPort.clear_counters!

# =================================================================================================
# CASE A -- THE WHOLE BIND, UNDER ATTACK. REAL validation, REAL spawn, REAL child.
# =================================================================================================
bound = INSTALLER.install_for_worker!

# Give the child a moment to write its marker, then read which bytes executed.
40.times { break if File.exist?(MARKER); sleep 0.05 }
marker = (File.read(MARKER) rescue "NO-MARKER")
child_stdout = begin
  INSTALLER.owned_spawn&.reader&.gets.to_s.strip
rescue StandardError
  ""
end

check("A0 the attack really was staged in the TOCTOU window (the junction was re-pointed from " \
      "inside Spawn#initialize, after validation, before popen3)") do
  REPOINTED == [true] && File.realpath(LINK_SCRIPT) == EVIL_PATH
end
check("A1 the bind SUCCEEDED (so this case is testing the LAUNCH path, not a refusal)") { bound == true }
check("A2 Spawn was handed the RESOLVED REALPATH of the validated script, NOT the junction alias " \
      "that was configured") do
  SPAWN_ARGS.size == 1 && SPAWN_ARGS[0][:script] == GOOD_PATH && SPAWN_ARGS[0][:script] != LINK_SCRIPT
end
check("A3 Spawn was handed the RESOLVED REALPATH of the interpreter") do
  SPAWN_ARGS[0][:interpreter] == INTERPRETER
end
check("A4 Spawn was handed the RESOLVED REALPATH of the sidecar root, not the junction") do
  SPAWN_ARGS[0][:sidecar_path] == REAL_GOOD && SPAWN_ARGS[0][:sidecar_path] != LINK_ROOT
end
check("A5 the paths in the spawn argv are FROZEN strings (they cannot be mutated in place " \
      "between validation and spawn)") do
  SPAWN_ARGS[0][:script].frozen? && SPAWN_ARGS[0][:interpreter].frozen? &&
    SPAWN_ARGS[0][:sidecar_path].frozen?
end
check("A6 the ACTUAL Open3.popen3 argv -- captured at the OS boundary -- is " \
      "[env, resolved_interpreter, resolved_script, opts]") do
  c = POPEN3_CALLS.last
  c && c[0].is_a?(Hash) && c[1] == INTERPRETER && c[2] == GOOD_PATH
end
check("A7 the popen3 argv contains NO junction/alias component anywhere") do
  c = POPEN3_CALLS.last
  c && c[1..2].none? { |a| a.to_s.include?("sidecar_link") }
end
check("A8 THE DECISIVE OBSERVATION: the REAL CHILD executed the VALIDATED+HASHED bytes " \
      "(marker=GOOD), not the substituted ones") { marker == "GOOD" }
check("A9 ...and the child's own stdout agrees it is the good launcher") do
  child_stdout == "good-launcher-online"
end
check("A10 the bytes that ran still hash to the pinned digest (hashed == executed)") do
  Digest::SHA256.file(GOOD_PATH).hexdigest == ENV["I3_I2_SCRIPT_SHA256"]
end
check("A11 popen3 was called EXACTLY ONCE (one child per process; no retry re-read ENV)") do
  POPEN3_CALLS.size == 1
end
check("A12 the child env passed to popen3 carries the RESOLVED sidecar root, so the child also " \
      "resolves STORE modules from the validated tree") do
  POPEN3_CALLS.last[0]["AV_STORE_SIDECAR_PATH"] == REAL_GOOD
end

verdict = INSTALLER.shutdown_owned_child!
check("A13 the child this harness started was stopped (verdict #{verdict.inspect})") do
  [:confirmed, :unconfirmed].include?(verdict)
end
INSTALLER.retry_unreaped!

# =================================================================================================
# CASE B -- THE NEGATIVE CONTROL: the SAME attack against the RAW ALIAS really does substitute.
# Without this, case A8 proves nothing: it could pass simply because the junction re-point did not
# work. Here `Open3.popen3` is handed the UNRESOLVED junction path -- i.e. exactly what the
# pre-fix snapshot stored -- and the EVIL bytes execute.
# =================================================================================================
FileUtils.rm_f(MARKER)
junction!(LINK, REAL_GOOD)
hashed_before = Digest::SHA256.file(LINK_SCRIPT).hexdigest  # validation-time hash, via the alias
junction!(LINK, REAL_EVIL)                                   # the swap, after validation
i, o, e, w = Open3.__r35_real_popen3(
  { "AV_STORE_SIDECAR_PATH" => LINK_ROOT, "AV_I2_STDIO_CONFIG" => "{}", "PYTHONUNBUFFERED" => "1" },
  INTERPRETER, LINK_SCRIPT, unsetenv_others: true
)
40.times { break if File.exist?(MARKER); sleep 0.05 }
control_marker = (File.read(MARKER) rescue "NO-MARKER")
[i, o, e].each { |io| io.close rescue nil }
begin
  Process.kill("KILL", w[:pid])
rescue StandardError
  nil
end
w.join rescue nil

check("B1 the validation-time hash through the alias WAS the good digest") { hashed_before == GOOD_DIGEST }
check("B2 NEGATIVE CONTROL: spawning the UNRESOLVED alias after the swap executes the EVIL bytes " \
      "(marker=EVIL) -- the attack is real and the junction re-point works") do
  control_marker == "EVIL"
end
check("B3 so case A8 distinguishes the two outcomes: same attack, GOOD via the snapshot vs EVIL " \
      "via the raw alias") { control_marker == "EVIL" && marker == "GOOD" }

# =================================================================================================
# CASE C -- THE PRE-FIX SOURCE, SAME ATTACK, IN A CHILD RUBY PROCESS.
# Two versions of the same module cannot coexist in one process, so the pre-fix file is driven in
# a child. The question asked is the one that matters: WHAT PATHS DOES THE SNAPSHOT HAND TO SPAWN?
# =================================================================================================
if File.exist?(PRE_FIX_FILE)
  probe = File.join(RUN_DIR, "pre_fix_snapshot_probe.rb")
  File.write(probe, <<~RB)
    require "json"
    module Atomspace
      module I3ReadPort
        def self.reset!; end
        def self.bind!(_impl); end
      end
    end
    load #{PRE_FIX_FILE.dump}
    I = Atomspace::I3ReadBindingInstaller
    ENV["I3_READ_BINDING"]       = "live"
    ENV["I3_I2_INTERPRETER"]     = #{INTERPRETER.dump}
    ENV["I3_I2_SCRIPT"]          = #{LINK_SCRIPT.dump}
    ENV["I3_STORE_SIDECAR_PATH"] = #{LINK_ROOT.dump}
    ENV["I3_I2_CONFIG"]          = JSON.generate("max_results" => 10)
    ENV["I3_I2_DEADLINE_MS"]     = "4000"
    ENV["I3_I2_SCRIPT_SHA256"]   = #{GOOD_DIGEST.dump}
    launch = I.send(:validated_launch)
    if launch
      puts JSON.generate(
        "built" => true,
        "script" => launch.script,
        "interpreter" => launch.interpreter,
        "sidecar" => launch.sidecar_path,
        "stored_raw_alias" => (launch.script == #{LINK_SCRIPT.dump})
      )
    else
      puts JSON.generate("built" => false)
    end
  RB
  junction!(LINK, REAL_GOOD)
  out = `ruby -W0 #{probe.dump} 2>&1`
  pre = begin
    JSON.parse(out.lines.grep(/^\{/).last.to_s)
  rescue StandardError
    nil
  end

  check("C1 PRE-FIX `validated_launch` built a snapshot for this configuration") do
    pre && pre["built"] == true
  end
  check("C2 PRE-FIX snapshot stored the RAW JUNCTION ALIAS as the script to spawn (the defect: " \
        "popen3 would re-traverse it at spawn time)") do
    pre && pre["stored_raw_alias"] == true
  end
  check("C3 CURRENT snapshot stores the RESOLVED REALPATH instead (the two differ, so the change " \
        "is real and not cosmetic)") do
    pre && pre["script"] != GOOD_PATH && SPAWN_ARGS[0][:script] == GOOD_PATH
  end
  puts "     (pre-fix child output: #{out.strip.lines.last.to_s.strip})"
else
  limit("C pre-fix baseline #{PRE_FIX_FILE} is absent, so the before-state could not be re-run")
end

# =================================================================================================
# CASE D -- FAIL-CLOSED ON AN UNRESOLVABLE PATH. The fix must REFUSE rather than fall back to the
# raw string when a path stops resolving between its gate and the snapshot; a fallback would
# quietly reopen the hole.
# =================================================================================================
Atomspace::I3ReadPort.clear_counters!
set_env!
junction!(LINK, REAL_GOOD)
check("D1 a readable, contained, correctly-pinned configuration DOES build a snapshot " \
      "(the refusals below are not vacuous)") do
  INSTALLER.send(:validated_launch).is_a?(Atomspace::I3ReadBindingInstaller::ValidatedLaunch)
end

set_env!
ENV["I3_I2_SCRIPT"] = File.join(LINK_ROOT, "tools", "nope_#{CANON}")
check("D2 an unresolvable script REFUSES (returns false) and resets the port") do
  INSTALLER.send(:validated_launch) == false && Atomspace::I3ReadPort.reset_count.to_i.positive?
end

set_env!
check("D3 the snapshot's three paths are ALL realpaths (no raw ENV string survives into it)") do
  l = INSTALLER.send(:validated_launch)
  l.script == GOOD_PATH && l.interpreter == INTERPRETER && l.sidecar_path == REAL_GOOD
end
check("D4 the snapshot itself is FROZEN") { INSTALLER.send(:validated_launch).frozen? }

# =================================================================================================
# CASE E -- SOURCE-LEVEL INVARIANTS that keep the fix from being undone by a later edit.
# =================================================================================================
src = File.read(INITIALIZER)
transport = File.read(File.join(DECK, "mod/mcp_api/lib/atomspace/i2_stdio_transport.rb"))

check("E1 `bind!` passes ONLY the snapshot's members to Spawn (no ENV read, no re-derivation)") do
  body = src[/def bind!\(launch:\).*?^      end/m].to_s
  body.include?("interpreter: launch.interpreter") &&
    body.include?("script: launch.script") &&
    body.include?("sidecar_path: launch.sidecar_path") &&
    !body.include?("ENV[") && !body.include?("realpath")
end
check("E2 the transport NEVER reads ENV and never resolves a path of its own: it spawns exactly " \
      "the two strings it was constructed with") do
  !transport.include?("ENV[") && !transport.include?("realpath") &&
    transport.include?("child_env, @interpreter, @script, unsetenv_others: true")
end
check("E3 `require_absolute!` in the transport returns the value UNCHANGED (it validates shape, " \
      "it does not re-resolve -- so it cannot reintroduce an alias)") do
  body = transport[/def require_absolute!\(value, name\).*?^      end/m].to_s
  body.include?("value\n") && !body.include?("expand_path") && !body.include?("realpath")
end
check("E4 there is no second ENV read on the launch path: the only ENV[] reads in the " \
      "initializer are the master switch, the single REQUIRED_ENV snapshot, and the prefork guard") do
  reads = src.lines.each_with_index.select { |l, _| l.include?("ENV[") && !l.strip.start_with?("#") }
  reads.size == 3 &&
    reads.any? { |l, _| l.include?("I3_READ_BINDING") } &&
    reads.any? { |l, _| l.include?("REQUIRED_ENV") || l.include?("[key, ENV[key]]") } &&
    reads.any? { |l, _| l.include?("PREFORK_CONCURRENCY_ENV") }
end
check("E5 no ENV.fetch anywhere in the initializer CODE (a second read would reopen the TOCTOU; " \
      "the two remaining mentions are comments describing the closed defect)") do
  code = src.lines.reject { |l| l.strip.start_with?("#") }.join
  !code.include?("ENV.fetch")
end
check("E6 the unresolvable branch REFUSES and does not fall back to the raw value") do
  snippet = src[/resolved_interpreter = realpath_or_nil.*?end\n/m].to_s
  snippet.include?("return refuse!") && !snippet.match?(/\|\|\s*raw\[/)
end
check("E7 both owned ruby files are syntactically valid") do
  system(RbConfig.ruby, "-c", INITIALIZER, out: File::NULL, err: File::NULL) &&
    system(RbConfig.ruby, "-c", File.join(DECK, "mod/mcp_api/lib/atomspace/i2_stdio_transport.rb"),
           out: File::NULL, err: File::NULL)
end

# =================================================================================================
Atomspace::I2StdioTransport.send(:remove_const, :Spawn)
Atomspace::I2StdioTransport.const_set(:Spawn, REAL_SPAWN)
Open3.singleton_class.send(:alias_method, :popen3, :__r35_real_popen3)
ENV["I3_READ_BINDING"] = nil
system("cmd", "/c", "rmdir", LINK.tr("/", "\\"), out: File::NULL, err: File::NULL)
FileUtils.rm_rf(RUN_DIR)

puts "\n#{'=' * 99}"
puts "PASS: #{PASS.size}   FAIL: #{FAIL.size}   TOTAL: #{PASS.size + FAIL.size}"
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
