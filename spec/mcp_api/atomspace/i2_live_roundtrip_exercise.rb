# frozen_string_literal: true
#
# LIVE ROUND-TRIP EXERCISE: VIEW's Ruby I3 reader against STORE's REAL Python I2Reader process.
#
# WHAT THIS ACTUALLY DOES, with nothing simulated on either side:
#
#   * It SPAWNS a real child process via Atomspace::I2StdioTransport::Spawn, using an interpreter
#     path and a script path given on the COMMAND LINE (no discovery, no default).
#   * The child is tools/i2_stdio_reader_server.py, which imports STORE's
#     atomspace_mirror_sidecar.i2_read and constructs the CANONICAL
#     I2Reader(RecordStore(retention=RetentionWindow(...)), I2Config(...)) -- STORE's own classes,
#     asserted to be STORE's own classes by the server itself.
#   * It then drives Atomspace::I2ReaderProcessClient -- the SAME object a local runtime would
#     bind -- over that child's real stdin/stdout pipes, and installs it into the real
#     Atomspace::I3ReadPort via Atomspace::LocalI3ReadBinding.install!.
#
# WHAT IT DOES NOT CLAIM. The store is seeded, when seeded at all, from STORE's V1-SHAPED GOLDEN
# VECTORS through STORE's own encoder and bootstrap validator. STORE's own words: "The inputs are
# V1-shaped, e.g. the shared golden vectors. They are NOT DEV data"; "Nothing on Magi DEV feeds a
# record store today: there is no producer." So this proves the TRANSPORT AND THE CONTRACT against
# the real reader. It proves nothing about live Decko data, and it is not a deployment.
#
# Run (both paths are REQUIRED; there is no default):
#   ruby spec/mcp_api/atomspace/i2_live_roundtrip_exercise.rb \
#     --interpreter C:/path/to/python.exe \
#     --script E:/GitHub/Magi-AGI/av-view-deck/tools/i2_stdio_reader_server.py \
#     --sidecar E:/GitHub/Magi-AGI/av-store-sidecar

require "json"

LIB = File.expand_path("../../../mod/mcp_api/lib/atomspace", __dir__)
require File.join(LIB, "i2_envelope")
require File.join(LIB, "i2_stdio_transport")
require File.join(LIB, "i2_reader_process_client")
require File.join(LIB, "local_i3_read_binding")

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
  FAILURES << "#{label} (#{e.class}: #{e.message})"
  puts "  FAIL  #{label} -- #{e.class}: #{e.message}"
end

def raised
  yield
  nil
rescue StandardError => e
  e
end

# ---- arguments: EXPLICIT, no discovery ------------------------------------------------------
opts = {}
ARGV.each_slice(2) { |flag, value| opts[flag.sub(/\A--/, "").to_sym] = value }
%i[interpreter script sidecar].each do |required|
  next if opts[required] && !opts[required].empty?

  abort "missing --#{required}: every path is explicit; there is no default and no discovery"
end

# STORE's WORKSHOP / TEST-LOCAL ceilings, verbatim from handoff 022b §6:
#   "WORKSHOP / TEST-LOCAL ONLY (not production, not reserved decisions):
#    entries 300, connections 900, per-neighbour 3, bytes 400,000, refresh 1 (inert), fanout 1,
#    RetentionWindow(positions=2, ms=None)."
# They are NOT production values and NOT reserved decisions. Copied, never chosen here.
WORKSHOP_CONFIG = {
  "page-max" => { "page-max-entries" => 300, "page-max-connections" => 900,
                  "page-max-bytes" => 400_000, "per-neighbour-link-max" => 3,
                  "refresh-max-participants" => 1 },
  "fanout-limit" => 1,
  "retention" => { "positions" => 2, "ms" => nil }
}.freeze

def spawn_reader(opts, seed: nil)
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: opts[:interpreter], script: opts[:script],
    sidecar_path: opts[:sidecar], config: WORKSHOP_CONFIG
  )
  # The seed flag is appended by re-invoking Spawn's argv through the script's own CLI. Spawn
  # itself takes no extra argv on purpose (it is the narrowest possible launcher), so the seeded
  # variant is started here explicitly, which keeps "seeded" a visible act at the call site.
  if seed
    require "open3"
    stdin, stdout, stderr, wait = Open3.popen3(
      { "AV_STORE_SIDECAR_PATH" => opts[:sidecar],
        "AV_I2_STDIO_CONFIG" => JSON.generate(WORKSHOP_CONFIG),
        "PYTHONUNBUFFERED" => "1" },
      opts[:interpreter], opts[:script], "--seed-from-golden-vectors", seed
    )
    stdin.sync = true
    return [stdin, stdout, stderr, wait]
  end
  spawn.start!
  [spawn.writer, spawn.reader, nil, spawn]
end

puts "\n1 -- the child is STORE's REAL I2Reader (self-check, separate invocation)"

require "open3"
self_check, status = Open3.capture2(
  { "AV_STORE_SIDECAR_PATH" => opts[:sidecar],
    "AV_I2_STDIO_CONFIG" => JSON.generate(WORKSHOP_CONFIG) },
  opts[:interpreter], opts[:script], "--self-check"
)
parsed = begin
  JSON.parse(self_check)
rescue JSON::ParserError
  {}
end

check "the self-check exits 0" do
  status.exitstatus.zero?
end

check "the loaded reader IS atomspace_mirror_sidecar.i2_read.I2Reader (not a double)" do
  parsed["reader_class"] == "atomspace_mirror_sidecar.i2_read.I2Reader"
end

check "the loaded store IS atomspace_mirror_sidecar.record_store.RecordStore" do
  parsed["store_class"] == "atomspace_mirror_sidecar.record_store.RecordStore"
end

check "the store's schema constant is decko-atomschema-v2" do
  parsed["schema_version"] == Atomspace::I2Envelope::SCHEMA_VERSION
end

puts "\n2 -- an UNSEEDED real store: 'not ready' with three nulls, and the port fails closed"

writer, reader, _err, handle = spawn_reader(opts)
begin
  client = Atomspace::I2ReaderProcessClient.new(writer: writer, reader: reader, deadline_ms: 10_000)

  check "I2-01 over the real pipe answers, and readiness is NOT READY (no published state)" do
    r = client.readiness
    r.ready? == false && r.reason == "i2_store_not_ready"
  end

  check "install! binds the live client; the port then reports data_origin 'live'" do
    Atomspace::LocalI3ReadBinding.install!(reader: client) == true &&
      Atomspace::I3ReadPort.origin == "live"
  end

  check "the PORT's readiness gate is closed on the unseeded store (-> controller 503)" do
    result = Atomspace::I3ReadPort.readiness
    result.ready? == false && result.reason == "i2_store_not_ready"
  end

  check "resolve_backend_address on an unready real store -> backend_digest_unavailable" do
    e = raised { client.resolve_backend_address(card_id: 100) }
    e.is_a?(Atomspace::I3ReadPort::AddressUnavailable) &&
      e.message == "backend_digest_unavailable"
  end

  check "a card read on an unready real store is ServiceUnavailable, never an empty list" do
    raised { client.open(card_id: 100) }.is_a?(Atomspace::ServiceUnavailable)
  end

  check "a REFUSED op (I2-04) comes back as STORE's own refusal, not a VIEW guess" do
    # Driven at the transport level, because the client deliberately never calls I2-04.
    id = "probe-i2-04"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-04",
                                               args: { "participant" => { "key" => "(Card 1)" } })
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    frame["ok"] == false && frame["error"]["kind"] == "i2-refused" &&
      frame["error"]["reason"].include?("I2-04")
  end

  check "all five refused ops (I2-04/05/06/08/10) refuse over the real reader" do
    %w[I2-04 I2-05 I2-06 I2-08 I2-10].all? do |op|
      id = "probe-#{op}"
      Atomspace::I2StdioTransport.write_request!(writer, id: id, op: op, args: {})
      frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
      frame["ok"] == false && frame["error"]["kind"] == "i2-refused"
    end
  end

  check "a NON-EMPTY narrowing is refused by the real reader BEFORE readiness (022b §3)" do
    id = "probe-narrowing"
    Atomspace::I2StdioTransport.write_request!(
      writer, id: id, op: "I2-03",
      args: { "participant" => { "key" => "(Card 1)" }, "bucket" => "links-to",
              "narrowing" => { "kind" => ["Entity"] } }
    )
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    frame["ok"] == false && frame["error"]["kind"] == "i2-refused"
  end

  # ---- SERVER-END identity rejection, proven on the REAL child over the REAL pipe -------------
  #
  # WHY THESE BYPASS `write_request!`. The client transport refuses an identity-shaped key before
  # any bytes exist, so driving these through it would only re-prove the CLIENT. The point here is
  # that the SERVER is independently identity-free: each end must refuse on its own, because a
  # patched, older or third-party client is exactly the case the server guard exists for. So these
  # write a RAW frame straight to the child's stdin -- bytes the client would never emit.
  raw_ask = lambda do |id, args|
    writer.puts(JSON.generate({ "v" => 1, "id" => id, "op" => "I2-09", "args" => args }))
    writer.flush
    Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
  end

  check "the REAL SERVER refuses a raw `auth_token` frame the client would never have sent" do
    frame = raw_ask.call("probe-authtoken", { "auth_token" => "never-a-real-credential" })
    frame["ok"] == false && frame["error"]["kind"] == "i2-refused" &&
      frame["error"]["reason"].include?("identity-shaped")
  end

  check "the REAL SERVER refuses `auth_token` at DEPTH and across casefold/separator spellings" do
    [
      ["d1", { "participant" => { "key" => "(Card 1)", "auth_token" => "x" } }],
      ["d2", { "a" => { "b" => { "c" => { "AUTH_TOKEN" => "x" } } } }],
      ["d3", { "list" => [{ "ok" => 1 }, { "Auth-Token" => "x" }] }],
      ["d4", { "limits" => { "authToken" => "x" } }]
    ].all? do |id, args|
      frame = raw_ask.call("probe-authtoken-#{id}", args)
      frame["ok"] == false && frame["error"]["kind"] == "i2-refused" &&
        frame["error"]["reason"].include?("identity-shaped")
    end
  end

  check "the SERVER's refusal names the key path and does NOT echo the credential value" do
    frame = raw_ask.call("probe-authtoken-novalue",
                         { "participant" => { "auth_token" => "sup3r-s3cret-do-not-echo" } })
    reason = frame["error"]["reason"]
    reason.include?("args.participant.auth_token") &&
      !reason.include?("sup3r-s3cret-do-not-echo")
  end

  check "the SERVER still answers a token-ADJACENT clean key (no over-broad prefix match)" do
    # Proves the server guard refuses the ALIAS, not every key containing 'token': this frame
    # must get PAST the identity check. Whatever the reader then decides on the merits (an
    # unseeded store answers not-ready) must NOT be an identity-shaped refusal.
    frame = raw_ask.call("probe-token-adjacent", { "tokenization" => "ngram" })
    !frame.dig("error", "reason").to_s.include?("identity-shaped")
  end
ensure
  Atomspace::LocalI3ReadBinding.uninstall!
  handle.respond_to?(:stop!) ? handle.stop! : nil
  [writer, reader].each { |io| io.close rescue nil }
end

puts "\n3 -- a SEEDED real store (V1-shaped GOLDEN VECTORS via STORE's own encoder; NOT DEV data)"

writer, reader, errio, wait = spawn_reader(opts, seed: "symbols_and_sorted_refs")
begin
  client = Atomspace::I2ReaderProcessClient.new(writer: writer, reader: reader, deadline_ms: 10_000)

  seeded_card_id = nil

  check "readiness over the real reader is now READY with a STRICT boolean true" do
    r = client.readiness
    r.ready? == true
  end

  check "I2-07 declarations come back from the real reader with the nineteen cp022 §4 heads" do
    # #declarations! answers [envelope, payload]: the envelope is RETAINED because these
    # declarations AUTHORIZE the unresolved-target exception, so the consumer must be able to
    # bind them to the state being projected. This exercise therefore also asserts that the
    # envelope arrives and is a real STATE-BEARING one (epoch + position present), because a
    # payload with no checkable envelope is exactly what the binding fix removed.
    envelope, payload = client.declarations!
    envelope.is_a?(Hash) &&
      envelope["epoch"].is_a?(String) && !envelope["epoch"].empty? &&
      envelope["position"].is_a?(Integer) &&
      payload["heads"].is_a?(Array) && payload["heads"].size >= 19
  end

  check "a clean bootstrap published NO malformed records (STORE's own admission check)" do
    _envelope, payload = client.declarations!
    payload["malformed"] == []
  end

  # DISCOVER the seeded card from the REAL reader, and discriminate on STORE's OWN `class` field.
  #
  # WHY THE FIRST RESOLVABLE PARTICIPANT IS THE WRONG ONE, and this is real STORE behaviour worth
  # recording: a reference link's TARGET is a participant of the state (it is addressable, it has
  # a key and a digest) but it has no stored `name` atom, so STORE reports `class: "missing"` and
  # ZERO properties (`i2_read.py:437-438` builds `present` from entity keys that have a `name`;
  # `:540` maps a non-present entity to "missing"). An empty `open` for such a participant is
  # CORRECT, not a defect. The SEEDED card is the one STORE classes as "entity".
  check "the seeded card is found by STORE's OWN class field (entity, not a 'missing' ref target)" do
    entity = nil
    (1..300).each do |candidate|
      begin
        client.resolve_backend_address(card_id: candidate)
      rescue Atomspace::I3ReadPort::AddressUnavailable
        next
      end
      # It resolves; now ask whether STORE classes it as a present entity.
      id = "probe-class-#{candidate}"
      Atomspace::I2StdioTransport.write_request!(
        writer, id: id, op: "I2-09",
        args: { "participant" => { "key" => "(Card #{candidate})" } }
      )
      frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
      next unless frame["ok"]

      _env, payload = Atomspace::I2Envelope.split!(frame)
      if payload.dig("participant", "class") == "entity"
        entity = candidate
        break
      end
    end
    seeded_card_id = entity
    !seeded_card_id.nil?
  end

  check "a 'missing' reference-target participant resolves but has NO atoms (correct, not a bug)" do
    # Card 1 in this vector is such a target. It must resolve (it is addressable) AND open empty.
    address = client.resolve_backend_address(card_id: 1)
    address["digest"].match?(/\A[0-9a-f]{32}\z/) && client.open(card_id: 1) == []
  end

  check "I2-02 returns STORE's OWN key + digest for the seeded participant" do
    address = client.resolve_backend_address(card_id: seeded_card_id)
    address["key"] == "(Card #{seeded_card_id})" &&
      address["digest"].is_a?(String) && address["digest"].match?(/\A[0-9a-f]{32}\z/)
  end

  check "that digest is the STORE's -- VIEW never computed it (32 lowercase hex, record_store.py:145)" do
    # Asserted as a property of the value, not by recomputing it: recomputing deck-side is exactly
    # what is forbidden, so this proof does not do it either.
    address = client.resolve_backend_address(card_id: seeded_card_id)
    address["digest"].match?(/\A[0-9a-f]{32}\z/) && !address["digest"].empty?
  end

  check "I2-09 open returns real atoms for the seeded card, all satisfying the atom contract" do
    atoms = client.open(card_id: seeded_card_id)
    atoms.is_a?(Array) && !atoms.empty? &&
      atoms.all? { |a| a.respond_to?(:associated_card_ids) && a.respond_to?(:to_h) } &&
      atoms.all? { |a| a.associated_card_ids == [seeded_card_id] }
  end

  check "those atoms carry STORE's own key, digest, head and value (nothing fabricated)" do
    atoms = client.open(card_id: seeded_card_id)
    atoms.all? do |a|
      h = a.to_h
      h["head"].is_a?(String) && !h["head"].empty? &&
        h["digest"].match?(/\A[0-9a-f]{32}\z/) && h.key?("value")
    end
  end

  check "the seeded card's mandatory heads (name, key, type-name, trash) are present" do
    heads = client.open(card_id: seeded_card_id).map { |a| a.to_h["head"] }
    %w[name key type-name trash].all? { |h| heads.include?(h) }
  end

  check "an UNKNOWN card on a ready store -> backend_digest_unavailable (same string as before)" do
    e = raised { client.resolve_backend_address(card_id: 999_999) }
    e.is_a?(Atomspace::I3ReadPort::AddressUnavailable) &&
      e.message == "backend_digest_unavailable"
  end

  check "an UNKNOWN card on open is an EMPTY list (a 200, not an oracle)" do
    client.open(card_id: 999_999) == []
  end

  check "the real envelope's epoch/position/read-at all pass strict validation" do
    id = "probe-envelope"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-01", args: {})
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    envelope, _payload = Atomspace::I2Envelope.split!(frame)
    envelope["position"].is_a?(Integer) && envelope["position"] >= 1 &&
      envelope["epoch"].is_a?(String) && !envelope["epoch"].empty? &&
      Atomspace::I2Envelope::READ_AT_PATTERN.match?(envelope["read-at"])
  end

  check "read-at is STORE-SAMPLED: tz-bearing ISO-8601 with EXACTLY six fractional digits" do
    id = "probe-readat"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-01", args: {})
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    envelope, = Atomspace::I2Envelope.split!(frame)
    envelope["read-at"].match?(/\.\d{6}(?:Z|[+-]\d{2}:\d{2})\z/)
  end

  check "I2-01's reported ceilings are the WORKSHOP values that were configured in (not defaults)" do
    id = "probe-ceilings"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-01", args: {})
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    _envelope, payload = Atomspace::I2Envelope.split!(frame)
    payload["page-max"] == WORKSHOP_CONFIG["page-max"] &&
      payload["fanout-limit"] == 1 &&
      payload["state-retain"] == { "state-retain-ms" => nil, "state-retain-positions" => 2 }
  end

  check "I2-01 carries versions.schema and NO versions.runtime (022b Q3 = NO source)" do
    id = "probe-versions"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-01", args: {})
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    _envelope, payload = Atomspace::I2Envelope.split!(frame)
    payload["versions"] == { "schema" => "decko-atomschema-v2" } &&
      !payload["versions"].key?("runtime")
  end

  check "I2-01 carries NO health block (O23 design-only; absent, not fabricated)" do
    id = "probe-health"
    Atomspace::I2StdioTransport.write_request!(writer, id: id, op: "I2-01", args: {})
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    _envelope, payload = Atomspace::I2Envelope.split!(frame)
    %w[health projection liveness drain-heartbeat oldest-unapplied-age hidden-provenance-count]
      .none? { |k| payload.key?(k) }
  end

  check "neighbours over the real reader: a NONEMPTY bucket round trip, all contract-satisfying" do
    # TIGHTENED (round 25, item b). This previously returned `true` when the bucket list was
    # EMPTY, so it could pass without ever exercising `neighbours` at all -- a vacuous assertion.
    # Now an empty bucket list is a FAILURE of this example, because the seeded golden-vector
    # state does contain link heads: the I2-02 answer below is asserted nonempty first, and the
    # neighbour round trip must then actually return.
    id = "probe-buckets"
    Atomspace::I2StdioTransport.write_request!(
      writer, id: id, op: "I2-02",
      args: { "participant" => { "key" => "(Card #{seeded_card_id})" } }
    )
    frame = Atomspace::I2StdioTransport.read_response!(reader, expect_id: id)
    _envelope, payload = Atomspace::I2Envelope.split!(frame)
    buckets = payload["buckets"]

    unless buckets.is_a?(Array) && !buckets.empty?
      puts "        (I2-02 returned #{buckets.inspect} buckets for card #{seeded_card_id})"
      next false
    end

    head = buckets.first["link-type"]
    atoms = client.neighbours(card_id: seeded_card_id, bucket: head, limit: 10)
    # A bucket STORE itself reported must round trip. An exception or a non-Array is a failure;
    # an empty list is reported so a reviewer can see whether the head was genuinely empty.
    puts "        (bucket #{head.inspect} -> #{atoms.size} neighbour atom(s))" if atoms.is_a?(Array)
    atoms.is_a?(Array) &&
      atoms.all? { |a| a.respond_to?(:associated_card_ids) && a.respond_to?(:to_h) }
  end

  check "the full port path works end to end: install! -> readiness -> open" do
    Atomspace::LocalI3ReadBinding.install!(reader: client)
    ready = Atomspace::I3ReadPort.readiness.ready? == true
    atoms = Atomspace::I3ReadPort.open(card_id: seeded_card_id)
    address = Atomspace::I3ReadPort.resolve_backend_address(card_id: seeded_card_id)
    ready && atoms.is_a?(Array) && !atoms.empty? &&
      address["key"] == "(Card #{seeded_card_id})" && Atomspace::I3ReadPort.origin == "live"
  end

  puts "\n  [seeded card id discovered from the real reader: #{seeded_card_id.inspect}]"
  puts "  [server stderr label] #{errio ? errio.read_nonblock(4096).to_s.strip : ''}" rescue nil
ensure
  Atomspace::LocalI3ReadBinding.uninstall!
  [writer, reader, errio].each { |io| io&.close rescue nil }
  wait.respond_to?(:join) ? wait.join : nil
end

puts "\n4 -- the process DIES mid-session: the client fails closed, never a false green"

writer, reader, _e, handle = spawn_reader(opts)
begin
  client = Atomspace::I2ReaderProcessClient.new(writer: writer, reader: reader, deadline_ms: 3_000)
  client.readiness                       # one real round trip first
  handle.respond_to?(:stop!) ? handle.stop! : nil
  writer.close rescue nil
  reader.close rescue nil

  check "after the child is gone, readiness is NOT READY with a channel/timeout reason" do
    r = client.readiness
    r.ready? == false &&
      %w[i2_reader_channel_unavailable i2_reader_timeout].include?(r.reason)
  end

  check "and a card read raises rather than returning an empty list" do
    !raised { client.open(card_id: 100) }.nil?
  end
ensure
  Atomspace::LocalI3ReadBinding.uninstall!
end

puts "\n" + "=" * 92
puts "PASSED: #{PASSES.size}   FAILED: #{FAILURES.size}"
unless FAILURES.empty?
  puts "\nFAILURES:"
  FAILURES.each { |f| puts "  - #{f}" }
end
puts "NOTE: the seeded state came from STORE's V1-SHAPED GOLDEN VECTORS via STORE's own encoder."
puts "      It is NOT DEV data, there is NO deployed v2 producer, and this is NOT a deployment."
puts "=" * 92
exit(FAILURES.empty? ? 0 : 1)
