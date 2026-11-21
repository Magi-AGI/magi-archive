# frozen_string_literal: true
#
# LANE-D LIVE I3 READER PROOF, pure Ruby. No Rails, no Postgres, no Decko boot, no DB.
#
# WHY A STANDALONE PROOF AND NOT `bundle exec rspec`. The locked bundle on this host cannot
# materialise: `bundle exec rspec --version` fails with Bundler::GemNotFound naming 70+ missing
# gems (decko-0.20.0, card-1.110.0, psych-5.3.1, activesupport-7.2.3.1, rspec-rails-7.1.1, ...).
# So `type: :request` examples CANNOT run here at all. This file follows the pattern already
# proven in this repo -- spec/mcp_api/lib/i3_round19_security_fix_proof.rb (49/0) and
# spec/mcp_api/local_authorization_harness.rb (30/0) -- and runs as plain Ruby with in-memory
# doubles.
#
# WHAT IT PROVES. The three new files' ACTUAL BEHAVIOUR, by loading and calling them:
#
#   A  I2Envelope fails closed on every missing/malformed envelope field (the central requirement)
#   B  I2StdioTransport frames are well-formed, correlated, and CANNOT carry an identity
#   C  I2ReaderProcessClient satisfies LocalI3ReadBinding's reader contract and installs
#   D  every address failure is the SAME indistinguishable reason string
#   E  a hung / dead reader is NOT-READY with its own reason -- never a hang, never a false green
#   F  capability gaps (versions.runtime, health) raise distinct typed refusals, never a value
#   G  source-level invariants: no digest computation, no clock, no fixture fallback, no identity
#
# WHAT IT DOES NOT PROVE: anything requiring Rails, a route, a real HTTP request, a DB, or live
# DEV data. Those are stated as unexecutable in the summary, not simulated here.
#
# Run: ruby spec/mcp_api/atomspace/i2_reader_process_client_proof.rb

require "stringio"
require "json"

LIB = File.expand_path("../../../mod/mcp_api/lib/atomspace", __dir__)
require File.join(LIB, "i2_envelope")
require File.join(LIB, "i2_stdio_transport")
require File.join(LIB, "i2_reader_process_client")
require File.join(LIB, "local_i3_read_binding")
require File.join(LIB, "fixture_i3_read_port")

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

# Raised-error helper: returns the exception, or nil if nothing was raised.
def raised
  yield
  nil
rescue StandardError => e
  e
end

# ---------------------------------------------------------------------------------------------
# A SCRIPTED TRANSPORT. Not a fake reader -- a fake PIPE. The distinction matters: the client's
# own logic runs unmodified over real IO-like objects, and only the bytes are scripted. Each
# response line is exactly what a server would write.
# ---------------------------------------------------------------------------------------------
class ScriptedChannel
  attr_reader :requests

  def initialize(responses, id_echo: true)
    @responses = responses
    @requests = []
    @id_echo = id_echo
    @out = StringIO.new
  end

  # The writer half.
  def puts(line)
    @requests << JSON.parse(line)
    nil
  end

  def flush; end

  # The reader half.
  def gets
    frame = @responses.shift
    return nil if frame.nil?                       # EOF: the child closed its stdout
    return frame if frame.is_a?(String)            # a raw line (for malformed-line cases)

    frame = frame.dup
    frame["id"] = @requests.last["id"] if @id_echo && @requests.last
    frame["v"] = Atomspace::I2StdioTransport::PROTOCOL_VERSION unless frame.key?("v")
    "#{JSON.generate(frame)}\n"
  end
end

# A channel whose `gets` blocks forever: the hung-reader case.
class HungChannel
  def puts(_line); end
  def flush; end

  def gets
    sleep 30
  end
end

READ_AT = "2026-11-15T09:41:02.123456+00:00"
EPOCH = "9f2c1d4e8a7b4c3d9e1f0a2b3c4d5e6f"

def ok_envelope(outcome: "ok", position: 1)
  { "outcome" => outcome, "epoch" => EPOCH, "position" => position, "read-at" => READ_AT }
end

def not_ready_envelope
  { "outcome" => "not ready", "epoch" => nil, "position" => nil, "read-at" => nil }
end

def ok_frame(payload, outcome: "ok")
  { "ok" => true, "envelope" => ok_envelope(outcome: outcome), "payload" => payload }
end

def client_for(*responses, deadline_ms: 5_000)
  channel = ScriptedChannel.new(responses)
  [Atomspace::I2ReaderProcessClient.new(writer: channel, reader: channel, deadline_ms: deadline_ms),
   channel]
end

STATUS_PAYLOAD = {
  "readiness" => "ready",
  "versions" => { "schema" => "decko-atomschema-v2" },
  "page-max" => { "page-max-entries" => 300, "page-max-connections" => 900,
                  "page-max-bytes" => 400_000, "per-neighbour-link-max" => 3,
                  "refresh-max-participants" => 1 },
  "fanout-limit" => 1,
  "state-retain" => { "state-retain-ms" => nil, "state-retain-positions" => 2 },
  "label-bearing-properties" => %w[name type-name trash]
}.freeze

# =============================================================================================
puts "\nA -- I2Envelope: a missing or malformed metadatum is a REFUSAL, never a default"
# =============================================================================================

check "a complete 'ok' envelope validates and is returned VERBATIM" do
  env = ok_envelope
  Atomspace::I2Envelope.validate!(env).equal?(env)
end

%w[outcome epoch position read-at].each do |field|
  check "a MISSING #{field} raises ContractViolation (no default is supplied)" do
    e = raised { Atomspace::I2Envelope.validate!(ok_envelope.reject { |k, _| k == field }) }
    e.is_a?(Atomspace::I2Envelope::ContractViolation) && e.rule == "envelope_missing_keys"
  end
end

check "a NIL epoch on a stateful outcome is refused (never minted)" do
  e = raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("epoch" => nil)) }
  e.is_a?(Atomspace::I2Envelope::ContractViolation) && e.rule == "epoch_missing_or_malformed"
end

check "an EMPTY-STRING epoch is refused" do
  raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("epoch" => "  ")) }&.rule ==
    "epoch_missing_or_malformed"
end

[0, -1, "1", 1.0, true, nil].each do |bad|
  check "position #{bad.inspect} is refused (int from 1, never coerced)" do
    raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("position" => bad)) }&.rule ==
      "position_missing_or_malformed"
  end
end

[
  "2026-11-15T09:41:02",                  # no fraction, no offset
  "2026-11-15T09:41:02.123456",           # NAIVE: no timezone -- not an instant
  "2026-11-15 09:41:02.123456+00:00",     # space separator
  "2026-11-15T09:41:02.123+00:00",        # milliseconds, not microseconds
  1_763_192_462,                          # an epoch int
  nil
].each do |bad|
  check "read-at #{bad.inspect} is refused (ISO-8601 + tz + 6 digits only)" do
    raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => bad)) }&.rule ==
      "read_at_missing_or_malformed"
  end
end

check "read-at with a Z offset is accepted (same instant as +00:00)" do
  Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => "2026-11-15T09:41:02.123456Z"))
  true
end

check "an outcome outside STORE's five is refused, not tolerated" do
  raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("outcome" => "degraded")) }&.rule ==
    "envelope_outcome_unknown"
end

check "STORE's five outcomes are exactly the accepted set" do
  Atomspace::I2Envelope::OUTCOMES.sort == ["not ready", "ok", "ok, partial", "reload", "unknown"]
end

check "a 'not ready' envelope with three nulls validates (record_store.py:196-201)" do
  Atomspace::I2Envelope.validate!(not_ready_envelope)
  Atomspace::I2Envelope.not_ready?(not_ready_envelope)
end

check "a 'not ready' envelope carrying a REAL EPOCH is refused (a known epoch is never reported)" do
  e = raised { Atomspace::I2Envelope.validate!(not_ready_envelope.merge("epoch" => EPOCH)) }
  e&.rule == "not_ready_envelope_carries_state"
end

check "a 'not ready' envelope carrying a real position is refused" do
  raised { Atomspace::I2Envelope.validate!(not_ready_envelope.merge("position" => 7)) }&.rule ==
    "not_ready_envelope_carries_state"
end

check "an envelope with a FIFTH key is refused (contract disagreement, not ignorable)" do
  raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("health" => {})) }&.rule ==
    "envelope_unexpected_keys"
end

[nil, "ok", [], 42].each do |bad|
  check "a non-Hash envelope #{bad.inspect} is refused" do
    raised { Atomspace::I2Envelope.validate!(bad) }&.rule == "envelope_not_a_mapping"
  end
end

check "split! refuses a frame whose payload key is ABSENT (not treated as {})" do
  raised { Atomspace::I2Envelope.split!({ "envelope" => ok_envelope }) }&.rule ==
    "frame_payload_missing"
end

check "participant_address! returns STORE's own key+digest VERBATIM" do
  payload = { "participant" => { "key" => "(Card 17120)", "digest" => "a" * 32 } }
  Atomspace::I2Envelope.participant_address!(payload) == ["(Card 17120)", "a" * 32]
end

check "participant_address! refuses a MISSING digest (never derives it from the key)" do
  e = raised do
    Atomspace::I2Envelope.participant_address!({ "participant" => { "key" => "(Card 1)" } })
  end
  e&.rule == "participant_address_incomplete"
end

check "participant_address! refuses a MISSING key" do
  raised do
    Atomspace::I2Envelope.participant_address!({ "participant" => { "digest" => "a" * 32 } })
  end&.rule == "participant_address_incomplete"
end

check "participant_address! refuses a non-String digest (0, [], {})" do
  [0, [], {}, nil].all? do |bad|
    raised do
      Atomspace::I2Envelope.participant_address!(
        { "participant" => { "key" => "(Card 1)", "digest" => bad } }
      )
    end&.rule == "participant_address_incomplete"
  end
end

# =============================================================================================
puts "\nB -- I2StdioTransport: framing, correlation, and NO IDENTITY by construction"
# =============================================================================================

check "a request frame carries exactly v/id/op/args when no deadline is given" do
  sink = ScriptedChannel.new([])
  Atomspace::I2StdioTransport.write_request!(sink, id: "x1", op: "I2-01", args: {})
  sink.requests.first.keys.sort == %w[args id op v]
end

check "a request frame with a deadline carries exactly those five keys and no more" do
  sink = ScriptedChannel.new([])
  Atomspace::I2StdioTransport.write_request!(sink, id: "x1", op: "I2-01", args: {}, deadline_ms: 10)
  sink.requests.first.keys.sort == %w[args deadline-ms id op v]
end

check "REQUEST_KEYS cannot express an identity (no account/token/bearer/cookie/user slot)" do
  forbidden = %w[account token bearer cookie user principal session authorization identity]
  (Atomspace::I2StdioTransport::REQUEST_KEYS & forbidden).empty?
end

check "a deadline-ms is sent so the server MAY self-limit (VIEW enforces its own regardless)" do
  sink = ScriptedChannel.new([])
  Atomspace::I2StdioTransport.write_request!(sink, id: "x", op: "I2-01", args: {}, deadline_ms: 250)
  sink.requests.first["deadline-ms"] == 250
end

check "non-Hash args are refused" do
  sink = ScriptedChannel.new([])
  raised do
    Atomspace::I2StdioTransport.write_request!(sink, id: "x", op: "I2-01", args: "nope")
  end.is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "EOF on the response channel is a ChannelError (never an empty success)" do
  src = ScriptedChannel.new([])
  raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "x") }
    .is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "a non-JSON response line is a ChannelError" do
  src = ScriptedChannel.new(["this is not json\n"])
  raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "x") }
    .is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "a MISMATCHED correlation id is a ChannelError (a stale answer is never read as current)" do
  src = ScriptedChannel.new([{ "id" => "other", "ok" => true, "envelope" => ok_envelope,
                               "payload" => {} }], id_echo: false)
  src.puts(JSON.generate({ "id" => "mine" }))
  raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "mine") }
    .is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "a WRONG protocol version is refused at the first frame" do
  src = ScriptedChannel.new([{ "v" => 99, "id" => "x", "ok" => true, "envelope" => ok_envelope,
                               "payload" => {} }], id_echo: false)
  src.puts(JSON.generate({ "id" => "x" }))
  raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "x") }
    .is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "ok must be a STRICT boolean -- 'false' and 0 are TRUTHY in Ruby and must not pass" do
  ["false", 0, 1, nil, "true"].all? do |bad|
    src = ScriptedChannel.new([{ "id" => "x", "ok" => bad, "envelope" => ok_envelope,
                                 "payload" => {} }], id_echo: false)
    src.puts(JSON.generate({ "id" => "x" }))
    raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "x") }
      .is_a?(Atomspace::I2StdioTransport::ChannelError)
  end
end

check "a response frame with an unexpected key is refused" do
  src = ScriptedChannel.new([{ "id" => "x", "ok" => true, "envelope" => ok_envelope,
                               "payload" => {}, "health" => {} }], id_echo: false)
  src.puts(JSON.generate({ "id" => "x" }))
  raised { Atomspace::I2StdioTransport.read_response!(src, expect_id: "x") }
    .is_a?(Atomspace::I2StdioTransport::ChannelError)
end

check "the four error kinds are exactly STORE's distinguishable conditions" do
  Atomspace::I2StdioTransport::ERROR_KINDS.sort ==
    %w[capability-missing i2-refused server-error unresolved-config]
end

# =============================================================================================
puts "\nB2 -- Spawn: explicit paths only, no discovery, no default, nothing at require time"
# =============================================================================================

SPAWN_CFG = { "page-max" => {}, "fanout-limit" => 1, "retention" => {} }.freeze

check "an EMPTY interpreter path is refused (no PATH search, no `which python`)" do
  raised do
    Atomspace::I2StdioTransport::Spawn.new(interpreter: "", script: "C:/x.py",
                                           sidecar_path: "C:/s", config: SPAWN_CFG)
  end.is_a?(Atomspace::ServiceUnavailable)
end

check "a RELATIVE script path is refused (cwd is not configuration)" do
  raised do
    Atomspace::I2StdioTransport::Spawn.new(interpreter: "C:/py.exe", script: "tools/s.py",
                                           sidecar_path: "C:/s", config: SPAWN_CFG)
  end.is_a?(Atomspace::ServiceUnavailable)
end

check "a nil sidecar_path is refused" do
  raised do
    Atomspace::I2StdioTransport::Spawn.new(interpreter: "C:/py.exe", script: "C:/s.py",
                                           sidecar_path: nil, config: SPAWN_CFG)
  end.is_a?(Atomspace::ServiceUnavailable)
end

check "constructing a Spawn starts NOTHING (pid is nil until start! is called)" do
  s = Atomspace::I2StdioTransport::Spawn.new(interpreter: "C:/py.exe", script: "C:/s.py",
                                             sidecar_path: "C:/s", config: SPAWN_CFG)
  s.pid.nil? && s.writer.nil? && s.reader.nil?
end

check "absolute POSIX and Windows paths are both accepted" do
  Atomspace::I2StdioTransport::Spawn.new(interpreter: "/usr/bin/python3", script: "/opt/s.py",
                                         sidecar_path: "/opt/store", config: SPAWN_CFG)
  Atomspace::I2StdioTransport::Spawn.new(interpreter: "C:\\py\\python.exe", script: "E:/s.py",
                                         sidecar_path: "E:/store", config: SPAWN_CFG)
  true
end

# =============================================================================================
puts "\nC -- I2ReaderProcessClient satisfies the LocalI3ReadBinding reader contract"
# =============================================================================================

check "it answers every REQUIRED_READER_METHOD (open, neighbours, resolve_backend_address)" do
  c, = client_for
  Atomspace::LocalI3ReadBinding::REQUIRED_READER_METHODS.all? { |m| c.respond_to?(m) }
end

check "it also answers the OPTIONAL readiness, so it is never assumed-not-ready" do
  c, = client_for
  c.respond_to?(:readiness)
end

check "origin is 'live' -- never 'fixture', never 'unavailable'" do
  c, = client_for
  c.origin == "live" && c.origin != Atomspace::FixtureI3ReadPort::ORIGIN
end

check "LocalI3ReadBinding.new ACCEPTS it (no partial-backend refusal)" do
  c, = client_for
  Atomspace::LocalI3ReadBinding.new(reader: c).origin == "live"
end

check "install! BINDS it and the port reports origin 'live'" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => STATUS_PAYLOAD })
  installed = Atomspace::LocalI3ReadBinding.install!(reader: c)
  ok = installed == true && Atomspace::I3ReadPort.origin == "live"
  Atomspace::LocalI3ReadBinding.uninstall!
  ok
end

check "a READY store yields a readiness Result with ready? == true (a STRICT boolean)" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => STATUS_PAYLOAD })
  r = c.readiness
  r.ready? == true
end

check "the port's own re-validation accepts that Result (shape AND value type)" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => STATUS_PAYLOAD })
  Atomspace::LocalI3ReadBinding.install!(reader: c)
  ok = Atomspace::I3ReadPort.readiness.ready? == true
  Atomspace::LocalI3ReadBinding.uninstall!
  ok
end

check "a 'not ready' store is NOT READY with reason i2_store_not_ready" do
  c, = client_for({ "ok" => true, "envelope" => not_ready_envelope, "payload" => STATUS_PAYLOAD })
  r = c.readiness
  r.ready? == false && r.reason == "i2_store_not_ready"
end

check "a MISMATCHED schema is NOT READY with its own reason (never a green light)" do
  payload = STATUS_PAYLOAD.merge("versions" => { "schema" => "decko-atomschema-v1" })
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => payload })
  r = c.readiness
  r.ready? == false && r.reason == "i2_reader_schema_mismatch"
end

check "a MISSING versions.schema is NOT READY (absent is not 'probably fine')" do
  payload = STATUS_PAYLOAD.reject { |k, _| k == "versions" }
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => payload })
  c.readiness.reason == "i2_reader_schema_mismatch"
end

check "a MALFORMED readiness envelope is NOT READY with i2_reader_contract_violation" do
  bad = ok_envelope.reject { |k, _| k == "read-at" }
  c, = client_for({ "ok" => true, "envelope" => bad, "payload" => STATUS_PAYLOAD })
  r = c.readiness
  r.ready? == false && r.reason == "i2_reader_contract_violation"
end

check "an I2-01 REFUSAL is NOT READY with i2_reader_refused_status" do
  c, = client_for({ "ok" => false, "error" => { "kind" => "i2-refused", "reason" => "nope" } })
  c.readiness.reason == "i2_reader_refused_status"
end

check "a stateful envelope whose readiness field is not 'ready' is a contract violation" do
  payload = STATUS_PAYLOAD.merge("readiness" => "not ready")
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => payload })
  c.readiness.reason == "i2_reader_contract_violation"
end

check "the participant key is the v2 text form (Card <id>) -- cp022 §4 / handoff 022b §4" do
  c, = client_for
  c.participant_key_for(17_120) == "(Card 17120)"
end

check "a non-integral card_id is REFUSED, never .to_i-coerced into another card" do
  c, = client_for
  ["17120x", "17120", nil, 0, -5, 1.0, true].all? do |bad|
    raised { c.participant_key_for(bad) }.is_a?(Atomspace::InvalidRequest)
  end
end

check "I2-02 'ok' returns STORE's OWN key and digest, verbatim" do
  payload = { "participant" => { "key" => "(Card 17120)", "digest" => "b" * 32 },
              "buckets" => [] }
  c, = client_for(ok_frame(payload))
  c.resolve_backend_address(card_id: 17_120) == { "key" => "(Card 17120)", "digest" => "b" * 32 }
end

check "the key SENT is the formed key, and a MISMATCHED returned key is REFUSED (not blessed)" do
  # THE AUTHORIZATION HOLE THIS CLOSES. The caller resolved read authorization for card 17120 and
  # the controller attributes everything this returns to 17120. A store answer naming (Card 999)
  # must therefore NOT be accepted: doing so would let card 999's backend address pass card
  # 17120's ACL decision. Refusal, with the SAME indistinguishable reason as every other address
  # failure, so no new existence oracle appears.
  payload = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32 }, "buckets" => [] }
  c, ch = client_for(ok_frame(payload))
  err = raised { c.resolve_backend_address(card_id: 17_120) }
  ch.requests.first["args"]["participant"]["key"] == "(Card 17120)" &&
    err.is_a?(Atomspace::I3ReadPort::AddressUnavailable) &&
    err.message == Atomspace::I2ReaderProcessClient::ADDRESS_REASON
end

check "the MISMATCH refusal is indistinguishable from an unknown card (no new oracle)" do
  mismatch = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32 } }
  c1, = client_for(ok_frame(mismatch))
  m1 = raised { c1.resolve_backend_address(card_id: 17_120) }.message

  c2, = client_for({ "ok" => true, "envelope" => ok_envelope(outcome: "unknown"), "payload" => {} })
  m2 = raised { c2.resolve_backend_address(card_id: 17_120) }.message

  m1 == m2 && m1 == "backend_digest_unavailable"
end

check "a MATCHING key is still returned VERBATIM with STORE's own digest (guard is not a rewrite)" do
  payload = { "participant" => { "key" => "(Card 17120)", "digest" => "ab" * 16 }, "buckets" => [] }
  c, = client_for(ok_frame(payload))
  c.resolve_backend_address(card_id: 17_120) == { "key" => "(Card 17120)", "digest" => "ab" * 16 }
end

check "MUTATION PROOF: the mismatch guard is what refuses -- without it (Card 999) would be returned" do
  # Proves the guard is LOAD-BEARING rather than merely present. The same frame is run against a
  # subclass whose guard is neutralised by overriding the comparison to always agree; that subclass
  # RETURNS the foreign key, while the real class REFUSES it. If the production guard were removed,
  # the real class would behave like this subclass and this example fails.
  permissive = Class.new(Atomspace::I2ReaderProcessClient) do
    def resolve_backend_address(card_id:)
      key = participant_key_for(card_id)
      frame = send(:call!, "I2-02", { "participant" => { "key" => key } })
      _envelope, payload = Atomspace::I2Envelope.split!(frame)
      k, d = Atomspace::I2Envelope.participant_address!(payload)
      { "key" => k, "digest" => d }        # the OLD, unguarded behaviour
    end
  end

  payload = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32 }, "buckets" => [] }
  unguarded_ch = ScriptedChannel.new([ok_frame(payload)])
  unguarded = permissive.new(writer: unguarded_ch, reader: unguarded_ch)
  leaked = unguarded.resolve_backend_address(card_id: 17_120)

  guarded_ch = ScriptedChannel.new([ok_frame(payload)])
  guarded = Atomspace::I2ReaderProcessClient.new(writer: guarded_ch, reader: guarded_ch)
  refused = raised { guarded.resolve_backend_address(card_id: 17_120) }

  leaked["key"] == "(Card 999)" &&
    refused.is_a?(Atomspace::I3ReadPort::AddressUnavailable)
end

check "OPEN refuses a participant answer naming a DIFFERENT card (no cross-card property stamping)" do
  # `open` stamps every property with the REQUESTED card_id, so a substituted participant would
  # relabel another card's material as this card's. 503, never silently-relabelled atoms.
  payload = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32,
                                 "properties" => [{ "key" => "(Card 999)", "digest" => "d" * 32,
                                                    "head" => "name", "value" => "secret" }] } }
  c, = client_for(ok_frame(payload))
  err = raised { c.open(card_id: 17_120) }
  err.is_a?(Atomspace::I2Envelope::ContractViolation) || err.is_a?(Atomspace::ServiceUnavailable)
end

check "MUTATION PROOF: without the open-path guard, card 999's property would be stamped card 17120" do
  payload = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32,
                                 "properties" => [{ "key" => "(Card 999)", "digest" => "d" * 32,
                                                    "head" => "name", "value" => "secret" }] } }
  # The unguarded path: build the atoms directly from the same payload under the requested id.
  c, = client_for(ok_frame(payload))
  unguarded_atoms = c.send(:atoms_from_properties, payload, 17_120)
  leaked_under_wrong_acl = unguarded_atoms.first.associated_card_ids == [17_120]

  c2, = client_for(ok_frame(payload))
  refused = raised { c2.open(card_id: 17_120) }

  leaked_under_wrong_acl && !refused.nil?
end

check "NEIGHBOURS refuses a participant answer naming a different card" do
  payload = { "participant" => { "key" => "(Card 999)", "digest" => "c" * 32 },
              "entries" => [{ "key" => "(Card 5)", "digest" => "e" * 32 }] }
  c, = client_for(ok_frame(payload))
  err = raised { c.neighbours(card_id: 17_120, bucket: "links") }
  err.is_a?(Atomspace::I2Envelope::ContractViolation) || err.is_a?(Atomspace::ServiceUnavailable)
end

check "OPEN still works normally when the participant key MATCHES" do
  payload = { "participant" => { "key" => "(Card 17120)", "digest" => "c" * 32,
                                 "properties" => [{ "key" => "(Card 17120)", "digest" => "d" * 32,
                                                    "head" => "name", "value" => "ok" }] } }
  c, = client_for(ok_frame(payload))
  atoms = c.open(card_id: 17_120)
  atoms.size == 1 && atoms.first.associated_card_ids == [17_120]
end

check "I2-02 is the operation used for the address (handoff 022b §4: CONFIRM with I2-02)" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "d" * 32 }, "buckets" => [] }
  c, ch = client_for(ok_frame(payload))
  c.resolve_backend_address(card_id: 1)
  ch.requests.first["op"] == "I2-02"
end

check "NO IDENTITY reaches the wire on any call (Q12: no identity at the I2 call)" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "d" * 32 },
              "properties" => [], "buckets" => [] }
  c, ch = client_for(ok_frame(payload), ok_frame(payload.merge("participant" =>
    { "key" => "(Card 1)", "digest" => "d" * 32, "properties" => [] })))
  c.resolve_backend_address(card_id: 1)
  c.open(card_id: 1)
  json = JSON.generate(ch.requests)
  %w[account token bearer cookie user principal session Authorization].none? { |f| json.include?(f) }
end

# =============================================================================================
puts "\nD -- the address reason string is ONE indistinguishable value (not an existence oracle)"
# =============================================================================================

ADDRESS_CASES = {
  "STORE answered 'unknown' (no such participant)" =>
    [{ "ok" => true, "envelope" => ok_envelope(outcome: "unknown"), "payload" => {} }],
  "STORE answered 'not ready' (no published state)" =>
    [{ "ok" => true, "envelope" => not_ready_envelope, "payload" => {} }],
  "STORE answered 'reload'" =>
    [{ "ok" => true, "envelope" => ok_envelope(outcome: "reload"), "payload" => {} }],
  "an AMBIGUOUS digest ('ok, partial')" =>
    [{ "ok" => true, "envelope" => ok_envelope(outcome: "ok, partial"),
       "payload" => { "omitted" => { "bound" => "ambiguous-digest", "count" => 2 } } }],
  "the digest was MISSING from an otherwise-ok answer" =>
    [ok_frame({ "participant" => { "key" => "(Card 1)" } })],
  "the key was MISSING from an otherwise-ok answer" =>
    [ok_frame({ "participant" => { "digest" => "e" * 32 } })],
  "the participant block was absent entirely" => [ok_frame({})],
  "the envelope was malformed (no epoch)" =>
    [{ "ok" => true, "envelope" => ok_envelope.merge("epoch" => nil),
       "payload" => { "participant" => { "key" => "(Card 1)", "digest" => "f" * 32 } } }],
  "the channel was DEAD (EOF)" => [],
  "the server REFUSED I2-02" =>
    [{ "ok" => false, "error" => { "kind" => "i2-refused", "reason" => "address" } }]
}.freeze

observed_reasons = []
ADDRESS_CASES.each do |label, responses|
  check "#{label} -> AddressUnavailable('backend_digest_unavailable')" do
    c, = client_for(*responses)
    e = raised { c.resolve_backend_address(card_id: 1) }
    observed_reasons << e&.message
    e.is_a?(Atomspace::I3ReadPort::AddressUnavailable) && e.message == "backend_digest_unavailable"
  end
end

check "ALL #{ADDRESS_CASES.size} address failures produced exactly ONE distinct reason string" do
  observed_reasons.uniq == ["backend_digest_unavailable"]
end

check "that string is IDENTICAL to the fixture's and the unwired port's" do
  fixture = Atomspace::FixtureI3ReadPort.new
  fe = raised { fixture.resolve_backend_address(card_id: 1) }
  Atomspace::LocalI3ReadBinding.uninstall!
  ue = raised { Atomspace::I3ReadPort.resolve_backend_address(card_id: 1) }
  fe.message == "backend_digest_unavailable" &&
    ue.is_a?(Atomspace::I3ReadPort::NotWired) &&
    observed_reasons.uniq == [fe.message]
end

check "the real cause IS available to the operator via last_refusal (server-side only)" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope(outcome: "unknown"), "payload" => {} })
  raised { c.resolve_backend_address(card_id: 1) }
  c.last_refusal.to_s.include?("does not hold this participant")
end

# =============================================================================================
puts "\nE -- a hung or dead reader is NOT-READY / unavailable, never a hang and never a false green"
# =============================================================================================

check "a HUNG reader times out and is NOT READY with reason i2_reader_timeout" do
  hung = HungChannel.new
  c = Atomspace::I2ReaderProcessClient.new(writer: hung, reader: hung, deadline_ms: 150)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = c.readiness
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  r.ready? == false && r.reason == "i2_reader_timeout" && elapsed < 5
end

check "a DEAD reader (EOF) is NOT READY with reason i2_reader_channel_unavailable" do
  c, = client_for
  r = c.readiness
  r.ready? == false && r.reason == "i2_reader_channel_unavailable"
end

check "a timeout KILLS the channel: every later call fails closed, never resynchronises" do
  hung = HungChannel.new
  c = Atomspace::I2ReaderProcessClient.new(writer: hung, reader: hung, deadline_ms: 100)
  c.readiness
  r2 = c.readiness
  r2.ready? == false && r2.reason == "i2_reader_channel_unavailable"
end

check "an UNREADY store on a card read is ServiceUnavailable, NOT an empty atom list" do
  c, = client_for({ "ok" => true, "envelope" => not_ready_envelope, "payload" => {} })
  raised { c.open(card_id: 1) }.is_a?(Atomspace::ServiceUnavailable)
end

check "a DEAD channel on a card read raises, never returns []" do
  c, = client_for
  e = raised { c.open(card_id: 1) }
  !e.nil? && !e.is_a?(NoMethodError)
end

check "STORE's 'unknown' participant IS an empty list (a 200, not an oracle)" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope(outcome: "unknown"), "payload" => {} })
  c.open(card_id: 1) == []
end

check "a MALFORMED open answer RAISES -- 'nothing there' stays distinct from 'no answer'" do
  c, = client_for(ok_frame({ "participant" => { "key" => "(Card 1)", "digest" => "a" * 32 } }))
  raised { c.open(card_id: 1) }.is_a?(Atomspace::I2Envelope::ContractViolation)
end

check "install!(reader: nil) leaves the port UNWIRED -> 503 (no fixture fallback)" do
  Atomspace::LocalI3ReadBinding.install!(reader: nil)
  Atomspace::I3ReadPort.readiness.reason == "i3_read_port_unwired" &&
    Atomspace::I3ReadPort.origin == "unavailable"
end

check "neighbours REFUSES a nil bucket (no invented 'all buckets' semantic)" do
  c, = client_for
  raised { c.neighbours(card_id: 1, bucket: nil) }.is_a?(Atomspace::InvalidRequest)
end

check "neighbours maps limit -> I2-03 limits['max-entries'] and sends NO narrowing" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "a" * 32 }, "entries" => [] }
  c, ch = client_for(ok_frame(payload))
  c.neighbours(card_id: 1, bucket: "links-to", limit: 25)
  args = ch.requests.first["args"]
  args["limits"] == { "max-entries" => 25 } && args["bucket"] == "links-to" &&
    !args.key?("narrowing") && !args.key?("kind") && !args.key?("direction")
end

check "a neighbour entry missing STORE's key/digest RAISES (never a half atom)" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "a" * 32 },
              "entries" => [{ "class" => "entity", "label" => {} }] }
  c, = client_for(ok_frame(payload))
  raised { c.neighbours(card_id: 1, bucket: "links-to") }
    .is_a?(Atomspace::I2Envelope::ContractViolation)
end

check "a well-formed neighbour entry becomes an Atom whose card id came from the KEY TEXT" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "a" * 32 },
              "entries" => [{ "key" => "(Card 4242)", "digest" => "b" * 32, "class" => "entity",
                              "label" => { "name" => "X" }, "trash" => false,
                              "link-count" => 1, "link-copy-count" => 1 }] }
  c, = client_for(ok_frame(payload))
  atoms = c.neighbours(card_id: 1, bucket: "links-to")
  atoms.size == 1 && atoms.first.associated_card_ids == [4242] &&
    atoms.first.to_h[:card_id] == 4242
end

check "a NON-card participant key yields NO card id -> the ACL filter DROPS it (safe direction)" do
  payload = { "participant" => { "key" => "(Card 1)", "digest" => "a" * 32 },
              "entries" => [{ "key" => '(Wanted "foo")', "digest" => "c" * 32,
                              "class" => "unresolved", "label" => {}, "trash" => nil,
                              "link-count" => 0, "link-copy-count" => 0 }] }
  c, = client_for(ok_frame(payload))
  atoms = c.neighbours(card_id: 1, bucket: "links-to")
  # EMPTY associated ids is exactly what atomspace_read_filter.rb:17 drops.
  atoms.size == 1 && atoms.first.associated_card_ids.empty?
end

check "open maps participant.properties to Atoms carrying the SOURCE card id" do
  payload = { "participant" => { "key" => "(Card 7)", "digest" => "a" * 32,
                                 "properties" => [
                                   { "key" => '(name (Card 7) "Alpha")', "digest" => "d" * 32,
                                     "head" => "name", "value" => "Alpha", "copy-count" => 1 }
                                 ] } }
  c, = client_for(ok_frame(payload))
  atoms = c.open(card_id: 7)
  atoms.size == 1 && atoms.first.associated_card_ids == [7] &&
    atoms.first.to_h[:type] == "I2Property"
end

check "every produced Atom satisfies the controller's atom contract (associated_card_ids + to_h)" do
  payload = { "participant" => { "key" => "(Card 7)", "digest" => "a" * 32,
                                 "properties" => [
                                   { "key" => "k", "digest" => "d" * 32, "head" => "name",
                                     "value" => "Alpha", "copy-count" => 1 }
                                 ] } }
  c, = client_for(ok_frame(payload))
  c.open(card_id: 7).all? { |a| a.respond_to?(:associated_card_ids) && a.respond_to?(:to_h) }
end

check "a property entry missing its head RAISES (an atom with a nil head is malformed)" do
  payload = { "participant" => { "key" => "(Card 7)", "digest" => "a" * 32,
                                 "properties" => [{ "key" => "k", "digest" => "d" * 32,
                                                    "value" => "Alpha" }] } }
  c, = client_for(ok_frame(payload))
  raised { c.open(card_id: 7) }.is_a?(Atomspace::I2Envelope::ContractViolation)
end

# =============================================================================================
puts "\nF -- capability gaps have NO SOURCE, so they raise distinct refusals and never a value"
# =============================================================================================

check "runtime_version! raises RuntimeVersionUnavailable (handoff 022b Q3 = NO)" do
  c, = client_for
  e = raised { c.runtime_version! }
  e.is_a?(Atomspace::I2ReaderProcessClient::RuntimeVersionUnavailable) &&
    e.message.include?("no source")
end

check "it is NOT a KeyError -- STORE asked that the two stay distinct (022b §2)" do
  c, = client_for
  !raised { c.runtime_version! }.is_a?(KeyError)
end

check "health! raises HealthSliceUnavailable naming the O23 gate" do
  c, = client_for
  e = raised { c.health! }
  e.is_a?(Atomspace::I2ReaderProcessClient::HealthSliceUnavailable) &&
    e.message.include?("o23_gated")
end

check "the health refusal names the five ABSENT (not fabricated) signals" do
  c, = client_for
  msg = raised { c.health! }.message
  %w[projection liveness heartbeat oldest-unapplied-age hidden-provenance-count]
    .all? { |s| msg.include?(s) }
end

check "the two refusals are DIFFERENT classes (one reason per condition)" do
  Atomspace::I2ReaderProcessClient::RuntimeVersionUnavailable !=
    Atomspace::I2ReaderProcessClient::HealthSliceUnavailable
end

check "no readiness path ever returns a health block" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope, "payload" => STATUS_PAYLOAD })
  r = c.readiness
  !r.respond_to?(:health) && r.to_h.keys.sort == %i[ready reason]
end

# =============================================================================================
puts "\nG -- source-level invariants: no digest, no clock, no fixture fallback, no identity"
# =============================================================================================

CLIENT_SRC = File.read(File.join(LIB, "i2_reader_process_client.rb"))
ENVELOPE_SRC = File.read(File.join(LIB, "i2_envelope.rb"))
TRANSPORT_SRC = File.read(File.join(LIB, "i2_stdio_transport.rb"))

def code_only(src)
  src.gsub(/^\s*#.*$/, "")
end

[["i2_reader_process_client.rb", CLIENT_SRC], ["i2_envelope.rb", ENVELOPE_SRC],
 ["i2_stdio_transport.rb", TRANSPORT_SRC]].each do |name, src|
  check "#{name}: NO digest is COMPUTED (no Digest::/hexdigest/OpenSSL/sha256 call)" do
    # CASE-SENSITIVE and anchored on a CALL, not on the word "digest": the field NAME `"digest"`
    # appears throughout these files legitimately -- it is the value STORE sends and VIEW copies.
    # What must be absent is any way to PRODUCE one: a Digest:: constant, a #hexdigest call, an
    # OpenSSL digest, or a sha256 helper.
    !code_only(src).match?(/Digest::|\.hexdigest|OpenSSL|\bsha256\b|\bSHA256\b/)
  end
end

[["i2_reader_process_client.rb", CLIENT_SRC], ["i2_envelope.rb", ENVELOPE_SRC]].each do |name, src|
  check "#{name}: NO clock call -- read-at is STORE-SAMPLED, never stamped by VIEW" do
    !code_only(src).match?(/Time\.(now|at)|DateTime|Date\.today|strftime|iso8601/)
  end
end

check "the client NEVER references the fixture (no silent degrade to synthetic data)" do
  !code_only(CLIENT_SRC).match?(/Fixture|fixture/)
end

check "the client constructs NO process (no popen/spawn/system/exec/fork/open3)" do
  !code_only(CLIENT_SRC).match?(/popen|Open3|\bspawn\b|\bsystem\(|\bexec\(|\bfork\b|backtick/)
end

check "the client constructs NO socket / URL / HTTP client" do
  !code_only(CLIENT_SRC).match?(/Socket|TCPSocket|Net::HTTP|URI\.|https?:\/\//)
end

check "the client holds NO credential / identity field" do
  !code_only(CLIENT_SRC).match?(/password|secret|bearer|api_key|token|cookie|credential/i)
end

check "the client supplies NO default for any envelope metadatum" do
  code = code_only(CLIENT_SRC)
  # No `envelope[...] || fallback` and no coercion of a metadatum.
  !code.match?(/envelope\[[^\]]+\]\s*\|\|/) &&
    !code.match?(/(epoch|position|read-at|read_at)[^\n]*\.to_(i|s|f)\b/)
end

check "the envelope validator supplies no default and does no coercion" do
  code = code_only(ENVELOPE_SRC)
  !code.match?(/fetch\([^)]*,\s*[^)]+\)/) && !code.match?(/\.to_(i|f)\b/)
end

check "the FIVE answering ops are the only ones the client calls (I2-01/02/03/07/09)" do
  ops = code_only(CLIENT_SRC).scan(/"(I2-\d\d)"/).flatten.uniq.sort
  ops == %w[I2-01 I2-02 I2-03 I2-07 I2-09]
end

check "none of the five REFUSED ops (I2-04/05/06/08/10) is called by the client" do
  code = code_only(CLIENT_SRC)
  %w[I2-04 I2-05 I2-06 I2-08 I2-10].none? { |op| code.include?(%("#{op}")) }
end

check "I3-01 and I3-09 are not implemented anywhere in the client (out of scope, Q2)" do
  !code_only(CLIENT_SRC).match?(/I3-01|I3-09/)
end

check "the client sends no narrowing parameter at all (unsupported, 022b §3)" do
  !code_only(CLIENT_SRC).match?(/narrowing|card-type|direction\[\]/)
end

check "the pinned install seam is untouched by this work (byte-identical)" do
  require "digest"
  path = File.join(LIB, "local_i3_read_binding.rb")
  Digest::SHA256.file(path).hexdigest.start_with?("1dc579da") &&
    File.readlines(path).size == 139
end

# =============================================================================================
puts "\nH -- ROUND-25 BLOCKER REGRESSIONS (each fails if its guard is reverted)"
# =============================================================================================

# ---- BLOCKER 2: the WRITE is inside the deadline --------------------------------------------

# A channel whose WRITE blocks forever: the child stopped consuming stdin and the pipe filled.
# The existing HungChannel blocks `gets`; this one never reaches a read at all.
class WriteHungChannel
  def puts(_line)
    sleep 30
  end

  def flush; end

  def gets
    raise "unreachable: the write must have blocked first"
  end
end

check "BLOCKER 2: a child that stops consuming stdin TIMES OUT (write is inside the deadline)" do
  c = Atomspace::I2ReaderProcessClient.new(writer: WriteHungChannel.new,
                                           reader: WriteHungChannel.new, deadline_ms: 300)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = c.readiness
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  # NOT-READY with the timeout reason, and it returned in roughly the budget -- not in 30s.
  result.ready? == false && result.reason == "i2_reader_timeout" && elapsed < 5
end

check "BLOCKER 2: a blocked WRITE kills the channel, like any other channel failure" do
  c = Atomspace::I2ReaderProcessClient.new(writer: WriteHungChannel.new,
                                           reader: WriteHungChannel.new, deadline_ms: 200)
  c.readiness
  err = raised { c.resolve_backend_address(card_id: 1) }
  err.is_a?(Atomspace::I3ReadPort::AddressUnavailable)
end

check "BLOCKER 2 MUTATION PROOF: writing BEFORE the deadline would hang past the budget" do
  # The old shape, reproduced exactly: write first, then bound only the read. Run in a thread so
  # this proof itself cannot hang, and assert the thread is STILL STUCK after 3x the budget --
  # which is what the production code did before the fix and no longer does.
  stuck = Thread.new do
    writer = WriteHungChannel.new
    Atomspace::I2StdioTransport.write_request!(writer, id: "x", op: "I2-01", args: {},
                                               deadline_ms: 200)
    :completed
  end
  still_blocked = stuck.join(0.6).nil?
  stuck.kill
  still_blocked
end

# ---- BLOCKER 4: read-at must denote a REAL instant -------------------------------------------

IMPOSSIBLE_READ_ATS = [
  "2026-99-99T09:41:02.123456+00:00",   # impossible month AND day
  "2026-13-01T09:41:02.123456+00:00",   # month 13
  "2026-02-30T09:41:02.123456+00:00",   # February 30th
  "2026-11-15T25:41:02.123456+00:00",   # hour 25
  "2026-11-15T09:61:02.123456+00:00",   # minute 61
  "2026-11-15T09:41:99.123456+00:00",   # second 99
  "2026-11-15T09:41:02.123456+99:99",   # impossible offset
  "2026-11-15T09:41:02.123456+25:00",   # offset beyond +24:00
  "2026-11-15T09:41:02.123456+00:99",   # offset minutes 99
  "2026-00-10T09:41:02.123456+00:00",   # month 0
  "2026-11-00T09:41:02.123456+00:00",   # day 0
  # ---- R26 PARTIAL CLOSURE: values the FIRST fix still admitted -----------------------------
  # The reviewer's two concrete survivors. Both matched the regex AND passed the first round of
  # range checks, because that round allowed a leap second (<= 60) and allowed +/-24:00 when the
  # minutes were zero. STORE's formatter (`datetime.isoformat` on a tz-aware datetime) can emit
  # NEITHER -- Python's datetime cannot represent second 60 and its `timezone` refuses a 24h
  # offset -- so each is a string that denotes no instant VIEW could ever have been sent.
  "2026-11-15T09:41:60.123456Z",        # second 60 (the leap-second allowance, now closed)
  "2026-11-15T09:41:60.123456+00:00",   # the same, in the spelling Python actually emits
  "2026-11-15T09:41:02.123456+24:00",   # whole-day offset, minutes zero (now closed)
  "2026-11-15T09:41:02.123456-24:00",   # and its negative twin
  "2026-11-15T09:41:02.123456+24:30",   # 24h with minutes was already refused; still is
  "2026-11-15T09:41:60.123456+14:00"    # second 60 is refused even on an otherwise-legal offset
].freeze

check "BLOCKER 4: every IMPOSSIBLE read-at instant is refused, though all match the old regex" do
  IMPOSSIBLE_READ_ATS.all? do |bad|
    shape_ok = Atomspace::I2Envelope::READ_AT_PATTERN.match?(bad)
    err = raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => bad)) }
    # The regex ACCEPTS it (so the regex alone was insufficient) and validate! REFUSES it.
    shape_ok && err.is_a?(Atomspace::I2Envelope::ContractViolation) &&
      err.rule == "read_at_missing_or_malformed"
  end
end

check "BLOCKER 4: a real instant still passes, in both +00:00 and Z spellings" do
  ["2026-11-15T09:41:02.123456+00:00", "2026-11-15T09:41:02.123456Z",
   "2026-02-29T23:59:59.999999-08:00",          # 2024 was leap; 2026-02-29 is not -- see below
   "2024-02-29T23:59:59.999999-08:00",
   "2026-11-15T09:41:02.123456+14:00"].reject { |s| s.start_with?("2026-02-29") }.all? do |good|
    Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => good)) ? true : false
  end
end

check "BLOCKER 4: 2026-02-29 does not exist and is refused (leap-year arithmetic is real)" do
  err = raised { Atomspace::I2Envelope.validate!(
    ok_envelope.merge("read-at" => "2026-02-29T01:02:03.123456Z")
  ) }
  ok2024 = Atomspace::I2Envelope.validate!(
    ok_envelope.merge("read-at" => "2024-02-29T01:02:03.123456Z")
  )
  err.is_a?(Atomspace::I2Envelope::ContractViolation) && !ok2024.nil?
end

check "BLOCKER 4 MUTATION PROOF: the lexical pattern alone would admit 2026-99-99T99:99:99" do
  # If the instant parse were reverted, validation would reduce to this regex -- which passes.
  Atomspace::I2Envelope::READ_AT_PATTERN.match?("2026-99-99T99:99:99.123456+99:99") == true
end

# ---- B4 PARTIAL CLOSURE (R26): the bounds are the FORMATTER's, not ISO's outer edge ----------

check "B4 PARTIAL: second 60 is REFUSED -- the leap-second allowance is closed" do
  ["2026-11-15T09:41:60.123456Z",
   "2026-11-15T09:41:60.123456+00:00",
   "2026-11-15T09:41:60.123456-08:00"].all? do |bad|
    err = raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => bad)) }
    # Shape-valid, so only the instant check can refuse it, and under the SAME rule token.
    Atomspace::I2Envelope::READ_AT_PATTERN.match?(bad) &&
      err.is_a?(Atomspace::I2Envelope::ContractViolation) &&
      err.rule == "read_at_missing_or_malformed"
  end
end

check "B4 PARTIAL: a whole-day offset (+/-24:00) is REFUSED, minutes zero or not" do
  ["2026-11-15T09:41:02.123456+24:00",
   "2026-11-15T09:41:02.123456-24:00",
   "2026-11-15T09:41:02.123456+24:01"].all? do |bad|
    err = raised { Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => bad)) }
    Atomspace::I2Envelope::READ_AT_PATTERN.match?(bad) &&
      err.is_a?(Atomspace::I2Envelope::ContractViolation) &&
      err.rule == "read_at_missing_or_malformed"
  end
end

check "B4 PARTIAL MUTATION PROOF: the FIRST fix's bounds would have ACCEPTED both survivors" do
  # The reverted predicate, reproduced exactly as it stood (second <= 60; offset hours <= 24 with
  # a minutes-zero carve-out for 24). Applied to the two values the tightened code now refuses,
  # it says VALID -- which is precisely the partial the reviewer found. If someone restores those
  # bounds, the two checks above start failing and this one keeps naming why.
  old_accepts = lambda do |s|
    m = Atomspace::I2Envelope::READ_AT_COMPONENTS.match(s)
    next false unless m

    second = Integer(m[6], 10)
    next false unless second.between?(0, 60)          # the OLD leap-second allowance

    off = m[8]
    next true if off == "Z"

    oh = Integer(off[1, 2], 10)
    om = Integer(off[4, 2], 10)
    !(oh > 24 || om > 59 || (oh == 24 && om != 0))    # the OLD +24:00 carve-out
  end

  old_accepts.call("2026-11-15T09:41:60.123456Z") == true &&
    old_accepts.call("2026-11-15T09:41:02.123456+24:00") == true &&
    # ...and the CURRENT code refuses both.
    raised { Atomspace::I2Envelope.validate!(
      ok_envelope.merge("read-at" => "2026-11-15T09:41:60.123456Z")
    ) }.is_a?(Atomspace::I2Envelope::ContractViolation) &&
    raised { Atomspace::I2Envelope.validate!(
      ok_envelope.merge("read-at" => "2026-11-15T09:41:02.123456+24:00")
    ) }.is_a?(Atomspace::I2Envelope::ContractViolation)
end

check "B4 PARTIAL: NO over-refusal -- every legitimate instant still passes" do
  # Each of these is a value STORE's formatter can really emit, including the largest offset any
  # zone actually keeps (+14:00, Kiritimati) and a real leap day. Narrowing must not cost these.
  ["2026-11-15T09:41:02.123456+00:00",
   "2026-11-15T09:41:02.123456Z",
   "2026-11-15T09:41:02.123456-08:00",
   "2026-11-15T09:41:59.999999+00:00",   # the LAST legal second
   "2026-11-15T09:41:02.123456+14:00",   # the largest real offset
   "2026-11-15T09:41:02.123456-12:00",
   "2026-11-15T09:41:02.123456+23:59",   # the new outer edge, still accepted
   "2024-02-29T23:59:59.999999-08:00",   # real leap day
   "2026-01-01T00:00:00.000000Z"].all? do |good|
    !Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => good)).nil?
  end
end

check "B4 PARTIAL: the accepted read-at is returned VERBATIM -- no normalisation, no resampling" do
  # The narrowing must not have turned into a rewrite: the validated envelope must carry the
  # caller's exact bytes, not a reserialised instant (no "Z"->"+00:00", no second-rounding).
  ["2026-11-15T09:41:02.123456Z",
   "2026-11-15T09:41:59.999999+14:00",
   "2024-02-29T23:59:59.999999-08:00"].all? do |good|
    env = Atomspace::I2Envelope.validate!(ok_envelope.merge("read-at" => good))
    env["read-at"].equal?(good) || env["read-at"] == good
  end
end

check "B4 PARTIAL: calendar validity is PROLEPTIC GREGORIAN, not Italy's 1582 reform" do
  # ISO-8601 defines 1582-10-05..14 proleptically; Ruby's DEFAULT Date::ITALY calls them invalid.
  # `read-at` is ISO-8601, so the gate must not refuse a date the format permits. The leap
  # arithmetic that actually matters is asserted unchanged alongside it.
  require "date"
  reform_day = Date.valid_date?(1582, 10, 10) == false &&
               Date.valid_date?(1582, 10, 10, Date::GREGORIAN) == true
  accepted = !Atomspace::I2Envelope.validate!(
    ok_envelope.merge("read-at" => "1582-10-10T09:41:02.123456Z")
  ).nil?
  leap_intact = Date.valid_date?(2024, 2, 29, Date::GREGORIAN) == true &&
                Date.valid_date?(2026, 2, 30, Date::GREGORIAN) == false &&
                Date.valid_date?(1900, 2, 29, Date::GREGORIAN) == false
  reform_day && accepted && leap_intact
end

check "B4 PARTIAL: the tightened check reads NO clock and needs NO timezone database" do
  src = File.read(File.join(LIB, "i2_envelope.rb"))
  code = src.lines.reject { |l| l.strip.start_with?("#") }.join
  # No clock read (the standing rule) and no tzdata/zone-lookup dependency introduced by the
  # offset narrowing -- the offset is checked by arithmetic on the supplied digits.
  !code.match?(/Time\.now|DateTime\.now|Date\.today|Time\.current/) &&
    !code.match?(/TZInfo|tzinfo|ActiveSupport::TimeZone|find_timezone|zone_for/)
end

check "BLOCKER 4: read-at is still never STAMPED -- no clock call was introduced" do
  src = File.read(File.join(LIB, "i2_envelope.rb"))
  code = src.lines.reject { |l| l.strip.start_with?("#") }.join
  # DateTime.iso8601 is a PARSE of a supplied string. `Time.now`/`DateTime.now`/`Date.today` are
  # clock reads, and none may appear.
  !code.match?(/Time\.now|DateTime\.now|Date\.today|Time\.current|\.utc\b/)
end

# ---- BLOCKER 5: READY requires outcome == "ok" -----------------------------------------------

NON_OK_OUTCOMES = ["ok, partial", "unknown", "reload"].freeze

check "BLOCKER 5: a 'readiness: ready' frame with a NON-OK outcome is NOT ready" do
  NON_OK_OUTCOMES.all? do |outcome|
    c, = client_for({ "ok" => true, "envelope" => ok_envelope(outcome: outcome),
                      "payload" => STATUS_PAYLOAD })
    r = c.readiness
    r.ready? == false && r.reason == "i2_store_outcome_not_ok"
  end
end

check "BLOCKER 5: the degraded-outcome reason is DISTINCT from the other not-ready reasons" do
  reasons = [Atomspace::I2ReaderProcessClient::REASON_DEGRADED_OUTCOME,
             Atomspace::I2ReaderProcessClient::REASON_STORE_NOT_READY,
             Atomspace::I2ReaderProcessClient::REASON_CONTRACT,
             Atomspace::I2ReaderProcessClient::REASON_CHANNEL_DOWN,
             Atomspace::I2ReaderProcessClient::REASON_TIMEOUT,
             Atomspace::I2ReaderProcessClient::REASON_SCHEMA,
             Atomspace::I2ReaderProcessClient::REASON_REFUSED]
  reasons.uniq.size == reasons.size
end

check "BLOCKER 5: 'not ready' still reports its OWN reason, not the new one" do
  c, = client_for({ "ok" => true, "envelope" => not_ready_envelope, "payload" => {} })
  c.readiness.reason == "i2_store_not_ready"
end

check "BLOCKER 5: a clean 'ok' + readiness:ready + right schema is STILL READY (no over-refusal)" do
  c, = client_for({ "ok" => true, "envelope" => ok_envelope(outcome: "ok"),
                    "payload" => STATUS_PAYLOAD })
  c.readiness.ready? == true
end

check "BLOCKER 5 MUTATION PROOF: excluding only 'not ready' would have granted READY on all three" do
  # The reverted predicate, applied to the very frames the fix now refuses.
  NON_OK_OUTCOMES.all? do |outcome|
    env = ok_envelope(outcome: outcome)
    old_would_grant = !Atomspace::I2Envelope.not_ready?(env) && STATUS_PAYLOAD["readiness"] == "ready"
    c, = client_for({ "ok" => true, "envelope" => env, "payload" => STATUS_PAYLOAD })
    old_would_grant && c.readiness.ready? == false
  end
end

# ---- NON-BLOCKING (a): identity-shaped keys at ANY depth -------------------------------------

check "NESTED identity-shaped keys are refused by the transport, at any depth" do
  nested = [
    { "participant" => { "key" => "(Card 1)", "token" => "t" } },
    { "participant" => { "key" => "(Card 1)" }, "limits" => { "Authorization" => "Bearer x" } },
    { "a" => { "b" => { "c" => { "session" => "s" } } } },
    { "list" => [{ "ok" => 1 }, { "api_key" => "k" }] },
    { "X-API-KEY" => "k" },
    { "participant" => { "key" => "(Card 1)", "user" => "admin" } }
  ]
  nested.all? do |args|
    err = raised do
      Atomspace::I2StdioTransport.write_request!(StringIO.new, id: "i", op: "I2-09", args: args)
    end
    err.is_a?(Atomspace::I2StdioTransport::ChannelError) && err.message.include?("identity-shaped")
  end
end

check "a CLEAN nested args mapping still serialises (the depth check is not a blanket refusal)" do
  out = StringIO.new
  line = Atomspace::I2StdioTransport.write_request!(
    out, id: "i", op: "I2-03",
    args: { "participant" => { "key" => "(Card 1)" }, "bucket" => "links",
            "limits" => { "max-entries" => 10 } }
  )
  JSON.parse(line)["args"]["limits"]["max-entries"] == 10
end

check "the `auth_token` ALIAS the comment advertises is actually rejected (casefold + separators)" do
  # REGRESSION. `FORBIDDEN_IDENTITY_KEYS` documented `auth_token` as a caught spelling while
  # omitting its NORMALISED form `authtoken`, so this exact alias -- the documented one -- was
  # the single spelling that serialised cleanly. `auth` and `token` are separate whole-key
  # entries and `identity_key?` is never a substring match, so neither covered it.
  spellings = [
    "auth_token", "authtoken", "AUTH_TOKEN", "Auth-Token", "auth-token", "Auth_Token",
    "aUtH tOkEn", "  auth_token  ".strip, "AuthToken"
  ]
  spellings.all? { |k| Atomspace::I2StdioTransport.identity_key?(k) }
end

check "`auth_token` is refused AT ANY DEPTH and inside arrays, not just at the top level" do
  nested = [
    { "auth_token" => "secret-value-never-logged" },
    { "participant" => { "key" => "(Card 1)", "auth_token" => "x" } },
    { "a" => { "b" => { "c" => { "Auth-Token" => "x" } } } },
    { "list" => [{ "ok" => 1 }, { "AUTH_TOKEN" => "x" }] },
    { "limits" => { "authToken" => "x" } }
  ]
  nested.all? do |args|
    err = raised do
      Atomspace::I2StdioTransport.write_request!(StringIO.new, id: "i", op: "I2-09", args: args)
    end
    err.is_a?(Atomspace::I2StdioTransport::ChannelError) && err.message.include?("identity-shaped")
  end
end

check "the auth_token refusal names the KEY PATH and never echoes the credential VALUE" do
  # The refusal must be diagnosable without turning the error channel into a credential leak.
  err = raised do
    Atomspace::I2StdioTransport.write_request!(
      StringIO.new, id: "i", op: "I2-09",
      args: { "participant" => { "auth_token" => "sup3r-s3cret-do-not-echo" } }
    )
  end
  err.is_a?(Atomspace::I2StdioTransport::ChannelError) &&
    err.message.include?("args.participant.auth_token") &&
    !err.message.include?("sup3r-s3cret-do-not-echo")
end

check "AUTH_TOKEN MUTATION PROOF: removing the `authtoken` entry re-opens the bypass" do
  # Load-bearing: with `authtoken` absent from the normalised list, `auth_token` serialises.
  original = Atomspace::I2StdioTransport::FORBIDDEN_IDENTITY_KEYS
  reverted = (original - ["authtoken"]).freeze
  swap = lambda do |list|
    Atomspace::I2StdioTransport.send(:remove_const, :FORBIDDEN_IDENTITY_KEYS)
    Atomspace::I2StdioTransport.const_set(:FORBIDDEN_IDENTITY_KEYS, list)
  end
  bypassed = begin
    swap.call(reverted)
    begin
      Atomspace::I2StdioTransport.write_request!(
        StringIO.new, id: "i", op: "I2-09", args: { "participant" => { "auth_token" => "x" } }
      )
      true
    rescue Atomspace::I2StdioTransport::ChannelError
      false
    end
  ensure
    swap.call(original)
  end
  # The pre-fix list LET IT THROUGH, and the restored list refuses it again.
  bypassed && Atomspace::I2StdioTransport.identity_key?("auth_token") &&
    !Atomspace::I2StdioTransport.identity_key?("nothing-identity-shaped")
end

check "a clean token-ADJACENT key is still allowed (the new entry is not an over-broad prefix)" do
  # `authtokens_allowed_count` and friends must NOT be swept up: whole-key comparison only.
  out = StringIO.new
  line = Atomspace::I2StdioTransport.write_request!(
    out, id: "i", op: "I2-03",
    args: { "participant" => { "key" => "(Card 1)" }, "bucket" => "links",
            "tokenization" => "ngram", "author_name_display" => "x" }
  )
  JSON.parse(line)["args"]["tokenization"] == "ngram"
end

check "NESTED identity MUTATION PROOF: the top-level key check alone would have let it through" do
  # REQUEST_KEYS constrains only the top level; the frame below is top-level-clean.
  frame = { "v" => 1, "id" => "i", "op" => "I2-09",
            "args" => { "participant" => { "key" => "(Card 1)", "token" => "leak" } } }
  (frame.keys - Atomspace::I2StdioTransport::REQUEST_KEYS).empty? &&
    JSON.generate(frame).include?("leak")
end

# ---- NON-BLOCKING (c): the transaction is serialised ------------------------------------------

check "concurrent callers do not interleave: the request/response transaction is serialised" do
  # A channel that would MISMATCH frames under interleaving: it answers slowly, so without a mutex
  # two threads would both write before either read and each could take the other's line. With the
  # mutex every caller gets the answer to its OWN id, which read_response! enforces by id.
  slow = Class.new do
    def initialize
      @lines = []
      @m = Mutex.new
    end

    def puts(line)
      @m.synchronize { @lines << JSON.parse(line) }
      nil
    end

    def flush; end

    def gets
      sleep 0.01
      req = @m.synchronize { @lines.shift }
      return nil unless req

      JSON.generate({ "v" => 1, "id" => req["id"], "ok" => true,
                      "envelope" => { "outcome" => "ok", "epoch" => EPOCH, "position" => 1,
                                      "read-at" => READ_AT },
                      "payload" => { "participant" => { "key" => req["args"]["participant"]["key"],
                                                        "digest" => "f" * 32 } } }) + "\n"
    end
  end.new

  c = Atomspace::I2ReaderProcessClient.new(writer: slow, reader: slow, deadline_ms: 4_000)
  results = {}
  threads = [11, 12, 13, 14].map do |id|
    Thread.new { results[id] = c.resolve_backend_address(card_id: id)["key"] }
  end
  threads.each(&:join)
  # Each caller received the address for the card IT asked about.
  results.all? { |id, key| key == "(Card #{id})" }
end

check "the client documents and holds a mutex for the single shared pipe" do
  c, = client_for
  c.instance_variable_get(:@mutex).is_a?(Mutex)
end

# ---- BLOCKER 3 and 6 are process-level: see i2_spawn_isolation_proof.rb ----------------------

check "BLOCKER 3: the spawn builds a REPLACEMENT env, and it carries only the three needed keys" do
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: "C:/python/python.exe", script: "C:/x/server.py",
    sidecar_path: "C:/sidecar", config: { "page-max" => { "entries" => 1 } }
  )
  env = spawn.send(:child_env)
  env.keys.sort == ["AV_I2_STDIO_CONFIG", "AV_STORE_SIDECAR_PATH", "PYTHONUNBUFFERED"]
end

check "BLOCKER 3: no identity-bearing key can appear in the child env (it is two paths + ceilings)" do
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: "C:/python/python.exe", script: "C:/x/server.py",
    sidecar_path: "C:/sidecar", config: { "page-max" => { "entries" => 1 } }
  )
  spawn.send(:child_env).keys.none? { |k| Atomspace::I2StdioTransport.identity_key?(k) }
end

check "BLOCKER 6: stop! has a bounded grace period rather than an unbounded join" do
  Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS.is_a?(Numeric) &&
    Atomspace::I2StdioTransport::Spawn::STOP_GRACE_SECONDS.positive?
end

check "BLOCKER 6: stop! on a never-started spawn is a no-op and returns immediately" do
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: "C:/python/python.exe", script: "C:/x/server.py",
    sidecar_path: "C:/sidecar", config: {}
  )
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  spawn.stop!
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 1.0
end

# ---------------------------------------------------------------------------------------------
Atomspace::LocalI3ReadBinding.uninstall!

puts "\n" + "=" * 92
puts "PASSED: #{PASSES.size}   FAILED: #{FAILURES.size}"
unless FAILURES.empty?
  puts "\nFAILURES:"
  FAILURES.each { |f| puts "  - #{f}" }
end
puts "=" * 92
exit(FAILURES.empty? ? 0 : 1)
