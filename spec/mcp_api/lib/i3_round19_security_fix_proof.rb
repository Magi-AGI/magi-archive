# frozen_string_literal: true
#
# ROUND-19 SECURITY-FIX PROOF, pure Ruby. No Rails, no Postgres, no Decko boot.
#
# This is NOT a substitute for the ~98 unrun `type: :request` examples. It proves the three
# round-19 corrections as PURE LOGIC, on the controller's OWN source bytes where possible, and
# on faithful re-expressions of the framework behaviour where the real class cannot load here.
# Every claim it makes is about the defect mechanics Codex named, nothing more.
#
#   F5b  a String/Array must NOT be able to become a successful address (strict Hash)
#   F4   the last-resort error handler must NOT consult the backend (constant metadata)
#   F1   service-account exclusion must use canonical identity (ids), not name strings
#
# Run: ruby spec/mcp_api/lib/i3_round19_security_fix_proof.rb

require "set"

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

CONTROLLER = File.expand_path(
  "../../../mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb", __dir__
)
SOURCE = File.read(CONTROLLER)

# ---------------------------------------------------------------------------------------------
# F5b -- STRICT MAPPING TYPE FOR THE BACKEND ADDRESS
#
# The defect: `respond_to?(:[])` does not establish a mapping. Ruby String#[] is SUBSTRING
# SEARCH, so the malformed address "key digest" yielded key="key" and digest="digest", both
# Strings, both non-blank -- and #lookup rendered found:true with an address no backend issued.
# ---------------------------------------------------------------------------------------------
puts "\nF5b -- address must be the declared mapping type (Hash), not anything answering []"

class AddressUnavailable < StandardError; end

# The FIXED extraction, transcribed verbatim from validated_address_fields.
def validated_address_fields(address)
  raise AddressUnavailable, "backend_digest_unavailable" unless address.is_a?(Hash)

  key = address["key"] || address[:key]
  digest = address["digest"] || address[:digest]
  unless key.is_a?(String) && !(key.nil? || key.empty?) &&
         digest.is_a?(String) && !(digest.nil? || digest.empty?)
    raise AddressUnavailable, "backend_digest_unavailable"
  end

  [key, digest]
end

# The ORIGINAL extraction, kept so the proof demonstrates the defect was REAL and is now closed.
def legacy_validated_address_fields(address)
  raise AddressUnavailable, "backend_digest_unavailable" unless address.respond_to?(:[])

  key = address["key"] || address[:key]
  digest = address["digest"] || address[:digest]
  unless key.is_a?(String) && !(key.nil? || key.empty?) &&
         digest.is_a?(String) && !(digest.nil? || digest.empty?)
    raise AddressUnavailable, "backend_digest_unavailable"
  end

  [key, digest]
end

def refuses?(address)
  validated_address_fields(address)
  false
rescue AddressUnavailable => e
  e.message == "backend_digest_unavailable"
end

# First: prove the defect was real, so this fix is not decorative.
check "REGRESSION WITNESS: the OLD check admitted the malformed String \"key digest\"" do
  legacy_validated_address_fields("key digest") == %w[key digest]
end

check "the malformed String \"key digest\" is now REFUSED (not a successful address)" do
  refuses?("key digest")
end

check "an ordinary String address is refused" do
  refuses?("some-card-name")
end

check "an Array address is refused (Array also answers [])" do
  refuses?(%w[key digest])
end

check "nil is refused" do
  refuses?(nil)
end

check "an Integer is refused" do
  refuses?(42)
end

check "a bare object answering [] is refused (duck typing is not a contract)" do
  duck = Object.new
  def duck.[](other)
    other.to_s
  end
  refuses?(duck)
end

check "a Hash missing digest is refused" do
  refuses?({ "key" => "abc" })
end

check "a Hash with a non-String digest is refused" do
  refuses?({ "key" => "abc", "digest" => 123 })
end

check "a Hash with a blank key is refused" do
  refuses?({ "key" => "", "digest" => "deadbeef" })
end

check "a Hash with a Hash-valued key is refused" do
  refuses?({ "key" => { "nested" => true }, "digest" => "deadbeef" })
end

check "a WELL-FORMED String-typed Hash still succeeds verbatim (no over-tightening)" do
  validated_address_fields({ "key" => "my_card", "digest" => "a" * 32 }) == ["my_card", "a" * 32]
end

check "symbol keys still succeed (the port's documented alternative)" do
  validated_address_fields({ key: "my_card", digest: "b" * 32 }) == ["my_card", "b" * 32]
end

check "SOURCE: validated_address_fields uses is_a?(Hash), and respond_to?(:[]) is gone from code" do
  body = SOURCE[/def validated_address_fields.*?\n      end/m]
  body.include?("address.is_a?(Hash)") && !body.include?("respond_to?(:[])")
end

# ---------------------------------------------------------------------------------------------
# F4 -- THE LAST-RESORT HANDLER MUST NOT CONSULT THE BACKEND
#
# Two distinct defects, both from calling i3_meta (which reads I3ReadPort.origin):
#   (a) an exception raised BEFORE authorization completes leaks the backend origin to a caller
#       who was never authorized; and
#   (b) if origin is ITSELF what raised, the handler re-enters the failing method and the fixed
#       error response is never produced.
# ---------------------------------------------------------------------------------------------
puts "\nF4 -- render_unexpected_error must use constant metadata, never the port"

ERROR_META = { surface: "i3" }.freeze

class ExplodingPort
  attr_reader :origin_calls

  def initialize
    @origin_calls = 0
  end

  def origin
    @origin_calls += 1
    raise "origin exploded"
  end
end

# The FIXED handler, transcribed: nothing derived from the exception or the backend.
def render_unexpected_error(_exception, port)
  { error: "i3_internal_error", reason: "i3_unexpected_error", _meta: ERROR_META }
end

# The ORIGINAL handler, for the regression witness.
def legacy_render_unexpected_error(_exception, port)
  { error: "i3_internal_error", reason: "i3_unexpected_error",
    _meta: { surface: "i3", data_origin: port.origin } }
end

check "REGRESSION WITNESS: the OLD handler re-entered a failing origin and produced NO response" do
  port = ExplodingPort.new
  begin
    legacy_render_unexpected_error(RuntimeError.new("boom"), port)
    false
  rescue RuntimeError => e
    e.message == "origin exploded" && port.origin_calls == 1
  end
end

check "the handler NEVER calls the port (origin_calls stays 0)" do
  port = ExplodingPort.new
  render_unexpected_error(RuntimeError.new("boom"), port)
  port.origin_calls.zero?
end

check "the handler still returns the fixed response when origin itself raises" do
  port = ExplodingPort.new
  body = render_unexpected_error(RuntimeError.new("boom"), port)
  body[:error] == "i3_internal_error" && body[:reason] == "i3_unexpected_error"
end

check "the response carries NO data_origin / backend signal" do
  body = render_unexpected_error(RuntimeError.new("boom"), ExplodingPort.new)
  !body[:_meta].key?(:data_origin) && body[:_meta] == { surface: "i3" }
end

check "the response carries NOTHING derived from the exception (no class, no message)" do
  exc = ArgumentError.new("card 'Secret Plans' is not readable by user 42")
  body = render_unexpected_error(exc, ExplodingPort.new)
  serialized = body.inspect
  !serialized.include?("Secret Plans") && !serialized.include?("ArgumentError") &&
    !serialized.include?("42")
end

check "a PRE-AUTHORIZATION exception discloses no more than a post-auth one (same constant)" do
  pre = render_unexpected_error(RuntimeError.new("raised in before_action"), ExplodingPort.new)
  post = render_unexpected_error(RuntimeError.new("raised in render"), ExplodingPort.new)
  pre == post && pre[:_meta] == ERROR_META
end

check "ERROR_META is frozen, so no request can mutate the shared constant" do
  ERROR_META.frozen?
end

check "SOURCE: render_unexpected_error references ERROR_META and does NOT call i3_meta" do
  body = SOURCE[/def render_unexpected_error.*?\n      end/m]
  # Strip comment lines first: the method's own prose explains WHY it must not call i3_meta, and
  # matching that prose would be checking the comment rather than the executable code.
  code = body.gsub(/^\s*#.*$/, "")
  code.include?("_meta: ERROR_META") && !code.include?("i3_meta")
end

check "SOURCE: ERROR_META is declared frozen and carries no data_origin" do
  decl = SOURCE[/ERROR_META = .*/]
  decl.include?(".freeze") && !decl.include?("data_origin") && !decl.include?("origin")
end

# ---------------------------------------------------------------------------------------------
# F1 -- CANONICAL SERVICE-ACCOUNT IDENTITY, NOT NAME STRINGS
#
# The defect: Decko identifies cards by a canonical KEY, not a display string. Cardname#simple_key
# (cardname.rb:101-116) underscores, collapses runs of non-key characters to "_" and stable-keys
# each part, so "mcp_admin", "mcp-admin", "MCP Admin" and "mcp--admin" are ONE card. A configured
# MCP_ADMIN_NAME="mcp_admin" therefore resolves the stored card "mcp-admin", while casecmp?
# compared the two literal strings, found them unequal, and ADMITTED the admin service identity.
# ---------------------------------------------------------------------------------------------
puts "\nF1 -- service-account exclusion must compare canonical identity (persisted ids)"

# A faithful re-expression of Cardname's canonicalization for the separator/case axis that the
# defect turns on. Decko's real OK4KEY_RE admits [a-zA-Z0-9*] and collapses everything else.
module Cardname
  def self.key(name)
    name.to_s
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
        .gsub(/[^a-z0-9*]+/, "_")
        .split(/_+/)
        .reject(&:empty?)
        .join("_")
  end
end

# A minimal Card store keyed canonically, exactly as Decko's Card[] lookup behaves.
class FakeCard
  attr_reader :id, :name

  def initialize(id, name)
    @id = id
    @name = name
  end
end

class CardStore
  def initialize
    @by_key = {}
    @next_id = 100
  end

  def create!(name)
    card = FakeCard.new(@next_id += 1, name)
    @by_key[Cardname.key(name)] = card
    card
  end

  def [](name)
    @by_key[Cardname.key(name)]
  end
end

STORE = CardStore.new
MCP_ADMIN = STORE.create!("mcp-admin")
MCP_GM = STORE.create!("mcp-gm")
MCP_USER = STORE.create!("mcp-user")
REAL_USER = STORE.create!("Joe User")

# The FIXED exclusion, transcribed: resolve through the SAME Card[] lookup, compare ids.
def service_account?(account, configured_names)
  return false unless account&.id

  ids = configured_names.filter_map { |svc| STORE[svc]&.id }
  ids.include?(account.id)
end

# The ORIGINAL exclusion, for the regression witness.
def legacy_service_account_name?(name, configured_names)
  candidate = name.to_s.strip
  return false if candidate.empty?

  configured_names.any? { |svc| svc.casecmp?(candidate) }
end

check "GROUND TRUTH: Decko canonicalization makes mcp_admin and mcp-admin the SAME card" do
  STORE["mcp_admin"] && STORE["mcp_admin"].id == MCP_ADMIN.id
end

check "REGRESSION WITNESS: the OLD string check MISSED the mcp_admin alias of mcp-admin" do
  # Configured as "mcp_admin"; the resolved card is named "mcp-admin". casecmp? says not-equal,
  # so the administrative service account was ADMITTED.
  legacy_service_account_name?(MCP_ADMIN.name, ["mcp_admin"]) == false
end

check "the alias mcp_admin -> card mcp-admin is now EXCLUDED (the actual blocker)" do
  service_account?(MCP_ADMIN, ["mcp_admin"])
end

check "the canonical spelling mcp-admin is excluded" do
  service_account?(MCP_ADMIN, ["mcp-admin"])
end

[
  "MCP_Admin", "MCP Admin", "mcp--admin", "  mcp-admin  ", "mcp_ADMIN", "McpAdmin"
].each do |alias_name|
  check "alias #{alias_name.inspect} is excluded (canonical identity, not string equality)" do
    service_account?(MCP_ADMIN, [alias_name])
  end
end

check "the gm service account is excluded via an alias too" do
  service_account?(MCP_GM, ["mcp_gm"])
end

check "the user service account is excluded via an alias too" do
  service_account?(MCP_USER, ["mcp_user"])
end

check "a REAL user is NOT excluded (no over-blocking)" do
  !service_account?(REAL_USER, %w[mcp_admin mcp_gm mcp_user])
end

check "a configured name that resolves to NOTHING excludes nobody (no guessing)" do
  !service_account?(REAL_USER, ["no-such-service-account"])
end

check "a nil account is not treated as a service account" do
  !service_account?(nil, ["mcp-admin"])
end

check "an account with no persisted id is never matched (unsaved card)" do
  unsaved = FakeCard.new(nil, "mcp-admin")
  !service_account?(unsaved, ["mcp-admin"])
end

check "SOURCE: the string comparator service_account_name? / casecmp? is GONE from the code" do
  code = SOURCE.gsub(/^\s*#.*$/, "") # strip comments; prose may still mention the old name
  !code.include?("service_account_name?") && !code.include?("casecmp?")
end

check "SOURCE: service_account? compares ids via include?(account.id)" do
  body = SOURCE[/def service_account\?.*?\n      end/m]
  body.include?("service_account_ids.include?(account.id)")
end

check "SOURCE: service_account_ids resolves through Card[...] and takes #id" do
  body = SOURCE[/def service_account_ids.*?\n      end/m]
  body.include?("Card[svc]") && body.include?("card&.id")
end

check "SOURCE: the call site checks BOTH the token subject and BaseController's account" do
  SOURCE.include?("if service_account?(account) || service_account?(@current_mcp_account)")
end

check "SOURCE: the refusal still uses the existing principal_not_permitted code (no new wire word)" do
  idx = SOURCE.index("service_account?(account) || service_account?(@current_mcp_account)")
  SOURCE[idx, 400].include?('error: "principal_not_permitted"')
end

# ---------------------------------------------------------------------------------------------
# ORDER-OF-GATES INVARIANT: the exclusion must still run before scope and readiness.
# ---------------------------------------------------------------------------------------------
puts "\nInvariants that must survive the three fixes"

check "SOURCE: gate order is principal, THEN scope, THEN readiness" do
  a = SOURCE.index("before_action :require_user_principal!")
  b = SOURCE.index("before_action :require_i3_read_scope!")
  c = SOURCE.index("before_action :require_i3_backend_ready!")
  a && b && c && a < b && b < c
end

check "SOURCE: no Card::Auth.as_bot anywhere on this surface" do
  # Comments must be stripped: the security header and two method docs legitimately NAME the
  # as_bot anti-pattern in order to forbid it. Only executable code may be asserted on.
  code = SOURCE.gsub(/^\s*#.*$/, "")
  !code.include?("as_bot")
end

check "SOURCE: pre-auth denials still use DENIED_META (no data_origin)" do
  decl = SOURCE[/DENIED_META = .*/]
  decl.include?(".freeze") && !decl.include?("data_origin")
end

check "SOURCE: readiness gate still requires a STRICT boolean true" do
  SOURCE.include?("return if result.ready? == true")
end

check "SOURCE: no digest is computed deck-side (no Digest/SHA/hexdigest call)" do
  code = SOURCE.gsub(/^\s*#.*$/, "")
  !code.match?(/Digest|hexdigest|SHA\d/)
end

puts "\n" + "=" * 90
puts "PASSED: #{PASSES.size}   FAILED: #{FAILURES.size}"
unless FAILURES.empty?
  puts "\nFAILURES:"
  FAILURES.each { |f| puts "  - #{f}" }
end
puts "=" * 90
exit(FAILURES.empty? ? 0 : 1)
