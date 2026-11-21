# frozen_string_literal: true
#
# PURE-RUBY, NO-RAILS, NO-DB, LOCAL-ONLY proof for the SAME-ORIGIN DECKO-SESSION authenticated
# I3 read path (lane D, round 24).
#
# WHY A STANDALONE HARNESS AND NOT `bundle exec rspec`. The deck's bundle cannot be resolved on
# this host: `bundle`/`gem` are broken shims ("No such file or directory --
# /e/Ruby34-x64/bin/bundle"), and the two gems this surface's request specs need most -- `card`
# (1.110.0) and `decko` (0.20.0) -- are NOT INSTALLED (only 203 gems are present under
# C:/Users/Lake/.local/share/gem/ruby/3.4.0/gems; `ls -d .../card-* .../decko-*` matches nothing).
# There is also no Postgres. So the ~98 `type: :request` examples in
# spec/mcp_api/controllers/i3_read_controller_spec.rb CANNOT EXECUTE HERE, and reporting an rspec
# result would be a fabrication. This file is plain Ruby with a hand-rolled assert, run as
# `ruby <this file>`, so what it prints is real.
#
# WHAT IS ACTUALLY PROVEN HERE: the controller's own AUTHENTICATION/AUTHORIZATION LOGIC, by
# loading the REAL private methods off the REAL controller source and running them against
# doubles of Card / Card::Auth / Card::Env / the Rails request. The methods are not transcribed
# or paraphrased -- they are extracted from the real file (see ControllerLogic below), so a
# change to the controller changes what this harness executes.
#
# WHAT IS **NOT** PROVEN, stated so a green run is not over-read:
#   * NO live Rails request. No router, no middleware stack, no real before_action halting
#     semantics, no real HTTP status codes on the wire.
#   * NO Postgres and NO real Decko. The real `Card::Auth.signin_with_session`, the real
#     `ok?(:read)`, real +*read rule resolution, real role cards, the real cookie jar and the
#     real session store are all DOUBLES here. DB-backed ACL behaviour is therefore ASSERTED
#     against in-memory doubles only.
#   * NO deployment, NO access grant, NO role creation.
#
# Run: ruby spec/mcp_api/i3_session_auth_harness.rb

# =============================================================================================
# Doubles for the framework surface the controller's auth path touches.
# =============================================================================================

class FakeCardname
  attr_reader :key

  def initialize(text)
    @text = text.to_s
    # A faithful re-expression of Cardname#simple_key's separator/case collapsing
    # (cardname-0.19.1/lib/cardname.rb:106-116): underscore, collapse non-key runs, drop empties.
    @key = @text.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
                .gsub(/[^a-z0-9*]+/, "_").split(/_+/).reject(&:empty?).join("_")
  end

  def to_s = @text
  def ==(other) = other.respond_to?(:key) ? key == other.key : to_s == other.to_s
end

# A Card double. `readable_by` is the set of account names permitted to read it, so an elevation
# (reading as a bot or as another user) is VISIBLE as a different answer.
class FakeCard
  attr_reader :id, :type_id, :trash, :read_rule_id

  def initialize(id:, name:, type_id: FakeCardConsts::USER_ID, readable_by: nil,
                 read_rule_id: 1, trash: false, new_card: false, account: true)
    @id = id
    @name_text = name
    @type_id = type_id
    @readable_by = readable_by
    @read_rule_id = read_rule_id
    @trash = trash
    @new_card = new_card
    @account = account
  end

  def name = FakeCardname.new(@name_text)
  def new_card? = @new_card
  def account? = @account

  def ok?(action)
    raise "unexpected action #{action}" unless action == :read

    # nil readable_by => world-readable. Otherwise only the listed identities may read.
    return true if @readable_by.nil?

    @readable_by.include?(FakeAuth.effective_identity)
  end
end

module FakeCardConsts
  # REAL PERSISTED VALUES from the stock deck's own fixtures, not invented ones. This matters:
  # the previous version of this harness used USER_ID = 7 / ANONYMOUS_ID = 8 and had
  # FakeAuth.current_card return **nil** for AnonymousID, which made the controller's
  # `return nil unless Card::Auth.signed_in? == true` line UNTESTABLE -- deleting it still left
  # the `card && ...` guard refusing a nil card, so the mutation was not caught (49/0 either way).
  #
  # In the real framework `Card::Auth.current_card` is `Card[current_id]`
  # (card/lib/card/auth/current.rb:21-25), and Anonymous is a REAL PERSISTED CARD:
  #   id: 201, name: Anonymous, codename: anonymous, type_id: 2, trash: 0
  #   (decko/mod/defaults/data/fixtures/real/cards.yml:3712-3730)
  # and card id 2 is RichText / codename `basic` (same file, :24-40). The User TYPE card is id 18
  # (same file, :316-320), so a real user account card carries type_id 18.
  USER_ID = 18
  ANONYMOUS_ID = 201
  ANONYMOUS_TYPE_ID = 2 # RichText, per the fixture above -- NOT a User type
end

# Card::Auth double. Models the REAL semantics the controller depends on:
#   * current_id defaults to AnonymousID            (card/lib/card/auth/current.rb:7-9)
#   * signed_in? is current_id != AnonymousID       (current.rb:45-47)
#   * signin_with -> signin_with_session reads session[session_user_key] and rejects a non-account
#     (current.rb:50-63)
#   * current_roles is [:anyone_signed_in] + role_ids(current_id)  (current.rb:28-33)
#   * as(name) pushes a proxy identity                             (auth/proxy.rb:6-24)
#   * reset clears current/as/roles                                (current.rb:78-80)
module FakeAuth
  SESSION_USER_KEY = :user_magi_archive_production

  class << self
    attr_reader :as_calls, :as_stack, :signin_calls
    attr_accessor :role_memberships
    # TEST SEAM for the signed_in?/current_card DIVERGENCE case (see the harness check
    # "the controller TRUSTS the framework's signed_in? predicate"). When set to false, signed_in?
    # answers false while current_card still returns a perfectly valid User account card -- which
    # is the ONLY input shape that the `return nil unless Card::Auth.signed_in? == true` line
    # refuses and the AnonymousID / account? / type_id guards do NOT. Without this seam that line
    # is behaviourally redundant and provable only by source inspection.
    attr_accessor :force_signed_in

    def reset!
      @current_id = FakeCardConsts::ANONYMOUS_ID
      @as_stack = []
      @as_calls = []
      @signin_calls = []
      @roles = nil
      @role_memberships = {}
      @force_signed_in = nil
    end

    def current_id = @current_id

    def current_id=(id)
      @roles = nil
      @current_id = id
    end

    def current_card
      # THE BLIND-SPOT FIX. This used to `return nil if @current_id == ANONYMOUS_ID`, which is NOT
      # what the framework does: `current_card` is `Card[current_id]`
      # (card/lib/card/auth/current.rb:21-25), and Anonymous is a PERSISTED CARD (id 201), so an
      # anonymous caller gets a REAL CARD OBJECT back, never nil.
      #
      # Returning nil here silently made the controller's `signed_in?` guard redundant: the
      # downstream `return nil unless card && ...` caught the nil, so deleting the signed_in? line
      # changed no test outcome. With the real registry lookup, an anonymous caller now arrives at
      # those downstream guards holding a live card, and ONLY the explicit anonymous checks refuse
      # it -- so each of them is independently provable by mutation.
      FakeCardRegistry.by_id[@current_id]
    end
    alias_method :current, :current_card

    def signed_in?
      # The seam: an explicit false models a framework that reports NOT-signed-in while
      # current_card still yields a valid account card. Default is the REAL semantics
      # (current.rb:45-47).
      return @force_signed_in if @force_signed_in == false

      @current_id != FakeCardConsts::ANONYMOUS_ID
    end

    def signin_with(opts = {})
      @signin_calls << opts
      # No token on the browser path -> signin_with_session.
      card_id = FakeEnv.session[SESSION_USER_KEY]
      # THE REAL CHECK (current.rb:61): a session id that is not an account is discarded.
      card_id = nil unless card_id && FakeCardRegistry.by_id[card_id]&.account?
      self.current_id = card_id || FakeCardConsts::ANONYMOUS_ID
    end

    def current_roles
      return [] unless signed_in?

      @roles ||= [FakeCardname.new("anyone signed in")] +
                 (@role_memberships[@current_id] || []).map { |r| FakeCardname.new(r) }
    end

    def as(name)
      @as_calls << name.to_s
      @as_stack.push(name.to_s)
      yield
    ensure
      @as_stack.pop
    end

    # Whoever a read is CURRENTLY attributed to: the innermost `as`, else the signed-in user.
    def effective_identity
      @as_stack.last || current_card&.name.to_s
    end

    def reset
      @current_id = FakeCardConsts::ANONYMOUS_ID
      @as_stack = []
      @roles = nil
    end
  end
end

# Card::Env double. Models that Env.session comes from the BOUND CONTROLLER's request
# (card/lib/card/env.rb:17-29) and that Env is MODULE-LEVEL state reset to nil (env.rb:25-29,:42).
module FakeEnv
  class << self
    attr_reader :controller, :reset_calls

    def reset!
      @controller = nil
      @reset_calls = []
    end

    def reset(controller = nil)
      @reset_calls << (controller.nil? ? :nil : :controller)
      @controller = controller
    end

    def session
      @controller&.request&.session || {}
    end
  end
end

module FakeCardRegistry
  class << self
    attr_accessor :by_name, :by_id

    def reset!
      @by_name = {}
      @by_id = {}
      # ANONYMOUS IS ALWAYS PRESENT, exactly as it is in any real deck. Registering it here is
      # what makes the controller's anonymous guards testable at all: with the real persisted
      # card in the registry, `Card::Auth.current_card` for an anonymous caller returns a LIVE,
      # NON-TRASHED card with an id -- so the downstream `card && !card.trash && card.id` guard
      # PASSES and only the explicit anonymous checks stand in the way.
      #
      # Values are the fixture's own (decko/mod/defaults/data/fixtures/real/cards.yml:3712-3730):
      # id 201, type_id 2, trash 0, read_rule_id 10, account? false
      # (decko/mod/account/set/self/anonymous.rb:7-9).
      anon = FakeCard.new(id: FakeCardConsts::ANONYMOUS_ID, name: "Anonymous",
                          type_id: FakeCardConsts::ANONYMOUS_TYPE_ID,
                          read_rule_id: 10, trash: false, account: false)
      @by_id[FakeCardConsts::ANONYMOUS_ID] = anon
      @by_name["anonymous"] = anon
    end

    def fetch(key)
      return @by_id[key] if key.is_a?(Integer)

      @by_name[FakeCardname.new(key).key]
    end

    def [](key) = fetch(key)
  end
end

# Install under the real constant names.
class Card
  UserID = FakeCardConsts::USER_ID
  AnonymousID = FakeCardConsts::ANONYMOUS_ID
  Auth = FakeAuth
  Env = FakeEnv
  Name = FakeCardname

  def self.fetch(key) = FakeCardRegistry.fetch(key)
  def self.[](key) = FakeCardRegistry.fetch(key)
end

# Rails.logger double that RECORDS every line, so "no secret in logs" is checkable.
module Rails
  class Logger
    attr_reader :lines

    def initialize = @lines = []
    def warn(msg) = @lines << msg.to_s
    def error(msg) = @lines << msg.to_s
    def info(msg) = @lines << msg.to_s
  end

  class << self
    attr_accessor :logger
  end
end
Rails.logger = Rails::Logger.new

# ActiveSupport's #blank?/#present? (the controller uses both).
class Object
  def blank? = respond_to?(:empty?) ? !!empty? : !self
  def present? = !blank?
end
class NilClass
  def blank? = true
end
class String
  def blank? = strip.empty?
end

# Minimal request/headers double.
FakeRequest = Struct.new(:headers, :session, keyword_init: true)

# =============================================================================================
# THE CODE UNDER TEST: the controller's REAL private methods, extracted from the REAL source.
#
# The controller cannot be `require`d here -- it inherits from BaseController <
# ActionController::API and includes an ActiveSupport::Concern, none of which exist without
# Rails. So the auth/authorization methods are CUT OUT OF THE REAL FILE BY NAME and evaluated
# into a plain class. If a method is renamed or deleted, extraction FAILS LOUDLY rather than
# silently testing nothing.
# =============================================================================================

CONTROLLER_PATH = File.expand_path(
  "../../mod/mcp_api/app/controllers/api/mcp/i3_read_controller.rb", __dir__
)
SOURCE = File.read(CONTROLLER_PATH)

EXTRACTED = %w[
  require_user_principal! session_mode? require_session_principal! session_account
  require_i3_read_scope! session_role_entitled? service_account? service_account_ids
  service_account_names token_scopes readable_source? render_card_scoped
  clear_mcp_state_after_request assert_single_threaded_identity!
  render_unavailable render_backend_unavailable render_unsupported_configuration
].freeze

def extract_method(name)
  escaped = Regexp.escape(name)
  # NOT `\b`: a word boundary does not match after `!` or `?`, so `require_user_principal!\b`
  # never matches. Assert instead that no further identifier character follows.
  body = SOURCE[/^      def #{escaped}(?![A-Za-z0-9_?!]).*?^      end$/m]
  raise "could not extract ##{name} from the controller source" unless body

  body.sub(/^      /, "").gsub(/^      /, "")
end

CONTROLLER_LOGIC_SRC = EXTRACTED.map { |m| extract_method(m) }.join("\n\n")

# A stand-in host for the extracted methods, supplying ONLY the collaborators the real
# controller inherits (render/performed?/params/request) -- never a relaxed auth decision.
class ControllerLogic
  DENIED_META = { surface: "i3" }.freeze
  ERROR_META = { surface: "i3" }.freeze

  # THE REAL CONSTANT, parsed out of the controller source rather than retyped here. If the
  # controller's list changes, this harness executes the NEW list; if the constant is deleted,
  # extraction fails loudly instead of silently testing a stale copy.
  VACUOUS_SESSION_ROLE_KEYS = begin
    literal = SOURCE[/VACUOUS_SESSION_ROLE_KEYS\s*=\s*%w\[([^\]]*)\]/, 1]
    raise "could not extract VACUOUS_SESSION_ROLE_KEYS from the controller source" unless literal

    literal.split.freeze
  end

  attr_reader :rendered, :request, :params
  attr_accessor :current_mcp_account

  def initialize(headers: {}, session: {}, params: {})
    @request = FakeRequest.new(headers: headers, session: session)
    @params = params
    @rendered = nil
    @current_mcp_account = nil
    @current_mcp_payload = nil
  end

  def render(opts)
    @rendered = opts
  end

  def performed? = !@rendered.nil?

  # The REAL default-deny predicate, copied verbatim from
  # mod/mcp_api/app/controllers/concerns/atomspace_read_filter.rb:26-30. The staleness check at
  # the bottom of this file re-reads that file and fails if the clauses change.
  def readable_card?(card)
    return false if card.nil? || card.new_card? || card.read_rule_id.nil? ||
                    card.read_rule_id.to_s.strip.empty?

    card.ok?(:read)
  end

  # The REAL multi-card filter, copied verbatim from atomspace_read_filter.rb:13-22.
  def filter_by_read_auth(atoms, account)
    Card::Auth.as(account.name) do
      atoms.select do |atom|
        ids = atom.associated_card_ids
        next false if ids.empty? || ids.any?(&:nil?)

        ids.all? { |cid| readable_card?(Card.fetch(cid)) }
      end
    end
  end

  def i3_meta = { surface: "i3", data_origin: Atomspace::I3ReadPort.origin }

  # THE PRE-AUTH CONFIG REFUSAL'S EXCEPTION CLASS. The real one is declared INSIDE the controller
  # class (`class UnsupportedServerConfiguration < StandardError`), which cannot be extracted as a
  # method, so it is declared here in the same lexical position -- and a SOURCE check below asserts
  # the real declaration still exists, still subclasses StandardError, and is NOT an
  # Atomspace::Error (which would let a backend rescue_from match it again).
  class UnsupportedServerConfiguration < StandardError; end

  # THE REAL CONSTANT BODY, parsed out of the controller source rather than retyped, so this harness
  # asserts against whatever the controller actually renders today.
  CONFIG_REFUSAL_BODY = begin
    literal = SOURCE[/CONFIG_REFUSAL_BODY = (.*?)\.freeze/m]
    raise "could not extract CONFIG_REFUSAL_BODY from the controller source" unless literal

    { error: SOURCE[/CONFIG_REFUSAL_BODY = \{ error: "([a-z0-9_]+)"/, 1],
      reason: SOURCE[/CONFIG_REFUSAL_BODY = .*?reason: "([a-z0-9_]+)"/m, 1] }.freeze
  end

  def clear_mcp_thread_flag = nil

  # Not exercised on the session path; present so extraction of require_user_principal! links.
  def authenticate_mcp_request! = nil

  class_eval(CONTROLLER_LOGIC_SRC)
end

# Minimal port double so i3_meta/render_card_scoped work.
module Atomspace
  module I3ReadPort
    class NotWired < StandardError; end
    class << self
      attr_accessor :impl
      def origin = @impl ? "live" : "unavailable"
      def reset! = (@impl = nil)
      def open(card_id:)
        raise NotWired, "i3_read_port_unwired" unless @impl

        @impl.open(card_id: card_id)
      end
    end
  end

  # Observability double that RECORDS every alert. Needed because the REAL render_unavailable is now
  # extracted (it fires a class-3 backend signal), and because "an unauthenticated caller must not be
  # able to fire a backend alert on their own behalf" is only checkable if the calls are observable.
  module Observability
    class << self
      def alerts = (@alerts ||= [])
      def reset! = alerts.clear
      def alert(signal_class:, payload:) = alerts << { signal_class: signal_class, payload: payload }
    end
  end
end

# THE REAL ACL MODULE AND THE REAL GRANTS CONSTANTS, loaded from source rather than doubled.
# `caller_scoped_card_authorization.rb` and `atomspace_grants.rb` are plain Ruby with no Rails
# dependency, so the single ACL implementation the controller delegates to is the one actually
# executed here -- not a re-expression of it.
LIB = File.expand_path("../../mod/mcp_api/lib", __dir__)
require File.join(LIB, "atomspace/errors")
require File.join(LIB, "atomspace/authorized_card_identity")
require File.join(LIB, "atomspace/caller_scoped_card_authorization")
require File.join(LIB, "mcp_api/atomspace_grants")

FakeAtom = Struct.new(:ids, :payload) do
  def associated_card_ids = ids
  def to_h = payload
end

# =============================================================================================
# Assertions
# =============================================================================================

$passed = 0
$failed = []

def check(label)
  FakeAuth.reset!
  FakeEnv.reset!
  FakeCardRegistry.reset!
  Atomspace::I3ReadPort.reset!
  Atomspace::Observability.reset!
  Rails.logger.lines.clear
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

SESSION_KEY = FakeAuth::SESSION_USER_KEY

# Register a user account card and return it.
def user!(id, name, readable_by: nil, **opts)
  card = FakeCard.new(id: id, name: name, readable_by: readable_by, **opts)
  FakeCardRegistry.by_id[id] = card
  FakeCardRegistry.by_name[FakeCardname.new(name).key] = card
  card
end

def content!(id, name, readable_by:)
  card = FakeCard.new(id: id, name: name, type_id: 99, readable_by: readable_by)
  FakeCardRegistry.by_id[id] = card
  FakeCardRegistry.by_name[FakeCardname.new(name).key] = card
  card
end

# A controller with a signed-in browser session for `account_id`.
def session_ctl(account_id, params: {}, headers: {})
  ControllerLogic.new(headers: headers, session: { SESSION_KEY => account_id }, params: params)
end

def with_role_env(role)
  prev = ENV["I3_SESSION_READ_ROLE"]
  ENV["I3_SESSION_READ_ROLE"] = role
  yield
ensure
  ENV["I3_SESSION_READ_ROLE"] = prev
end

ENTITLED = "RDA Member"

puts "\nSOURCE INTEGRITY (the harness runs the controller's real methods)"

check "all #{EXTRACTED.size} auth/authorization methods were extracted from the real controller" do
  assert_eq EXTRACTED.size, 17
  EXTRACTED.each { |m| assert extract_method(m).include?("def #{m}"), "#{m} missing" }
end

check "the harness's READABLE predicate still matches the concern's own readable_card?" do
  src = File.read(File.expand_path(
                    "../../mod/mcp_api/app/controllers/concerns/atomspace_read_filter.rb", __dir__
                  ))
  assert src.include?("card.nil? || card.new_card? || card.read_rule_id.blank?"),
         "atomspace_read_filter.rb changed; this harness's copy is stale"
  assert src.include?("card.ok?(:read)")
end

puts "\nSESSION MODE SELECTION (no Authorization header -> session; a header stays on token path)"

check "a request with NO Authorization header selects SESSION mode" do
  assert_eq session_ctl(101).session_mode?, true
end

check "a Bearer header selects TOKEN mode (session is NOT a fallback for a bad token)" do
  ctl = ControllerLogic.new(headers: { "Authorization" => "Bearer whatever" },
                            session: { SESSION_KEY => 101 })
  assert_eq ctl.session_mode?, false
end

check "a PRESENT-BUT-MALFORMED Authorization header stays on the TOKEN path (never downgraded)" do
  # EVERY header the caller actually SET -- including an empty or whitespace-only one -- must be
  # token mode. This is the `.nil?` (not `.blank?`) semantics: a crafted blank header must not be
  # able to INDUCE the parent-gate skip, because the skip condition IS this predicate.
  ["", "   ", "\t", "Basic abc", "Bearer", "bearer tok", "BEARER tok", "garbage",
   "Bearer ", " Bearer x", "Negotiate x", "Bearer x, Basic y"].each do |header|
    ctl = ControllerLogic.new(headers: { "Authorization" => header },
                              session: { SESSION_KEY => 101 })
    assert_eq ctl.session_mode?, false,
              "header #{header.inspect} must NOT select session mode"
  end
end

check "ONLY a genuinely ABSENT Authorization header selects session mode" do
  assert_eq ControllerLogic.new(headers: {}, session: {}).session_mode?, true
  assert_eq ControllerLogic.new(headers: { "Authorization" => nil },
                                session: {}).session_mode?, true,
            "an explicitly nil header value is still 'absent'"
  # And no OTHER header name can select it.
  %w[authorization AUTHORIZATION X-Authorization Proxy-Authorization].each do |name|
    ctl = ControllerLogic.new(headers: { name => "Bearer x" }, session: {})
    assert_eq ctl.session_mode?, true,
              "#{name} is not the Authorization header Rack normalizes to; absence still holds"
  end
end

puts "\nSIGNED-IN vs ANONYMOUS"

check "a SIGNED-IN session resolves the REAL account card as the principal" do
  alice = user!(101, "Alice")
  ctl = session_ctl(101)
  with_role_env(ENTITLED) { ctl.send(:require_session_principal!) }
  assert_eq ctl.rendered, nil, "a signed-in caller must not be refused"
  assert_eq ctl.current_mcp_account.id, alice.id
  assert_eq ctl.current_mcp_account.name.to_s, "Alice"
end

check "the principal is the FRAMEWORK's account, not anything the request asserted" do
  user!(101, "Alice")
  user!(102, "Bob")
  # The request tries to name Bob in every way it can; the session says Alice.
  ctl = ControllerLogic.new(
    headers: { "X-User" => "Bob", "X-Forwarded-User" => "Bob" },
    session: { SESSION_KEY => 101 },
    params: { user: "Bob", account: "Bob", sub: "user:Bob", role: "admin" }
  )
  ctl.send(:require_session_principal!)
  assert_eq ctl.current_mcp_account.name.to_s, "Alice",
            "the request must not be able to choose the principal"
end

check "NO SESSION at all is REFUSED 401 (no anonymous-but-permissive read)" do
  ctl = ControllerLogic.new(headers: {}, session: {})
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
  assert_eq ctl.rendered[:json][:error], "principal_unresolved"
  assert_eq ctl.current_mcp_account, nil
end

check "an ANONYMOUS session id is REFUSED (signed_in? is false for AnonymousID)" do
  ctl = session_ctl(FakeCardConsts::ANONYMOUS_ID)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
  assert_eq FakeAuth.signed_in?, false
end

# ---------------------------------------------------------------------------------------------
# THE CLOSED BLIND SPOT. The previous harness returned nil from current_card for AnonymousID,
# so the controller's anonymous guards were covered only by the generic `card &&` nil check and
# deleting `return nil unless Card::Auth.signed_in? == true` still passed 49/0.
#
# These checks establish the PRECONDITION that makes that mutation detectable: the real
# Anonymous card is PERSISTED and LIVE, so it survives every generic guard.
# ---------------------------------------------------------------------------------------------

check "PRECONDITION: Anonymous is a REAL persisted card, so it survives the generic nil guards" do
  anon = FakeCardRegistry.by_id[FakeCardConsts::ANONYMOUS_ID]
  assert anon, "Anonymous must be registered, as it is in every real deck"
  assert_eq anon.id, 201, "the fixture's own id"
  assert_eq anon.type_id, 2, "the fixture's own type_id (RichText), NOT a User type"
  assert_eq anon.trash, false, "the fixture's trash: 0"
  assert anon.read_rule_id, "Anonymous has a read rule, so it is not default-denied as 'blank'"
  # This is the precise shape that used to be unreachable: a live card that passes `card &&
  # !card.trash && card.id` and therefore reaches the explicit anonymous checks.
  assert(anon && !anon.trash && anon.id,
         "Anonymous passes the generic guard -- only the explicit checks can refuse it")
end

check "an ANONYMOUS caller holding the REAL Anonymous card is refused with NO account set" do
  ctl = session_ctl(FakeCardConsts::ANONYMOUS_ID)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
  assert_eq ctl.rendered[:json][:error], "principal_unresolved"
  assert_eq ctl.current_mcp_account, nil, "Anonymous must never become the principal"
end

check "Anonymous is refused even if RETYPED to User (type check alone is not the guard)" do
  # A deck where Anonymous had been retyped would defeat a type-only check. The explicit
  # AnonymousID and account? guards must still refuse it.
  FakeCardRegistry.by_id[FakeCardConsts::ANONYMOUS_ID] =
    FakeCard.new(id: FakeCardConsts::ANONYMOUS_ID, name: "Anonymous",
                 type_id: FakeCardConsts::USER_ID, # retyped to User!
                 read_rule_id: 10, trash: false, account: false)
  ctl = session_ctl(FakeCardConsts::ANONYMOUS_ID)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized,
            "a retyped Anonymous must STILL be refused"
  assert_eq ctl.current_mcp_account, nil
end

check "a card that is type:User but account? == false is REFUSED" do
  # account? is the framework's own account-holder predicate (anonymous.rb:7-9 defines it false).
  FakeCardRegistry.by_id[700] = FakeCard.new(id: 700, name: "Not An Account",
                                             type_id: FakeCardConsts::USER_ID,
                                             read_rule_id: 10, account: false)
  FakeCardRegistry.by_name["not_an_account"] = FakeCardRegistry.by_id[700]
  ctl = session_ctl(700)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
  assert_eq ctl.current_mcp_account, nil
end

# THE BEHAVIOURAL PROOF OF THE signed_in? GUARD.
#
# Honest note on why this seam exists. With the Anonymous card now persisted, the AnonymousID /
# account? / type_id guards already refuse every anonymous shape, so DELETING the
# `return nil unless Card::Auth.signed_in? == true` line was still caught only by the SOURCE
# check below -- behaviourally it was redundant. That is a real coverage gap, not a nitpick: a
# source-text assertion proves the line EXISTS, not that it DOES anything.
#
# The one input shape only that line refuses is a framework DIVERGENCE: signed_in? reports false
# while current_card still answers a valid, non-anonymous, type:User, account? == true card. That
# is reachable in the real framework (signed_in? is `current_id != AnonymousID` while current_card
# is `Card[current_id]` -- two different reads, and `Card::Auth.reset` clears @current_id while a
# memoized @current_card can still be returned by a concurrent reader, current.rb:21-25, :45-47,
# :78-80). The seam models exactly that and nothing else.
check "the controller TRUSTS the framework's signed_in? predicate even when current_card answers" do
  alice = user!(101, "Alice")
  ctl = session_ctl(101)

  # Establish the divergence as the framework itself would see it: bind Env to this controller and
  # run the framework's own session resolution, so current_id/current_card are REALLY populated.
  FakeEnv.reset(ctl)
  FakeAuth.signin_with
  assert_eq FakeAuth.current_card&.id, alice.id,
            "precondition: current_card answers a VALID User account card"
  assert_eq FakeAuth.current_card.account?, true
  assert_eq FakeAuth.current_card.type_id, FakeCardConsts::USER_ID
  assert FakeAuth.current_card.id != FakeCardConsts::ANONYMOUS_ID,
         "precondition: the card is NOT Anonymous"

  # NOW diverge: the framework reports not-signed-in while that same valid card stays retrievable.
  FakeAuth.force_signed_in = false
  assert_eq FakeAuth.signed_in?, false, "precondition: the divergence is in place"
  assert_eq FakeAuth.current_card&.id, alice.id,
            "precondition: the valid card is STILL retrievable -- this is the whole point"

  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized,
            "signed_in? == false must refuse, even though every other guard would pass"
  assert_eq ctl.current_mcp_account, nil
end

check "SOURCE: all THREE anonymous guards are present and independent" do
  body = extract_method("session_account")
  assert body.include?("Card::Auth.signed_in? == true"),
         "the framework signed_in? guard must be present"
  assert body.include?("card.id == Card::AnonymousID"),
         "an EXPLICIT AnonymousID refusal must be present (not just the type check)"
  assert body.include?("card.account? == true"),
         "the framework's own account? predicate must be required"
  assert body.include?("card.type_id == Card::UserID"),
         "the User-type requirement must remain"
end

check "a session naming a NON-ACCOUNT card is REFUSED (the framework's own account? check)" do
  user!(300, "Some Content Card", account: false)
  ctl = session_ctl(300)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
  assert_eq ctl.current_mcp_account, nil
end

check "a session naming a TRASHED account is REFUSED" do
  user!(101, "Alice", trash: true)
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
end

check "a session naming a NON-USER-TYPE card is REFUSED" do
  user!(101, "Alice", type_id: 42)
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
end

check "a session naming a DELETED/absent card id is REFUSED" do
  ctl = session_ctl(999_999)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :unauthorized
end

check "the refusal carries DENIED_META -- no backend/readiness signal to an unauthorized caller" do
  ctl = ControllerLogic.new(headers: {}, session: {})
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:json][:_meta], { surface: "i3" }
  assert !ctl.rendered[:json][:_meta].key?(:data_origin)
end

puts "\nSERVICE ACCOUNTS AND BOT SUBJECTS ARE NOT USABLE AS A BROWSER PRINCIPAL"

check "a SERVICE ACCOUNT session is REFUSED 403 (same canonical-id exclusion as the token path)" do
  svc = user!(500, "mcp-admin")
  ctl = session_ctl(svc.id)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :forbidden
  assert_eq ctl.rendered[:json][:error], "principal_not_permitted"
  assert_eq ctl.current_mcp_account, nil
end

check "a service-account ALIAS is refused too (canonical key, not string equality)" do
  svc = user!(500, "mcp_admin") # stored with an underscore; ENV default is "mcp-admin"
  ctl = session_ctl(svc.id)
  ctl.send(:require_session_principal!)
  assert_eq ctl.rendered[:status], :forbidden,
            "mcp_admin and mcp-admin are ONE card; the alias must not slip through"
end

check "NO as_bot / DeckoBot identity is ever used on the session path" do
  user!(101, "Alice")
  content!(201, "Secret", readable_by: ["Bob"])
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  ctl.send(:readable_source?, 201)
  assert_eq FakeAuth.as_calls, ["Alice"], "every card touch must run as the CALLER"
  assert !FakeAuth.as_calls.any? { |n| n.match?(/bot|admin/i) }
end

check "SOURCE: no as_bot anywhere in the controller's executable code" do
  code = SOURCE.gsub(/^\s*#.*$/, "")
  assert !code.include?("as_bot")
  assert !code.include?("Card::Auth.as_bot")
end

puts "\nROLE IS READ FROM THE FRAMEWORK, NEVER ASSERTED BY THE REQUEST"

check "a caller HOLDING the configured role passes the gate" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [ENTITLED] }
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  with_role_env(ENTITLED) { ctl.send(:require_i3_read_scope!) }
  assert_eq ctl.rendered, nil
end

check "a signed-in caller WITHOUT the role is REFUSED 403 (not 'any signed-in user')" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [] }
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  with_role_env(ENTITLED) { ctl.send(:require_i3_read_scope!) }
  assert_eq ctl.rendered[:status], :forbidden
  assert_eq ctl.rendered[:json][:error], "forbidden"
end

check "anyone_signed_in NEVER satisfies the gate -- configuring it is REFUSED, not honoured" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [] }
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert FakeAuth.current_roles.any? { |r| r.key == "anyone_signed_in" },
         "precondition: the framework really does grant anyone_signed_in to every signed-in user"

  # Naming the vacuous role must FAIL CLOSED (it would otherwise entitle every signed-in account).
  ["anyone signed in", "anyone_signed_in", "Anyone Signed In", "ANYONE-SIGNED-IN"].each do |spelling|
    c = session_ctl(101)
    c.send(:require_session_principal!)
    with_role_env(spelling) { c.send(:require_i3_read_scope!) }
    assert_eq c.rendered[:status], :forbidden,
              "vacuous role #{spelling.inspect} must be refused, not honoured"
  end
end

check "the other vacuous everyone-roles are refused too (all / *all / Anyone)" do
  user!(101, "Alice")
  # Even a caller who somehow HOLDS the named role is refused, because the CONFIG is the error.
  FakeAuth.role_memberships = { 101 => ["all", "Anyone", "*all"] }
  ["all", "*all", "Anyone", "ALL", "an_yone"].each do |spelling|
    c = session_ctl(101)
    c.send(:require_session_principal!)
    with_role_env(spelling) { c.send(:require_i3_read_scope!) }
    assert_eq c.rendered[:status], :forbidden,
              "everyone-role #{spelling.inspect} must not confer I3 read"
  end
end

check "a vacuous config is LOGGED as an operator error (fail-closed and diagnosable)" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [] }
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Rails.logger.lines.clear
  with_role_env("anyone signed in") { assert_eq ctl.send(:session_role_entitled?), false }
  assert Rails.logger.lines.any? { |l| l.include?("vacuous") },
         "the operator must be told the configuration is being refused"
end

check "the vacuous list is the CONTROLLER's own constant, not a harness copy" do
  assert ControllerLogic::VACUOUS_SESSION_ROLE_KEYS.include?("anyone_signed_in")
  assert_eq ControllerLogic::VACUOUS_SESSION_ROLE_KEYS.sort,
            %w[*all all anyone anyone_signed_in].sort
end

check "an UNCONFIGURED I3_SESSION_READ_ROLE refuses everyone (default-deny, no new grant)" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [ENTITLED, "Administrator"] }
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  with_role_env("") { ctl.send(:require_i3_read_scope!) }
  assert_eq ctl.rendered[:status], :forbidden
end

check "a role ALIAS in the config still matches (canonical key comparison)" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => ["RDA Member"] }
  %w[rda_member rda-member RDA\ Member RDA__MEMBER].each do |spelling|
    ctl = session_ctl(101)
    ctl.send(:require_session_principal!)
    with_role_env(spelling) { ctl.send(:require_i3_read_scope!) }
    assert_eq ctl.rendered, nil, "config spelling #{spelling.inspect} must match the held role"
  end
end

check "the request CANNOT assert a role or scope to pass the gate" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [] } # holds nothing
  ctl = ControllerLogic.new(
    headers: { "X-Role" => "admin", "X-Scope" => "mcp:i3:read" },
    session: { SESSION_KEY => 101 },
    params: { role: "admin", scope: "mcp:i3:read", roles: ENTITLED }
  )
  ctl.send(:require_session_principal!)
  with_role_env(ENTITLED) { ctl.send(:require_i3_read_scope!) }
  assert_eq ctl.rendered[:status], :forbidden,
            "a self-asserted role/scope must not confer entitlement"
end

puts "\nPER-CARD READ ACL: caller A cannot read caller B's private card"

check "caller A is refused a card only B may read, and the answer is the EMPTY-shaped non-oracle" do
  user!(101, "Alice")
  user!(102, "Bob")
  content!(201, "Bob Private", readable_by: ["Bob"])

  alice = session_ctl(101)
  alice.send(:require_session_principal!)
  assert_eq alice.send(:readable_source?, 201), false, "Alice must not read Bob's private card"

  bob = session_ctl(102)
  bob.send(:require_session_principal!)
  assert_eq bob.send(:readable_source?, 201), true, "Bob must still read his own card"
end

check "an ABSENT card and an UNREADABLE card are INDISTINGUISHABLE to the caller" do
  user!(101, "Alice")
  content!(201, "Bob Private", readable_by: ["Bob"])
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert_eq ctl.send(:readable_source?, 201), ctl.send(:readable_source?, 999_999)
end

check "default-deny: a new card and a blank-read-rule card are denied WITHOUT asking ok?(:read)" do
  user!(101, "Alice")
  FakeCardRegistry.by_id[301] = FakeCard.new(id: 301, name: "New", type_id: 99, new_card: true)
  FakeCardRegistry.by_id[302] = FakeCard.new(id: 302, name: "NoRule", type_id: 99,
                                             read_rule_id: nil)
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert_eq ctl.send(:readable_source?, 301), false
  assert_eq ctl.send(:readable_source?, 302), false
end

puts "\nNEIGHBOURS / LINKS: an unreadable neighbour is FILTERED OUT of the response"

check "an unreadable NEIGHBOUR is dropped from the rendered results" do
  user!(101, "Alice")
  content!(210, "Open Neighbour", readable_by: nil)
  content!(211, "Secret Neighbour", readable_by: ["Bob"])
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Atomspace::I3ReadPort.impl = Object.new

  atoms = [FakeAtom.new([210], { type: "Card", card_id: 210 }),
           FakeAtom.new([211], { type: "Card", card_id: 211 })]
  ctl.send(:render_card_scoped, atoms)

  ids = ctl.rendered[:json][:results].map { |h| h[:card_id] }
  assert_eq ids, [210], "the unreadable neighbour must not appear"
  assert !ctl.rendered.inspect.include?("Secret Neighbour")
end

check "a REFERENCE atom is dropped unless EVERY associated card is readable (multi-card deny)" do
  user!(101, "Alice")
  content!(220, "Readable Referer", readable_by: nil)
  content!(221, "Secret Referee", readable_by: ["Bob"])
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Atomspace::I3ReadPort.impl = Object.new

  atoms = [FakeAtom.new([220, 221], { type: "DeckoReference", card_id: 220 }),
           FakeAtom.new([220], { type: "Card", card_id: 220 })]
  ctl.send(:render_card_scoped, atoms)

  results = ctl.rendered[:json][:results]
  assert_eq results.size, 1, "the reference touching a secret referee must be dropped"
  assert_eq results.first[:type], "Card"
end

check "an atom with a NIL associated id is dropped (no partial authorization)" do
  user!(101, "Alice")
  content!(230, "Open", readable_by: nil)
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Atomspace::I3ReadPort.impl = Object.new
  ctl.send(:render_card_scoped, [FakeAtom.new([230, nil], { type: "DeckoReference" })])
  assert_eq ctl.rendered[:json][:results], []
end

check "the ACL filter runs under the CALLER's identity on the way out" do
  user!(101, "Alice")
  content!(240, "Open", readable_by: nil)
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Atomspace::I3ReadPort.impl = Object.new
  FakeAuth.as_calls.clear
  ctl.send(:render_card_scoped, [FakeAtom.new([240], { type: "Card", card_id: 240 })])
  assert_eq FakeAuth.as_calls, ["Alice"]
  assert_eq FakeAuth.as_stack, [], "the identity must be popped"
end

puts "\nCURSOR / RESULT-SET CANNOT WIDEN ACROSS IDENTITIES (re-filtered every request)"

check "the SAME port result set yields DIFFERENT filtered output per identity" do
  user!(101, "Alice")
  user!(102, "Bob")
  content!(250, "Shared", readable_by: nil)
  content!(251, "Alice Only", readable_by: ["Alice"])
  content!(252, "Bob Only", readable_by: ["Bob"])
  Atomspace::I3ReadPort.impl = Object.new

  # One list, as if a cursor had captured it, replayed for two callers.
  cursor_page = lambda do
    [FakeAtom.new([250], { card_id: 250 }), FakeAtom.new([251], { card_id: 251 }),
     FakeAtom.new([252], { card_id: 252 })]
  end

  alice = session_ctl(101)
  alice.send(:require_session_principal!)
  alice.send(:render_card_scoped, cursor_page.call)
  assert_eq alice.rendered[:json][:results].map { |h| h[:card_id] }.sort, [250, 251]

  bob = session_ctl(102)
  bob.send(:require_session_principal!)
  bob.send(:render_card_scoped, cursor_page.call)
  assert_eq bob.rendered[:json][:results].map { |h| h[:card_id] }.sort, [250, 252],
            "a page minted under Alice must not widen Bob's results (or vice versa)"
end

check "a cursor page cannot leak a card the PRESENTING caller cannot read" do
  user!(101, "Alice")
  content!(260, "Not For Alice", readable_by: ["Bob"])
  Atomspace::I3ReadPort.impl = Object.new
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  # Even if the page was assembled for someone who COULD read it, Alice gets nothing.
  ctl.send(:render_card_scoped, [FakeAtom.new([260], { card_id: 260, name: "Not For Alice" })])
  assert_eq ctl.rendered[:json][:results], []
  assert !ctl.rendered.inspect.include?("Not For Alice")
end

check "the filter is applied on EVERY request -- nothing from the port is pre-authorized" do
  user!(101, "Alice")
  content!(270, "Secret", readable_by: ["Bob"])
  Atomspace::I3ReadPort.impl = Object.new
  3.times do
    ctl = session_ctl(101)
    ctl.send(:require_session_principal!)
    ctl.send(:render_card_scoped, [FakeAtom.new([270], { card_id: 270 })])
    assert_eq ctl.rendered[:json][:results], [], "no request may skip the filter"
  end
end

puts "\nIDENTITY DOES NOT LEAK BETWEEN REQUESTS (Card::Env / Card::Auth teardown)"

check "teardown resets Card::Env and Card::Auth even when the action renders" do
  user!(101, "Alice")
  ctl = session_ctl(101)
  ctl.send(:clear_mcp_state_after_request) { ctl.send(:require_session_principal!) }
  assert_eq FakeEnv.controller, nil, "a bound controller must not survive the request"
  assert_eq FakeAuth.signed_in?, false, "the signed-in identity must not survive the request"
  assert_eq FakeEnv.reset_calls.last, :nil
end

check "teardown still runs when the action RAISES" do
  user!(101, "Alice")
  ctl = session_ctl(101)
  begin
    ctl.send(:clear_mcp_state_after_request) do
      ctl.send(:require_session_principal!)
      raise "boom"
    end
  rescue RuntimeError
    nil
  end
  assert_eq FakeEnv.controller, nil
  assert_eq FakeAuth.signed_in?, false
end

check "a SECOND request does not inherit the FIRST request's session identity" do
  user!(101, "Alice")
  user!(102, "Bob")
  first = session_ctl(101)
  first.send(:clear_mcp_state_after_request) { first.send(:require_session_principal!) }
  assert_eq first.current_mcp_account.name.to_s, "Alice"

  # A request with NO session must not be answered as Alice.
  second = ControllerLogic.new(headers: {}, session: {})
  second.send(:clear_mcp_state_after_request) { second.send(:require_session_principal!) }
  assert_eq second.current_mcp_account, nil, "the stale identity must be gone"
  assert_eq second.rendered[:status], :unauthorized
end

check "Card::Env is bound to THIS controller before the session is read" do
  user!(101, "Alice")
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  assert FakeEnv.reset_calls.include?(:controller),
         "Env must be bound to this request's controller, not left stale"
  assert_eq FakeAuth.signin_calls.size, 1, "the framework's own signin_with must be invoked"
end

puts "\nNO SECRETS IN RESPONSES OR LOGS"

check "no response body on this path contains a token, cookie, session id or digest material" do
  user!(101, "Alice")
  FakeAuth.role_memberships = { 101 => [ENTITLED] }
  secrets = %w[session_id _magi_archive_session Bearer password salt api_key jwt cookie
               Authorization secret token]
  bodies = []

  # refusal (no session)
  anon = ControllerLogic.new(headers: {}, session: {})
  anon.send(:require_session_principal!)
  bodies << anon.rendered

  # refusal (no role)
  norole = session_ctl(101)
  norole.send(:require_session_principal!)
  with_role_env("Other Role") { norole.send(:require_i3_read_scope!) }
  bodies << norole.rendered

  # success
  content!(280, "Open", readable_by: nil)
  Atomspace::I3ReadPort.impl = Object.new
  ok = session_ctl(101)
  ok.send(:require_session_principal!)
  ok.send(:render_card_scoped, [FakeAtom.new([280], { card_id: 280 })])
  bodies << ok.rendered

  bodies.compact.each do |body|
    text = body.inspect
    secrets.each do |s|
      assert !text.downcase.include?(s.downcase), "#{s} must not appear in a response body"
    end
  end
end

check "no LOG line emits a credential or session value" do
  # Force the framework-failure log paths.
  broken = ControllerLogic.new(headers: {}, session: { SESSION_KEY => :explode })
  def broken.params = (raise "unused")
  FakeCardRegistry.by_id[:explode] = nil
  broken.send(:require_session_principal!)
  with_role_env(ENTITLED) { broken.send(:session_role_entitled?) }
  Rails.logger.lines.each do |line|
    %w[_magi_archive_session Bearer password salt session_id].each do |s|
      assert !line.include?(s), "log line leaked #{s}: #{line}"
    end
  end
end

check "the session cookie VALUE is never read into a response or log by this code" do
  code = SOURCE.gsub(/^\s*#.*$/, "")
  %w[cookies\[ request.cookie session_id form_authenticity_token].each do |needle|
    assert !code.include?(needle), "controller code must not touch #{needle}"
  end
end

puts "\nFAIL-CLOSED BEHAVIOUR PRESERVED ON THE SESSION PATH"

check "an UNWIRED port raises NotWired (-> the existing 503 handler), it does not answer" do
  user!(101, "Alice")
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  Atomspace::I3ReadPort.reset!
  raised = begin
    Atomspace::I3ReadPort.open(card_id: 1)
    nil
  rescue Atomspace::I3ReadPort::NotWired => e
    e.message
  end
  assert_eq raised, "i3_read_port_unwired"
end

check "a non-Array port result is a CONTRACT VIOLATION, not an empty success" do
  user!(101, "Alice")
  Atomspace::I3ReadPort.impl = Object.new
  [nil, { a: 1 }, "atoms", 42].each do |bad|
    ctl = session_ctl(101)
    ctl.send(:require_session_principal!)
    ctl.send(:render_card_scoped, bad)
    assert_eq ctl.rendered[:status], :service_unavailable, "#{bad.inspect} must fail closed"
    assert_eq ctl.rendered[:json][:reason], "i3_backend_result_contract_violation"
  end
end

check "an EMPTY array is still a legitimate 200 (the non-oracle answer)" do
  user!(101, "Alice")
  Atomspace::I3ReadPort.impl = Object.new
  ctl = session_ctl(101)
  ctl.send(:require_session_principal!)
  ctl.send(:render_card_scoped, [])
  assert_eq ctl.rendered[:json][:results], []
  assert_eq ctl.rendered[:status], nil, "an empty result must NOT be an error status"
end

check "SOURCE: I3-01/I3-09 health remains a 501 capability refusal, nothing fabricated" do
  body = SOURCE[/def health.*?\n      end/m]
  assert body.include?("capability_missing")
  assert body.include?("i3_health_slice_unavailable_o23_gated")
  assert body.include?(":not_implemented")
  code = SOURCE.gsub(/^\s*#.*$/, "")
  %w[versions runtime coverage epoch read_at].each do |fabricated|
    assert !code.include?("\"#{fabricated}\""), "#{fabricated} must not be synthesised"
  end
end

check "SOURCE: gate order is still principal -> scope -> readiness" do
  a = SOURCE.index("before_action :require_user_principal!")
  b = SOURCE.index("before_action :require_i3_read_scope!")
  c = SOURCE.index("before_action :require_i3_backend_ready!")
  assert a && b && c && a < b && b < c
end

check "SOURCE: the session path adds NO new error vocabulary" do
  codes = SOURCE.scan(/error: "([a-z0-9_]+)"/).flatten.uniq
  allowed = %w[bad_request capability_missing forbidden i3_backend_not_ready
               i3_backend_unavailable i3_internal_error principal_not_permitted
               principal_unresolved]
  unexpected = codes - allowed
  assert_eq unexpected, [], "new wire vocabulary introduced: #{unexpected.inspect}"
  # And the session path's two refusals must reuse the PRE-EXISTING codes.
  assert codes.include?("principal_unresolved")
  assert codes.include?("principal_not_permitted")
end

check "SOURCE: no CORS header is ever set by this controller" do
  code = SOURCE.gsub(/^\s*#.*$/, "")
  ["Access-Control-Allow", "allow_origin", "cors"].each do |needle|
    assert !code.downcase.include?(needle.downcase), "no CORS relaxation permitted"
  end
end

check "SOURCE: no token is minted, signed or returned on this path" do
  code = SOURCE.gsub(/^\s*#.*$/, "")
  %w[generate_token encode sign_token JWT.encode secret_key_base].each do |needle|
    assert !code.include?(needle), "#{needle} must not appear"
  end
end

puts "\nPRE-AUTHENTICATION CONFIG REFUSAL DISCLOSES NOTHING (R26 blocker)"

# The defect: `prepend_around_action :clear_mcp_state_after_request` wraps the ENTIRE action, so
# `assert_single_threaded_identity!` runs BEFORE the auth chain. When it raised
# Atomspace::ServiceUnavailable that was handled by render_backend_unavailable -> render_unavailable,
# which renders `_meta: i3_meta` (carrying the backend's data_origin) and fires a class-3 backend
# alert -- to an ENTIRELY UNAUTHENTICATED caller. The guard must stay pre-auth; only the RESPONSE
# was wrong.

# Drive the guard with a chosen RAILS_MAX_THREADS, restoring the real value afterwards.
def with_max_threads(value)
  prev = ENV["RAILS_MAX_THREADS"]
  ENV["RAILS_MAX_THREADS"] = value
  yield
ensure
  ENV["RAILS_MAX_THREADS"] = prev
end

# An UNAUTHENTICATED request (no session, no Authorization header) through the REAL around_action,
# rendered by the REAL handler the controller's rescue_from names. Returns the rendered body.
def unauthenticated_config_refusal
  ctl = ControllerLogic.new(headers: {}, session: {})
  begin
    ctl.send(:clear_mcp_state_after_request) { raise "the auth chain must never be reached" }
  rescue ControllerLogic::UnsupportedServerConfiguration => e
    ctl.send(:render_unsupported_configuration, e)
  end
  ctl
end

check "the guard still REFUSES a multi-threaded server, and BEFORE any authentication" do
  with_max_threads("5") do
    ctl = ControllerLogic.new(headers: {}, session: {})
    reached = false
    err = begin
      ctl.send(:clear_mcp_state_after_request) { reached = true }
      nil
    rescue ControllerLogic::UnsupportedServerConfiguration => e
      e
    end
    assert err, "the control must still fire -- it was NOT removed or moved after auth"
    assert !reached, "the action/auth chain must not run under an unsupported configuration"
    assert_eq ctl.current_mcp_account, nil
  end
end

check "(a) the UNAUTHENTICATED refusal body carries NO _meta at all" do
  with_max_threads("4") do
    ctl = unauthenticated_config_refusal
    body = ctl.rendered[:json]
    assert !body.key?(:_meta), "a pre-auth refusal must not carry _meta: #{body.inspect}"
    assert_eq ctl.rendered[:status], :service_unavailable, "the status must stay 503"
  end
end

check "(a) the refusal body carries NO data_origin and NO backend origin VALUE" do
  with_max_threads("8") do
    Atomspace::I3ReadPort.impl = Object.new # origin would now be "live"
    assert_eq Atomspace::I3ReadPort.origin, "live", "the port must have a disclosable origin to leak"
    ctl = unauthenticated_config_refusal
    text = ctl.rendered.inspect
    assert !text.include?("data_origin"), "data_origin leaked: #{text}"
    # The body is EXACTLY the source-derived constant, so nothing backend-derived can be hiding in
    # it. Checking equality rather than only scanning for substrings: "unavailable" legitimately
    # occurs inside the pre-existing `i3_backend_unavailable` code and the :service_unavailable
    # status, so a bare substring scan for that origin value would be a false positive.
    assert_eq ctl.rendered[:json], ControllerLogic::CONFIG_REFUSAL_BODY
    %w[live fixture unwired].each do |origin|
      assert !text.include?(origin), "backend origin value #{origin.inspect} leaked: #{text}"
    end
    # And the port must never even be consulted: an exploding origin must not change the response.
    Atomspace::I3ReadPort.impl = nil
    assert_eq unauthenticated_config_refusal.rendered[:json], ctl.rendered[:json],
              "the response must not vary with the backend's state (that variation IS the oracle)"
  end
end

check "(a) the refusal leaks NO configuration detail -- no thread count, no env var name" do
  with_max_threads("7") do
    text = unauthenticated_config_refusal.rendered.inspect
    %w[RAILS_MAX_THREADS thread threaded concurrent 7 puma Card::Auth Card::Env].each do |needle|
      assert !text.downcase.include?(needle.downcase), "#{needle} must not be on the wire: #{text}"
    end
  end
end

check "(a) the refusal fires NO backend Observability alert on the caller's behalf" do
  with_max_threads("2") do
    unauthenticated_config_refusal
    assert_eq Atomspace::Observability.alerts, [],
              "an unauthenticated caller must not drive the backend alerting channel"
  end
end

check "the diagnosis still reaches the OPERATOR via the server-side log only" do
  with_max_threads("3") do
    unauthenticated_config_refusal
    logged = Rails.logger.lines.join("\n")
    assert logged.include?("i3_read_requires_single_threaded_server"),
           "the operator must still be able to diagnose this"
    assert logged.include?("RAILS_MAX_THREADS=3"), "the actual value belongs in the LOG"
  end
end

check "the refusal reuses the EXISTING 503 vocabulary (not fingerprintable as a new shape)" do
  with_max_threads("2") do
    body = unauthenticated_config_refusal.rendered[:json]
    assert_eq body[:error], "i3_backend_unavailable"
    assert_eq body, ControllerLogic::CONFIG_REFUSAL_BODY
    assert body.frozen?, "the shared constant body must be frozen"
  end
end

check "a single-threaded (or unset/unparseable) configuration is NOT refused" do
  [nil, "", "1", "not-a-number"].each do |value|
    with_max_threads(value) do
      ctl = ControllerLogic.new(headers: {}, session: {})
      ran = false
      ctl.send(:clear_mcp_state_after_request) { ran = true }
      assert ran, "RAILS_MAX_THREADS=#{value.inspect} must be allowed to serve"
      assert_eq ctl.rendered, nil
    end
  end
end

check "(b) NO REGRESSION: the post-auth backend-unavailable 503 STILL carries its _meta" do
  Atomspace::I3ReadPort.impl = Object.new
  ctl = ControllerLogic.new(headers: {}, session: {})
  ctl.send(:render_backend_unavailable, Atomspace::ServiceUnavailable.new("boom"))
  body = ctl.rendered[:json]
  assert_eq ctl.rendered[:status], :service_unavailable
  assert_eq body[:_meta], { surface: "i3", data_origin: "live" },
            "the genuine post-auth backend case must keep its intended provenance meta"
  assert_eq body[:reason], "i3_backend_unavailable"
  assert_eq Atomspace::Observability.alerts.size, 1,
            "the real backend case must still raise its class-3 signal"
end

check "(c) MUTATION PROOF: routing the config refusal through render_unavailable WOULD leak" do
  Atomspace::I3ReadPort.impl = Object.new
  legacy = ControllerLogic.new(headers: {}, session: {})
  # The OLD shape: the pre-auth guard's error handled by the meta-bearing renderer.
  legacy.send(:render_unavailable, "i3_backend_unavailable")
  leaked = legacy.rendered[:json]
  assert leaked[:_meta].key?(:data_origin),
         "the witness is void unless the old shape really did disclose data_origin"
  assert_eq leaked[:_meta][:data_origin], "live"
  assert_eq Atomspace::Observability.alerts.size, 1,
            "the old shape also fired a backend alert for an unauthenticated caller"

  # And the FIXED path must differ from that witness in exactly those two respects.
  Atomspace::Observability.reset!
  with_max_threads("2") do
    fixed = unauthenticated_config_refusal.rendered[:json]
    assert !fixed.key?(:_meta)
    assert fixed != leaked, "the fix must not render the legacy body"
    assert_eq Atomspace::Observability.alerts, []
  end
end

check "(c) MUTATION PROOF: SOURCE -- the guard must NOT raise a class any backend handler catches" do
  body = SOURCE[/def assert_single_threaded_identity!.*?\n      end/m]
  code = body.gsub(/^\s*#.*$/, "")
  assert code.include?("raise UnsupportedServerConfiguration"),
         "the guard must raise its own class"
  assert !code.include?("Atomspace::ServiceUnavailable"),
         "reverting to Atomspace::ServiceUnavailable re-opens the pre-auth disclosure"
end

check "(c) MUTATION PROOF: SOURCE -- the config handler renders the constant, never i3_meta" do
  body = SOURCE[/def render_unsupported_configuration.*?\n      end/m]
  assert body, "render_unsupported_configuration must exist"
  code = body.gsub(/^\s*#.*$/, "")
  assert code.include?("json: CONFIG_REFUSAL_BODY")
  assert !code.include?("i3_meta"), "the pre-auth handler must not consult the port"
  assert !code.include?("render_unavailable"), "it must not delegate to the meta-bearing renderer"
  assert !code.include?("Observability"), "it must not fire a backend signal"
  assert code.include?(":service_unavailable"), "the status must remain 503"
end

check "SOURCE: the refusal class is its own StandardError, NOT an Atomspace::Error" do
  decl = SOURCE[/class UnsupportedServerConfiguration < ([A-Za-z:]+)/, 1]
  assert_eq decl, "StandardError",
            "subclassing Atomspace::Error would let a backend rescue_from match it again"
  assert SOURCE.include?("rescue_from UnsupportedServerConfiguration, " \
                         "with: :render_unsupported_configuration"),
         "the distinct handler must be registered"
  # Registered AFTER the StandardError catch-all, or the catch-all would win.
  assert SOURCE.index("rescue_from StandardError") <
         SOURCE.index("rescue_from UnsupportedServerConfiguration")
end

check "SOURCE: CONFIG_REFUSAL_BODY is frozen and carries no _meta / origin / thread detail" do
  decl = SOURCE[/CONFIG_REFUSAL_BODY = .*?\.freeze/m]
  assert decl.include?(".freeze")
  %w[_meta data_origin origin THREADS thread].each do |needle|
    assert !decl.include?(needle), "#{needle} must not appear in the pre-auth body constant"
  end
end

check "SOURCE: the guard still runs INSIDE the prepended around_action, before the gates" do
  assert SOURCE.include?("prepend_around_action :clear_mcp_state_after_request"),
         "the teardown must still wrap the whole chain"
  body = SOURCE[/def clear_mcp_state_after_request.*?\n      end/m]
  guard = body.index("assert_single_threaded_identity!")
  yielded = body.index("yield")
  assert guard && yielded && guard < yielded,
         "the configuration must be refused BEFORE any card touch, not after authentication"
end

check "SOURCE: the guard's comment matches the code it describes (no unverified Puma API)" do
  comment = SOURCE[/((?:^      #.*\n)+)      def assert_single_threaded_identity!/, 1]
  body = SOURCE[/def assert_single_threaded_identity!.*?\n      end/m].gsub(/^\s*#.*$/, "")
  claims_puma_api = comment.match?(/Puma's own setting/)
  reads_puma_api = body.match?(/Puma|puma/)
  assert_eq claims_puma_api, reads_puma_api,
            "the comment must not claim an input the code does not read"
  assert comment.include?("RAILS_MAX_THREADS"), "the real input must be named"
end

puts "\n#{$passed} passed, #{$failed.size} failed"
unless $failed.empty?
  puts "\nFAILURES:"
  $failed.each { |label, msg| puts "  - #{label}: #{msg}" }
end
exit($failed.empty? ? 0 : 1)
