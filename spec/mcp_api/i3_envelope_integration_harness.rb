# frozen_string_literal: true

# ============================================================================================
# I3 ENVELOPE INTEGRATION HARNESS -- the REAL controller file, the REAL STORE child, and the
# REAL av-client parser.
# ============================================================================================
#
# WHAT THIS PROVES, and the three words that matter are REAL, ACTUAL and SERIALIZED:
#
#   1. It `require`s the ACTUAL shipped controller source
#      `mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb` -- not a copy, not a
#      re-implementation, not an extracted method. The file's own `require_relative`s pull in the
#      real I3ReadPort, I3Envelope, I3ReadResult, LocalI3ReadBinding and I2ReaderProcessClient.
#   2. It invokes the ACTUAL handler methods (`#lookup`, `#open`, `#neighbours`) on a real instance
#      of that class, so the real renderer path (`render_card_scoped` -> `render_i3` ->
#      `Atomspace::I3Envelope.compose`) executes.
#   3. It captures what the controller passed to `render json:` and SERIALIZES it, then writes the
#      bytes to disk for av-client's REAL parser to consume. Key order is preserved end to end
#      (Ruby hashes are insertion-ordered and so is JSON.generate), which is the property
#      LIVE-TRANSPORT.md:163-165 calls load-bearing.
#   4. The STORE side is a REAL child process: a real `i2_stdio_reader_service.py` spawned over
#      real STDIO, projecting the REAL ATTESTED two-card export
#      (`card-export.json`, sha256 f78ae2a6...22614, 1463 B, ids [1,2]). No fixture store, no
#      golden vectors, no `--seed-from-golden-vectors`.
#
# WHAT IT HONESTLY DOES NOT PROVE -- stated here, not buried:
#
#   * NO RAILS IS BOOTED. `bundle check` reports ~40 missing gems (decko 0.20.0, card 1.110.0,
#     actionpack 7.2.3.1, ...) so `bundle exec rspec` is UNRUNNABLE in this worktree. This harness
#     supplies MINIMAL STUBS for the ActionController class-level DSL and for Card/Card::Auth.
#     Therefore:
#       - the FILTER CHAIN does not run. Authentication, the session/token principal gates, the
#         scope gate and `require_i3_backend_ready!` are NOT exercised here. They are exercised by
#         `i3_session_auth_harness.rb` and `local_authorization_harness.rb`.
#       - ACL DECISIONS are stubbed. `readable_card?` is driven by an explicit allow-set in this
#         harness. The real multi-card default-deny filter logic is exercised by
#         `local_authorization_harness.rb`.
#     This harness's claim is narrow and specific: THE ENVELOPE AND ITS SERIALIZED BYTES ARE
#     CONTRACT-CONFORMING ACCORDING TO THE REAL CLIENT PARSER. It claims nothing about auth.
#   * It is NOT a Rails request spec. No HTTP, no routing, no middleware, no PG.
#
# USAGE:
#   ruby spec/mcp_api/i3_envelope_integration_harness.rb \
#     --interpreter <ABS python> --script <ABS i2_stdio_reader_service.py> \
#     --sidecar <ABS sidecar parent dir> --export <ABS card-export.json> \
#     --out <ABS dir for the captured response bytes>
#
#   Omit --interpreter/--script to run the NO-STATE-ONLY subset (no STORE child).

require "json"
require "digest"
require "optparse"
require "fileutils"
require "tmpdir"

# -------------------------------------------------------------------- minimal ActiveSupport shims
unless Object.new.respond_to?(:present?)
  class Object
    def blank? = respond_to?(:empty?) ? !!empty? : !self
    def present? = !blank?
    def presence = present? ? self : nil
  end

  class NilClass
    def blank? = true
    def present? = false
    def presence = nil
  end

  class String
    def blank? = strip.empty?
  end
end

# ActiveSupport::Concern stand-in: `include`-time `included do ... end` is not used by the two
# concerns this harness loads, so a module that just supports `extend` is sufficient.
module ActiveSupport
  module Concern
    def self.extended(_base); end
    def included(base = nil, &block)
      return super if base.nil? && block.nil?

      super
    end
  end
end

# ---------------------------------------------------------------------------- Rails/Card stubs
module Rails
  class NullLogger
    def initialize = @lines = []
    attr_reader :lines
    def warn(m) = @lines << [:warn, m.to_s]
    def error(m) = @lines << [:error, m.to_s]
    def info(m) = @lines << [:info, m.to_s]
    def debug(m) = @lines << [:debug, m.to_s]
  end

  def self.logger = (@logger ||= NullLogger.new)
end

# A deliberately tiny Card stand-in. It exists ONLY so the real controller's name-resolution and
# read-filter calls have something to call; it makes NO claim to model Decko's ACL semantics.
class Card
  class Error < StandardError
    class PermissionDenied < Error; end
  end

  ALL = {}

  attr_reader :id, :name, :read_rule_id

  def initialize(id:, name:, readable: true)
    @id = id
    @name = name
    @read_rule_id = 1
    @readable = readable
  end

  def new_card? = false
  def ok?(_action) = @readable
  def to_s = @name

  def self.reset!
    ALL.clear
  end

  def self.seed(id:, name:, readable: true)
    card = new(id: id, name: name, readable: readable)
    ALL[id] = card
    ALL[name] = card
    ALL[name.downcase.gsub(/[^a-z0-9]+/, "_")] = card
    card
  end

  def self.fetch(ref, *)
    return ALL[ref] if ALL.key?(ref)
    return nil unless ref.is_a?(String)

    ALL[ref.downcase.gsub(/[^a-z0-9]+/, "_")]
  end

  module Auth
    class << self
      attr_accessor :current_id

      def as(_name)
        block_given? ? yield : nil
      end

      def signed_in? = true
      def reset(*) = nil
    end
  end

  module Env
    def self.reset(*) = nil
  end
end

module Atomspace
  module Observability
    def self.alert(**_kwargs) = nil
  end
end

# ------------------------------------------------------- minimal ActionController::API stand-in
#
# RECORDS the class-level DSL instead of executing it. The callback chain is therefore NOT run --
# disclosed in the header. `render` captures, so the body the real controller produced is
# inspectable byte-for-byte.
module ActionController
  class API
    class << self
      def _recorded_callbacks = (@_recorded_callbacks ||= [])
      def _rescue_handlers = (@_rescue_handlers ||= [])

      def before_action(*args, **opts) = _recorded_callbacks << [:before, args, opts]
      def after_action(*args, **opts) = _recorded_callbacks << [:after, args, opts]
      def around_action(*args, **opts) = _recorded_callbacks << [:around, args, opts]
      def prepend_around_action(*args, **opts) = _recorded_callbacks << [:prepend_around, args, opts]

      # Mirrors the real semantics closely enough for the load to succeed, and still FAILS LOUD if
      # the named parent filter is absent -- the property the controller's own comment relies on.
      def skip_before_action(name, **opts)
        inherited_names = ancestors.flat_map do |a|
          a.respond_to?(:_recorded_callbacks) ? a._recorded_callbacks.map { |(_, args, _)| args } : []
        end.flatten
        unless inherited_names.include?(name) || opts[:raise] == false
          raise ArgumentError, "cannot skip undefined callback #{name}"
        end

        _recorded_callbacks << [:skip_before, [name], opts]
      end

      def rescue_from(*classes, with:) = _rescue_handlers << [classes, with]
      def helper_method(*) = nil
      def respond_to(*) = nil
    end

    attr_reader :rendered, :rendered_status, :params, :request
    attr_accessor :action_name

    def initialize(params: {}, headers: {})
      @params = StubParams.new(params)
      @request = StubRequest.new(headers)
      @rendered = nil
      @rendered_status = nil
      @performed = false
      # The real Rails attribute the controller's own filters read (`require_i3_backend_ready!`
      # exempts `health` by name). The stub defaults it to the handler under test, set by Rig.
      @action_name = nil
    end

    def render(json: nil, status: :ok, **_rest)
      raise "double render" if @performed

      @performed = true
      @rendered = json
      @rendered_status = status
      json
    end

    def performed? = @performed
    def controller_name = self.class.name.split("::").last.sub(/Controller\z/, "").downcase

    class StubParams
      def initialize(h) = @h = h.transform_keys(&:to_sym)
      def [](k) = @h[k.to_sym]
      def require(k) = (@h.fetch(k.to_sym) { raise "param missing #{k}" })
      def to_unsafe_h = @h
    end

    class StubRequest
      def initialize(h) = @headers = h
      def headers = @headers
      def env = @headers
      def remote_ip = "127.0.0.1"
      def ip = "127.0.0.1"
      def ssl? = true
    end
  end
end

module RateLimitable; end

# -------------------------------------------------------------------- load the REAL source files
ROOT = File.expand_path("../..", __dir__)
MOD = File.join(ROOT, "mod/mcp_api")
LIB = File.join(MOD, "lib")

require File.join(LIB, "atomspace/errors")
require File.join(LIB, "atomspace/mirror_readiness")
require File.join(LIB, "atomspace/i2_envelope")
require File.join(LIB, "atomspace/i3_read_result")
require File.join(LIB, "atomspace/i3_envelope")
require File.join(LIB, "atomspace/i3_read_port")
require File.join(LIB, "atomspace/fixture_i3_read_port")
require File.join(LIB, "atomspace/i2_stdio_transport")
require File.join(LIB, "atomspace/i2_reader_process_client")
require File.join(LIB, "atomspace/local_i3_read_binding")

# A BaseController stand-in that registers the parent filter the real subclass skips, so the
# subclass's `skip_before_action :authenticate_mcp_request!` resolves exactly as it must.
module Api
  module Mcp
    class BaseController < ActionController::API
      include RateLimitable
      before_action :set_mcp_thread_flag
      before_action :authenticate_mcp_request!, unless: :auth_endpoint?
      after_action :clear_mcp_thread_flag
      rescue_from StandardError, with: :handle_error

      private

      def set_mcp_thread_flag = nil
      def clear_mcp_thread_flag = nil
      def auth_endpoint? = false
      def authenticate_mcp_request! = nil
      def handle_error(_e) = nil
      def render_unauthorized(_m) = nil
      def extract_token_from_header = nil
      def verify_token(_t) = nil
      def find_mcp_account(_p) = nil
    end
  end
end

# THE ACTUAL SHIPPED CONTROLLER FILE. Loaded unmodified.
CONTROLLER_PATH = File.join(MOD, "app/controllers/api/mcp/i3_read_controller.rb")
require CONTROLLER_PATH

# ------------------------------------------------------------------------------------ test rig
class Rig
  attr_reader :failures, :checks, :captured

  def initialize(out_dir)
    @failures = []
    @checks = 0
    @captured = []
    @out_dir = out_dir
    FileUtils.mkdir_p(@out_dir)
  end

  def check(label)
    @checks += 1
    ok, detail = yield
    if ok
      puts "  PASS  #{label}"
    else
      puts "  FAIL  #{label}#{detail ? " -- #{detail}" : ''}"
      @failures << label
    end
  rescue StandardError => e
    puts "  FAIL  #{label} -- raised #{e.class}: #{e.message}"
    puts "        #{e.backtrace.first(4).join("\n        ")}"
    @failures << label
  end

  # Invoke a REAL handler on a REAL controller instance and capture the SERIALIZED bytes.
  def invoke(endpoint_id, action, params: {}, account_name: "Nemquae", readable_ids: nil, label: nil)
    ctrl = Api::Mcp::I3ReadController.new(params: params)
    ctrl.action_name = action.to_s
    ctrl.instance_variable_set(:@current_mcp_account, OpenStructLite.new(name: account_name))
    ctrl.instance_variable_set(:@harness_readable_ids, readable_ids)
    begin
      ctrl.send(action)
    rescue StandardError => e
      handler = resolve_rescue(e)
      raise unless handler

      # SURFACE THE EXCEPTION THE LAST-RESORT HANDLER SWALLOWS. `render_unexpected_error` renders a
      # fixed body with nothing derived from the exception (correctly -- it must not disclose), so
      # without this line a harness failure on that path reports only "i3_unexpected_error" and is
      # undiagnosable. Printed to the harness's own stdout, never to a captured body.
      if handler.to_s == "render_unexpected_error"
        puts "        [harness] UNEXPECTED #{e.class}: #{e.message}"
        puts "        [harness]   #{Array(e.backtrace).first(5).join("\n        [harness]   ")}"
      end
      ctrl.send(handler, e)
    end
    body = ctrl.rendered
    status = ctrl.rendered_status
    # SERIALIZE exactly as the response would be: JSON.generate preserves Ruby's insertion order.
    bytes = JSON.generate(body)
    name = label || "#{action}"
    path = File.join(@out_dir, "#{name}.json")
    File.binwrite(path, bytes)
    rec = { "endpointId" => endpoint_id, "label" => name, "status" => status.to_s,
            "path" => path, "bytes" => bytes.bytesize,
            "sha256" => Digest::SHA256.hexdigest(bytes) }
    @captured << rec
    [body, bytes, status, rec]
  end

  def resolve_rescue(exception)
    Api::Mcp::I3ReadController._rescue_handlers.reverse_each do |(classes, handler)|
      return handler if classes.any? { |c| exception.is_a?(c) }
    end
    nil
  end

  def write_manifest
    path = File.join(@out_dir, "captured-responses.json")
    File.binwrite(path, JSON.pretty_generate(@captured))
    path
  end
end

class OpenStructLite
  def initialize(**kw) = @kw = kw
  def name = @kw[:name]
end

# The harness drives ACL through an explicit allow-set so the ENVELOPE is what is under test.
module Api
  module Mcp
    class I3ReadController
      def readable_card?(card)
        return false if card.nil?

        ids = instance_variable_get(:@harness_readable_ids)
        return card.ok?(:read) if ids.nil?

        ids.include?(card.id) && card.ok?(:read)
      end
    end
  end
end

# =================================================================================== the run
opts = { out: File.join(Dir.tmpdir, "i3-envelope-harness") }
OptionParser.new do |o|
  o.on("--interpreter PATH") { |v| opts[:interpreter] = v }
  o.on("--script PATH") { |v| opts[:script] = v }
  o.on("--sidecar PATH") { |v| opts[:sidecar] = v }
  o.on("--export PATH") { |v| opts[:export] = v }
  o.on("--out PATH") { |v| opts[:out] = v }
  # WHERE THE CLIENT-SIDE ACCEPTANCE ARTEFACT GOES. Defaults to the export's own directory (the
  # `i3real` scratch dir the attested export and the real STORE probe already live in), so the
  # path is DERIVED from --export rather than hardcoded; overridable for a different consumer.
  o.on("--bodies-dir PATH") { |v| opts[:bodies_dir] = v }
end.parse!

rig = Rig.new(opts[:out])
puts "I3 ENVELOPE INTEGRATION HARNESS"
puts "  controller source : #{CONTROLLER_PATH}"
puts "  controller sha256 : #{Digest::SHA256.file(CONTROLLER_PATH).hexdigest}"
puts "  out dir           : #{opts[:out]}"
puts

# ---------------------------------------------------------------- PART 1: NO-STATE FAILURE PATH
#
# THE PORT IS UNWIRED -- nothing is bound at all. This is the ENUMERATED OUTCOME `unavailable`,
# NOT a refusal, and it therefore owes the caller a FULL CONFORMING ENVELOPE.
#
# These two checks previously asserted a 503 non-envelope body
#   {"error":"i3_backend_unavailable","reason":"i3_read_port_unwired","_meta":{...}}
# and that body was PROVEN non-conforming by av-client's REAL `checkI3Body`, which rejected it
# with LiveProtocolViolation on its first assertion (no top-level `outcome`). The assertions are
# REPLACED WITH STRICTER ONES, not relaxed:
#   * K8 §5.1 `:289-291` scopes "refusal" to a K9 ACCESS decision only -- "Refusal is K9's, not
#     K8's" -- so an unreachable backend is not a refusal;
#   * K8 §5.3 `:487` enumerates it: `unavailable` = "the store could not be reached or could not
#     answer";
#   * K8 §5.2 `:300` is EXACT that "Every response, including every failure that is not a refusal,
#     begins with" the six-field envelope, and `:390-392` that on the no-state outcomes "epoch,
#     position and read-at are all three PRESENT ... uniform across all nine outcomes";
#   * the status must be 200, because the client's `classifyHttp` (`live-bridge.mjs:821`) turns any
#     `status >= 500` into `backend-error` and throws BEFORE parsing, which would make the
#     contract-required outcome invisible.
# Every property the old checks asserted is still asserted here -- the unwired REASON is still
# required on the body, and `data_origin` is still required to be "unavailable" -- plus the whole
# envelope contract the old body violated.
puts "PART 1 -- UNWIRED PORT => the ENUMERATED `unavailable` OUTCOME, in band (not a refusal)"
Atomspace::I3ReadPort.reset!
Card.reset!
Card.seed(id: 1, name: "Decko Bot")

# The six envelope fields, all three state nulls PRESENT, and the provenance stamp. Shared by both
# unwired checks so neither can drift from the other.
assert_unavailable_envelope = lambda do |bytes, status|
  parsed = JSON.parse(bytes)
  problems = []
  problems << "status=#{status.inspect} (must be :ok -- a >=500 is unparseable by the client)" unless status == :ok
  problems << "outcome=#{parsed['outcome'].inspect}" unless parsed["outcome"] == "unavailable"
  Atomspace::I3Envelope::STATE_KEYS.each do |k|
    problems << "#{k} ABSENT (must be present)" unless parsed.key?(k)
    problems << "#{k}=#{parsed[k].inspect} (must be exactly null)" unless parsed[k].nil?
  end
  problems << "schema-version ABSENT" unless parsed.key?("schema-version")
  problems << "limits ABSENT" unless parsed.key?("limits")
  # The six envelope fields FIRST, in K8 §5.2 row order -- the diagnostic sibling must not displace
  # them (LIVE-TRANSPORT.md:163-165 compares key order).
  unless parsed.keys.first(6) == Atomspace::I3Envelope::FIELDS
    problems << "envelope key order is #{parsed.keys.first(6).inspect}"
  end
  # A known bootstrap epoch must never be reported here (k8-draft-2.md:398-402). Covered by the
  # explicit-null assertions above; restated so the intent is not lost.
  problems << "health must be OMITTED, not null" if parsed.key?("health")
  [problems.empty?, problems.join("; ")]
end

rig.check("unwired lookup: 200 + outcome 'unavailable' + conforming envelope (NOT a 503 refusal)") do
  _b, bytes, status, = rig.invoke("I3-10", :lookup, params: { name: "Decko Bot" },
                                                    label: "nostate-lookup")
  ok, detail = assert_unavailable_envelope.call(bytes, status)
  parsed = JSON.parse(bytes)
  # The operator-facing unwired reason is PRESERVED, as a NON-envelope sibling AFTER the six.
  unless parsed["reason"] == Atomspace::I3ReadPort::UNWIRED_REASON
    ok = false
    detail = "#{detail}; reason=#{parsed['reason'].inspect} (expected #{Atomspace::I3ReadPort::UNWIRED_REASON.inspect})"
  end
  [ok, "#{detail} body=#{bytes}"]
end

rig.check("unwired open: 200 + outcome 'unavailable' + the unwired reason as a non-envelope sibling") do
  _b, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" }, readable_ids: [1],
                                                  label: "nostate-open")
  ok, detail = assert_unavailable_envelope.call(bytes, status)
  parsed = JSON.parse(bytes)
  unless parsed["reason"] == Atomspace::I3ReadPort::UNWIRED_REASON
    ok = false
    detail = "#{detail}; reason=#{parsed['reason'].inspect}"
  end
  [ok, "#{detail} body=#{bytes}"]
end

rig.check("unwired bodies stamp data_origin 'unavailable' and carry NO VIEW-stamped read-at") do
  offending = rig.captured.select { |c| c["label"].start_with?("nostate-") }.filter_map do |c|
    p = JSON.parse(File.binread(c["path"]))
    reasons = []
    reasons << "read-at=#{p['read-at'].inspect}" unless p["read-at"].nil?
    origin = p.dig("_meta", "data_origin")
    reasons << "data_origin=#{origin.inspect}" unless origin == "unavailable"
    [c["label"], reasons] if reasons.any?
  end
  [offending.empty?, offending.inspect]
end

puts
puts "PART 2 -- NO-STATE ENVELOPE (reader bound but STORE has no published state)"

# A reader that is BOUND and envelope-capable but reports a not-ready store. This is the
# "bound-but-no-state" case, which must produce a CONFORMING no-state ENVELOPE (three nulls),
# not a 503 and not a success default.
class NotReadyReader
  NOT_READY_ENVELOPE = {
    "outcome" => "not ready", "epoch" => nil, "position" => nil, "read-at" => nil
  }.freeze

  def origin = "live"
  def readiness = Atomspace::MirrorReadiness::READY
  def resolve_backend_address(card_id:) = raise(Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable")
  def open(card_id:) = []
  def neighbours(card_id:, bucket: nil, limit: nil) = []

  def lookup_reading(card_id:)
    Atomspace::I3ReadResult.new(envelope: NOT_READY_ENVELOPE)
  end

  def open_reading(card_id:)
    Atomspace::I3ReadResult.new(envelope: NOT_READY_ENVELOPE)
  end

  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    Atomspace::I3ReadResult.new(envelope: NOT_READY_ENVELOPE)
  end

  def store_profile = nil

  # STORE'S OWN `not ready` ANSWER, carried -- matching the REAL reader after this round's repair
  # (`i2_reader_process_client.rb#state_envelope` no longer discards it). This is what lets the
  # ACL-empty / lookup-miss paths report STORE's real outcome instead of VIEW guessing one.
  def state_envelope = NOT_READY_ENVELOPE
end

Atomspace::LocalI3ReadBinding.install!(reader: NotReadyReader.new)

rig.check("no-state open: 200 with outcome 'not ready' and all three nulls PRESENT") do
  body, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" }, readable_ids: [1],
                                                    label: "notready-open")
  parsed = JSON.parse(bytes)
  [status == :ok && parsed["outcome"] == "not ready" &&
     parsed.key?("epoch") && parsed["epoch"].nil? &&
     parsed.key?("position") && parsed["position"].nil? &&
     parsed.key?("read-at") && parsed["read-at"].nil? &&
     parsed.key?("schema-version") && parsed.key?("limits"),
   "status=#{status.inspect} body=#{bytes}"]
end

rig.check("no-state lookup: 200, outcome 'not ready', no fabricated key/digest") do
  body, bytes, status, = rig.invoke("I3-10", :lookup, params: { name: "Decko Bot" },
                                                      label: "notready-lookup")
  parsed = JSON.parse(bytes)
  [status == :ok && parsed["outcome"] == "not ready" &&
     !parsed.key?("key") && !parsed.key?("digest"),
   "status=#{status.inspect} body=#{bytes}"]
end

rig.check("no-state neighbours: 200, outcome 'not ready'") do
  body, bytes, status, = rig.invoke("I3-03", :neighbours,
                                    params: { id: "1", bucket: "refers_to" },
                                    readable_ids: [1], label: "notready-neighbours")
  parsed = JSON.parse(bytes)
  [status == :ok && parsed["outcome"] == "not ready", "status=#{status.inspect} body=#{bytes}"]
end

rig.check("NO VIEW-STAMPED read-at anywhere in the no-state bodies") do
  offending = rig.captured.select { |c| c["label"].start_with?("notready-") }.reject do |c|
    JSON.parse(File.binread(c["path"]))["read-at"].nil?
  end
  [offending.empty?, offending.inspect]
end

# ------------------------------------------------- PART 2b: THE READINESS FILTER, EXERCISED FOR REAL
#
# WHY THIS CASE WAS ADDED. The reviewer correctly observed that NotReadyReader above reports
# `readiness = READY`, so `require_i3_backend_ready!` ALWAYS passed and the readiness path was
# never executed by this harness at all. That filter used to render a NON-ENVELOPE 503
#   {"error":"i3_backend_not_ready","reason":...,"_meta":{...}}
# which the real client discards before parsing (`live-bridge.mjs:821` maps >=500 to
# backend-error). It now renders the `not ready` ENVELOPE through the same shared renderer, and
# that claim is worthless unless the filter actually runs. So this reader reports NOT READY.
#
# THE FILTER IS INVOKED EXPLICITLY, AND THE HARNESS SAYS SO. No Rails callback chain exists here
# (see the header), so `require_i3_backend_ready!` is CALLED DIRECTLY on a real controller instance
# -- the real method, on the real class, rendering through the real renderer. What this does NOT
# prove is the CHAIN ORDER (that principal+scope run first); that remains Rails-boot territory and
# is listed as an unverified gap.
puts
puts "PART 2b -- THE READINESS FILTER itself: NOT-READY backend => the `not ready` ENVELOPE, not a 503"

class NotReadyBackendReader < NotReadyReader
  # STORE'S OWN NO-STATE REASON, not an invented string. This fixture previously used
  # `"i3_mirror_not_ready"`, which EXISTS NOWHERE in production code -- a grep finds it only in
  # this harness. With the readiness classification now in place (see
  # I3ReadController#readiness_outcome_for) an unrecognised reason FAILS CLOSED to `unavailable`,
  # which is the correct and intended behaviour, so a fabricated reason can no longer stand in for
  # a store answer. The real constant is used instead: `REASON_STORE_NOT_READY`
  # (`i2_reader_process_client.rb:113`) is set at `:200-202` from STORE's OWN I2-01 envelope
  # reporting `not ready`, which is exactly the condition `k8-draft-2.md:486` describes.
  #
  # EVERY ASSERTION IN THE CHECK BELOW IS UNCHANGED -- same 200, same three present nulls, same
  # envelope key order, same post-envelope `reason` sibling, same "no legacy `error` key". Only the
  # fixture's reason string changed, from one that named no real condition to one that does.
  NOT_READY_REASON = Atomspace::I2ReaderProcessClient::REASON_STORE_NOT_READY

  # The ONLY difference from NotReadyReader: readiness reports FALSE, so the readiness filter
  # halts the request instead of passing it to a handler.
  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: NOT_READY_REASON)
  end
end

Atomspace::LocalI3ReadBinding.install!(reader: NotReadyBackendReader.new)

rig.check("readiness filter: 200 + outcome 'not ready' + three nulls PRESENT (NOT a 503 wrapper)") do
  ctrl = Api::Mcp::I3ReadController.new(params: { id: "1" })
  ctrl.instance_variable_set(:@current_mcp_account, OpenStructLite.new(name: "Nemquae"))
  ctrl.send(:require_i3_backend_ready!)
  bytes = JSON.generate(ctrl.rendered)
  status = ctrl.rendered_status
  File.binwrite(File.join(opts[:out], "readiness-filter.json"), bytes)
  rig.captured << { "endpointId" => "I3-02", "label" => "readiness-filter",
                    "status" => status.to_s,
                    "path" => File.join(opts[:out], "readiness-filter.json"),
                    "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
  p = JSON.parse(bytes)
  problems = []
  problems << "status=#{status.inspect} (must be :ok)" unless status == :ok
  problems << "outcome=#{p['outcome'].inspect}" unless p["outcome"] == "not ready"
  %w[epoch position read-at].each do |k|
    problems << "#{k} ABSENT" unless p.key?(k)
    problems << "#{k}=#{p[k].inspect} not null" unless p[k].nil?
  end
  problems << "schema-version ABSENT" unless p.key?("schema-version")
  problems << "limits ABSENT" unless p.key?("limits")
  # The operator-facing reason is PRESERVED, as a POST-envelope sibling.
  unless p["reason"] == NotReadyBackendReader::NOT_READY_REASON
    problems << "reason=#{p['reason'].inspect}"
  end
  unless p.keys.first(6) == Atomspace::I3Envelope::FIELDS
    problems << "envelope key order=#{p.keys.first(6).inspect}"
  end
  # The old wrapper's `error` key must be GONE -- its presence would mean the 503 shape survived.
  problems << "legacy 'error' key still present" if p.key?("error")
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

# ----------------------------- PART 2b-split: UNREACHABLE vs NO-PUBLISHED-STATE, SEPARATED
#
# WHY THESE CASES WERE ADDED. The readiness filter above renders the `not ready` envelope, and the
# single check above proved only that ONE shape. But `require_i3_backend_ready!` used to end with a
# BARE `render_not_ready_envelope(result.reason)`, so EVERY non-ready readiness verdict was reported
# as `not ready` -- "no published state can be read yet" (`k8-draft-2.md:486`), which ASSERTS THE
# STORE ANSWERED. Most reasons that reach that filter assert no such thing:
#   * `i3_read_port.rb:72`  -- NO READER IS BOUND; no store was contacted at all;
#   * `i2_reader_process_client.rb:232-237` -- TIMEOUT / DEAD CHANNEL / unreadable frame;
#   * `i3_read_port.rb:76`, `:83` -- a MALFORMED readiness answer from the bound impl.
# `k8-draft-2.md:487` has the outcome that is TRUE of those: `unavailable`, "the store could not be
# reached or could not answer". Reporting them as `not ready` was a false statement about the store.
#
# These three checks assert the OUTCOME STRING for each class, which is the only thing that
# distinguishes the two no-state answers on the wire (both are 200 with three nulls).
puts
puts "PART 2b-split -- UNREACHABLE (`unavailable`) vs STORE'S OWN NO-STATE ANSWER (`not ready`)"

# Shared assertion: BOTH no-state classes must keep every structural property. Only the outcome
# differs, so everything else is checked identically for both and cannot drift apart.
assert_readiness_envelope = lambda do |bytes, status, expected_outcome, expected_reason, origin|
  p = JSON.parse(bytes)
  problems = []
  problems << "status=#{status.inspect} (must be :ok)" unless status == :ok
  problems << "outcome=#{p['outcome'].inspect} (expected #{expected_outcome.inspect})" unless p["outcome"] == expected_outcome
  %w[epoch position read-at].each do |k|
    problems << "#{k} ABSENT" unless p.key?(k)
    problems << "#{k}=#{p[k].inspect} not null" unless p[k].nil?
  end
  problems << "schema-version ABSENT" unless p.key?("schema-version")
  problems << "limits ABSENT" unless p.key?("limits")
  # The reason survives as a POST-envelope sibling on BOTH classes.
  problems << "reason=#{p['reason'].inspect} (expected #{expected_reason.inspect})" unless p["reason"] == expected_reason
  unless p.keys.first(6) == Atomspace::I3Envelope::FIELDS
    problems << "envelope key order=#{p.keys.first(6).inspect}"
  end
  problems << "legacy 'error' key still present" if p.key?("error")
  # `_meta` is PRESERVED on both, with the port's own provenance verdict.
  problems << "_meta ABSENT" unless p.key?("_meta")
  if origin
    problems << "data_origin=#{p.dig('_meta', 'data_origin').inspect}" unless p.dig("_meta", "data_origin") == origin
  end
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

# Drive the readiness filter on a real controller instance and capture what it rendered.
run_readiness_filter = lambda do |label|
  ctrl = Api::Mcp::I3ReadController.new(params: { id: "1" })
  ctrl.instance_variable_set(:@current_mcp_account, OpenStructLite.new(name: "Nemquae"))
  ctrl.send(:require_i3_backend_ready!)
  bytes = JSON.generate(ctrl.rendered)
  status = ctrl.rendered_status
  File.binwrite(File.join(opts[:out], "#{label}.json"), bytes)
  rig.captured << { "endpointId" => "I3-02", "label" => label,
                    "status" => status.to_s,
                    "path" => File.join(opts[:out], "#{label}.json"),
                    "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
  [bytes, status]
end

# (1) THE PORT IS UNWIRED -- nothing bound at all, so NOTHING was asked of any store. The readiness
# filter must report `unavailable`, NOT `not ready`.
rig.check("readiness filter, UNWIRED port: outcome 'unavailable' (NOT 'not ready') -- no store was asked") do
  Atomspace::I3ReadPort.reset!
  bytes, status = run_readiness_filter.call("readiness-filter-unwired")
  assert_readiness_envelope.call(bytes, status, "unavailable",
                                 Atomspace::I3ReadPort::UNWIRED_REASON, "unavailable")
end

# (2) A BOUND reader whose readiness probe reports the TIMEOUT / CHANNEL-DOWN class. The store was
# never reached, so `unavailable` is the true outcome.
class TimedOutReader < NotReadyReader
  TIMEOUT_REASON = Atomspace::I2ReaderProcessClient::REASON_TIMEOUT

  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: TIMEOUT_REASON)
  end
end

rig.check("readiness filter, READER TIMEOUT: outcome 'unavailable' (the store could not answer)") do
  Atomspace::LocalI3ReadBinding.install!(reader: TimedOutReader.new)
  bytes, status = run_readiness_filter.call("readiness-filter-timeout")
  assert_readiness_envelope.call(bytes, status, "unavailable",
                                 TimedOutReader::TIMEOUT_REASON, "live")
end

class ChannelDownReader < NotReadyReader
  DOWN_REASON = Atomspace::I2ReaderProcessClient::REASON_CHANNEL_DOWN

  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: DOWN_REASON)
  end
end

rig.check("readiness filter, CHANNEL DOWN: outcome 'unavailable' (the store could not be reached)") do
  Atomspace::LocalI3ReadBinding.install!(reader: ChannelDownReader.new)
  bytes, status = run_readiness_filter.call("readiness-filter-channel-down")
  assert_readiness_envelope.call(bytes, status, "unavailable",
                                 ChannelDownReader::DOWN_REASON, "live")
end

# (3) STORE'S OWN GENUINE NO-STATE ANSWER. The store WAS reached, it DID answer, and its answer was
# that it has no published, ready state (`i2_reader_process_client.rb:200-202`, from STORE's own
# I2-01 envelope). This -- and only this class -- is the outcome `not ready`.
class StoreSaysNoStateReader < NotReadyReader
  STORE_REASON = Atomspace::I2ReaderProcessClient::REASON_STORE_NOT_READY

  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: STORE_REASON)
  end
end

rig.check("readiness filter, STORE ANSWERED 'no published state': outcome 'not ready' (the store DID answer)") do
  Atomspace::LocalI3ReadBinding.install!(reader: StoreSaysNoStateReader.new)
  bytes, status = run_readiness_filter.call("readiness-filter-store-not-ready")
  assert_readiness_envelope.call(bytes, status, "not ready",
                                 StoreSaysNoStateReader::STORE_REASON, "live")
end

# (4) THE FAIL-CLOSED DEFAULT. An UNRECOGNISED reason must NOT be allowed to manufacture the
# stronger claim ("the store answered and has no state"). It must report `unavailable`.
class UnknownReasonReader < NotReadyReader
  UNKNOWN_REASON = "a_reason_this_classification_has_never_seen"

  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: UNKNOWN_REASON)
  end
end

rig.check("readiness filter, UNRECOGNISED reason FAILS CLOSED to 'unavailable' (never the stronger claim)") do
  Atomspace::LocalI3ReadBinding.install!(reader: UnknownReasonReader.new)
  bytes, status = run_readiness_filter.call("readiness-filter-unknown-reason")
  assert_readiness_envelope.call(bytes, status, "unavailable",
                                 UnknownReasonReader::UNKNOWN_REASON, "live")
end

# (4b) THE THIRD CATEGORY: the store ANSWERED, coherently, with a STATE-BEARING outcome that is not
# a clean "ok" ("ok, partial" / "unknown" / "reload" -- i2_reader_process_client.rb:119). A state
# EXISTS, so `not ready` would assert the one thing this answer disproves. It must be `unavailable`.
class DegradedOutcomeReader < NotReadyReader
  DEGRADED_REASON = Atomspace::I2ReaderProcessClient::REASON_DEGRADED_OUTCOME

  def readiness
    Atomspace::MirrorReadiness::Result.new(ready: false, reason: DEGRADED_REASON)
  end
end

rig.check("readiness filter, STATE-BEARING degraded outcome: 'unavailable', NOT the false 'no state' claim") do
  Atomspace::LocalI3ReadBinding.install!(reader: DegradedOutcomeReader.new)
  bytes, status = run_readiness_filter.call("readiness-filter-degraded-outcome")
  assert_readiness_envelope.call(bytes, status, "unavailable",
                                 DegradedOutcomeReader::DEGRADED_REASON, "live")
end

# (5) THE CLASSIFICATION ITSELF, exhaustively, against the REAL constants -- so a future reason
# string added to either list cannot silently land in the wrong class.
rig.check("every declared readiness reason classifies to the CONTRACT-correct outcome") do
  ctrl = Api::Mcp::I3ReadController.new(params: {})
  problems = []
  Api::Mcp::I3ReadController::READINESS_UNREACHABLE_REASONS.each do |r|
    got = ctrl.send(:readiness_outcome_for, r)
    problems << "#{r} -> #{got.inspect} (expected 'unavailable')" unless got == "unavailable"
  end
  Api::Mcp::I3ReadController::READINESS_STORE_ANSWERED_REASONS.each do |r|
    got = ctrl.send(:readiness_outcome_for, r)
    problems << "#{r} -> #{got.inspect} (expected 'not ready')" unless got == "not ready"
  end
  # The interpolated probe-error form (`i3_read_port.rb:88`) is matched by PREFIX.
  probe = "#{Api::Mcp::I3ReadController::READINESS_PROBE_ERROR_PREFIX}RuntimeError"
  got = ctrl.send(:readiness_outcome_for, probe)
  problems << "#{probe} -> #{got.inspect} (expected 'unavailable')" unless got == "unavailable"
  # nil and "" are not store answers either.
  [nil, ""].each do |r|
    got = ctrl.send(:readiness_outcome_for, r)
    problems << "#{r.inspect} -> #{got.inspect} (expected 'unavailable')" unless got == "unavailable"
  end
  # The two lists must be DISJOINT, or a reason's class would depend on lookup order.
  overlap = Api::Mcp::I3ReadController::READINESS_UNREACHABLE_REASONS &
            Api::Mcp::I3ReadController::READINESS_STORE_ANSWERED_REASONS
  problems << "lists overlap: #{overlap.inspect}" unless overlap.empty?
  [problems.empty?, problems.join("; ")]
end

# ------------------------------- PART 2c: THE CONTINUATION-IDENTITY LEAK (the real ACL bypass)
#
# WHY THIS CASE WAS ADDED. The reviewer correctly observed that the supplied neighbours result was
# `unknown`, so `forward_store_metadata` -- and therefore the whole continuation-forwarding path --
# was NEVER EXECUTED. That path copied STORE's `omitted` through UNCHANGED after the atom list had
# been ACL-filtered, so a DENIED card stayed identifiable via `omitted.continue[].key` / `.after`.
#
# This reader answers `ok, partial` WITH a real `omitted.continue` carrying TWO identities, one of
# which the harness ACL DENIES. The assertion then searches THE RAW SERIALIZED BYTES for the denied
# key text and its digest: not the parsed object, the actual string that would go on the wire.
puts
puts "PART 2c -- ACL-FILTERED `ok, partial`: a DENIED continuation identity must not reach the bytes"

DENIED_CARD_ID = 777
DENIED_KEY = "(Card #{DENIED_CARD_ID})"
DENIED_DIGEST = "ffffffffffffffffffffffffffffffff"
ALLOWED_KEY = "(Card 1)"

# A real Atom-shaped object. `associated_card_ids` is what the real ACL filter selects on.
class HarnessAtom
  def initialize(card_id) = @card_id = card_id
  def associated_card_ids = [@card_id]
  def to_h = { type: "DeckoProperty", card_id: @card_id }
end

class PartialWithContinuationReader < NotReadyReader
  STATEFUL_ENVELOPE = {
    "outcome" => "ok, partial", "epoch" => "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0",
    # SIX fractional digits are MANDATORY: I2Envelope::READ_AT_PATTERN (i2_envelope.rb:77) requires
    # `\.\d{6}`, and the real STORE emits exactly that (observed: 2026-11-17T01:55:36.090097+00:00).
    # A fixture without them is refused by the REAL validator -- which is the validator working, not
    # a production defect. Do not relax the pattern to accommodate a fixture.
    "position" => 7, "read-at" => "2026-11-17T01:00:00.000000+00:00"
  }.freeze

  # STORE's REAL §5.8 omission report shape: `bound` from the closed seven, an exact `count`, and
  # a `continue` list whose items carry PARTICIPANT IDENTITIES (`i2_read.py:705-706`).
  OMITTED = {
    "bound" => "entries",
    "count" => 2,
    "continue" => [
      { "key" => ALLOWED_KEY, "digest" => "11111111111111111111111111111111" },
      { "key" => DENIED_KEY, "digest" => DENIED_DIGEST }
    ]
  }.freeze

  def readiness = Atomspace::MirrorReadiness::READY
  def origin = "live"
  def state_envelope = STATEFUL_ENVELOPE

  def store_profile
    { "schema-version" => "harness-1",
      "limits" => Atomspace::I3Envelope::LIMITS_KEYS.each_with_object({}) { |k, h| h[k] = nil } }
  end

  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    Atomspace::I3ReadResult.new(
      envelope: STATEFUL_ENVELOPE,
      payload: { "entries" => [], "omitted" => OMITTED },
      atoms: [HarnessAtom.new(1), HarnessAtom.new(DENIED_CARD_ID)]
    )
  end
end

Atomspace::LocalI3ReadBinding.install!(reader: PartialWithContinuationReader.new)
Card.reset!
Card.seed(id: 1, name: "Decko Bot")
Card.seed(id: DENIED_CARD_ID, name: "Denied Neighbour")

rig.check("ACL-denied continuation identity is ABSENT from the serialized bytes (string search)") do
  # readable_ids EXCLUDES the denied card, so the real ACL filter drops its atom AND the
  # continuation authorizer must drop the continuation that still names it.
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: "1", bucket: "refers_to" },
                                  readable_ids: [1], label: "acl-partial-continuation")
  problems = []
  problems << "status=#{status.inspect}" unless status == :ok
  # THE LEAK TEST, on the RAW BYTES -- not on a parsed view of them.
  problems << "DENIED KEY #{DENIED_KEY.inspect} LEAKED" if bytes.include?(DENIED_KEY)
  problems << "DENIED DIGEST LEAKED" if bytes.include?(DENIED_DIGEST)
  problems << "denied card id 777 LEAKED" if bytes.include?("777")
  p = JSON.parse(bytes)
  # The ALLOWED atom still renders -- the fix must not have emptied the answer.
  problems << "allowed atom missing: results=#{p['results'].inspect}" unless p["results"] == [{ "type" => "DeckoProperty", "card_id" => 1 }]
  # STORE's identity-free omission facts SURVIVE: `bound` and `count` carry no identity.
  problems << "omitted absent" unless p.key?("omitted")
  problems << "bound=#{p.dig('omitted', 'bound').inspect}" unless p.dig("omitted", "bound") == "entries"
  problems << "count=#{p.dig('omitted', 'count').inspect}" unless p.dig("omitted", "count") == 2
  # And the continuation itself is GONE -- absent, not null.
  problems << "continue still present: #{p.dig('omitted', 'continue').inspect}" if p["omitted"].is_a?(Hash) && p["omitted"].key?("continue")
  problems << "outcome=#{p['outcome'].inspect}" unless p["outcome"] == "ok, partial"
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

rig.check("an ALL-READABLE continuation is still forwarded VERBATIM (the fix is not a blanket drop)") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: "1", bucket: "refers_to" },
                                  readable_ids: [1, DENIED_CARD_ID],
                                  label: "acl-partial-continuation-allowed")
  p = JSON.parse(bytes)
  cont = p.dig("omitted", "continue")
  [status == :ok && cont == PartialWithContinuationReader::OMITTED["continue"],
   "status=#{status.inspect} continue=#{cont.inspect}"]
end

# ------------------- PART 2c-nested: STORE'S REAL `{bucket, cursor}` SHAPE (the actual leak)
#
# WHY THESE CASES WERE ADDED, and this is the defect that mattered most. The checks above cover the
# FLAT `{key, digest}` continuation item. `continue_item_authorized?` used to inspect ONLY an item's
# OWN TOP-LEVEL KEYS and never recursed, and `cursor` is an allowlisted STRUCTURAL key -- so an item
# shaped `{bucket, cursor}` passed authorization WITH NO IDENTITY CHECK WHATSOEVER.
#
# That is not a hypothetical shape. It is what STORE ACTUALLY EMITS on the neighbours page-out path:
#     omitted["continue"].append({"bucket": h, "cursor": self._cursor(state, key, h, last)})
#                                                                        (`i2_read.py:888`)
# with `_cursor` (`i2_read.py:695-700`) returning
#     {"kind": "entries", "participant": subject, "bucket": head, "narrowing": None,
#      "after": last, "epoch": state.epoch, "position": state.position}
# so `cursor.participant` and `cursor.after` are participant KEY TEXTS -- card identities -- nested
# one level down. They reached the wire UNAUTHORIZED: a genuine read-permission leak, and the
# round-43/44 regression test missed it because it only ever built the flat shape.
#
# These two checks use STORE'S REAL NESTED SHAPE, and the denied-case assertion is a STRING SEARCH
# OF THE WHOLE SERIALIZED BODY -- not a parsed view of it.
puts
puts "PART 2c-nested -- STORE'S REAL `{bucket, cursor:{participant, after, ...}}` continuation"

NESTED_DENIED_CARD_ID = 909
NESTED_DENIED_PARTICIPANT = "(Card #{NESTED_DENIED_CARD_ID})"
NESTED_DENIED_AFTER = "(Card #{NESTED_DENIED_CARD_ID + 1})"
NESTED_BUCKET = "refers_to"

# STORE's REAL cursor shape, field for field, built the way `_cursor` builds it. `participant` and
# `after` are the two identities; everything else is structural.
def nested_cursor(participant, after)
  { "kind" => "entries", "participant" => participant, "bucket" => NESTED_BUCKET,
    "narrowing" => nil, "after" => after,
    "epoch" => "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0", "position" => 7 }
end

class NestedCursorReader < NotReadyReader
  STATEFUL_ENVELOPE = PartialWithContinuationReader::STATEFUL_ENVELOPE

  def initialize(continuation) = @continuation = continuation

  def readiness = Atomspace::MirrorReadiness::READY
  def origin = "live"
  def state_envelope = STATEFUL_ENVELOPE

  def store_profile
    { "schema-version" => "harness-1",
      "limits" => Atomspace::I3Envelope::LIMITS_KEYS.each_with_object({}) { |k, h| h[k] = nil } }
  end

  # STORE's real neighbours page-out answer: `bound`/`count` plus the NESTED `{bucket, cursor}`
  # continuation item.
  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    Atomspace::I3ReadResult.new(
      envelope: STATEFUL_ENVELOPE,
      payload: { "entries" => [],
                 "omitted" => { "bound" => "entries", "count" => 3,
                                "continue" => @continuation } },
      atoms: [HarnessAtom.new(1)]
    )
  end
end

# (1) THE LEAK CASE: the ACL DENIES the NESTED participant/after identities.
Atomspace::LocalI3ReadBinding.install!(
  reader: NestedCursorReader.new(
    [{ "bucket" => NESTED_BUCKET,
       "cursor" => nested_cursor(NESTED_DENIED_PARTICIPANT, NESTED_DENIED_AFTER) }]
  )
)
Card.reset!
Card.seed(id: 1, name: "Decko Bot")
Card.seed(id: NESTED_DENIED_CARD_ID, name: "Nested Denied Participant")
Card.seed(id: NESTED_DENIED_CARD_ID + 1, name: "Nested Denied After")

rig.check("NESTED cursor: a DENIED identity under `cursor` is ABSENT from the raw bytes (whole-body string search)") do
  # readable_ids ALLOWS only card 1. The nested identities are DENIED, so the whole continuation
  # must be dropped.
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: "1", bucket: NESTED_BUCKET },
                                  readable_ids: [1], label: "acl-nested-cursor-denied")
  problems = []
  problems << "status=#{status.inspect}" unless status == :ok
  # THE LEAK TEST: the denied identity strings must not appear ANYWHERE in the serialized body.
  problems << "NESTED DENIED PARTICIPANT #{NESTED_DENIED_PARTICIPANT.inspect} LEAKED" if bytes.include?(NESTED_DENIED_PARTICIPANT)
  problems << "NESTED DENIED AFTER #{NESTED_DENIED_AFTER.inspect} LEAKED" if bytes.include?(NESTED_DENIED_AFTER)
  problems << "denied card id #{NESTED_DENIED_CARD_ID} LEAKED" if bytes.include?(NESTED_DENIED_CARD_ID.to_s)
  problems << "denied card id #{NESTED_DENIED_CARD_ID + 1} LEAKED" if bytes.include?((NESTED_DENIED_CARD_ID + 1).to_s)
  p = JSON.parse(bytes)
  # The whole continuation is DROPPED -- absent, not null.
  if p["omitted"].is_a?(Hash) && p["omitted"].key?("continue")
    problems << "continue still present: #{p.dig('omitted', 'continue').inspect}"
  end
  # `bound` and `count` SURVIVE: they carry no identity, so the truthful "that, and how many" is
  # still reported.
  problems << "omitted absent entirely" unless p.key?("omitted")
  problems << "bound=#{p.dig('omitted', 'bound').inspect}" unless p.dig("omitted", "bound") == "entries"
  problems << "count=#{p.dig('omitted', 'count').inspect}" unless p.dig("omitted", "count") == 3
  problems << "outcome=#{p['outcome'].inspect}" unless p["outcome"] == "ok, partial"
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

# (2) THE ALL-READABLE NESTED CONTROL: the SAME nested shape, every identity readable. The
# continuation must be forwarded VERBATIM -- which is what proves the fix is targeted
# authorization and not a blanket drop of anything containing a `cursor`.
NESTED_ALLOWED_CONTINUATION = [
  { "bucket" => NESTED_BUCKET, "cursor" => nested_cursor("(Card 1)", "(Card 2)") }
].freeze

rig.check("NESTED cursor, ALL identities READABLE: the continuation is forwarded VERBATIM") do
  Atomspace::LocalI3ReadBinding.install!(reader: NestedCursorReader.new(NESTED_ALLOWED_CONTINUATION))
  Card.reset!
  Card.seed(id: 1, name: "Decko Bot")
  Card.seed(id: 2, name: "Decko Bot+description")
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: "1", bucket: NESTED_BUCKET },
                                  readable_ids: [1, 2], label: "acl-nested-cursor-allowed")
  p = JSON.parse(bytes)
  cont = p.dig("omitted", "continue")
  problems = []
  problems << "status=#{status.inspect}" unless status == :ok
  # VERBATIM: the nested cursor survives field for field, including the nulls and the integers.
  problems << "continue=#{cont.inspect}" unless cont == JSON.parse(JSON.generate(NESTED_ALLOWED_CONTINUATION))
  problems << "bound=#{p.dig('omitted', 'bound').inspect}" unless p.dig("omitted", "bound") == "entries"
  problems << "count=#{p.dig('omitted', 'count').inspect}" unless p.dig("omitted", "count") == 3
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

# (3) THE §5.8 `no-such-bucket` FORM MUST STILL WORK. `cursor` is present and EXACTLY NULL there
# (`k8-draft-2.md:793-799`), which names nobody. The fix inspects a cursor's CONTENTS when it is a
# Hash; it must NOT have started rejecting the key itself.
NO_SUCH_BUCKET_CONTINUATION = [
  { "bucket" => "rivals", "cursor" => nil, "reason" => "no-such-bucket" }
].freeze

rig.check("§5.8 `no-such-bucket` item ({bucket, cursor:null, reason}) is STILL forwarded (cursor is an ACCEPTED key)") do
  Atomspace::LocalI3ReadBinding.install!(reader: NestedCursorReader.new(NO_SUCH_BUCKET_CONTINUATION))
  Card.reset!
  Card.seed(id: 1, name: "Decko Bot")
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: "1", bucket: "rivals" },
                                  readable_ids: [1], label: "acl-no-such-bucket")
  p = JSON.parse(bytes)
  cont = p.dig("omitted", "continue")
  [status == :ok && cont == JSON.parse(JSON.generate(NO_SUCH_BUCKET_CONTINUATION)),
   "status=#{status.inspect} continue=#{cont.inspect}"]
end

# (4) THE RECURSIVE FAIL-CLOSED PROPERTIES, asserted directly on the REAL module so each one is
# proven individually rather than inferred from the two end-to-end cases above.
rig.check("recursive continuation authorization fails closed on every unauditable nested shape") do
  allow_all = ->(_k) { true }
  deny = ->(k) { k != NESTED_DENIED_PARTICIPANT }
  problems = []

  check_one = lambda do |label, continuation, authorize, expected|
    got = Atomspace::I3Envelope.send(:authorized_continue, continuation, authorize)
    emitted = !got.nil?
    problems << "#{label}: emitted=#{emitted} (expected #{expected})" unless emitted == expected
  end

  # The nested DENIED identity -> dropped, even though the item's own top level is clean.
  check_one.call("nested denied participant",
                 [{ "bucket" => NESTED_BUCKET,
                    "cursor" => nested_cursor(NESTED_DENIED_PARTICIPANT, "(Card 1)") }], deny, false)
  # The nested denied `after` -> dropped.
  check_one.call("nested denied after",
                 [{ "bucket" => NESTED_BUCKET,
                    "cursor" => nested_cursor("(Card 1)", NESTED_DENIED_PARTICIPANT) }], deny, false)
  # An UNRECOGNISED key NESTED inside the cursor -> dropped (it could be a future identity form).
  check_one.call("unrecognised nested key",
                 [{ "bucket" => NESTED_BUCKET,
                    "cursor" => nested_cursor("(Card 1)", "(Card 1)").merge("future_id" => "x") }],
                 allow_all, false)
  # A NON-STRING identity nested under `participant` -> dropped (cannot be mapped to a card).
  check_one.call("non-string nested identity",
                 [{ "bucket" => NESTED_BUCKET,
                    "cursor" => nested_cursor({ "key" => "(Card 1)" }, "(Card 1)") }],
                 allow_all, false)
  # A nested PRESENT-BUT-NULL identity names nobody -> still emitted.
  check_one.call("nested null identities",
                 [{ "bucket" => NESTED_BUCKET, "cursor" => nested_cursor(nil, nil) }],
                 allow_all, true)
  # A `digest` with NO sibling `key` text cannot be authorized -> dropped. STORE only ever emits a
  # digest beside a key (`i2_read.py:705-706`).
  check_one.call("unpaired digest",
                 [{ "bucket" => NESTED_BUCKET, "digest" => "ab" * 16 }], allow_all, false)
  # A digest PAIRED with an authorized key -> emitted (STORE's real ambiguous-digest form).
  check_one.call("paired digest with authorized key",
                 [{ "key" => "(Card 1)", "digest" => "ab" * 16 }], allow_all, true)
  # A digest paired with a DENIED key -> dropped.
  check_one.call("paired digest with denied key",
                 [{ "key" => NESTED_DENIED_PARTICIPANT, "digest" => "ab" * 16 }], deny, false)
  # A pathologically DEEP structure cannot be finished -> dropped.
  deep = { "cursor" => nil }
  (Atomspace::I3Envelope::CONTINUE_MAX_DEPTH + 3).times { deep = { "cursor" => deep } }
  check_one.call("over-deep nesting", [deep], allow_all, false)
  # NO authorize predicate at all -> dropped.
  check_one.call("no authorize predicate",
                 [{ "bucket" => NESTED_BUCKET, "cursor" => nested_cursor("(Card 1)", "(Card 1)") }],
                 nil, false)

  [problems.empty?, problems.join("; ")]
end

# ----------------------- PART 2d: THE GENERIC AVAILABILITY RENDERER (render_unavailable)
#
# WHY THIS CASE WAS ADDED. `render_unavailable` is the generic method EVERY remaining availability
# path funnels into -- `render_address_unavailable`, `render_backend_unavailable`, the atom/result
# contract violations in `render_card_scoped`, and `render_i3`'s own Unrenderable rescue. A previous
# round repaired only `render_port_unwired`, leaving this one emitting the non-envelope 503. Both of
# its live entry points are exercised here, through the REAL rescue dispatch, and the bodies are
# CAPTURED so the parser gate sees them too.
puts
puts "PART 2d -- THE GENERIC AVAILABILITY PATHS: `unavailable` envelope, not a 503 wrapper"

# A reader that is READY but whose every card-scoped read FAILS -- the real-world shape of a
# channel that died after the readiness probe.
class ChannelFailureReader < NotReadyReader
  def readiness = Atomspace::MirrorReadiness::READY
  def origin = "live"
  def state_envelope = nil
  def store_profile = nil

  def lookup_reading(card_id:)
    raise Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable"
  end

  def open_reading(card_id:)
    raise Atomspace::ServiceUnavailable, "i2_store_not_ready"
  end

  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    raise Atomspace::ServiceUnavailable, "i2_store_not_ready"
  end
end

Atomspace::LocalI3ReadBinding.install!(reader: ChannelFailureReader.new)
Card.reset!
Card.seed(id: 1, name: "Decko Bot")

assert_unavailable_body = lambda do |bytes, status, expected_reason|
  p = JSON.parse(bytes)
  problems = []
  problems << "status=#{status.inspect} (must be :ok)" unless status == :ok
  problems << "outcome=#{p['outcome'].inspect}" unless p["outcome"] == "unavailable"
  %w[epoch position read-at].each do |k|
    problems << "#{k} ABSENT" unless p.key?(k)
    problems << "#{k}=#{p[k].inspect} not null" unless p[k].nil?
  end
  problems << "schema-version ABSENT" unless p.key?("schema-version")
  problems << "limits ABSENT" unless p.key?("limits")
  problems << "reason=#{p['reason'].inspect} (expected #{expected_reason.inspect})" unless p["reason"] == expected_reason
  problems << "legacy 'error' key still present" if p.key?("error")
  unless p.keys.first(6) == Atomspace::I3Envelope::FIELDS
    problems << "envelope key order=#{p.keys.first(6).inspect}"
  end
  [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
end

rig.check("ADDRESS-unavailable (render_address_unavailable -> render_unavailable): `unavailable` envelope") do
  _b, bytes, status, = rig.invoke("I3-10", :lookup, params: { name: "Decko Bot" },
                                                    label: "unavailable-address")
  assert_unavailable_body.call(bytes, status, "backend_digest_unavailable")
end

rig.check("BACKEND-unavailable (render_backend_unavailable -> render_unavailable): `unavailable` envelope") do
  _b, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" }, readable_ids: [1],
                                                  label: "unavailable-backend")
  assert_unavailable_body.call(bytes, status, "i3_backend_unavailable")
end

# --------------- PART 2e: NESTED JOINING-LINK IDENTITY (the link-key disclosure leak)
#
# WHY THESE CASES WERE ADDED, and this is a DISCLOSURE, not a shape defect. `entry_authorized?`
# authorizes an entry's OWN `key` and nothing else. A KEPT entry's `links[]` were then forwarded
# VERBATIM -- each with its own `key` AND `digest`. But a STORE LINK KEY TEXT IS AN EXPRESSION THAT
# EMBEDS THE CARD ADDRESS OF EVERY PARTICIPANT. Measured on the real reader child
# (`store-raw-probe.json`):
#     "(created-by (Card 2) (Card 1))"
#     "(includes (Card 2) (Card 34) \"rich_text+description\")"
# and `k8-draft-2.md:624-628` documents links with THREE OR MORE participants. Meanwhile the
# controller's authorizer `card_id_from_store_key_text` (`i3_read_controller.rb:1040-1048`) matches
# ONLY /\A\(Card (\d+)\)\z/, so a LINK key is UNMAPPABLE and could never be authorized -- yet it
# was emitted anyway. A readable entry therefore DISCLOSED A DENIED THIRD PARTICIPANT's address.
#
# THE FIXTURE IS SHAPED ON THE MEASURED STORE PAYLOAD and adds the three-participant form K8
# documents, because the attested export happens to contain only two-participant links -- the
# three-participant case is the one the real ACL mapper provably cannot authorize, so it must be
# exercised deliberately rather than hoped for. Every assertion is on the ACTUAL SERIALIZED BYTES.
puts
puts "PART 2e -- NESTED JOINING-LINK IDENTITY: a link key naming a DENIED card must not reach the bytes"

LINK_SUBJECT_ID = 2
LINK_KEPT_NEIGHBOUR_ID = 34
LINK_DENIED_THIRD_ID = 99
LINK_ALL_DENIED_ENTRY_ID = 7
LINK_EMPTY_LINKS_ENTRY_ID = 5

# STORE's own two-participant link, verbatim in shape from the measured probe.
LINK_TWO_PARTY = {
  "key" => "(includes (Card 2) (Card 34) \"rich_text+description\")",
  "digest" => "644e26bceedfb6ac3ef0bd7fb032f3f1",
  "link-type" => "includes", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# THE THREE-PARTICIPANT JOINING LINK (`k8-draft-2.md:624-628`). Its key names card 99, which the
# ACL DENIES, so emitting this link would disclose card 99's address to a caller denied card 99.
LINK_THREE_PARTY = {
  "key" => "(includes (Card 2) (Card 34) (Card 99))",
  "digest" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "link-type" => "includes", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# A link on an entry whose EVERY link names the denied card -> the `links` key must be ABSENT.
LINK_ALL_DENIED = {
  "key" => "(includes (Card 2) (Card 7) (Card 99))",
  "digest" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "link-type" => "includes", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# STORE's REAL `links-continue` cursor shape (`i2_read.py:615-618`).
LINK_CONTINUE = {
  "kind" => "links", "participant" => "(Card 2)", "bucket" => "includes",
  "neighbour" => ["(Card 34)", "", -1], "after-link" => LINK_TWO_PARTY["key"],
  "epoch" => "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1", "position" => 9
}.freeze
# SELF-LINKS, same rule: a loop's key text still enumerates participants.
SELF_LINK_ALLOWED = {
  "key" => "(refers-to (Card 2) (Card 2))", "digest" => "cccccccccccccccccccccccccccccccc",
  "link-type" => "refers-to", "subject-positions" => [0, 1], "copy-count" => 1,
  "is-participant" => false
}.freeze
SELF_LINK_DENIED = {
  "key" => "(refers-to (Card 2) (Card 2) (Card 99))", "digest" => "dddddddddddddddddddddddddddddddd",
  "link-type" => "refers-to", "subject-positions" => [0, 1], "copy-count" => 1,
  "is-participant" => false
}.freeze

class LinkIdentityReader < NotReadyReader
  STATEFUL_ENVELOPE = {
    "outcome" => "ok", "epoch" => "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1",
    "position" => 9, "read-at" => "2026-11-17T02:00:00.000000+00:00"
  }.freeze

  def readiness = Atomspace::MirrorReadiness::READY
  def origin = "live"
  def state_envelope = STATEFUL_ENVELOPE

  def store_profile
    { "schema-version" => "harness-1",
      "limits" => Atomspace::I3Envelope::LIMITS_KEYS.each_with_object({}) { |k, h| h[k] = nil } }
  end

  # The MEASURED I2-03 page shape plus the enrichment keys the reader client supplies.
  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    Atomspace::I3ReadResult.new(
      envelope: STATEFUL_ENVELOPE,
      payload: {
        "entries" => [
          # A KEPT entry carrying one ALL-ALLOWED link, one DENIED-THIRD-PARTICIPANT link, and a
          # cursor. The entry's own key is authorized, so only the links are at issue.
          { "key" => "(Card #{LINK_KEPT_NEIGHBOUR_ID})", "digest" => "27c0c6cba3d1f59f2b4f139f4e4e3ae0",
            "class" => "missing", "label" => { "name" => nil, "type-name" => nil }, "trash" => nil,
            "link-count" => 2, "link-copy-count" => 2,
            "links" => [LINK_TWO_PARTY, LINK_THREE_PARTY],
            "links-continue" => LINK_CONTINUE },
          # EVERY link denied -> `links` ABSENT, entry still emitted.
          { "key" => "(Card #{LINK_ALL_DENIED_ENTRY_ID})", "digest" => "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "class" => "entity", "link-count" => 1, "links" => [LINK_ALL_DENIED] },
          # STORE'S OWN EMPTY LIST -- truthful, and therefore PRESERVED as `[]`.
          { "key" => "(Card #{LINK_EMPTY_LINKS_ENTRY_ID})", "digest" => "ffffffffffffffffffffffffffffffee",
            "class" => "entity", "link-count" => 0, "links" => [] }
        ],
        "participant" => { "key" => "(Card #{LINK_SUBJECT_ID})", "digest" => "2a10fe04e4c4da7310d27c31714a144f",
                           "class" => "entity" },
        "bucket" => { "link-type" => "includes",
                      "counts" => { "neighbour-count" => 3, "link-count" => 4 } },
        "self-links" => [SELF_LINK_ALLOWED, SELF_LINK_DENIED]
      },
      atoms: [HarnessAtom.new(LINK_KEPT_NEIGHBOUR_ID), HarnessAtom.new(LINK_ALL_DENIED_ENTRY_ID),
              HarnessAtom.new(LINK_EMPTY_LINKS_ENTRY_ID)]
    )
  end
end

Atomspace::LocalI3ReadBinding.install!(reader: LinkIdentityReader.new)
Card.reset!
Card.seed(id: LINK_SUBJECT_ID, name: "Decko Bot+description")
Card.seed(id: LINK_KEPT_NEIGHBOUR_ID, name: "Card Thirty Four")
Card.seed(id: LINK_ALL_DENIED_ENTRY_ID, name: "Card Seven")
Card.seed(id: LINK_EMPTY_LINKS_ENTRY_ID, name: "Card Five")
Card.seed(id: LINK_DENIED_THIRD_ID, name: "Denied Third Participant")

rig.check("a LINK whose key embeds a DENIED card is DROPPED -- key AND digest absent, the ENTRY survives") do
  # Card 99 is SEEDED but NOT in readable_ids: denied deliberately, so a drop cannot be confused
  # with "never seeded".
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_SUBJECT_ID.to_s, bucket: "includes" },
                                  readable_ids: [LINK_SUBJECT_ID, LINK_KEPT_NEIGHBOUR_ID,
                                                 LINK_ALL_DENIED_ENTRY_ID, LINK_EMPTY_LINKS_ENTRY_ID],
                                  label: "link-identity-denied-third")
  problems = []
  problems << "status #{status.inspect}" unless status == :ok

  # THE DISCLOSURE TEST, ON THE RAW BYTES. Neither the denied link's key nor its digest, and not
  # the denied card's address in ANY form, may appear anywhere in the serialized string.
  problems << "DENIED 3-party link KEY LEAKED" if bytes.include?(LINK_THREE_PARTY["key"])
  problems << "DENIED 3-party link DIGEST LEAKED" if bytes.include?(LINK_THREE_PARTY["digest"])
  problems << "DENIED all-denied link KEY LEAKED" if bytes.include?(LINK_ALL_DENIED["key"])
  problems << "DENIED all-denied link DIGEST LEAKED" if bytes.include?(LINK_ALL_DENIED["digest"])
  problems << "DENIED self-link KEY LEAKED" if bytes.include?(SELF_LINK_DENIED["key"])
  problems << "DENIED self-link DIGEST LEAKED" if bytes.include?(SELF_LINK_DENIED["digest"])
  problems << "the denied card address `(Card 99)` LEAKED" if bytes.include?("(Card #{LINK_DENIED_THIRD_ID})")

  p = JSON.parse(bytes)
  entries = p["entries"]
  if entries.is_a?(Array)
    kept = entries.find { |e| e["key"] == "(Card #{LINK_KEPT_NEIGHBOUR_ID})" }
    if kept.nil?
      problems << "THE ENTRY WAS DROPPED TOO (over-broad): #{entries.map { |e| e['key'] }.inspect}"
    else
      # The entry itself survives untouched, including its own digest and its STORE counts.
      problems << "entry digest #{kept['digest'].inspect}" unless kept["digest"] == "27c0c6cba3d1f59f2b4f139f4e4e3ae0"
      problems << "entry link-count #{kept['link-count'].inspect}" unless kept["link-count"] == 2
      # THE SURVIVING LINK IS STILL THERE, BYTE-IDENTICAL to STORE's object.
      links = kept["links"]
      unless links == [LINK_TWO_PARTY]
        problems << "the all-allowed link was not kept verbatim: #{links.inspect}"
      end
      # AND THE CURSOR IS WITHHELD, because a link of this entry was dropped: a cursor seeded past
      # content the caller never received would corrupt its next page. ABSENT, never null.
      problems << "links-continue EMITTED past dropped content: #{kept['links-continue'].inspect}" \
        if kept.key?("links-continue")
    end

    # EVERY link denied -> the `links` KEY IS ABSENT, not `[]`. Absent != empty.
    all_denied = entries.find { |e| e["key"] == "(Card #{LINK_ALL_DENIED_ENTRY_ID})" }
    if all_denied.nil?
      problems << "the all-links-denied ENTRY was dropped (only its links should be)"
    elsif all_denied.key?("links")
      problems << "links present on the all-denied entry: #{all_denied['links'].inspect} (must be ABSENT, not [])"
    end

    # STORE'S OWN EMPTY LIST IS TRUTH and is preserved exactly.
    empty = entries.find { |e| e["key"] == "(Card #{LINK_EMPTY_LINKS_ENTRY_ID})" }
    if empty.nil?
      problems << "the STORE-empty-links entry was dropped"
    else
      problems << "STORE's own `links: []` was not preserved: #{empty['links'].inspect}" \
        unless empty.key?("links") && empty["links"] == []
    end
  else
    problems << "NO entries: #{entries.inspect}"
  end

  # SELF-LINKS obey the same per-link rule: the allowed loop survives, the denied one is gone.
  problems << "self-links #{p['self-links'].inspect} is not just the allowed loop" \
    unless p["self-links"] == [SELF_LINK_ALLOWED]

  # NO VOCABULARY IS COINED to announce any of this -- that is the non-oracle property.
  %w[acl-filtered-count acl-omitted dropped withheld links-omitted link-omitted].each do |invented|
    problems << "INVENTED key #{invented} on the wire" if bytes.include?(invented)
  end
  # And no eighth `omitted.bound` member was minted.
  problems << "an `omitted` block was invented" if p.key?("omitted")

  [problems.empty?, problems.join("; ")]
end

rig.check("with ALL participants allowed the REAL links are present and BYTE-IDENTICAL (not mangled)") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_SUBJECT_ID.to_s, bucket: "includes" },
                                  readable_ids: [LINK_SUBJECT_ID, LINK_KEPT_NEIGHBOUR_ID,
                                                 LINK_ALL_DENIED_ENTRY_ID, LINK_EMPTY_LINKS_ENTRY_ID,
                                                 LINK_DENIED_THIRD_ID],
                                  label: "link-identity-all-allowed")
  p = JSON.parse(bytes)
  problems = []
  problems << "status #{status.inspect}" unless status == :ok

  entries = p["entries"] || []
  kept = entries.find { |e| e["key"] == "(Card #{LINK_KEPT_NEIGHBOUR_ID})" }
  if kept.nil?
    problems << "the entry is missing: #{entries.map { |e| e['key'] }.inspect}"
  else
    # BOTH links, in STORE's own order, with every member untouched -- no re-casing, no
    # re-ordering, no recomputed digest, nothing stripped.
    unless kept["links"] == [LINK_TWO_PARTY, LINK_THREE_PARTY]
      problems << "links were MANGLED: #{kept['links'].inspect}"
    end
    # NOTHING WAS DROPPED, so the cursor may travel -- but it still has to pass the recursive
    # continuation ACL, whose `neighbour` / `after-link` keys it does not recognise, so it is
    # correctly WITHHELD. Asserted so the fail-closed direction is proven, not assumed.
    problems << "links-continue emitted despite unrecognised cursor keys: #{kept['links-continue'].inspect}" \
      if kept.key?("links-continue")
  end

  all_denied = entries.find { |e| e["key"] == "(Card #{LINK_ALL_DENIED_ENTRY_ID})" }
  problems << "the previously-all-denied entry's link did not return: #{all_denied && all_denied['links'].inspect}" \
    unless all_denied && all_denied["links"] == [LINK_ALL_DENIED]

  # BOTH self-links now travel, verbatim and in order.
  problems << "self-links #{p['self-links'].inspect}" \
    unless p["self-links"] == [SELF_LINK_ALLOWED, SELF_LINK_DENIED]

  [problems.empty?, problems.join("; ")]
end

rig.check("DENYING THE SUBJECT drops the whole structured graph (the participant gate still holds)") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_SUBJECT_ID.to_s, bucket: "includes" },
                                  readable_ids: [LINK_KEPT_NEIGHBOUR_ID],
                                  label: "link-identity-subject-denied")
  problems = []
  problems << "status #{status.inspect}" unless status == :ok
  # The subject is unreadable, so the read never reaches the graph at all: NO link key, NO digest,
  # NO self-link, nothing structured.
  %w[participant entries self-links bucket].each do |k|
    problems << "structured `#{k}` emitted for a DENIED subject" if bytes.include?("\"#{k}\"")
  end
  [LINK_TWO_PARTY, LINK_THREE_PARTY, SELF_LINK_ALLOWED, SELF_LINK_DENIED].each do |link|
    problems << "link key #{link['key']} LEAKED" if bytes.include?(link["key"])
    problems << "link digest LEAKED" if bytes.include?(link["digest"])
  end
  [problems.empty?, problems.join("; ")]
end

# ------------------------------------------- PART 2f: PARTICIPANT *FORM*, NOT JUST PARTICIPANT COUNT
#
# R48-B1. PART 2e proves that a DENIED `(Card N)` participant drops its link. It does NOT prove
# anything about a participant in ANY OTHER FORM, and the shipped scan-for-`(Card \d+)` rule
# rejected ONLY the zero-match case. So a link key MIXING an authorized `(Card N)` with a
# participant in another declared form passed `ids.all?` vacuously-for-that-member and rode out
# WHOLE, disclosing that other participant's identity text.
#
# THIS IS NOT HYPOTHETICAL VOCABULARY. STORE's participant heads are RUNTIME-DECLARED -- the
# reader fits arguments over `_PARTICIPANT_TYPES = ("Entity", "Link", "%Undefined%")` using only
# the heads the space declares (`i2_read.py:93`, `_signature`, `_Fitter#link_members`) -- and
# `grep -c Card i2_read.py` is ZERO: `Card` is a DECKO convention, not a STORE constant. K8 itself
# documents the non-Card participant form `(Wanted "k")` as an unresolved target belonging to its
# link (`k8-draft-2.md:630`), and av-fixtures declares `(: Wanted ...)` beside `(: Card ...)`.
#
# R48-N1. The SAME scan read QUOTED STRING DATA as structure. A link key embeds its data members
# as `json.dumps` string literals (`i2_read.py:183`) -- measured: `(includes (Card 2) (Card 34)
# "rich_text+description")` -- so a link whose DATA merely CONTAINS the text `(Card 99)` had `99`
# treated as a participant and was OVER-REDACTED: a genuinely readable link silently dropped.
#
# Both are asserted on the ACTUAL SERIALIZED BYTES, and both FAIL against the pre-fix module --
# which is the proof they test something real rather than restating what already worked.
puts
puts "PART 2f -- LINK-KEY PARTICIPANT *FORM*: a non-Card participant fails closed; quoted DATA is data"

LINK_FORM_SUBJECT_ID = 2
LINK_FORM_ENTRY_ID = 34
LINK_FORM_DENIED_ID = 99

# THE MIXED-FORM LINK. Participant position 0 is `(Card 2)` -- AUTHORIZED. Position 1 is the
# documented unresolved-target form `(Wanted "ghost-key")` (`k8-draft-2.md:630`), which this deck
# CANNOT map to a card id and therefore CANNOT authorize. The pre-fix rule scanned out exactly one
# id (`2`), found it authorized, and emitted the link -- disclosing `ghost-key`.
LINK_MIXED_FORM = {
  "key" => "(links-to (Card 2) (Wanted \"ghost-key\"))",
  "digest" => "9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f",
  "link-type" => "links-to", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# THE QUOTED-DATA LINK. Its REAL participants are `(Card 2)` and `(Card 34)`, both authorized. Its
# DATA member is a json.dumps string literal that happens to CONTAIN the text `(Card 99)` -- a
# denied id. That text is DATA, not a participant position, so the link MUST be emitted verbatim.
LINK_QUOTED_DATA = {
  "key" => "(links-to (Card 2) (Card 34) \"see (Card 99) for detail\")",
  "digest" => "7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e",
  "link-type" => "links-to", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# THE ALL-CARD, ALL-AUTHORIZED REGRESSION GUARD -- must stay byte-identical.
LINK_FORM_PLAIN = {
  "key" => "(includes (Card 2) (Card 34) \"rich_text+description\")",
  "digest" => "644e26bceedfb6ac3ef0bd7fb032f3f1",
  "link-type" => "includes", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# A REAL DENIED `(Card 99)` PARTICIPANT -- PART 2e's rule, re-asserted here so the new structural
# audit cannot pass the form checks by accidentally loosening the id check.
LINK_FORM_REAL_DENIED = {
  "key" => "(includes (Card 2) (Card 34) (Card 99))",
  "digest" => "6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d6d",
  "link-type" => "includes", "subject-positions" => [0], "neighbour-positions" => [1],
  "copy-count" => 1, "is-participant" => false
}.freeze
# SELF-LINKS take the SAME audit: a loop key is still an expression with participant positions.
SELF_LINK_MIXED_FORM = {
  "key" => "(refers-to (Card 2) (Wanted \"loop-ghost\"))",
  "digest" => "3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b",
  "link-type" => "refers-to", "subject-positions" => [0], "copy-count" => 1,
  "is-participant" => false
}.freeze
SELF_LINK_FORM_PLAIN = {
  "key" => "(refers-to (Card 2) (Card 2))", "digest" => "cccccccccccccccccccccccccccccccc",
  "link-type" => "refers-to", "subject-positions" => [0, 1], "copy-count" => 1,
  "is-participant" => false
}.freeze

class LinkFormReader < NotReadyReader
  STATEFUL_ENVELOPE = {
    "outcome" => "ok", "epoch" => "f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2",
    "position" => 11, "read-at" => "2026-11-17T03:00:00.000000+00:00"
  }.freeze

  def readiness = Atomspace::MirrorReadiness::READY
  def origin = "live"
  def state_envelope = STATEFUL_ENVELOPE

  def store_profile
    { "schema-version" => "harness-1",
      "limits" => Atomspace::I3Envelope::LIMITS_KEYS.each_with_object({}) { |k, h| h[k] = nil } }
  end

  def neighbours_reading(card_id:, bucket: nil, limit: nil)
    Atomspace::I3ReadResult.new(
      envelope: STATEFUL_ENVELOPE,
      payload: {
        "entries" => [
          { "key" => "(Card #{LINK_FORM_ENTRY_ID})", "digest" => "27c0c6cba3d1f59f2b4f139f4e4e3ae0",
            "class" => "entity", "link-count" => 4, "link-copy-count" => 4,
            "links" => [LINK_FORM_PLAIN, LINK_QUOTED_DATA, LINK_MIXED_FORM,
                        LINK_FORM_REAL_DENIED] }
        ],
        "participant" => { "key" => "(Card #{LINK_FORM_SUBJECT_ID})",
                           "digest" => "2a10fe04e4c4da7310d27c31714a144f", "class" => "entity" },
        "bucket" => { "link-type" => "links-to",
                      "counts" => { "neighbour-count" => 1, "link-count" => 4 } },
        "self-links" => [SELF_LINK_FORM_PLAIN, SELF_LINK_MIXED_FORM]
      },
      atoms: [HarnessAtom.new(LINK_FORM_ENTRY_ID)]
    )
  end
end

Atomspace::LocalI3ReadBinding.install!(reader: LinkFormReader.new)
Card.reset!
Card.seed(id: LINK_FORM_SUBJECT_ID, name: "Decko Bot+description")
Card.seed(id: LINK_FORM_ENTRY_ID, name: "Card Thirty Four")
# SEEDED BUT DENIED, so a drop can never be confused with "never existed".
Card.seed(id: LINK_FORM_DENIED_ID, name: "Denied Third Participant")

# The allow-set is the SAME for all three checks below: subject + entry, and NOT card 99.
LINK_FORM_READABLE = [LINK_FORM_SUBJECT_ID, LINK_FORM_ENTRY_ID].freeze

rig.check("R48-B1: a link MIXING an authorized `(Card N)` with a NON-Card participant form is DROPPED") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_FORM_SUBJECT_ID.to_s, bucket: "links-to" },
                                  readable_ids: LINK_FORM_READABLE,
                                  label: "link-form-mixed-dropped")
  problems = []
  problems << "status #{status.inspect}" unless status == :ok

  # THE DISCLOSURE TEST, ON THE RAW BYTES. The mixed-form link's key, its digest, AND the
  # non-Card participant's own identity text must appear NOWHERE in the serialized string.
  problems << "MIXED-FORM link KEY LEAKED" if bytes.include?(LINK_MIXED_FORM["key"])
  problems << "MIXED-FORM link DIGEST LEAKED" if bytes.include?(LINK_MIXED_FORM["digest"])
  problems << "the non-Card participant text `(Wanted \"ghost-key\")` LEAKED" \
    if bytes.include?("(Wanted \\\"ghost-key\\\")") || bytes.include?("ghost-key")
  # The self-link form carrying the same defect.
  problems << "MIXED-FORM self-link KEY LEAKED" if bytes.include?(SELF_LINK_MIXED_FORM["key"])
  problems << "MIXED-FORM self-link DIGEST LEAKED" if bytes.include?(SELF_LINK_MIXED_FORM["digest"])
  problems << "the non-Card self-link participant `loop-ghost` LEAKED" if bytes.include?("loop-ghost")

  p = JSON.parse(bytes)
  entry = (p["entries"] || []).find { |e| e["key"] == "(Card #{LINK_FORM_ENTRY_ID})" }
  if entry.nil?
    problems << "THE ENTRY WAS DROPPED TOO (over-broad): #{(p['entries'] || []).map { |e| e['key'] }.inspect}"
  else
    # THE ENTRY SURVIVES -- its own key is authorized. Only the unauditable LINKS go.
    problems << "entry digest #{entry['digest'].inspect}" \
      unless entry["digest"] == "27c0c6cba3d1f59f2b4f139f4e4e3ae0"
    problems << "STORE's own link-count was altered: #{entry['link-count'].inspect}" \
      unless entry["link-count"] == 4
    links = entry["links"]
    # EXACTLY the two auditable, authorized links remain -- in STORE's order, byte-identical.
    unless links == [LINK_FORM_PLAIN, LINK_QUOTED_DATA]
      problems << "kept links are not [plain, quoted-data] verbatim: #{links.inspect}"
    end
  end
  # SELF-LINKS: the all-Card loop survives, the mixed-form loop is gone.
  problems << "self-links #{p['self-links'].inspect} is not just the all-Card loop" \
    unless p["self-links"] == [SELF_LINK_FORM_PLAIN]

  # STILL NO COINED VOCABULARY. The drop is silent, exactly as a denied `(Card N)` drop is.
  %w[acl-filtered-count acl-omitted dropped withheld links-omitted link-omitted
     unauditable participant-form].each do |invented|
    problems << "INVENTED key #{invented} on the wire" if bytes.include?(invented)
  end
  problems << "an `omitted` block was invented" if p.key?("omitted")

  [problems.empty?, problems.join("; ")]
end

rig.check("R48-N1: QUOTED DATA containing `(Card 99)` is DATA -- the link is emitted, NOT over-redacted") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_FORM_SUBJECT_ID.to_s, bucket: "links-to" },
                                  readable_ids: LINK_FORM_READABLE,
                                  label: "link-form-quoted-data")
  problems = []
  problems << "status #{status.inspect}" unless status == :ok

  p = JSON.parse(bytes)
  entry = (p["entries"] || []).find { |e| e["key"] == "(Card #{LINK_FORM_ENTRY_ID})" }
  if entry.nil?
    problems << "the entry is missing entirely"
  else
    links = entry["links"] || []
    quoted = links.find { |l| l["digest"] == LINK_QUOTED_DATA["digest"] }
    if quoted.nil?
      problems << "OVER-REDACTED: a link whose REAL participants are all authorized was dropped " \
                  "because its QUOTED DATA mentions `(Card 99)` (i2_read.py:183). kept=#{links.inspect}"
    else
      # BYTE-IDENTICAL: key, digest, positions, counts -- nothing mangled to make it safe.
      problems << "the quoted-data link was MANGLED: #{quoted.inspect}" unless quoted == LINK_QUOTED_DATA
    end
    # And its key text -- which CONTAINS `(Card 99)` as data -- rode out verbatim in the bytes.
    problems << "the quoted-data link KEY is not verbatim in the bytes" \
      unless bytes.include?("see (Card 99) for detail")
  end
  [problems.empty?, problems.join("; ")]
end

rig.check("REGRESSION: all-Card all-authorized links stay BYTE-IDENTICAL; any REAL denied participant still drops") do
  _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                  params: { id: LINK_FORM_SUBJECT_ID.to_s, bucket: "links-to" },
                                  readable_ids: LINK_FORM_READABLE,
                                  label: "link-form-regression")
  problems = []
  problems << "status #{status.inspect}" unless status == :ok

  p = JSON.parse(bytes)
  entry = (p["entries"] || []).find { |e| e["key"] == "(Card #{LINK_FORM_ENTRY_ID})" }
  if entry.nil?
    problems << "the entry is missing entirely"
  else
    plain = (entry["links"] || []).find { |l| l["digest"] == LINK_FORM_PLAIN["digest"] }
    problems << "the all-Card all-authorized link was not kept verbatim: #{plain.inspect}" \
      unless plain == LINK_FORM_PLAIN
  end
  # A REAL denied `(Card 99)` participant position still drops its link WHOLE -- key and digest.
  problems << "a REAL denied `(Card 99)` participant did NOT drop its link (key leaked)" \
    if bytes.include?(LINK_FORM_REAL_DENIED["key"])
  problems << "a REAL denied `(Card 99)` participant did NOT drop its link (digest leaked)" \
    if bytes.include?(LINK_FORM_REAL_DENIED["digest"])
  # NO denied card address in ANY participant position reaches the wire. The ONLY `(Card 99)` text
  # permitted anywhere in this body is the one inside the QUOTED DATA member, which is data.
  participant_form_hits = bytes.scan(/\(Card 99\)/).length
  quoted_data_hits = bytes.scan(/see \(Card 99\) for detail/).length
  problems << "`(Card 99)` appears #{participant_form_hits}x but only #{quoted_data_hits}x is quoted data" \
    unless participant_form_hits == quoted_data_hits

  [problems.empty?, problems.join("; ")]
end

# -------------------------------------------------------------- PART 3: REAL STORE CHILD, REAL DATA
puts
puts "PART 3 -- REAL STORE CHILD over REAL STDIO against the REAL ATTESTED EXPORT"

if opts[:interpreter].nil? || opts[:script].nil? || opts[:sidecar].nil? || opts[:export].nil?
  puts "  SKIPPED -- --interpreter/--script/--sidecar/--export not all supplied."
  puts "  (This is a REPORTED GAP, not a pass. The real-data integration is the primary claim.)"
  real_ran = false
else
  real_ran = true
  export_sha = Digest::SHA256.file(opts[:export]).hexdigest
  export_bytes = File.size(opts[:export])
  puts "  export      : #{opts[:export]}"
  puts "  export bytes: #{export_bytes}"
  puts "  export sha256: #{export_sha}"
  puts "  interpreter : #{opts[:interpreter]}"
  puts "  script      : #{opts[:script]}"
  puts "  script sha256: #{Digest::SHA256.file(opts[:script]).hexdigest}"

  # The I2 ceilings, which have NO DEFAULTS anywhere (`i2_read.py:120` "Every value is required;
  # there is no default anywhere"), plus the attested-export projection. Stated here in full
  # because neither STORE nor I2StdioTransport::Spawn will guess one.
  config = {
    "page-max" => {
      "page-max-entries" => 200, "page-max-connections" => 200, "page-max-bytes" => 1_048_576,
      "per-neighbour-link-max" => 100, "refresh-max-participants" => 50
    },
    "fanout-limit" => 100,
    "retention" => { "positions" => nil, "ms" => nil },
    "store-projection" => {
      "kind" => "attested-card-export",
      "raw-path" => opts[:export],
      "raw-sha256" => export_sha,
      "declare-ready" => true
    }
  }

  # KEYWORDS MATCH THE REAL Spawn SIGNATURE (`i2_stdio_transport.rb:253`): interpreter, script,
  # sidecar_path and config are all REQUIRED and none is discovered or defaulted.
  spawn = Atomspace::I2StdioTransport::Spawn.new(
    interpreter: opts[:interpreter],
    script: opts[:script],
    sidecar_path: opts[:sidecar],
    config: config
  )
  spawn.start!
  puts "  child pid   : #{spawn.pid}"

  # The real client over the real pipe pair (`i2_reader_process_client.rb:134`).
  client = Atomspace::I2ReaderProcessClient.new(writer: spawn.writer, reader: spawn.reader,
                                                deadline_ms: 15_000)
  readiness = client.readiness
  puts "  STORE readiness: ready?=#{readiness.ready?} reason=#{readiness.reason.inspect}"
  puts "  last_refusal   : #{client.last_refusal.inspect}" if client.respond_to?(:last_refusal)

  if readiness.ready? != true
    puts "  REAL STORE NOT READY -- the real-data assertions below CANNOT run and are reported as"
    puts "  FAILURES, not skipped, because the real-data integration is the primary claim."
    rig.check("REAL STORE child reaches ready") { [false, "reason=#{readiness.reason.inspect}"] }
    real_ran = false
  else
    Atomspace::LocalI3ReadBinding.install!(reader: client)
    Card.reset!
    Card.seed(id: 1, name: "Decko Bot")
    Card.seed(id: 2, name: "Decko Bot+description")

    profile = client.store_profile
    puts "  store_profile schema-version: #{profile && profile['schema-version'].inspect}"

    rig.check("REAL store_profile carries STORE's own schema-version and all ten limits names") do
      ok = profile.is_a?(Hash) &&
           profile["schema-version"].is_a?(String) &&
           profile["limits"].is_a?(Hash) &&
           Atomspace::I3Envelope::LIMITS_KEYS.all? { |k| profile["limits"].key?(k) }
      [ok, profile.inspect]
    end

    rig.check("REAL lookup: 200, outcome from STORE, STORE's key+digest, and NO Decko-sourced name") do
      _b, bytes, status, = rig.invoke("I3-10", :lookup, params: { name: "decko bot" },
                                                        label: "real-lookup")
      p = JSON.parse(bytes)
      ok = status == :ok &&
           %w[ok ok,\ partial unknown].include?(p["outcome"]) &&
           p.key?("epoch") && p.key?("position") && p.key?("read-at") &&
           p.key?("schema-version") && p.key?("limits")
      # BLOCKING-4 RESOLUTION (b), ASSERTED AGAINST THE REAL STORE. A probe of the real reader
      # child shows I2-02's resolved participant carries exactly ["class","digest","key"] -- NO
      # name, by key and by digest alike, because `_participant` emits `label`/`name` only
      # `with_properties` (i2_read.py:554-563) and I2-02 does not set it (:754). K8 I3-10's own
      # Returns names ONLY `key` + `digest` (k8-draft-2.md:574). So the payload must carry NO
      # `name` key at all -- previously it carried Decko's `card.name`
      # (authorized_card_identity.rb:58) mislabelled as the STORE-resolved canonical name.
      ok &&= !p.key?("name")
      ok &&= p["key"].is_a?(String) && p["digest"].is_a?(String) if p.key?("key")
      [ok, "status=#{status.inspect} body=#{bytes}"]
    end

    rig.check("REAL lookup emits NO `name` key, and NO Decko name string anywhere in the bytes") do
      path = File.join(opts[:out], "real-lookup.json")
      bytes = File.binread(path)
      p = JSON.parse(bytes)
      problems = []
      problems << "name key PRESENT: #{p['name'].inspect}" if p.key?("name")
      # The SEEDED DECKO NAME must not appear as a value anywhere in the serialized bytes -- that
      # is the exact substitution this defect was: Decko's name presented as STORE's answer.
      problems << "Decko name 'Decko Bot' LEAKED into the bytes" if bytes.include?("Decko Bot")
      # And the request string must not be echoed either (the original canonical-name rule).
      problems << "request string 'decko bot' echoed" if bytes.include?("decko bot")
      [problems.empty?, "#{problems.join('; ')} body=#{bytes}"]
    end

    rig.check("REAL lookup MISS answers the outcome 'unknown', NOT a 503") do
      _b, bytes, status, = rig.invoke("I3-10", :lookup,
                                      params: { name: "No Such Card At All 98765" },
                                      label: "real-lookup-miss")
      p = JSON.parse(bytes)
      [status == :ok && p["outcome"] == "unknown" && !p.key?("key"),
       "status=#{status.inspect} body=#{bytes}"]
    end

    rig.check("REAL lookup of an UNREADABLE card is indistinguishable from the miss (no oracle)") do
      Card.seed(id: 9, name: "Secret Card", readable: false)
      _b, bytes, status, = rig.invoke("I3-10", :lookup, params: { name: "Secret Card" },
                                                        readable_ids: [1, 2],
                                                        label: "real-lookup-unreadable")
      miss = JSON.parse(File.binread(File.join(opts[:out], "real-lookup-miss.json")))
      p = JSON.parse(bytes)
      [status == :ok && p["outcome"] == miss["outcome"] && p.keys.sort == miss.keys.sort,
       "unreadable=#{p.inspect} miss=#{miss.inspect}"]
    end

    rig.check("REAL open: 200, full envelope, real state triple from STORE") do
      _b, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" }, readable_ids: [1, 2],
                                                      label: "real-open")
      p = JSON.parse(bytes)
      ok = status == :ok &&
           Atomspace::I3Envelope::NINE_OUTCOMES.include?(p["outcome"]) &&
           p.key?("schema-version") && p.key?("limits")
      # A stateful outcome MUST carry a non-null triple.
      unless Atomspace::I3Envelope::NO_STATE_OUTCOMES.include?(p["outcome"])
        ok &&= !p["epoch"].nil? && !p["position"].nil? && !p["read-at"].nil?
      end
      [ok, "status=#{status.inspect} body=#{bytes[0, 600]}"]
    end

    rig.check("REAL neighbours: 200, full envelope") do
      _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                      params: { id: "1", bucket: "refers_to" },
                                      readable_ids: [1, 2], label: "real-neighbours")
      p = JSON.parse(bytes)
      ok = status == :ok && Atomspace::I3Envelope::NINE_OUTCOMES.include?(p["outcome"]) &&
           p.key?("schema-version") && p.key?("limits")
      unless Atomspace::I3Envelope::NO_STATE_OUTCOMES.include?(p["outcome"])
        ok &&= !p["epoch"].nil? && !p["position"].nil? && !p["read-at"].nil?
      end
      [ok, "status=#{status.inspect} body=#{bytes[0, 600]}"]
    end

    rig.check("REAL open with an ACL that filters everything still renders a conforming envelope") do
      _b, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" }, readable_ids: [],
                                                      label: "real-open-acl-empty")
      p = JSON.parse(bytes)
      # Unreadable source -> the ACL-empty shape, which must still be a conforming envelope.
      [status == :ok && Atomspace::I3Envelope::NINE_OUTCOMES.include?(p["outcome"]) &&
         p.key?("epoch") && p.key?("schema-version"),
       "status=#{status.inspect} body=#{bytes}"]
    end

    rig.check("envelope key ORDER is exactly K8 §5.2's six, first, in order") do
      bad = []
      %w[real-lookup real-open real-neighbours notready-open].each do |n|
        f = File.join(opts[:out], "#{n}.json")
        next unless File.exist?(f)

        keys = JSON.parse(File.binread(f)).keys
        bad << [n, keys.first(6)] unless keys.first(6) == Atomspace::I3Envelope::FIELDS
      end
      [bad.empty?, bad.inspect]
    end

    # ==========================================================================================
    # PART 3b -- THE STRUCTURED STORE GRAPH, against the REAL STORE and the REAL CLIENT CONTRACT
    # ==========================================================================================
    #
    # WHAT THESE PROVE. Every assertion below reads the ACTUAL SERIALIZED BYTES the real
    # controller passed to `render json:` -- never a hand-authored body -- and compares them to
    # values MEASURED from the real STORE child (`store-raw-probe.json`, sha256
    # e0dbe1235869833df15085552b0acb4ec0c75b79942ca67c01889254610e89c3).
    #
    # THE DEFECT UNDER TEST. `render_card_scoped` used to build `{"results" => [flat atoms]}` and
    # nothing else, which reduced STORE's structured answer -- `{"participant":…, "buckets":[…]}`
    # for I2-09 and `{"entries":[…]}` for I2-03 -- to a flat Array<Atom>. The only consumer that
    # exists, `av-client/src/drawn-graph.mjs`, ingests the drawn graph from `response.participant`
    # / `.buckets[]` / `.entries[]` / `.bucket` / `.counts` / `['self-links']` and NEVER reads
    # `results`, and its `ingestOpen` throws TypeError unless `participant.key` AND
    # `participant.digest` are both Strings. So the graph could not be ingested at all.
    puts
    puts "PART 3b -- THE STRUCTURED STORE GRAPH (real STORE payload shapes, real ACL)"

    # The MEASURED heads of card 1's eight I2-09 properties, in STORE's own order.
    REAL_CARD1_PROPERTY_HEADS = %w[
      codename content created-at key name trash type-name updated-at
    ].freeze
    # The MEASURED link-types of card 1's three I2-09 buckets.
    REAL_CARD1_BUCKET_LINK_TYPES = %w[created-by has-type updated-by].freeze
    # The MEASURED missing neighbour of card 2's `includes` bucket, verbatim from the probe.
    REAL_MISSING_ENTRY_KEY = "(Card 34)"
    REAL_MISSING_ENTRY_DIGEST = "27c0c6cba3d1f59f2b4f139f4e4e3ae0"
    # The MEASURED entries of card 2's `has-type` bucket: one readable entity, one missing card.
    REAL_HASTYPE_READABLE_KEY = "(Card 1)"
    REAL_HASTYPE_READABLE_DIGEST = "0742d9272ac67270a40dfa2f32a2c021"
    REAL_HASTYPE_DENIABLE_KEY = "(Card 3)"
    REAL_HASTYPE_DENIABLE_DIGEST = "39d3ba9cf9c5ecfa6eec9eb46d64a027"

    # The neighbour cards STORE really names, seeded so the harness ACL can ADMIT or DENY them
    # deliberately. An unseeded id is denied by absence, which would confuse "dropped by the ACL"
    # with "never seeded", so every id under test is seeded explicitly.
    Card.seed(id: 3, name: "Card Three")
    Card.seed(id: 34, name: "Card Thirty Four")

    # ---- (a) OPEN card 1: the participant address, label, eight properties and three buckets
    rig.check("REAL open card 1 carries STORE's participant (real key+digest), label, 8 properties and 3 buckets") do
      _b, bytes, status, = rig.invoke("I3-02", :open, params: { id: "1" },
                                                      readable_ids: [1, 2],
                                                      label: "struct-open-card1")
      p = JSON.parse(bytes)
      problems = []
      problems << "status #{status.inspect}" unless status == :ok

      part = p["participant"]
      if part.is_a?(Hash)
        # STORE's REAL address, both halves, String-typed -- what the client's wireIdentity needs.
        problems << "participant.key #{part['key'].inspect}" unless part["key"] == "(Card 1)"
        unless part["digest"] == "0742d9272ac67270a40dfa2f32a2c021"
          problems << "participant.digest #{part['digest'].inspect}"
        end
        problems << "participant.class #{part['class'].inspect}" unless part["class"] == "entity"
        # The label the client builds its `properties` label form from, VERBATIM.
        unless part["label"] == { "name" => "Decko Bot", "type-name" => "RichText" }
          problems << "participant.label #{part['label'].inspect}"
        end
        # STORE's trash is a REAL BOOLEAN false, not the string "False" the trash PROPERTY carries.
        problems << "participant.trash #{part['trash'].inspect}" unless part["trash"] == false
        problems << "participant.trash not a boolean" unless part["trash"].is_a?(FalseClass)

        props = part["properties"]
        if props.is_a?(Array)
          problems << "properties length #{props.length}" unless props.length == 8
          heads = props.map { |x| x["head"] }
          problems << "property heads #{heads.inspect}" unless heads == REAL_CARD1_PROPERTY_HEADS
          # Every property keeps STORE's own key+digest pair.
          bad_pairs = props.reject { |x| x["key"].is_a?(String) && x["digest"].is_a?(String) }
          problems << "properties with a non-String key/digest: #{bad_pairs.length}" if bad_pairs.any?
          # The `trash` PROPERTY's value is the STRING "False" and is NOT normalised to a boolean.
          trash_prop = props.find { |x| x["head"] == "trash" }
          problems << "trash property value #{trash_prop && trash_prop['value'].inspect} is not the untouched string" \
            unless trash_prop && trash_prop["value"].is_a?(String)
        else
          problems << "properties absent or not an Array: #{props.inspect}"
        end
      else
        problems << "NO participant: #{part.inspect}"
      end

      buckets = p["buckets"]
      if buckets.is_a?(Array)
        problems << "bucket link-types #{buckets.map { |b| b['link-type'] }.inspect}" \
          unless buckets.map { |b| b["link-type"] } == REAL_CARD1_BUCKET_LINK_TYPES
        # `drawn` is STORE's own flag and is false on every real bucket. The client gates reading
        # `entries` / `self-links` on it, so flipping it would change what is ingested.
        problems << "a bucket's `drawn` is not STORE's false" unless buckets.all? { |b| b["drawn"] == false }
        # STORE's real counts travel, including the position-subtotals list.
        created_by = buckets.find { |b| b["link-type"] == "created-by" }
        counts = created_by && created_by["counts"]
        unless counts.is_a?(Hash) && counts["neighbour-count"] == 1 && counts["link-count"] == 2 &&
               counts["link-copy-count"] == 2 && counts["position-subtotals"].is_a?(Array)
          problems << "created-by counts #{counts.inspect}"
        end
      else
        problems << "NO buckets: #{buckets.inspect}"
      end

      # ADDITIVE: the legacy flat list is STILL emitted, unchanged.
      problems << "results missing or wrong length: #{p['results'].inspect}" \
        unless p["results"].is_a?(Array) && p["results"].length == 8

      [problems.empty?, problems.join("; ")]
    end

    # ---- (b) NEIGHBOURS card 2 bucket `includes`: participant address + the real entry
    rig.check("REAL neighbours card 2 `includes` carries STORE's participant address and the real entry") do
      _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                      params: { id: "2", bucket: "includes" },
                                      readable_ids: [1, 2, 34],
                                      label: "struct-neighbours-card2-includes")
      p = JSON.parse(bytes)
      problems = []
      problems << "status #{status.inspect}" unless status == :ok

      # STORE's I2-03 payload carries NO participant (top-level keys are exactly ["entries"]), so
      # this address is the one the reader client obtains from STORE's OWN I2-02 and forwards
      # verbatim. The client REQUIRES it: ingestNeighboursPage throws without a String key+digest.
      part = p["participant"]
      if part.is_a?(Hash)
        problems << "participant.key #{part['key'].inspect}" unless part["key"] == "(Card 2)"
        unless part["digest"] == "2a10fe04e4c4da7310d27c31714a144f"
          problems << "participant.digest #{part['digest'].inspect}"
        end
      else
        problems << "NO participant on the neighbours page: #{part.inspect}"
      end

      # STORE's own bucket descriptor and its counts, for the REQUESTED link-type.
      bucket = p["bucket"]
      problems << "bucket #{bucket.inspect}" unless bucket.is_a?(Hash) && bucket["link-type"] == "includes"
      counts = p["counts"]
      unless counts.is_a?(Hash) && counts["neighbour-count"] == 1 && counts["link-count"] == 1
        problems << "counts #{counts.inspect}"
      end

      entries = p["entries"]
      if entries.is_a?(Array)
        entry = entries.find { |e| e["key"] == REAL_MISSING_ENTRY_KEY }
        if entry.nil?
          problems << "the #{REAL_MISSING_ENTRY_KEY} entry is ABSENT: #{entries.map { |e| e['key'] }.inspect}"
        else
          # THE LITERAL STRING, asserted as such -- not a truthiness test on some other field.
          problems << "class #{entry['class'].inspect} is not the literal \"missing\"" unless entry["class"] == "missing"
          problems << "digest #{entry['digest'].inspect}" unless entry["digest"] == REAL_MISSING_ENTRY_DIGEST
          links = entry["links"]
          if links.is_a?(Array) && links.length == 1
            link = links.first
            problems << "link-type #{link['link-type'].inspect}" unless link["link-type"] == "includes"
            problems << "link key not STORE's" unless link["key"].is_a?(String) && link["key"].include?("(includes (Card 2)")
            problems << "link digest #{link['digest'].inspect}" unless link["digest"].is_a?(String)
            problems << "is-participant #{link['is-participant'].inspect} is not a real boolean" \
              unless link["is-participant"] == false
            problems << "subject-positions #{link['subject-positions'].inspect}" unless link["subject-positions"] == [0]
          else
            problems << "links #{links.inspect}"
          end
        end
      else
        problems << "NO entries: #{entries.inspect}"
      end

      [problems.empty?, problems.join("; ")]
    end

    # ---- (c) NEGATIVE ACL: UNKNOWN and UNREADABLE are INDISTINGUISHABLE
    #
    # Both go through `render_acl_empty`, which is the WHOLE non-oracle argument for this surface:
    # a caller must not be able to tell "this card exists but you may not read it" from "there is
    # no such card". The comparison is on the ACTUAL SERIALIZED BYTES, with only STORE's own
    # per-read `read-at` normalised -- epoch and position are stable within one published state,
    # so they are compared as-is and are NOT normalised away.
    rig.check("NEGATIVE ACL: an UNREADABLE card and an UNKNOWN card are BYTE-IDENTICAL (no oracle)") do
      _b1, unreadable_bytes, unreadable_status, = rig.invoke(
        "I3-02", :open, params: { id: "1" }, readable_ids: [], label: "struct-open-denied-source"
      )
      _b2, unknown_bytes, unknown_status, = rig.invoke(
        "I3-02", :open, params: { id: "4242" }, readable_ids: [1, 2], label: "struct-open-unknown-source"
      )
      # STORE's read-at is sampled per read and legitimately differs; everything else must match.
      normalise = lambda { |s| s.gsub(/"read-at":"[^"]*"/, '"read-at":"<store-sampled>"') }
      problems = []
      problems << "status #{unreadable_status.inspect} vs #{unknown_status.inspect}" \
        unless unreadable_status == unknown_status
      unless normalise.call(unreadable_bytes) == normalise.call(unknown_bytes)
        problems << "BYTES DIFFER:\n          unreadable=#{unreadable_bytes}\n          unknown   =#{unknown_bytes}"
      end

      # AND no structured identity for the denied card may appear ANYWHERE in either body.
      [unreadable_bytes, unknown_bytes].each_with_index do |bytes, i|
        which = i.zero? ? "unreadable" : "unknown"
        %w[participant entries buckets self-links bucket digest].each do |k|
          problems << "#{which} body carries a structured `#{k}`" if bytes.include?("\"#{k}\"")
        end
        problems << "#{which} body leaks the key text (Card 1)" if bytes.include?("(Card 1)")
        problems << "#{which} body leaks card 1's digest" if bytes.include?("0742d9272ac67270a40dfa2f32a2c021")
        problems << "#{which} body leaks the Decko name" if bytes.include?("Decko Bot")
      end

      [problems.empty?, problems.join("; ")]
    end

    # ---- (d) NEGATIVE ACL: a DENIED NEIGHBOUR is DROPPED, key AND digest together
    #
    # Card 2's real `has-type` bucket holds TWO entries -- `(Card 1)` (class `entity`) and
    # `(Card 3)` (class `missing`). Denying ONE of them must remove it ENTIRELY, with its digest,
    # while the other survives. A digest that outlived its denied key would be a usable address
    # (STORE accepts `{"digest": …}` -- `i2_read.py:474-482`), i.e. the same read-permission
    # oracle a leaked key is.
    rig.check("NEGATIVE ACL: a DENIED neighbour's key AND digest are ABSENT, the readable one SURVIVES") do
      _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                      params: { id: "2", bucket: "has-type" },
                                      readable_ids: [1, 2],
                                      label: "struct-neighbours-denied-neighbour")
      p = JSON.parse(bytes)
      problems = []
      problems << "status #{status.inspect}" unless status == :ok

      # THE DENIED NEIGHBOUR: nowhere in the RAW BYTES, by key or by digest.
      problems << "DENIED key #{REAL_HASTYPE_DENIABLE_KEY} LEAKED" if bytes.include?(REAL_HASTYPE_DENIABLE_KEY)
      problems << "DENIED digest LEAKED" if bytes.include?(REAL_HASTYPE_DENIABLE_DIGEST)

      entries = p["entries"]
      if entries.is_a?(Array)
        keys = entries.map { |e| e["key"] }
        problems << "the denied entry is still listed: #{keys.inspect}" if keys.include?(REAL_HASTYPE_DENIABLE_KEY)
        # THE FIX IS NOT A BLANKET DROP: the readable neighbour is still there, with its digest.
        kept = entries.find { |e| e["key"] == REAL_HASTYPE_READABLE_KEY }
        if kept.nil?
          problems << "the READABLE neighbour #{REAL_HASTYPE_READABLE_KEY} was dropped too: #{keys.inspect}"
        else
          problems << "kept entry digest #{kept['digest'].inspect}" unless kept["digest"] == REAL_HASTYPE_READABLE_DIGEST
          problems << "kept entry class #{kept['class'].inspect}" unless kept["class"] == "entity"
          problems << "kept entry lost its links" unless kept["links"].is_a?(Array) && kept["links"].any?
        end
      else
        problems << "NO entries: #{entries.inspect}"
      end

      # NO VOCABULARY IS COINED to announce the drop -- that is what keeps it non-distinguishable.
      %w[acl-filtered-count acl-omitted dropped withheld].each do |invented|
        problems << "INVENTED key #{invented} on the wire" if bytes.include?(invented)
      end

      [problems.empty?, problems.join("; ")]
    end

    # ---- (e) A `missing` NEIGHBOUR stays `missing`: not relabelled, no metadata faked
    rig.check("a `missing` neighbour is classified `missing`, NOT deleted/trashed, with NO faked metadata") do
      bytes = File.binread(File.join(opts[:out], "struct-neighbours-card2-includes.json"))
      p = JSON.parse(bytes)
      entry = (p["entries"] || []).find { |e| e["key"] == REAL_MISSING_ENTRY_KEY }
      problems = []
      if entry.nil?
        problems << "the missing entry is absent entirely"
      else
        problems << "class #{entry['class'].inspect}" unless entry["class"] == "missing"
        # NOT RELABELLED. STORE has exactly one word for this and VIEW does not paraphrase it.
        %w[deleted trashed absent gone removed unknown placeholder].each do |wrong|
          problems << "relabelled as #{wrong}" if entry["class"] == wrong
        end
        # NO METADATA IS FAKED. STORE sent label {name:null, type-name:null} and trash:null; the
        # keys are PRESENT and the values are EXPLICITLY null. A substituted name would be VIEW
        # inventing a label for a card the store says it does not hold.
        label = entry["label"]
        unless label.is_a?(Hash) && label.key?("name") && label["name"].nil? &&
               label.key?("type-name") && label["type-name"].nil?
          problems << "label #{label.inspect} is not STORE's explicit {name:null, type-name:null}"
        end
        problems << "trash key absent" unless entry.key?("trash")
        problems << "trash #{entry['trash'].inspect} is not STORE's explicit null" unless entry["trash"].nil?
        # The digest and links are REAL and still travel (the entry's key was authorized).
        problems << "digest #{entry['digest'].inspect}" unless entry["digest"] == REAL_MISSING_ENTRY_DIGEST
        problems << "link-count #{entry['link-count'].inspect}" unless entry["link-count"] == 1
      end
      [problems.empty?, problems.join("; ")]
    end

    # ---- (f) THE ENVELOPE IS STILL COMPOSE'S, AND STILL STORE'S OWN STATE
    #
    # The structured keys are ADDITIVE: they must not displace, reorder or re-mint any of the six
    # envelope fields. `outcome`, `epoch` and `position` are compared against a DIRECT read of the
    # real STORE child taken in this same run, so "no fabricated success" is asserted against the
    # store's own answer rather than against a shape.
    rig.check("the envelope is still I3Envelope.compose's six, first, carrying STORE's REAL outcome/epoch/position") do
      direct = client.open_reading(card_id: 1)
      store_envelope = direct.envelope
      problems = []
      problems << "the direct STORE read produced no envelope" unless store_envelope.is_a?(Hash)

      %w[struct-open-card1 struct-neighbours-card2-includes struct-neighbours-denied-neighbour].each do |n|
        body = JSON.parse(File.binread(File.join(opts[:out], "#{n}.json")))
        keys = body.keys
        problems << "#{n}: first six #{keys.first(6).inspect}" unless keys.first(6) == Atomspace::I3Envelope::FIELDS
        # Every structured key must come AFTER the envelope, which is compose's insertion order.
        %w[participant buckets entries bucket counts].each do |sk|
          next unless keys.include?(sk)

          problems << "#{n}: structured `#{sk}` precedes the envelope" if keys.index(sk) < 6
        end
        problems << "#{n}: outcome #{body['outcome'].inspect} is outside the nine" \
          unless Atomspace::I3Envelope::NINE_OUTCOMES.include?(body["outcome"])
        next unless store_envelope.is_a?(Hash)

        # STORE's OWN state, not a VIEW default. epoch/position are stable across reads of one
        # published state; read-at is sampled per read and is only required to be STORE-shaped.
        problems << "#{n}: epoch #{body['epoch'].inspect} != STORE's #{store_envelope['epoch'].inspect}" \
          unless body["epoch"] == store_envelope["epoch"]
        problems << "#{n}: position #{body['position'].inspect} != STORE's #{store_envelope['position'].inspect}" \
          unless body["position"] == store_envelope["position"]
        problems << "#{n}: read-at #{body['read-at'].inspect} is not STORE's microsecond form" \
          unless body["read-at"].to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00\z/)
      end

      [problems.empty?, problems.join("; ")]
    end

    # ==========================================================================================
    # PART 3c -- MIXED-STATE ENRICHMENT: one response may not mix two STORE states
    # ==========================================================================================
    #
    # THE DEFECT. `merge_i2_03_participant_address` enriches an I2-03 neighbours page with
    # STORE's own `participant` / `bucket` / `counts`, obtained by issuing a SECOND, LATER I2-02
    # read. `address_envelope` was bound but used ONLY for an error string -- its `epoch` and
    # `position` were NEVER compared with the PRIMARY I2-03 envelope's. So if STORE published a
    # new state between the two reads, the participant class, the bucket descriptor and its counts
    # would be sampled at the LATER state while riding out under the EARLIER envelope's triple:
    # ONE response whose fields come from TWO DIFFERENT STORE STATES, labelled as one.
    #
    # HOW IT IS FORCED HERE, AGAINST THE REAL STORE. A subclass of the REAL
    # `Atomspace::I2ReaderProcessClient` over the REAL pipe pair perturbs ONE coordinate of the
    # I2-02 answer's envelope -- nothing else is stubbed. Both reads are genuine round trips to
    # the live reader child; the only fiction is the state skew, which is exactly the race a test
    # cannot schedule reliably. The PRIMARY read and the atoms are completely untouched.
    puts
    puts "PART 3c -- MIXED-STATE ENRICHMENT (real STORE, one coordinate skewed)"

    # Skew the I2-02 (enrichment) envelope ONLY. `OP_BUCKETS` is matched so the primary I2-03 read
    # and every other op keep STORE's own envelope verbatim.
    class EpochSkewedClient < Atomspace::I2ReaderProcessClient
      def initialize(skew:, **kw)
        @skew = skew
        super(**kw)
      end

      private

      def read_participant!(op, card_id, extra_args)
        envelope, payload = super
        return [envelope, payload] unless op == Atomspace::I2ReaderProcessClient::OP_BUCKETS
        return [envelope, payload] unless envelope.is_a?(Hash)

        [envelope.merge(@skew), payload]
      end
    end

    # The epoch skew. A separate POSITION skew case follows, so each coordinate is proven to be
    # compared -- a check that looked only at `epoch` would pass the position case and vice versa.
    EPOCH_SKEW = { "epoch" => "ffffffffffffffffffffffffffffffff" }.freeze

    rig.check("MIXED STATE: a skewed enrichment epoch leaves participant/bucket/counts ABSENT, still 200, same atoms") do
      skewed = EpochSkewedClient.new(writer: spawn.writer, reader: spawn.reader,
                                     deadline_ms: 15_000, skew: EPOCH_SKEW)
      problems = []

      # THE BASELINE, from the UNSKEWED real client: the enrichment normally DOES arrive.
      baseline = client.neighbours_reading(card_id: 2, bucket: "includes")
      unless baseline.payload.is_a?(Hash) && baseline.payload["participant"].is_a?(Hash)
        problems << "the UNSKEWED baseline carries no participant, so this case proves nothing"
      end
      baseline_atoms = baseline.atoms.map(&:to_h)

      reading = skewed.neighbours_reading(card_id: 2, bucket: "includes")
      payload = reading.payload
      # ABSENT, NOT NULL, NOT FABRICATED -- all three enrichment keys.
      %w[participant bucket counts].each do |k|
        problems << "`#{k}` is PRESENT (#{payload[k].inspect}) under a skewed state" if payload.key?(k)
      end
      # THE READ STILL SUCCEEDED, with STORE's own envelope and the SAME atoms. Not a 503.
      problems << "the reading lost its envelope" unless reading.envelope.is_a?(Hash)
      problems << "outcome #{reading.envelope['outcome'].inspect} is not a stateful success" \
        unless %w[ok ok,\ partial].include?(reading.envelope["outcome"])
      problems << "no_state? became true (this must NOT degrade to a refusal)" if reading.no_state?
      problems << "STORE's entries were disturbed" unless payload["entries"].is_a?(Array)
      unless reading.atoms.map(&:to_h) == baseline_atoms
        problems << "THE ATOMS CHANGED: #{reading.atoms.map(&:to_h).inspect} vs #{baseline_atoms.inspect}"
      end
      # The reason is recorded on the SERVER-SIDE-ONLY channel, naming the real mismatch.
      refusal = skewed.last_refusal
      problems << "no refusal recorded for the mismatch" unless refusal.is_a?(String)
      problems << "the refusal does not name the state skew: #{refusal.inspect}" \
        unless refusal.to_s.include?("NEW STATE BETWEEN THE TWO READS")

      skewed.stop! if skewed.respond_to?(:stop!)
      [problems.empty?, problems.join("; ")]
    end

    rig.check("MIXED STATE: a skewed enrichment POSITION is caught too (both coordinates compared)") do
      # STORE's OWN position, +1 -- a real neighbouring state value, not a sentinel.
      real_position = client.neighbours_reading(card_id: 2, bucket: "includes").envelope["position"]
      problems = []
      problems << "STORE's position is not an Integer: #{real_position.inspect}" unless real_position.is_a?(Integer)

      skewed = EpochSkewedClient.new(writer: spawn.writer, reader: spawn.reader,
                                     deadline_ms: 15_000, skew: { "position" => real_position + 1 })
      reading = skewed.neighbours_reading(card_id: 2, bucket: "includes")
      %w[participant bucket counts].each do |k|
        problems << "`#{k}` PRESENT under a skewed position" if reading.payload.key?(k)
      end
      problems << "no_state? became true" if reading.no_state?
      problems << "the atoms were lost" unless reading.atoms.is_a?(Array) && !reading.atoms.empty?
      problems << "the refusal does not name the skew: #{skewed.last_refusal.inspect}" \
        unless skewed.last_refusal.to_s.include?("NEW STATE BETWEEN THE TWO READS")

      skewed.stop! if skewed.respond_to?(:stop!)
      [problems.empty?, problems.join("; ")]
    end

    rig.check("MIXED STATE renders a REAL 200 with the SAME atoms and NO structured graph (not a 503)") do
      # THROUGH THE REAL CONTROLLER, on the SERIALIZED BYTES. The skewed client is bound to the
      # real port, so this is the whole stack with one coordinate perturbed.
      skewed = EpochSkewedClient.new(writer: spawn.writer, reader: spawn.reader,
                                     deadline_ms: 15_000,
                                     skew: { "epoch" => "ffffffffffffffffffffffffffffffff" })
      Atomspace::LocalI3ReadBinding.install!(reader: skewed)
      _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                      params: { id: "2", bucket: "includes" },
                                      readable_ids: [1, 2, 34],
                                      label: "mixed-state-neighbours")
      p = JSON.parse(bytes)
      problems = []
      # A REAL 200 WITH A REAL ENVELOPE -- the degradation must not become a refusal.
      problems << "status #{status.inspect} (must be :ok, never a 503)" unless status == :ok
      problems << "outcome #{p['outcome'].inspect}" unless Atomspace::I3Envelope::NINE_OUTCOMES.include?(p["outcome"])
      problems << "envelope order #{p.keys.first(6).inspect}" unless p.keys.first(6) == Atomspace::I3Envelope::FIELDS
      problems << "the envelope triple went null on a stateful outcome" \
        if !Atomspace::I3Envelope::NO_STATE_OUTCOMES.include?(p["outcome"]) &&
           (p["epoch"].nil? || p["position"].nil?)
      # ABSENT, NOT NULL. A `"participant":null` would assert an address exists and is nothing.
      %w[participant bucket counts].each do |k|
        problems << "`#{k}` emitted from a DIFFERENT store state" if p.key?(k)
        problems << "`#{k}` emitted as an explicit null" if bytes.include?("\"#{k}\":null")
      end
      # THE ATOMS STILL CAME THROUGH: `results` is the unchanged flat list, identical to the
      # unskewed render, so a previously-succeeding read still succeeds with the same atoms.
      unskewed = JSON.parse(File.binread(File.join(opts[:out], "struct-neighbours-card2-includes.json")))
      problems << "results #{p['results'].inspect} != the unskewed #{unskewed['results'].inspect}" \
        unless p["results"] == unskewed["results"]
      problems << "`entries` was lost" unless p["entries"].is_a?(Array) && !p["entries"].empty?
      # NOTHING WAS COINED to report the skew.
      %w[mixed-state stale-enrichment state-skew enrichment].each do |invented|
        problems << "INVENTED key #{invented}" if bytes.include?(invented)
      end

      skewed.stop! if skewed.respond_to?(:stop!)
      # REBIND THE UNSKEWED CLIENT so the checks after this one see the real store again.
      Atomspace::LocalI3ReadBinding.install!(reader: client)
      [problems.empty?, problems.join("; ")]
    end

    rig.check("COUNTS PRECEDENCE: a pre-existing TOP-LEVEL `counts` is NOT overwritten by the enrichment") do
      # STORE's real I2-03 payload carries NO top-level `counts` (measured: top-level keys are
      # exactly ["entries"]), so the precedence rule is LATENT against this store. It is forced
      # here by having the REAL client's own I2-03 answer carry one, and asserted both on the
      # payload and on the serialized bytes.
      sentinel = { "neighbour-count" => 4242, "link-count" => 4242, "store-authoritative" => true }

      counts_client = Class.new(Atomspace::I2ReaderProcessClient) do
        private

        define_method(:read_participant!) do |op, card_id, extra_args|
          envelope, payload = super(op, card_id, extra_args)
          # Inject a TOP-LEVEL `counts` into STORE's own I2-03 payload, exactly as a future STORE
          # that emitted one would. Everything else is untouched and the state is NOT skewed.
          if op == Atomspace::I2ReaderProcessClient::OP_NEIGHBOURS && payload.is_a?(Hash)
            payload = payload.merge("counts" => sentinel)
          end
          [envelope, payload]
        end
      end.new(writer: spawn.writer, reader: spawn.reader, deadline_ms: 15_000)

      problems = []
      reading = counts_client.neighbours_reading(card_id: 2, bucket: "includes")
      # STORE'S OWN TOP-LEVEL VALUE WINS -- the bucket-derived one must not replace it.
      unless reading.payload["counts"] == sentinel
        problems << "the enrichment OVERWROTE STORE's top-level counts: #{reading.payload['counts'].inspect}"
      end
      # And the enrichment still delivered its OTHER keys: this is a precedence rule, not a veto.
      problems << "the participant enrichment was lost as collateral" unless reading.payload["participant"].is_a?(Hash)
      problems << "the bucket descriptor was lost as collateral" unless reading.payload["bucket"].is_a?(Hash)

      # THROUGH THE REAL RENDERER, on the serialized bytes: `forward_store_metadata` forwards the
      # top-level `counts` and `project_store_graph` must leave it alone.
      Atomspace::LocalI3ReadBinding.install!(reader: counts_client)
      _b, bytes, status, = rig.invoke("I3-03", :neighbours,
                                      params: { id: "2", bucket: "includes" },
                                      readable_ids: [1, 2, 34],
                                      label: "counts-precedence-neighbours")
      p = JSON.parse(bytes)
      problems << "status #{status.inspect}" unless status == :ok
      problems << "rendered counts #{p['counts'].inspect} is not STORE's own top-level value" \
        unless p["counts"] == sentinel
      problems << "the bucket's own counts were substituted for STORE's" \
        if p["counts"] == p.dig("bucket", "counts") && p.dig("bucket", "counts") != sentinel

      counts_client.stop! if counts_client.respond_to?(:stop!)
      Atomspace::LocalI3ReadBinding.install!(reader: client)
      [problems.empty?, problems.join("; ")]
    end

    # ==========================================================================================
    # THE CLIENT-SIDE ACCEPTANCE ARTEFACT -- the REAL serialized bodies, written for av-client
    # ==========================================================================================
    #
    # Written NEXT TO THE ATTESTED EXPORT (the `i3real` scratch directory the real STORE probe and
    # the export already live in), derived from `--export` rather than hardcoded.
    #
    # `legacy_results_only` IS THE NEGATIVE CONTROL and it is DERIVED FROM THE REAL BYTES, not
    # hand-authored: the real `open_card1` body minus the structured keys and minus the six
    # envelope fields, which reconstructs the OLD pre-repair `{results:, _meta:}` wrapper. That is
    # the shape av-client's REAL `checkI3Body` must REJECT (it fails on the first assertion -- no
    # top-level `outcome`), and the shape `drawn-graph.mjs` cannot ingest.
    rig.check("the REAL serialized controller bodies are written for the CLIENT-side acceptance step") do
      bodies_dir = opts[:bodies_dir] || File.join(File.dirname(opts[:export]))
      FileUtils.mkdir_p(bodies_dir)
      bodies_path = File.join(bodies_dir, "controller-bodies.json")

      read_body = lambda do |label|
        JSON.parse(File.binread(File.join(opts[:out], "#{label}.json")))
      end

      lookup_body = read_body.call("real-lookup")
      open_body = read_body.call("struct-open-card1")
      neighbours_body = read_body.call("struct-neighbours-card2-includes")

      # DERIVED FROM THE REAL BODY. Remove the structured graph keys and the six envelope fields;
      # whatever remains IS the old wrapper, in the old key order.
      legacy = open_body.reject do |k, _v|
        Atomspace::I3Envelope::FIELDS.include?(k) ||
          %w[participant buckets entries bucket counts self-links].include?(k)
      end

      doc = {
        "lookup" => lookup_body,
        "open_card1" => open_body,
        "neighbours_card2_includes" => neighbours_body,
        "legacy_results_only" => legacy
      }
      bytes = JSON.pretty_generate(doc)
      File.binwrite(bodies_path, bytes)

      problems = []
      problems << "legacy control still carries an `outcome`" if legacy.key?("outcome")
      problems << "legacy control is not the {results,_meta} wrapper: #{legacy.keys.inspect}" \
        unless legacy.keys.sort == %w[_meta results]
      problems << "open_card1 lost its participant" unless open_body["participant"].is_a?(Hash)
      problems << "neighbours lost its entries" unless neighbours_body["entries"].is_a?(Array)

      puts "  controller-bodies.json : #{bodies_path}"
      puts "  controller-bodies bytes: #{bytes.bytesize}"
      puts "  controller-bodies sha256: #{Digest::SHA256.hexdigest(bytes)}"

      [problems.empty?, problems.join("; ")]
    end

    client.stop! if client.respond_to?(:stop!)
    spawn.stop! if spawn.respond_to?(:stop!)
  end
end

manifest = rig.write_manifest

# ============================================================== THE GLOBAL STATUS ASSERTION
#
# WHY THIS EXISTS. The client's `classifyHttp` (`live-bridge.mjs:821`) maps ANY `status >= 500` to
# `backend-error` and the caller throws LiveTransportFailed BEFORE `checkI3Body` runs, so a 5xx
# makes its body UNREADABLE no matter how conforming the body is. A single surviving 5xx on a
# non-refusal path would therefore re-open exactly the defect this round repaired. Asserted ONCE,
# over EVERY captured response in the whole run, rather than per-case where one could be missed.
#
# THE ONE DOCUMENTED EXCEPTION is a genuine K9 / configuration REFUSAL, which K8 §5.1 `:289-291`
# puts OUTSIDE the outcome set entirely ("Refusal is K9's, not K8's") and which therefore correctly
# carries NO envelope. The only such body on this surface is the frozen CONFIG_REFUSAL_BODY. It is
# asserted POSITIVELY below -- that it is non-envelope ON PURPOSE -- so the exception is proven
# rather than merely tolerated.
puts
puts "GLOBAL -- no captured response may carry an HTTP status >= 500 (the client cannot parse one)"

HTTP_STATUS_NUMBERS = {
  "ok" => 200, "bad_request" => 400, "unauthorized" => 401, "forbidden" => 403,
  "not_found" => 404, "not_implemented" => 501, "service_unavailable" => 503,
  "internal_server_error" => 500
}.freeze

rig.check("NO captured response has HTTP status >= 500 (every non-refusal body stays parseable)") do
  offenders = rig.captured.filter_map do |c|
    code = HTTP_STATUS_NUMBERS[c["status"]]
    next "#{c['label']}: UNMAPPED status #{c['status'].inspect}" if code.nil?

    "#{c['label']}: status #{c['status']} (#{code})" if code >= 500
  end
  [offenders.empty?, offenders.join("; ")]
end

rig.check("the CONFIG refusal is SEPARATELY and INTENTIONALLY non-envelope (a K9 refusal, 503)") do
  body = Api::Mcp::I3ReadController::CONFIG_REFUSAL_BODY
  problems = []
  # It must NOT be an envelope: a refusal is outside K8's outcome set (k8-draft-2.md:289-291).
  problems << "refusal carries an `outcome` -- it must not" if body.key?(:outcome) || body.key?("outcome")
  # It must carry NO _meta at all: an unauthenticated caller gets no backend/readiness signal.
  problems << "refusal carries _meta" if body.key?(:_meta) || body.key?("_meta")
  problems << "refusal is not frozen" unless body.frozen?
  # And it is NOT in the captured manifest -- it is never produced by any envelope path.
  leaked = rig.captured.select { |c| JSON.parse(File.binread(c["path"])).key?("error") }
  problems << "an `error`-shaped body was captured: #{leaked.map { |c| c['label'] }.inspect}" if leaked.any?
  [problems.empty?, problems.join("; ")]
end

manifest = rig.write_manifest
puts
puts "captured #{rig.captured.length} serialized responses -> #{manifest}"
puts
puts "=" * 86
puts "RESULT: #{rig.checks - rig.failures.length} passed, #{rig.failures.length} failed, of #{rig.checks} checks"
puts "REAL-STORE INTEGRATION RAN: #{real_ran}"
rig.failures.each { |f| puts "  FAILED: #{f}" }
puts "=" * 86
exit(rig.failures.empty? && real_ran ? 0 : 1)
