# frozen_string_literal: true

# PURE-RUBY, NO-RAILS, NO-DB, LOCAL-ONLY harness for the VIEW-owned authorization boundary.
#
# WHY A STANDALONE HARNESS AND NOT AN RSPEC FILE. The deck's gems are locked and this environment
# has no usable `bundle`/`gem` (the Ruby install's gem shim is broken: "No such file or directory
# -- /e/Ruby34-x64/bin/gem"), and a PG database is not available. So `bundle exec rspec` CANNOT
# RUN HERE and reporting an rspec result would be a fabrication. This file is plain Ruby with a
# hand-rolled assert, run as `ruby <this file>`, so the logic below is ACTUALLY EXECUTED and its
# output is real.
#
# WHAT IT COVERS: the three sources this lane owns and can execute without Rails --
# `authorized_card_identity.rb`, `caller_scoped_card_authorization.rb`, `local_i3_read_binding.rb`
# -- driven against DOUBLES of Decko's `Card`, `Card::Auth` and the read predicate.
#
# WHAT IT CANNOT COVER, stated here so the result is not over-read: the REAL `Card::Auth.as`,
# the REAL `ok?(:read)`, Decko's actual ACL resolution, rule-cache behaviour, request-identity
# isolation across concurrent Rails requests, and HTTP status mapping. Those need a booted Rails
# with a database and are NOT proven by anything in this file. The doubles below record the
# identity each call ran under, so what IS proven is that this code always asks under the
# caller's identity and never elevates.

require "set"

# --------------------------------------------------------------------------------------------
# Minimal doubles for the Decko surface the module touches.
# --------------------------------------------------------------------------------------------

# A Cardname double. `#name` on a real card is a Cardname, not a String, which is exactly why
# AuthorizedCardIdentity calls `.to_s` on it -- so the double must not be a String either, or the
# test would not exercise that line.
class FakeCardname
  def initialize(text) = @text = text
  def to_s = @text
end

class FakeCard
  attr_reader :id, :read_rule_id

  def initialize(id:, name:, readable: true, read_rule_id: 1, new_card: false)
    @id = id
    @name_text = name
    @readable = readable
    @read_rule_id = read_rule_id
    @new_card = new_card
  end

  def name = FakeCardname.new(@name_text)
  def new_card? = @new_card
  # `ok?(:read)` is answered per the identity CURRENTLY in effect, so an elevation would be
  # visible as a different answer. That is how the no-elevation assertions below have teeth.
  def ok?(action)
    raise "unexpected action #{action}" unless action == :read

    return true if FakeAuth.current == "admin-bot"      # a bot would see everything

    @readable
  end
end

# `Card::Auth.as` double that RECORDS the identity stack, so a test can prove which identity a
# read ran under and that it was popped afterwards.
module FakeAuth
  class << self
    attr_reader :stack, :as_calls

    def reset!
      @stack = []
      @as_calls = []
    end

    def current = @stack.last

    def as(name)
      @as_calls << name.to_s
      @stack.push(name.to_s)
      yield
    ensure
      @stack.pop
    end
  end
end

module FakeCardRegistry
  class << self
    attr_accessor :by_name, :by_id, :fetch_calls

    def reset!
      @by_name = {}
      @by_id = {}
      @fetch_calls = []
    end

    def fetch(key)
      @fetch_calls << key
      return @by_id[key] if key.is_a?(Integer)

      @by_name[key.to_s]
    end
  end
end

# Install the doubles under the real constant names the module calls.
class Card
  def self.fetch(key) = FakeCardRegistry.fetch(key)
  Auth = FakeAuth
end

# The real default-deny predicate, copied VERBATIM from
# mod/mcp_api/app/controllers/concerns/atomspace_read_filter.rb:26-30 so the harness exercises the
# actual rule rather than a simplification. If that file changes, this copy is wrong and the
# comparison below (which re-reads the source) fails loudly.
READABLE = lambda do |card|
  next false if card.nil? || card.new_card? || card.read_rule_id.nil? ||
                card.read_rule_id.to_s.strip.empty?

  card.ok?(:read)
end

# --------------------------------------------------------------------------------------------
# Load the code under test.
# --------------------------------------------------------------------------------------------

LIB = File.expand_path("../../mod/mcp_api/lib/atomspace", __dir__)

# `MirrorReadiness::Result` is needed by the port and the binding; load the real file.
require File.join(LIB, "errors")
require File.join(LIB, "mirror_readiness")
require File.join(LIB, "i3_read_port")
require File.join(LIB, "authorized_card_identity")
require File.join(LIB, "caller_scoped_card_authorization")
require File.join(LIB, "local_i3_read_binding")

# --------------------------------------------------------------------------------------------
# Tiny assertion harness.
# --------------------------------------------------------------------------------------------

$passed = 0
$failed = []

def check(label)
  FakeAuth.reset!
  FakeCardRegistry.reset!
  Atomspace::I3ReadPort.reset!
  yield
  $passed += 1
  puts "  ok   #{label}"
rescue StandardError, Exception => e # rubocop:disable Lint/ShadowedException
  $failed << [label, "#{e.class}: #{e.message}"]
  puts "  FAIL #{label}"
  puts "       #{e.class}: #{e.message}"
  puts "       #{e.backtrace&.first}"
end

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

def assert_eq(actual, expected, msg = nil)
  return if actual == expected

  raise(msg || "expected #{expected.inspect}, got #{actual.inspect}")
end

def assert_raises(klass)
  yield
  raise "expected #{klass} to be raised, nothing was"
rescue klass => e
  e
end

ACCOUNT = Struct.new(:name).new("alice")

def register(card, name: nil)
  FakeCardRegistry.by_id[card.id] = card
  FakeCardRegistry.by_name[name || card.name.to_s] = card
  card
end

CSA = Atomspace::CallerScopedCardAuthorization
ACI = Atomspace::AuthorizedCardIdentity

puts "\nAuthorizedCardIdentity"

check "from_card yields the framework's own id and name text" do
  card = FakeCard.new(id: 17_120, name: "MCP Admin")
  identity = ACI.from_card(card)
  assert_eq identity.card_id, 17_120
  assert_eq identity.canonical_name, "MCP Admin"
  assert identity.canonical_name.is_a?(String), "a Cardname must be rendered to String text"
end

check "the payload uses the field names the Python bridge consumes, and NO echoed name field" do
  payload = ACI.from_card(FakeCard.new(id: 7, name: "Ada")).to_authorization_payload
  assert_eq payload, { "card_id" => 7, "canonical_name" => "Ada" }
  # decko_bridge.ECHOED_REQUEST_NAME_FIELDS = ("name", "requested_name", "query")
  %w[name requested_name query].each do |echoed|
    assert !payload.key?(echoed), "payload must not carry the echoed request field #{echoed}"
  end
end

check "a blank or non-String canonical name is REFUSED, never defaulted" do
  assert_raises(ACI::Incomplete) { ACI.new(card_id: 1, canonical_name: "   ") }
  assert_raises(ACI::Incomplete) { ACI.new(card_id: 1, canonical_name: nil) }
  assert_raises(ACI::Incomplete) { ACI.new(card_id: 1, canonical_name: :Ada) }
end

check "a non-positive or non-Integer id is REFUSED (no coercion)" do
  assert_raises(ACI::Incomplete) { ACI.new(card_id: 0, canonical_name: "Ada") }
  assert_raises(ACI::Incomplete) { ACI.new(card_id: -3, canonical_name: "Ada") }
  assert_raises(ACI::Incomplete) { ACI.new(card_id: "7", canonical_name: "Ada") }
  assert_raises(ACI::Incomplete) { ACI.new(card_id: 7.0, canonical_name: "Ada") }
end

check "the identity is frozen, so a consumer cannot mutate an authorization result" do
  identity = ACI.from_card(FakeCard.new(id: 7, name: "Ada"))
  assert identity.frozen?
  assert identity.canonical_name.frozen?
end

puts "\nCallerScopedCardAuthorization#readable_identity_for_name"

check "a readable card resolves to (id, canonical_name) UNDER THE CALLER'S IDENTITY" do
  register(FakeCard.new(id: 101, name: "Ada Lovelace"))
  identity = CSA.readable_identity_for_name("Ada Lovelace", account: ACCOUNT, readable: READABLE)
  assert_eq identity.card_id, 101
  assert_eq identity.canonical_name, "Ada Lovelace"
  assert_eq FakeAuth.as_calls, ["alice"], "the read must run as the CALLER, not a bot"
  assert_eq FakeAuth.stack, [], "the identity must be popped after the block"
end

check "THE CANONICAL NAME IS THE CARD'S, NOT THE REQUESTED STRING (the alias case)" do
  # The whole reason the bridge needs a canonical name: Cardname collapses separators and case,
  # so these three requests are ONE card, and the canonical answer differs from the request.
  card = FakeCard.new(id: 55, name: "MCP Admin")
  %w[mcp_admin mcp-admin MCP\ Admin].each { |alias_text| register(card, name: alias_text) }
  %w[mcp_admin mcp-admin].each do |requested|
    identity = CSA.readable_identity_for_name(requested, account: ACCOUNT, readable: READABLE)
    assert_eq identity.canonical_name, "MCP Admin",
              "the canonical name must be the CARD's, not the requested #{requested.inspect}"
    assert identity.canonical_name != requested
  end
end

check "an ABSENT card and an UNREADABLE card are INDISTINGUISHABLE (both nil)" do
  register(FakeCard.new(id: 102, name: "Secret", readable: false))
  unreadable = CSA.readable_identity_for_name("Secret", account: ACCOUNT, readable: READABLE)
  absent = CSA.readable_identity_for_name("No Such Card", account: ACCOUNT, readable: READABLE)
  assert_eq unreadable, nil
  assert_eq absent, nil
  assert_eq unreadable, absent, "absent and unreadable must collapse to the SAME answer"
end

check "default-deny: a new card and a blank-read-rule card are DENIED WITHOUT asking ok?(:read)" do
  asked = []
  probe = lambda do |card|
    next false if card.nil? || card.new_card? || card.read_rule_id.to_s.strip.empty?

    asked << card.id
    card.ok?(:read)
  end
  register(FakeCard.new(id: 103, name: "New One", new_card: true))
  register(FakeCard.new(id: 104, name: "No Rule", read_rule_id: nil))
  assert_eq CSA.readable_identity_for_name("New One", account: ACCOUNT, readable: probe), nil
  assert_eq CSA.readable_identity_for_name("No Rule", account: ACCOUNT, readable: probe), nil
  assert_eq asked, [], "ok?(:read) must NOT be asked for a new/blank-rule card"
end

check "NO ELEVATION: the identity used is always the account's, never a bot" do
  register(FakeCard.new(id: 105, name: "Hidden", readable: false))
  result = CSA.readable_identity_for_name("Hidden", account: ACCOUNT, readable: READABLE)
  assert_eq result, nil, "a bot-scoped read would have returned the card"
  assert_eq FakeAuth.as_calls, ["alice"]
  assert !FakeAuth.as_calls.include?("admin-bot")
end

check "an AUTHORIZED card that cannot state its identity RAISES (not a denial)" do
  # A framework contract violation must not be laundered into "not readable": nil means absent or
  # unreadable, and this card demonstrably passed the read check.
  register(FakeCard.new(id: nil, name: "Broken"))
  assert_raises(ACI::Incomplete) do
    CSA.readable_identity_for_name("Broken", account: ACCOUNT, readable: READABLE)
  end
end

check "a blank name RAISES InvalidRequest and fetches nothing" do
  assert_raises(Atomspace::InvalidRequest) do
    CSA.readable_identity_for_name("   ", account: ACCOUNT, readable: READABLE)
  end
  assert_eq FakeCardRegistry.fetch_calls, [], "a blank name must not reach Card.fetch"
end

check "an unusable principal RAISES PrincipalUnusable, and asks nothing" do
  assert_raises(CSA::PrincipalUnusable) do
    CSA.readable_identity_for_name("Ada", account: nil, readable: READABLE)
  end
  assert_raises(CSA::PrincipalUnusable) do
    CSA.readable_identity_for_name("Ada", account: Struct.new(:name).new(""), readable: READABLE)
  end
  assert_eq FakeCardRegistry.fetch_calls, []
end

check "an OMITTED read predicate refuses to run -- there is no permissive default" do
  assert_raises(ArgumentError) do
    CSA.readable_identity_for_name("Ada", account: ACCOUNT, readable: nil)
  end
end

puts "\nCallerScopedCardAuthorization#readable_card_id? (the per-neighbour gate)"

check "a readable id is true, an unreadable id and an absent id are both false" do
  register(FakeCard.new(id: 201, name: "Open"))
  register(FakeCard.new(id: 202, name: "Closed", readable: false))
  assert_eq CSA.readable_card_id?(201, account: ACCOUNT, readable: READABLE), true
  assert_eq CSA.readable_card_id?(202, account: ACCOUNT, readable: READABLE), false
  assert_eq CSA.readable_card_id?(999, account: ACCOUNT, readable: READABLE), false
end

check "the gate answers a strict boolean, never a truthy card object" do
  register(FakeCard.new(id: 203, name: "Open"))
  assert_eq CSA.readable_card_id?(203, account: ACCOUNT, readable: READABLE).class, TrueClass
  assert_eq CSA.readable_card_id?(204, account: ACCOUNT, readable: READABLE).class, FalseClass
end

check "a non-Integer / non-positive id is DENIED WITHOUT asking (no .to_i coercion)" do
  register(FakeCard.new(id: 1, name: "Card One"))
  ["1", 1.0, nil, true, 0, -1, :one].each do |bad|
    assert_eq CSA.readable_card_id?(bad, account: ACCOUNT, readable: READABLE), false,
              "#{bad.inspect} must be denied"
  end
  assert_eq FakeCardRegistry.fetch_calls, [], "a non-id must not reach Card.fetch at all"
  assert_eq FakeAuth.as_calls, [], "and must not even open an identity block"
end

check "the gate runs under the caller's identity too" do
  register(FakeCard.new(id: 205, name: "Open"))
  CSA.readable_card_id?(205, account: ACCOUNT, readable: READABLE)
  assert_eq FakeAuth.as_calls, ["alice"]
  assert_eq FakeAuth.stack, []
end

puts "\nLocalI3ReadBinding (the local runtime binding for a port that was spec-only)"

class FakeReader
  attr_reader :calls

  def initialize(address: { "key" => "(Card 101)", "digest" => "a" * 32 },
                 ready: true, open_result: [], neighbours_result: [])
    @address = address
    @ready = ready
    @open_result = open_result
    @neighbours_result = neighbours_result
    @calls = []
  end

  def origin = "live"

  def readiness
    @ready ? Atomspace::MirrorReadiness::READY
           : Atomspace::MirrorReadiness::Result.new(ready: false, reason: "reader_cold")
  end

  def resolve_backend_address(card_id:)
    @calls << [:resolve, card_id]
    @address
  end

  def open(card_id:)
    @calls << [:open, card_id]
    @open_result
  end

  def neighbours(card_id:, bucket: nil, limit: nil)
    @calls << [:neighbours, card_id, bucket, limit]
    @neighbours_result
  end
end

LB = Atomspace::LocalI3ReadBinding

check "the port FAILS CLOSED before any install (this is the pre-existing production state)" do
  assert_eq Atomspace::I3ReadPort.readiness.ready?, false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired"
  assert_eq Atomspace::I3ReadPort.origin, "unavailable"
  assert_raises(Atomspace::I3ReadPort::NotWired) { Atomspace::I3ReadPort.open(card_id: 1) }
end

check "install! binds the port and the three reads reach the injected reader" do
  reader = FakeReader.new(open_result: [:atom], neighbours_result: [:n1])
  assert_eq LB.install!(reader: reader), true
  assert_eq Atomspace::I3ReadPort.readiness.ready?, true
  assert_eq Atomspace::I3ReadPort.origin, "live"
  assert_eq Atomspace::I3ReadPort.open(card_id: 101), [:atom]
  assert_eq Atomspace::I3ReadPort.neighbours(card_id: 101, bucket: "links-to", limit: 5), [:n1]
  assert_eq Atomspace::I3ReadPort.resolve_backend_address(card_id: 101),
            { "key" => "(Card 101)", "digest" => "a" * 32 }
  assert_eq reader.calls.last(3).map(&:first).sort, %i[neighbours open resolve]
end

check "install!(reader: nil) leaves the port UNWIRED -- no fixture fallback" do
  assert_eq LB.install!(reader: nil), false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired"
  assert_eq Atomspace::I3ReadPort.origin, "unavailable"
end

# ROUND-23 FINDING 4 (Codex). THE REGRESSION THE TEST ABOVE COULD NOT CATCH.
#
# `check` calls `I3ReadPort.reset!` before every block, so the test above always ran against an
# ALREADY-UNWIRED port: `install!(reader: nil)` returning false looked correct because there was
# nothing bound to leave behind. The real sequence -- bind a reader, THEN install nil -- was never
# exercised, and on those bytes `install!` returned false while the OLD reader stayed bound and
# kept answering reads. A caller that de-configured its backend was still served by it.
#
# The documented contract for a missing backend is "unwired -> 503", so the nil path must RESET
# the port, not merely decline to rebind it. This check binds first on purpose.
check "install!(reader: nil) AFTER a successful install UNBINDS the old reader (no stale binding)" do
  reader = FakeReader.new(open_result: [:atom], neighbours_result: [:n1])
  assert_eq LB.install!(reader: reader), true
  assert_eq Atomspace::I3ReadPort.readiness.ready?, true,
            "precondition: a reader really is bound and serving before the nil install"
  assert_eq Atomspace::I3ReadPort.open(card_id: 101), [:atom]

  # The de-configuring call. It reports failure AND must leave nothing behind.
  assert_eq LB.install!(reader: nil), false

  assert_eq Atomspace::I3ReadPort.readiness.ready?, false,
            "the port must not still be ready via the PREVIOUS reader"
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired"
  assert_eq Atomspace::I3ReadPort.origin, "unavailable"
  assert_raises(Atomspace::I3ReadPort::NotWired) { Atomspace::I3ReadPort.open(card_id: 101) }
  assert_raises(Atomspace::I3ReadPort::NotWired) do
    Atomspace::I3ReadPort.neighbours(card_id: 101, bucket: "links-to", limit: 5)
  end
end

check "install!(reader: nil) on an ALREADY-unwired port is idempotent, not an error" do
  assert_eq LB.install!(reader: nil), false
  assert_eq LB.install!(reader: nil), false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired"
end

check "a PARTIAL reader is refused and the port is left unwired, not half-bound" do
  partial = Object.new
  def partial.open(card_id:) = []
  assert_raises(Atomspace::ServiceUnavailable) { LB.install!(reader: partial) }
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired",
            "a refused install must not leave the port bound"
end

check "a reader with NO readiness is NOT READY (never assumed ready)" do
  silent = Object.new
  def silent.open(card_id:) = []
  def silent.neighbours(card_id:, bucket: nil, limit: nil) = []
  def silent.resolve_backend_address(card_id:) = { "key" => "k", "digest" => "d" }
  LB.install!(reader: silent)
  assert_eq Atomspace::I3ReadPort.readiness.ready?, false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_reader_declares_no_readiness"
end

check "a nil address is backend_digest_unavailable -- NEVER a computed digest" do
  LB.install!(reader: FakeReader.new(address: nil))
  err = assert_raises(Atomspace::I3ReadPort::AddressUnavailable) do
    Atomspace::I3ReadPort.resolve_backend_address(card_id: 1)
  end
  assert_eq err.message, "backend_digest_unavailable"
end

check "a cold reader's own reason reaches the readiness result" do
  LB.install!(reader: FakeReader.new(ready: false))
  assert_eq Atomspace::I3ReadPort.readiness.ready?, false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "reader_cold"
end

check "a NON-BOOLEAN readiness verdict is a contract violation, not a green light" do
  liar = FakeReader.new
  def liar.readiness = Atomspace::MirrorReadiness::Result.new(ready: "false", reason: nil)
  LB.install!(reader: liar)
  assert_eq Atomspace::I3ReadPort.readiness.ready?, false
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_readiness_contract_violation"
end

check "uninstall! returns the port to its fail-closed default" do
  LB.install!(reader: FakeReader.new)
  LB.uninstall!
  assert_eq Atomspace::I3ReadPort.readiness.reason, "i3_read_port_unwired"
  assert_raises(Atomspace::I3ReadPort::NotWired) { Atomspace::I3ReadPort.open(card_id: 1) }
end

puts "\nThe default-deny predicate this harness copies is still the concern's own"

check "READABLE matches atomspace_read_filter.rb's readable_card? clauses" do
  src = File.read(File.expand_path("../../mod/mcp_api/app/controllers/concerns/atomspace_read_filter.rb", __dir__))
  # If the concern's rule changes, this harness's copy is stale and the comparison must fail.
  assert src.include?("card.nil? || card.new_card? || card.read_rule_id.blank?"),
         "atomspace_read_filter.rb's readable_card? changed; this harness's READABLE copy is stale"
  assert src.include?("card.ok?(:read)")
end

puts "\n#{$passed} passed, #{$failed.size} failed"
unless $failed.empty?
  puts "\nFAILURES:"
  $failed.each { |label, msg| puts "  - #{label}: #{msg}" }
end
exit($failed.empty? ? 0 : 1)
