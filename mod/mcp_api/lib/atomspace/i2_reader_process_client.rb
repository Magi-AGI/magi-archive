# frozen_string_literal: true

require_relative "errors"
require_relative "atom"
require_relative "i3_read_port"
require_relative "mirror_readiness"
require_relative "i2_envelope"
require_relative "i2_stdio_transport"
require_relative "i3_envelope"
require_relative "i3_read_result"

module Atomspace
  # THE REAL (non-fixture) I3 READER. This is the production counterpart to FixtureI3ReadPort and
  # the object `LocalI3ReadBinding.install!(reader: ...)` was built to bind.
  #
  # THE GAP IT CLOSES, precisely. `LocalI3ReadBinding` has a `reader:` injection seam
  # (local_i3_read_binding.rb:48) and declares what a reader must answer
  # (REQUIRED_READER_METHODS = open, neighbours, resolve_backend_address, plus optional
  # `readiness`). Until now the ONLY objects satisfying it were `FixtureI3ReadPort` -- which stamps
  # `origin == "fixture"` on every response by design -- and in-spec doubles. So the seam could be
  # exercised but never FILLED: no object existed that reached STORE's actual
  # `atomspace_mirror_sidecar.i2_read.I2Reader`. This class is that object.
  #
  # IT IS NOT A VARIANT OF THE FIXTURE. It shares no code with it, fabricates nothing, and has no
  # in-memory corpus: every value it returns came off the wire from STORE's reader this call, or it
  # raises. `origin` is "live" because an answer from this class IS live backend data; there is no
  # mode, flag or fallback that could make it serve synthetic content under that label.
  #
  # ==== HOW IT REACHES THE BACKEND
  #
  # Through an INJECTED writer/reader PAIR -- the same discipline LocalI3ReadBinding applies to
  # itself (local_i3_read_binding.rb:30-34 "Through an INJECTED callable ... This class constructs
  # no socket, no URL, no host and no credential"). Concretely:
  #
  #   * This class constructs NO process. It calls no `spawn`, `popen3`, `system`, `exec` or
  #     `fork`; it does not require `open3`. The process, if there is one, is the local operator's,
  #     started explicitly via `I2StdioTransport::Spawn`.
  #   * It constructs NO socket, NO URL and NO credential, for the reasons STORE states:
  #     "Not exposed on any socket: privileged, identity-free, and not MCP REST"
  #     (i2_read.py:57-58), and handoff 022b Q12: "One process, no socket, NO user identity at the
  #     I2 call; ACL stays on your I3 side."
  #   * It carries NO USER IDENTITY. There is no account, token or principal parameter anywhere in
  #     this file, and `I2StdioTransport::REQUEST_KEYS` cannot express one. Authorization is
  #     entirely the deck's: `I3ReadController` resolves and filters under
  #     `Card::Auth.as(account.name)` BEFORE and AFTER calling the port
  #     (i3_read_controller.rb:153, :174, :297).
  #
  # ==== FAIL CLOSED ON MISSING METADATA -- the central requirement
  #
  # Every answer passes `I2Envelope.validate!` before any of its values are used. A missing or
  # malformed `outcome`, `epoch`, `position` or `read-at`, a "not ready" envelope carrying a real
  # epoch, a state-bearing envelope carrying a null, or an address answer missing STORE's own key
  # or digest, is a REFUSAL. This class contains:
  #
  #   * no default for any metadatum (no `||` fallback, no `fetch` with a default);
  #   * no clock call -- `read-at` is STORE-SAMPLED (handoff 022b §1) and VIEW never stamps one;
  #   * no digest computation. VIEW is FORBIDDEN to compute a digest deck-side
  #     (i3_read_port.rb:20-25); `resolve_backend_address` returns STORE's own pair verbatim or
  #     raises. There is no Digest/SHA/hexdigest call in this file and a spec asserts that;
  #   * no fixture fallback. `FixtureI3ReadPort` is not required, referenced or reachable from
  #     here, so a backend failure can never degrade into synthetic data. An ABSENT backend leaves
  #     the port UNWIRED -> 503, which is the documented correct behaviour
  #     (local_i3_read_binding.rb:20-23).
  #
  # ==== CAPABILITIES WITH NO SOURCE
  #
  # `versions.runtime` (handoff 022b Q3 = NO) and the O23 health block (Q1 = NO) HAVE NO SOURCE.
  # A request needing them fails closed with its own distinct reason and NEVER a fabricated value:
  # see `#runtime_version!` and `#health!`, which raise rather than answer. I3-01 and I3-09 are
  # OUT OF SCOPE (Q2) and are not implemented here at all.
  #
  # ==== THE REASON-STRING DISCIPLINE (not an existence oracle)
  #
  # An unresolvable address, an unwired backend and a malformed address must be INDISTINGUISHABLE
  # on the wire, or the surface becomes an existence oracle. So every address failure -- STORE
  # answered "unknown", STORE answered "not ready", the channel was dead, the envelope was
  # malformed, the digest was missing, the digest was ambiguous -- raises
  # `AddressUnavailable("backend_digest_unavailable")`, the SAME string the fixture and the unwired
  # port use (fixture_i3_read_port.rb:34, local_i3_read_binding.rb:88). The operator still gets the
  # real cause through `last_refusal`, which is SERVER-SIDE ONLY and never rendered.
  class I2ReaderProcessClient
    # Stamped into `_meta.data_origin` on every response built from this reader.
    ORIGIN = "live"

    # A VIEW-side default deadline. Not a STORE value and not a contract term: it is how long THIS
    # client waits before declaring the reader unavailable. A hung reader must produce a
    # not-ready/503 answer, never a hung request (requirement 6).
    DEFAULT_DEADLINE_MS = 5_000

    # The I2 operation ids this client uses, and the reader methods they serve. The mapping is
    # STORE's (i2_read.py's own section comments) and is declared here so the handoff packet and
    # the code cannot drift:
    #
    #   I2-01 status        (i2_read.py:710) -> #readiness        (the readiness probe)
    #   I2-02 buckets       (i2_read.py:744) -> #resolve_backend_address  (STORE's key + digest)
    #   I2-03 neighbours    (i2_read.py:759) -> #neighbours
    #   I2-09 open          (i2_read.py:858) -> #open
    #   I2-07 declarations  (i2_read.py:732) -> #declarations!    (diagnostic; not on the I3 surface)
    #
    # The five refused operations (I2-04/05/06/08/10, i2_read.py:898-911) are NOT called by this
    # client at all: calling an operation the slice refuses in order to discover that it refuses is
    # pointless traffic.
    OP_STATUS = "I2-01"
    OP_BUCKETS = "I2-02"
    OP_NEIGHBOURS = "I2-03"
    OP_DECLARATIONS = "I2-07"
    OP_OPEN = "I2-09"

    # Readiness reasons. One DISTINCT string per failure mode, matching the discipline
    # i3_read_port.rb:31-34 requires ("ONE distinct reason string per failure"). These reach the
    # wire via the controller's 503 `reason` field, so each must name a condition and never a
    # detail of the backend's internals.
    REASON_STORE_NOT_READY = "i2_store_not_ready"
    REASON_CHANNEL_DOWN = "i2_reader_channel_unavailable"
    REASON_TIMEOUT = "i2_reader_timeout"
    REASON_CONTRACT = "i2_reader_contract_violation"
    REASON_REFUSED = "i2_reader_refused_status"
    REASON_SCHEMA = "i2_reader_schema_mismatch"
    # The I2-01 envelope carried a state-bearing outcome that is NOT a clean "ok" -- "ok, partial",
    # "unknown" or "reload". DISTINCT from REASON_CONTRACT (a malformed frame) and from
    # REASON_STORE_NOT_READY (the store said so itself) because the operator's response differs:
    # the store answered coherently, but what it answered is not a green light.
    REASON_DEGRADED_OUTCOME = "i2_store_outcome_not_ok"

    # The SINGLE reason string every address failure collapses to. Deliberately identical to the
    # unwired and malformed cases so the three are indistinguishable (see the class header).
    ADDRESS_REASON = "backend_digest_unavailable"

    # @param writer [#puts] the reader process's stdin, INJECTED. Never built here.
    # @param reader [#gets] the reader process's stdout, INJECTED. Never built here.
    # @param deadline_ms [Integer] this client's own wait budget.
    # @param id_factory [#call] correlation-id source. Injected so a spec gets deterministic ids;
    #   the default is a counter, NOT a clock, because this file makes no time call.
    def initialize(writer:, reader:, deadline_ms: DEFAULT_DEADLINE_MS, id_factory: nil)
      unless writer.respond_to?(:puts)
        raise Atomspace::ServiceUnavailable, "the injected transport writer must answer #puts"
      end
      unless reader.respond_to?(:gets)
        raise Atomspace::ServiceUnavailable, "the injected transport reader must answer #gets"
      end
      unless deadline_ms.is_a?(Integer) && deadline_ms.positive?
        raise Atomspace::ServiceUnavailable, "deadline_ms must be a positive Integer"
      end

      @writer = writer
      @reader = reader
      @deadline_ms = deadline_ms
      @counter = 0
      @id_factory = id_factory
      @last_refusal = nil
      # Once the channel is proven broken the client STAYS broken. A half-read stream cannot be
      # resynchronised (the next `gets` would return the tail of a frame), so continuing to use it
      # risks reading one operation's answer as another's. A dead channel is permanent until the
      # operator rebinds.
      @channel_dead = false
      # One pipe pair, one transaction at a time. See #call!.
      require "thread"
      @mutex = ::Mutex.new
    end

    # Provenance. Always "live": there is no path through this class that produces synthetic data,
    # so the label cannot be wrong. A reader that is NOT live is a different class
    # (FixtureI3ReadPort), which is how the two stay impossible to confuse.
    def origin
      ORIGIN
    end

    # The OPERATOR-FACING cause of the most recent refusal. Server-side only: the controller never
    # renders it, because an address failure's real cause is exactly what must not be disclosed
    # (see the reason-string discipline in the class header).
    # @return [String, nil]
    attr_reader :last_refusal

    # ---- the LocalI3ReadBinding reader contract ---------------------------------------------
    #
    # REQUIRED_READER_METHODS (local_i3_read_binding.rb:39) = open, neighbours,
    # resolve_backend_address. `readiness` is optional there and implemented here, because a reader
    # that cannot state its readiness is treated as NOT READY (local_i3_read_binding.rb:71-79) and
    # this one can state it: I2-01 carries it.

    # Readiness from I2-01 `status`.
    #
    # EVERY failure is NOT-READY with its own reason, and none is ever a false green:
    #
    #   * STORE answered "not ready"                       -> REASON_STORE_NOT_READY
    #   * the channel is dead / the pipe closed / EOF       -> REASON_CHANNEL_DOWN
    #   * the child did not answer in time                  -> REASON_TIMEOUT      (requirement 6)
    #   * the envelope was missing/malformed                -> REASON_CONTRACT
    #   * STORE refused I2-01                               -> REASON_REFUSED
    #   * STORE reported another schema                     -> REASON_SCHEMA
    #
    # @return [Atomspace::MirrorReadiness::Result]
    def readiness
      frame = call!(OP_STATUS, {})
      unless frame["ok"]
        return not_ready(REASON_REFUSED, "I2-01 #{error_kind(frame)}: #{error_reason(frame)}")
      end

      envelope, payload = Atomspace::I2Envelope.split!(frame)
      if Atomspace::I2Envelope.not_ready?(envelope)
        return not_ready(REASON_STORE_NOT_READY, "the store has no published, ready state")
      end

      # The SCHEMA is checked before readiness is granted. `versions.schema` is a STORE constant
      # (record_store.py:133, handoff 022b §1), so a different value means a different corpus and
      # the atom vocabulary VIEW maps would not apply.
      schema = payload.dig("versions", "schema")
      unless schema == Atomspace::I2Envelope::SCHEMA_VERSION
        return not_ready(REASON_SCHEMA, "the store reports schema #{schema.inspect}")
      end

      # `readiness` is I2-01's OWN field (i2_read.py:726-728): "ready" with a state, NOT_READY
      # without. A stateful envelope whose readiness field disagrees is a contract violation, not
      # something to resolve in VIEW's favour.
      unless payload["readiness"] == "ready"
        return not_ready(REASON_CONTRACT, "I2-01 readiness #{payload['readiness'].inspect} with a state")
      end

      # THE OUTCOME MUST BE EXACTLY "ok" FOR READY. Excluding only "not ready" is not enough: the
      # five outcomes are `ok | ok, partial | unknown | reload | not ready` (STORE handoff 022b §1),
      # and "ok, partial" (a truncated/ambiguous answer), "unknown" and "reload" (the published
      # state moved) each describe a store whose status answer is NOT a clean green. Granting READY
      # on them because the `readiness` FIELD said "ready" would let a degraded store present as
      # fully ready -- a false green, which is the one outcome this class must never produce. Each
      # non-ok outcome is NOT-READY with its own distinct reason.
      outcome = envelope["outcome"]
      unless outcome == "ok"
        return not_ready(REASON_DEGRADED_OUTCOME, "I2-01 envelope outcome #{outcome.inspect} is not \"ok\"")
      end

      Atomspace::MirrorReadiness::READY
    rescue Atomspace::I2StdioTransport::Timeout => e
      not_ready(REASON_TIMEOUT, e.message)
    rescue Atomspace::I2StdioTransport::ChannelError => e
      not_ready(REASON_CHANNEL_DOWN, e.message)
    rescue Atomspace::I2Envelope::ContractViolation => e
      not_ready(REASON_CONTRACT, e.message)
    end

    # STORE's OWN key and digest for a card, verbatim -- or a refusal. NEVER computed.
    #
    # THE TWO-STEP STORE PRESCRIBED (handoff 022b §4 Q4): "Resolve name -> card id deck-side, form
    # the key, CONFIRM it with I2-02 (the store's own key + digest). NEVER compute a digest."
    # So: VIEW forms the v2 participant key text `(Card <id>)` (cp022 §4; key text e.g.
    # "(Card 17120)"), asks I2-02, and returns the key and digest THE STORE ANSWERED WITH.
    #
    # THE ANSWER MUST BE ABOUT THE CARD THAT WAS ASKED ABOUT. "Confirm the key" means the store
    # AGREES with the formed key, not that the store may substitute another participant. An
    # I2-02 answer whose `participant.key` is a DIFFERENT key is REFUSED, because the caller
    # resolved authorization for the REQUESTED card id and the controller attributes everything
    # returned here to that id: honouring a substituted key would let one card's backend material
    # be addressed, and on the `open` path PROPERTIED, under another card's ACL decision. The
    # refusal uses the SAME ADDRESS_REASON as every other address failure, so no new oracle is
    # created -- a mismatch is indistinguishable from an unknown card on the wire.
    #
    # THE COMPARISON IS ON THE KEY ALONE. No digest is computed, derived or compared here (VIEW is
    # forbidden to compute one -- i3_read_port.rb:20-25); once the key matches, STORE's own key AND
    # digest are returned VERBATIM, exactly as before.
    #
    # FORMING A KEY IS NOT COMPUTING A DIGEST. The key is a documented text form over a card id;
    # the digest is SHA-256-derived and is STORE's alone. If STORE's answer lacks either half, this
    # raises: there is no code path that could fill one in from the other.
    #
    # @return [Hash] {"key" => String, "digest" => String} -- exactly what STORE sent.
    # @raise [Atomspace::I3ReadPort::AddressUnavailable] always with ADDRESS_REASON.
    def resolve_backend_address(card_id:)
      key = participant_key_for(card_id)
      frame = call!(OP_BUCKETS, { "participant" => { "key" => key } })
      refuse_address!("I2-02 #{error_kind(frame)}: #{error_reason(frame)}") unless frame["ok"]

      envelope, payload = Atomspace::I2Envelope.split!(frame)

      # "not ready" -> no state exists, so no address exists. Refused with the SAME string an
      # unknown card gets, because distinguishing them would tell a caller whether the store holds
      # a state for this card.
      refuse_address!("the store has no published state") if Atomspace::I2Envelope.not_ready?(envelope)

      case envelope["outcome"]
      when "ok"
        k, d = Atomspace::I2Envelope.participant_address!(payload)
        # THE IDENTITY GUARD. See the method header: a returned key that is not the requested key
        # is a refusal, never a silently-accepted substitution.
        unless k == key
          refuse_address!(
            "I2-02 answered for participant #{k.inspect} but #{key.inspect} was requested"
          )
        end
        { "key" => k, "digest" => d }
      when "unknown"
        # STORE's "unknown" (i2_read.py:703): the key is not a participant of this state.
        refuse_address!("the store does not hold this participant")
      when "ok, partial"
        # AN AMBIGUOUS DIGEST (i2_read.py:704-706, AMBIGUOUS_DIGEST_BOUND). Two keys share a
        # digest, so there is NO single authoritative address. Refused rather than picking one:
        # picking would mean VIEW chose a backend address, which is precisely what it may not do.
        refuse_address!("the store reported an ambiguous or truncated address")
      else
        # "reload" and anything else: no address was delivered.
        refuse_address!("I2-02 answered #{envelope['outcome'].inspect}")
      end
    rescue Atomspace::I2StdioTransport::ChannelError => e
      refuse_address!(e.message)
    rescue Atomspace::I2Envelope::ContractViolation => e
      refuse_address!(e.message)
    end

    # THE ENVELOPE-PRESERVING FORM of #resolve_backend_address, for I3-10 `lookup`.
    #
    # #resolve_backend_address returns only `{"key"=>, "digest"=>}` and so DISCARDS the validated
    # envelope -- including on the `unknown` branch, where it converts a perfectly ordinary
    # stateful answer into an AddressUnavailable refusal. That conflation is wrong for the I3
    # surface in both directions:
    #
    #   * on a HIT, the surface must report STORE's own outcome/epoch/position/read-at alongside
    #     the address, and had no source for them;
    #   * on a MISS, K8 §5.5 `:574` says lookup answers `unknown` -- a 200-shaped envelope outcome
    #     with no payload (`:483` payload column: "none") -- NOT a 503 backend condition. Reporting
    #     a miss as a backend failure both misstates the condition and makes a non-participant
    #     distinguishable from a backend outage.
    #
    # THE NON-ORACLE PROPERTY IS PRESERVED EXACTLY. `#resolve_backend_address`'s whole reason-string
    # discipline is that every address FAILURE -- dead channel, malformed envelope, missing digest,
    # ambiguous digest, not-ready store -- raises the SAME `backend_digest_unavailable`. That is
    # unchanged here: this method still refuses all of those identically. The ONLY branch it treats
    # differently is STORE's explicit `unknown`, which is not a failure at all but the contract's
    # own answer for "this key is not a participant of this state".
    #
    # @return [Atomspace::I3ReadResult] on a hit, `address` holds STORE's verbatim key+digest; on a
    #   miss the carrier holds STORE's real `unknown` envelope and NO address.
    # @raise [Atomspace::I3ReadPort::AddressUnavailable] for every genuine address failure.
    def lookup_reading(card_id:)
      key = participant_key_for(card_id)
      frame = call!(OP_BUCKETS, { "participant" => { "key" => key } })
      refuse_address!("I2-02 #{error_kind(frame)}: #{error_reason(frame)}") unless frame["ok"]

      envelope, payload = Atomspace::I2Envelope.split!(frame)

      # "not ready" -> no state exists, so no address exists.
      #
      # THE REAL STORE ANSWER IS CARRIED, NOT DESTROYED. This used to `refuse_address!`, which
      # raised AddressUnavailable -> the controller's non-envelope 503. STORE had actually ANSWERED
      # -- with a VALIDATED `not ready` envelope, one of K8's nine outcomes (`:486`) and one of the
      # two that legally carry the all-null triple (`:495-498`) -- and raising threw that answer
      # away, leaving the surface with nothing to render but a wrapper the real client provably
      # discards before parsing (`live-bridge.mjs:821` classifies >=500 as backend-error). So the
      # carrier holds STORE'S OWN envelope and the renderer emits STORE's own outcome.
      #
      # FAIL-CLOSED IS PRESERVED EXACTLY. `address` is nil (no state, so no address, and none is
      # invented) and `atoms` is nil -- NOT `[]`. `I3ReadResult#no_state?` is true for a `not ready`
      # envelope (i3_read_result.rb:99-101), so the renderer cannot present this as `ok` and the
      # controller cannot present it as an empty atom list.
      #
      # THE NON-ORACLE PROPERTY IS UNCHANGED. A `not ready` store answers `not ready` for EVERY
      # card, readable or not, present or absent -- the answer is a property of the store's state,
      # not of this card -- so it still distinguishes nothing about the subject.
      if Atomspace::I2Envelope.not_ready?(envelope)
        return Atomspace::I3ReadResult.new(envelope: envelope, reason: REASON_STORE_NOT_READY)
      end

      case envelope["outcome"]
      when "ok"
        k, d = Atomspace::I2Envelope.participant_address!(payload)
        unless k == key
          refuse_address!(
            "I2-02 answered for participant #{k.inspect} but #{key.inspect} was requested"
          )
        end
        Atomspace::I3ReadResult.new(
          envelope: envelope, payload: payload, address: { "key" => k, "digest" => d }
        )
      when "unknown"
        # STORE's own `unknown` (i2_read.py:703). Carried as the ANSWER, with its real state
        # triple, and NOT downgraded to a refusal. No address: none exists, and none is invented.
        Atomspace::I3ReadResult.new(envelope: envelope)
      when "ok, partial"
        # AN AMBIGUOUS DIGEST (i2_read.py:704-706). Two keys share a digest, so there is NO single
        # authoritative address. Refused rather than picking one.
        refuse_address!("the store reported an ambiguous or truncated address")
      else
        refuse_address!("I2-02 answered #{envelope['outcome'].inspect}")
      end
    rescue Atomspace::I2StdioTransport::ChannelError => e
      refuse_address!(e.message)
    rescue Atomspace::I2Envelope::ContractViolation => e
      refuse_address!(e.message)
    end

    # STORE's OWN `schema-version` and `limits`, read from I2-01 `status`.
    #
    # These are the two envelope fields that are NOT per-read: they describe the store, not the
    # answer. K8 §5.2 `:308-309` requires both on EVERY response, and `cpd001:467-470` records the
    # transformation: I2-01's `page-max.*`, `fanout-limit`, `state-retain.*` and
    # `label-bearing-properties` "move out of the payload into `limits` on the envelope".
    #
    # EVERY VALUE IS STORE'S. `schema-version` is `payload["versions"]["schema"]` verbatim --
    # deliberately NOT `I2Envelope::SCHEMA_VERSION`, which is VIEW's EXPECTATION and whose use here
    # would be VIEW asserting a schema the store never reported. The ten limits names are a
    # flattening of STORE's own nested blocks; no ceiling is derived, defaulted or clamped.
    #
    # A MALFORMED OR NOT-READY STATUS ANSWER YIELDS nil, NOT A PARTIAL BLOCK. The renderer then
    # emits `schema-version: null` / `limits: null` -- keys PRESENT (the client checks presence,
    # live-bridge.mjs:777) with honestly-null values -- rather than a half-filled limits hash that
    # a caller would read as the store's real ceilings.
    #
    # @return [Hash, nil] {"schema-version" => String, "limits" => Hash}, or nil.
    def store_profile
      frame = call!(OP_STATUS, {})
      return nil unless frame["ok"]

      envelope, payload = Atomspace::I2Envelope.split!(frame)
      # A not-ready store still reports its CONFIGURED ceilings: i2_read.py:727 spreads the same
      # `payload` on the no-state branch. So the profile is read even when no state exists -- the
      # ceilings are configuration, not state, and reporting them is not reporting a state.
      _ = envelope
      Atomspace::I3Envelope.profile_from_status_payload(payload)
    rescue Atomspace::I3Envelope::Unrenderable, Atomspace::I2Envelope::ContractViolation,
           Atomspace::I2StdioTransport::ChannelError, Atomspace::I2StdioTransport::Timeout => e
      record_refusal!("I2-01 profile unavailable: #{e.message}")
      nil
    end

    # STORE's current published-state envelope, from I2-01, with NO card-scoped read.
    #
    # WHY IT IS A SEPARATE METHOD FROM #readiness: readiness answers a BOOLEAN with a reason, and
    # deliberately discards the envelope. The I3 surface needs the envelope ITSELF for the two
    # answers that never touch the backend for the subject card (a lookup miss, an ACL-empty
    # result) but still owe the caller a real state triple.
    #
    # A `not ready` ANSWER IS CARRIED, NOT DISCARDED. This used to `return nil` for `not ready`, so
    # that a caller could not attach a triple of nulls to a stateful outcome. The guard was right
    # about the risk and wrong about the remedy: returning nil CONFLATED "the store answered and
    # has no state" with "the store could not be reached", and the controller then had to pick one
    # of the two no-state outcomes without evidence. STORE's own validated `not ready` envelope is
    # now returned, so the renderer reports STORE's OWN outcome (`k8-draft-2.md:486`) and nil means
    # exactly one thing: nothing could be read.
    #
    # THE ORIGINAL RISK IS STILL CLOSED, in two places that do not rely on this return value:
    #   * `I2Envelope.validate!` (run again at the I3ReadResult boundary) requires a `not ready`
    #     envelope's triple to be ALL NULL, so a null triple can never ride a stateful outcome; and
    #   * `I3Envelope.compose`'s no-state branch is the ONLY producer of null triples, and
    #     `state_triple` RAISES Unrenderable for any other outcome whose triple is missing or null
    #     (i3_envelope.rb:199-213).
    #
    # @return [Hash, nil] the VALIDATED four-key envelope, verbatim (stateful OR `not ready`), or
    #   nil when nothing could be read at all.
    def state_envelope
      frame = call!(OP_STATUS, {})
      return nil unless frame["ok"]

      envelope, _payload = Atomspace::I2Envelope.split!(frame)
      envelope
    rescue Atomspace::I2Envelope::ContractViolation, Atomspace::I2StdioTransport::ChannelError,
           Atomspace::I2StdioTransport::Timeout => e
      record_refusal!("I2-01 state envelope unavailable: #{e.message}")
      nil
    end

    # The card's own atoms, from I2-09 `open`.
    #
    # NARROWING IS UNSUPPORTED (handoff 022b §3): a non-empty kind[]/card-type[]/direction[] raises
    # I2Refused BEFORE readiness and is never reported via `omitted`. So this client sends NO
    # narrowing at all -- the argument does not exist on this method and cannot be smuggled in.
    #
    # @return [Array<Atomspace::Atom>] possibly EMPTY, which is a legitimate answer the controller
    #   renders as a 200 (i3_read_controller.rb:279-281). A malformed answer RAISES instead, so
    #   "nothing is there" and "the backend did not answer" stay distinguishable.
    def open(card_id:)
      # FAIL-CLOSED FOR THE BARE-ARRAY API, UNCHANGED. `read_participant!` now RETURNS a `not
      # ready` envelope instead of raising (see its header), which is right for the I3 surface --
      # it renders STORE's real outcome. But THIS method's contract is a bare `Array<Atom>`, which
      # has nowhere to put an outcome, so `[]` here would say "this card has no atoms" about an
      # unready store: exactly the fabrication the old raise prevented. So this legacy entry point
      # keeps raising, with the SAME class and the SAME reason string as before.
      reading = open_reading(card_id: card_id)
      raise Atomspace::ServiceUnavailable, REASON_STORE_NOT_READY if reading.no_state?
      # A `reload` has NO graph payload, so this method's bare Array would be `[]` -- "this card
      # has no atoms" about a state the store told us to re-read. Same fabrication as the unready
      # case, same fail-closed answer. The ENVELOPE-PRESERVING form above is where `reload` is
      # forwarded intact; this legacy entry point has nowhere to put an outcome.
      raise Atomspace::ServiceUnavailable, REASON_DEGRADED_OUTCOME if reading.outcome == "reload"

      reading.atoms || []
    end

    # THE ENVELOPE-PRESERVING FORM of #open. This is the method the I3 surface uses.
    #
    # WHY IT EXISTS: #open above returns a BARE array and therefore DISCARDS the envelope
    # `read_participant!` already validated -- `envelope` was used for nothing but the `.nil?`
    # test and then went out of scope. The I3 surface must emit STORE's own `outcome`, `epoch`,
    # `position` and `read-at` (K8 §5.2), and this deck is forbidden to invent any of them, so the
    # validated envelope has to SURVIVE the call. It does, on the carrier, by reference.
    #
    # STORE's `omitted` / `cursor-stale` / `counts` ride along on `payload` for the same reason:
    # real metadata, forwarded, never replaced by a success default.
    #
    # @return [Atomspace::I3ReadResult] carrying STORE's VALIDATED envelope and its whole payload.
    def open_reading(card_id:)
      envelope, payload = read_participant!(OP_OPEN, card_id, {})
      # STORE answered `unknown`: the key is not a participant of this state. The envelope is REAL
      # and stateful (see read_participant!'s `unknown` branch), so the reading carries STORE's own
      # outcome and triple and the renderer reports them verbatim. No atoms, because there is no
      # participant -- and an empty atom list is NOT substituted, which is what would have turned
      # "this participant is not in the state" into "this card has no atoms".
      return Atomspace::I3ReadResult.new(envelope: envelope) if payload.nil?

      Atomspace::I3ReadResult.new(
        envelope: envelope, payload: payload, atoms: atoms_from_properties(payload, card_id)
      )
    end

    # Atoms of adjacent cards, from I2-03 `neighbours`.
    #
    # `bucket` is STORE's link-type head, a plain String; `limit` becomes I2-03's
    # `limits["max-entries"]` (i2_read.py:784-786), which the store clamps against its OWN ceiling
    # and reports every cut via `omitted` (handoff 022b §6 Q9). VIEW does not re-clamp: the store's
    # ceilings are STORE's (P-PAGE-MAX, K3) and VIEW owns none of them.
    #
    # A nil bucket is a REFUSAL, not a wildcard: I2-03 requires a bucket
    # (i2_read.py:776 -- a non-String bucket yields "unknown"), and inventing an "all buckets"
    # semantic would be VIEW adding a wire behaviour STORE never specified.
    def neighbours(card_id:, bucket: nil, limit: nil, after: nil)
      # FAIL-CLOSED FOR THE BARE-ARRAY API -- same reasoning as #open above.
      reading = neighbours_reading(card_id: card_id, bucket: bucket, limit: limit, after: after)
      raise Atomspace::ServiceUnavailable, REASON_STORE_NOT_READY if reading.no_state?
      # See #open: `[]` for a `reload` would assert an empty neighbourhood. Refused here; the
      # envelope-preserving #neighbours_reading forwards STORE's verdict instead.
      raise Atomspace::ServiceUnavailable, REASON_DEGRADED_OUTCOME if reading.outcome == "reload"

      reading.atoms || []
    end

    # THE ENVELOPE-PRESERVING FORM of #neighbours. This is the method the I3 surface uses.
    #
    # Same rationale as #open_reading: the envelope `read_participant!` validated is RETAINED
    # instead of being used for a `.nil?` test and dropped. It additionally matters more here,
    # because I2-03 is the op that reports truncation: STORE's `omitted` (i2_read.py:796) and
    # `cursor-stale` / `counts` (:779-781, :799-800) are carried on `payload` and forwarded by the
    # renderer, so a page cut by the store's own ceiling is reported as cut rather than as a short
    # but complete page.
    #
    # @return [Atomspace::I3ReadResult]
    # ==== THE INBOUND CURSOR (`after`), FORWARDED VERBATIM AND NEVER CONSTRUCTED
    #
    # `after` is I3-03's governing continuation input (`k8-draft-2.md:567`) and maps onto I2-03's
    # own `after` argument (`:1037`). It is passed STRAIGHT THROUGH to STORE as the canonical
    # outbound arg name `"after"`, with NO transformation whatsoever:
    #
    #   * NOTHING IS CONSTRUCTED. This deck never builds, mutates, re-orders, re-cases, extends or
    #     re-serializes a cursor, and never synthesises one from a key or digest. The ONLY value it
    #     will send is one STORE ITSELF ISSUED (the controller proves that before calling here).
    #   * THE CURSOR STAYS OPAQUE. §5.8 (`:734`) makes a cursor opaque to the client; this deck
    #     likewise does not read it for MEANING. It is inspected only to AUTHORIZE it, and the
    #     structure handed to STORE is byte-equal to the structure the caller presented.
    #   * ABSENT MEANS FIRST PAGE. `nil` omits the argument entirely rather than sending a null,
    #     because `after: null` would be a value STORE never issued.
    #
    # @param after [Hash, String, nil] the STORE-issued continuation, already validated and
    #   authorized by the caller. Forwarded verbatim.
    def neighbours_reading(card_id:, bucket: nil, limit: nil, after: nil)
      unless Atomspace::I2Envelope.string_present?(bucket)
        raise Atomspace::InvalidRequest, "bucket_required"
      end

      args = { "bucket" => bucket }
      args["limits"] = { "max-entries" => limit } if limit.is_a?(Integer) && limit.positive?
      # VERBATIM, and only when present. Never a null, never a reconstruction.
      args["after"] = after unless after.nil?

      envelope, payload = read_participant!(OP_NEIGHBOURS, card_id, args)
      # STORE answered `unknown` -- real, stateful envelope, no payload. See #open_reading.
      return Atomspace::I3ReadResult.new(envelope: envelope) if payload.nil?

      entries = payload["entries"]
      # A state-bearing I2-03 answer MUST carry `entries` (i2_read.py:794). Absent means malformed,
      # and `[]` would read as an empty neighbourhood -- the exact conflation
      # i3_read_controller.rb:270-277 forbids.
      unless entries.is_a?(Array)
        contract_violation!("I2-03 answered #{envelope['outcome'].inspect} without an entries list")
      end

      Atomspace::I3ReadResult.new(
        envelope: envelope,
        # The PRIMARY envelope is passed in so the best-effort enrichment can PROVE it sampled the
        # SAME published state before any of its keys are merged (see the method's own note).
        payload: merge_i2_03_participant_address(payload, card_id, bucket, envelope),
        atoms: entries.map { |entry| atom_from_entry!(entry) }
      )
    end

    # ---- declared capability gaps: NO SOURCE, so NO VALUE -----------------------------------
    #
    # These two exist so the absence is NAMED IN CODE and cannot be filled in later by someone who
    # assumes a default is harmless. Neither is on the I3 surface; the controller already refuses
    # health with 501 (i3_read_controller.rb:187-193).

    # `versions.runtime` HAS NO SOURCE (handoff 022b Q3 = NO). STORE's I2-01 payload carries
    # `versions: {schema: ...}` ONLY (i2_read.py:714). A caller needing a runtime version gets a
    # DISTINCT typed refusal, never a fabricated string.
    #
    # The distinction STORE asked VIEW to preserve (handoff 022b §2): the DIRECT adapter raises a
    # bare KeyError 'runtime' while `call_i3` gives RuntimeVersionUnavailable. This is the
    # deck-side analogue of the LATTER -- a named, typed refusal -- and it is deliberately NOT a
    # KeyError, so the two cannot be confused.
    class RuntimeVersionUnavailable < Atomspace::Error; end

    # The O23 health slice is DESIGN-ONLY (handoff 022b Q1 = NO; i2_read.py:60 "Absent, not
    # fabricated: health (O23 gated)"). Projection, liveness, drain heartbeat,
    # oldest-unapplied-age and hidden-provenance-count are ABSENT, not zero.
    class HealthSliceUnavailable < Atomspace::Error; end

    def runtime_version!
      raise RuntimeVersionUnavailable,
            "i2_runtime_version_unavailable: versions.runtime has no source in this slice " \
            "(STORE 022b Q3); no value is substituted"
    end

    def health!
      raise HealthSliceUnavailable,
            "i2_health_slice_unavailable_o23_gated: the health slice is design-only (STORE 022b " \
            "Q1); projection, liveness, drain heartbeat, oldest-unapplied-age and " \
            "hidden-provenance-count are absent, not fabricated"
    end

    # I2-07 declarations. A DIAGNOSTIC for the local operator (which of the nineteen cp022 §4 heads
    # the store actually holds), AND -- since the unresolved-target rule (N04) is authorized from
    # it -- a STATE-BEARING answer whose envelope the caller must be able to check.
    #
    # THE ENVELOPE IS RETURNED, NOT DISCARDED. This used to return `payload` alone. The I3
    # projection uses these heads to decide whether a non-Card position is an admissible
    # unresolved target, so the declarations are no longer purely diagnostic: they AUTHORIZE. A
    # payload with no envelope cannot be checked against the state being projected, which left the
    # door open to authorizing entries in one reading with declarations read from a DIFFERENT
    # store state. The envelope rides along so `declared_unresolved_heads` can require
    # epoch+position agreement before applying the exception -- the same binding the I2-02
    # participant enrichment already enforces.
    # @return [Array(Hash, Hash)] [envelope, payload] where payload is
    #   {"heads" => [...], "malformed" => [...]}.
    def declarations!
      frame = call!(OP_DECLARATIONS, {})
      unless frame["ok"]
        raise Atomspace::ServiceUnavailable, "I2-07 #{error_kind(frame)}: #{error_reason(frame)}"
      end

      envelope, payload = Atomspace::I2Envelope.split!(frame)
      raise Atomspace::ServiceUnavailable, REASON_STORE_NOT_READY if Atomspace::I2Envelope.not_ready?(envelope)

      [envelope, payload]
    end

    # The v2 participant key text for a decko card id: `(Card <id>)`.
    #
    # cp022 §4 / handoff 022b §4: "The v2 participant is (Card <cards.id>), key text e.g.
    # '(Card 17120)'." STORE's own encoder builds the same atom
    # (v2_bootstrap.py:80-81 `_card` -> `_expr(_sym("Card"), ("int", card_id))`) and its canonical
    # text comes from `key_text` (i2_read.py:178-190), which renders an expr as
    # "(" + parts joined by " " + ")" with an int rendered by `str`. So `(Card 17120)`.
    #
    # THIS IS A KEY, NOT A DIGEST. It is sent to I2-02 to be CONFIRMED; the authoritative key and
    # digest are whatever STORE answers with. A non-integral card id is refused rather than
    # coerced: `.to_i` on "17120x" would silently address a different card.
    def participant_key_for(card_id)
      self.class.participant_key_text(card_id)
    end

    # THE CANONICAL PARTICIPANT KEY TEXT, as a class method so there is exactly ONE definition of
    # the form and every caller shares it.
    #
    # Promoted from the instance method (which now delegates here) because the I3 controller must
    # build the SAME text to check that an inbound cursor's subject is the card being requested.
    # A second copy of `"(Card #{id})"` in the controller would be a second definition of a store
    # address form, and the two could drift; this keeps the one definition that
    # #card_id_from_store_key_text's pattern is the exact inverse of.
    #
    # Still a KEY, not a digest, and still refuses rather than coerces a non-integral id.
    def self.participant_key_text(card_id)
      unless card_id.is_a?(Integer) && !card_id.is_a?(TrueClass) && card_id.positive?
        raise Atomspace::InvalidRequest, "card_id_invalid"
      end

      "(Card #{card_id})"
    end

    private

    # ONE request/response round trip, with the deadline enforced on VIEW's side.
    #
    # WHY VIEW ENFORCES ITS OWN DEADLINE (requirement 6). A hung or dead reader must produce a
    # not-ready/service-unavailable answer, never a hang. The child is TOLD the budget
    # (`deadline-ms`, advisory) but cannot be trusted to honour it -- a wedged process honours
    # nothing -- so the wait is bounded here with Ruby's own Timeout around the blocking read.
    #
    # A TIMEOUT KILLS THE CHANNEL. After one, the stream position is unknown: the late answer may
    # still arrive and would be read as the NEXT operation's response. Marking the channel dead
    # makes every later call fail closed instead of mismatching frames.
    #
    # THE WRITE IS INSIDE THE DEADLINE. A pipe has a finite buffer (64KB on Windows, 64KB on
    # Linux), so a child that has stopped CONSUMING its stdin will cause `puts`/`flush` to block
    # once that buffer fills -- forever, with no read ever reached. Bounding only the read would
    # leave exactly the hang requirement 6 forbids, just moved one line earlier. Both halves of the
    # round trip therefore run under one budget.
    #
    # THE TRANSACTION IS SERIALISED. One pipe pair carries every operation and frames are matched
    # by `id`, so two concurrent callers would interleave their writes and could each consume the
    # other's response line -- a silent cross-operation data mix, which on this surface means one
    # card's answer delivered for another card's request. The mutex makes request+response one
    # atomic transaction. It is NOT re-entrant: this client never calls itself.
    def call!(op, args)
      @mutex.synchronize { transact!(op, args) }
    end

    def transact!(op, args)
      if @channel_dead
        raise Atomspace::I2StdioTransport::ChannelError,
              "this reader channel was already declared dead; the operator must rebind"
      end

      id = next_id
      with_deadline do
        Atomspace::I2StdioTransport.write_request!(
          @writer, id: id, op: op, args: args, deadline_ms: @deadline_ms
        )
        Atomspace::I2StdioTransport.read_response!(@reader, expect_id: id)
      end
    rescue Atomspace::I2StdioTransport::ChannelError
      @channel_dead = true
      raise
    end

    # The blocking read, bounded. `Timeout` is required lazily so this file loads in a bare-Ruby
    # proof process without pulling it in until a real wait happens.
    def with_deadline
      require "timeout"
      ::Timeout.timeout(@deadline_ms / 1000.0) { yield }
    rescue ::Timeout::Error
      raise Atomspace::I2StdioTransport::Timeout,
            "the reader process did not answer within #{@deadline_ms}ms"
    end

    # SUPPLY THE I3-03 PARTICIPANT ADDRESS -- from STORE, never constructed.
    #
    # ==== THE GAP THIS FILLS, measured rather than assumed
    #
    # STORE's real I2-03 payload top-level keys are EXACTLY `["entries"]` -- no participant, no
    # bucket, no counts (measured against the real reader child; `i2_read.py:794` emits the entries
    # list alone). But the only consumer that exists REQUIRES a participant on this page:
    # `av-client/src/drawn-graph.mjs` `ingestNeighboursPage` reads `response.participant` and runs
    # its key AND digest through `wireIdentity`, which THROWS TypeError unless BOTH are Strings. So
    # a neighbours page with no participant cannot be ingested into the drawn graph at all.
    #
    # ==== WHERE THE ADDRESS COMES FROM, AND WHERE IT DOES NOT
    #
    # It is STORE'S OWN, obtained by issuing the EXISTING I2-02 `buckets` op through the EXISTING
    # `read_participant!` machinery -- the same transport, the same identity guard
    # (`assert_participant_identity!`), the same envelope validation. NOTHING is constructed here:
    #   * the `key` is the one STORE answered with, forwarded VERBATIM;
    #   * the `digest` is STORE's, forwarded VERBATIM and NEVER computed (VIEW is forbidden to
    #     compute one -- `i3_read_port.rb:20-25`), which is why a local `(Card <id>)` string is not
    #     an acceptable substitute: it carries no digest and the client requires one;
    #   * the `bucket` descriptor and its `counts` are STORE's own I2-02 bucket object for the
    #     REQUESTED link-type, forwarded VERBATIM so its real counts travel with the page.
    # All three ride under STORE's OWN K8 key names (`participant`, `bucket`, `counts`), so no wire
    # vocabulary is coined.
    #
    # ==== BEST-EFFORT, HONEST OMISSION, AND NO NEW FAILURE MODE
    #
    # This is ADDITIVE ENRICHMENT of an answer that already succeeded. A neighbours read that
    # succeeded before MUST still succeed with the SAME atoms, so every failure of the I2-02
    # resolve -- refusal, not-ready, unknown, ambiguous, channel death, contract violation, a
    # bucket the descriptor does not list -- is RESCUED, recorded on the server-side-only
    # `last_refusal` via the existing `record_refusal!`, and leaves the keys ABSENT.
    #
    # ABSENT, NEVER NULL, NEVER FABRICATED. An absent key says "this page carries no address",
    # which is true and which the client handles by throwing a protocol error the operator can see.
    # A `participant: null` would assert an address exists and is nothing; a locally-built key with
    # no digest would be VIEW inventing a backend address. Both are worse than absence.
    #
    # ==== ONE RESPONSE, ONE STORE STATE (the mixed-state defect this repairs)
    #
    # THE DEFECT. The I2-02 resolve is a SECOND, LATER read of the store. Its envelope was bound
    # but used ONLY to build an error string -- its `epoch` and `position` were never compared with
    # the PRIMARY I2-03 envelope's. So if the store published a new state between the two reads,
    # the participant class, the bucket descriptor and its counts would be sampled at the LATER
    # state while riding out under the EARLIER envelope's triple: ONE response whose fields come
    # from TWO DIFFERENT STORE STATES, labelled as one. The whole point of the envelope is that
    # every field under it was read at the state it names, so that is a false claim about provenance
    # even when every individual value is real.
    #
    # THE FIX. The enrichment envelope's `epoch` AND `position` must EQUAL the primary's, exactly.
    # Both come from `I2Envelope.validate!` (`i2_envelope.rb:87` -- `KEYS` carries both), so they
    # are read through the existing validated-envelope contract and never hand-parsed. On ANY
    # mismatch -- or when either envelope cannot supply the pair -- the enrichment is ABANDONED:
    # `participant`, `bucket` and `counts` stay ABSENT, the reason goes to the server-side-only
    # `last_refusal`, and the neighbours answer STORE already gave is returned EXACTLY as it was.
    # Absent, never null, never fabricated, and never a 503: a read that succeeded before still
    # succeeds, with the same atoms, which is the whole contract of this best-effort step.
    #
    # @param envelope [Hash] the PRIMARY I2-03 envelope the response will be rendered under.
    # @return [Hash] a COPY of STORE's payload plus whatever STORE actually supplied. The original
    #   payload hash is not mutated, so the atoms built from `entries` above are unaffected.
    def merge_i2_03_participant_address(payload, card_id, bucket, envelope)
      return payload unless payload.is_a?(Hash)

      address_envelope, address_payload = read_participant!(OP_BUCKETS, card_id, {})
      # `not ready` / `unknown` return a nil payload through the same contract every caller uses.
      # No state or no participant -> no address, and none is invented.
      if address_payload.nil?
        return record_i2_03_address_gap(payload, "I2-02 supplied no participant payload " \
                                                 "(outcome #{address_envelope && address_envelope['outcome'].inspect})")
      end

      # SAME STATE OR NO ENRICHMENT. Checked BEFORE anything is merged, so no partially-merged
      # mixed-state payload can exist even transiently.
      mismatch = state_mismatch_detail(envelope, address_envelope)
      return record_i2_03_address_gap(payload, mismatch) if mismatch

      participant = address_payload["participant"]
      unless participant.is_a?(Hash)
        return record_i2_03_address_gap(payload, "I2-02 answered without a participant mapping")
      end

      # STORE's own key AND digest must BOTH be present and String-typed, because the consumer
      # requires both. A half-address is treated as no address rather than completed from the
      # other half -- there is no code path here that could complete one.
      Atomspace::I2Envelope.participant_address!(address_payload)

      enriched = payload.dup
      enriched["participant"] = participant

      descriptor = i2_02_bucket_descriptor(address_payload, bucket)
      if descriptor.nil?
        record_refusal!("I2-02 listed no bucket #{bucket.inspect} for #{participant_key_for(card_id)}")
      else
        enriched["bucket"] = descriptor
        # `counts` is forwarded ONLY when STORE's descriptor actually carries one AND STORE's OWN
        # I2-03 payload sent NO top-level `counts`. STORE's top-level value is the authoritative
        # one (the documented precedence at `i3_envelope.rb:354`), so overwriting it with a
        # bucket-derived one would be exactly the substitution of a real STORE value by a derived
        # one that this lane forbids. Latent today -- measured I2-03 top-level keys are exactly
        # ["entries"] -- and guarded anyway, so the code and that note cannot drift apart.
        if descriptor.key?("counts") && !payload.key?("counts")
          enriched["counts"] = descriptor["counts"]
        end
      end

      enriched
    rescue Atomspace::Error, Atomspace::I2Envelope::ContractViolation,
           Atomspace::I2StdioTransport::ChannelError => e
      # EVERY address failure degrades to ABSENCE, never to a refusal of the whole read. The
      # neighbours answer STORE already gave is returned exactly as it was.
      record_i2_03_address_gap(payload, "#{e.class}: #{e.message}")
    end

    # Why these two validated envelopes do not describe the SAME published state, or nil when they
    # do. Returns a DETAIL STRING for `record_refusal!` -- server-side only, never on the wire.
    #
    # `epoch` and `position` are the two state coordinates `I2Envelope::KEYS` carries
    # (`i2_envelope.rb:87`) and `validate_stateful!` requires on every state-bearing outcome. They
    # are compared with `==`, verbatim, through the validated envelope's own keys -- NOT re-parsed,
    # NOT normalised, NOT coerced. A missing coordinate on either side is a MISMATCH, not a pass:
    # an envelope that cannot state where it was read is one whose provenance cannot be confirmed.
    def state_mismatch_detail(primary, enrichment)
      return "the primary I2-03 envelope is not a mapping" unless primary.is_a?(Hash)
      return "I2-02 answered without an envelope" unless enrichment.is_a?(Hash)

      %w[epoch position].each do |coord|
        unless primary.key?(coord) && enrichment.key?(coord)
          return "the #{coord} coordinate is absent from one of the two envelopes"
        end

        next if primary[coord] == enrichment[coord]

        return "STORE PUBLISHED A NEW STATE BETWEEN THE TWO READS -- I2-03 #{coord} " \
               "#{primary[coord].inspect} != I2-02 #{coord} #{enrichment[coord].inspect}; the " \
               "participant/bucket/counts enrichment is abandoned rather than mixed into an " \
               "envelope that names a different state"
      end

      nil
    end

    # STORE's I2-02 bucket object for one link-type head, or nil. Matched on STORE's OWN
    # `link-type` value -- the requested head is compared, never rewritten or re-cased.
    def i2_02_bucket_descriptor(address_payload, bucket)
      buckets = address_payload["buckets"]
      return nil unless buckets.is_a?(Array)

      buckets.find { |b| b.is_a?(Hash) && b["link-type"] == bucket }
    end

    # Record WHY no address travelled (server-side only) and return the payload UNCHANGED.
    def record_i2_03_address_gap(payload, detail)
      record_refusal!("I2-03 participant address unavailable -- #{detail}")
      payload
    end

    # Resolve a participant and return [envelope, payload], or [nil, nil] for STORE's "unknown".
    #
    # "unknown" is NOT an error here: on the card-scoped reads an unknown participant is an empty
    # result, which the controller renders as a 200 -- identical to a card with no readable atoms,
    # and therefore not an existence oracle (i3_read_controller.rb:233-239). On the ADDRESS path it
    # IS a refusal, because #lookup's contract distinguishes a backend condition from `unknown`.
    def read_participant!(op, card_id, extra_args)
      requested_key = participant_key_for(card_id)
      args = { "participant" => { "key" => requested_key } }.merge(extra_args)
      frame = call!(op, args)

      unless frame["ok"]
        kind = error_kind(frame)
        # A SLICE REFUSAL is a backend condition, not an empty result. The most likely cause is a
        # narrowing or cursor the slice does not support (handoff 022b §3) -- which this client
        # never sends -- so reaching here means the server and this contract disagree.
        raise Atomspace::ServiceUnavailable, "#{op} #{kind}: #{error_reason(frame)}"
      end

      envelope, payload = Atomspace::I2Envelope.split!(frame)

      # NOT READY -> STORE'S OWN ANSWER, carried; never an empty list, and never a bare 503.
      #
      # THE DEFECT THIS REPLACES. This used to `raise Atomspace::ServiceUnavailable,
      # REASON_STORE_NOT_READY`, which landed on the controller's `render_backend_unavailable` ->
      # `render_unavailable` -> a NON-ENVELOPE 503 body. STORE had answered with a VALIDATED
      # `not ready` envelope -- an enumerated K8 outcome (`k8-draft-2.md:486`) that legally carries
      # the all-null triple (`:495-498`) -- and the raise destroyed it, so the only consumer that
      # exists received a wrapper it discards before parsing (`live-bridge.mjs:821`). The real
      # answer is now RETURNED, with its own envelope, through the ordinary [envelope, payload]
      # contract this method already has.
      #
      # THE FAIL-CLOSED PROPERTY IS UNCHANGED, AND THAT IS THE POINT. `payload` is nil, exactly as
      # on the `unknown` branch below, so every caller's existing `payload.nil?` test routes this
      # to `I3ReadResult.new(envelope: envelope)` with atoms NIL -- never `[]`. An unready store
      # therefore still CANNOT be rendered as "this card has no atoms", which is the fabrication
      # this class exists to prevent, and `I3ReadResult#no_state?` (i3_read_result.rb:99-101)
      # returns true for a `not ready` envelope so it cannot be rendered as `ok` either.
      return [envelope, nil] if Atomspace::I2Envelope.not_ready?(envelope)

      case envelope["outcome"]
      when "ok", "ok, partial"
        # THE SAME IDENTITY GUARD resolve_backend_address applies, for the same reason and here it
        # matters MORE: `#open` stamps every returned property with the REQUESTED card_id
        # (atoms_from_properties' `card_id:` argument), which is the id the controller already
        # authorized. If the server answered about a DIFFERENT participant, those properties would
        # be attributed to -- and disclosed under -- the requested card's ACL decision. A
        # mismatched participant is therefore a CONTRACT VIOLATION (503), never silently relabelled
        # material. The key is compared only; no digest is computed.
        assert_participant_identity!(op, payload, requested_key)
        [envelope, payload]
      when "unknown"
        # STORE's `unknown` (i2_read.py:703): the key is not a participant of this state.
        #
        # THE ENVELOPE IS RETURNED, THE PAYLOAD IS NOT. This used to be `[nil, nil]`, which threw
        # away a VALIDATED envelope describing a REAL READ STATE. `unknown` is one of K8's nine
        # outcomes and it is a STATEFUL one: the store read a state and reported that this
        # participant is not in it, so `epoch`, `position` and `read-at` are real and MUST be
        # reported (an all-null triple is legal only on `not ready` / `unavailable` --
        # k8-draft-2.md:495-498). Discarding the envelope here left the I3 surface with no state to
        # report on a perfectly ordinary answer, and the only ways to fill that gap would have been
        # to invent a triple or to mislabel the answer as no-state. Both are forbidden; keeping the
        # envelope removes the need for either.
        #
        # `payload` is nil because STORE sent none for `unknown` ("none" -- k8-draft-2.md:483);
        # callers distinguish the branch on the payload, not on the envelope.
        [envelope, nil]
      when "reload"
        # STORE's `reload` (i2_read.py:774, :831): the cursor this read carried cannot be honoured
        # against the current state -- the epoch changed under it, or the retained position fell
        # outside STORE's `state-retain-positions` window.
        #
        # THE ENVELOPE IS RETURNED, NOT RAISED ON. This branch used to
        # `raise Atomspace::ServiceUnavailable, "... which this client sent no cursor for"`, whose
        # premise stopped being true once `after` was forwarded verbatim
        # (#neighbours_reading's `args["after"] = after`). A cursor IS now sent, so `reload` is an
        # ENUMERATED, LEGITIMATE K8 outcome (`k8-draft-2.md:478-488`, and one of the five this
        # slice emits -- i2_envelope.rb:24) and STORE's own §5.8 verdict for a stale continuation
        # (`:741-745`). Raising destroyed a VALIDATED, STATE-BEARING envelope and reported STORE's
        # correct answer as a VIEW backend failure: the caller got a non-envelope 503 that the only
        # consumer discards before parsing (`live-bridge.mjs:821`), instead of being told to
        # restart the page from the beginning.
        #
        # NOTHING IS INVENTED AND NOTHING IS WIDENED. `payload` is nil -- exactly as on the
        # `unknown` branch above -- so every caller's existing `payload.nil?` test routes this to
        # `I3ReadResult.new(envelope: envelope)` with atoms NIL, never `[]`. A `reload` therefore
        # CANNOT be rendered as "this card has no neighbours", and the emitted `outcome`, `epoch`,
        # `position` and `read-at` are STORE's own (`reload` is a STATEFUL outcome --
        # i2_envelope.rb:61 -- so `validate_stateful!` has already required a real triple, and
        # `I3Envelope.state_triple` will refuse to emit a null one). No retry is attempted here and
        # no cursor is rebuilt: the verdict is forwarded to the caller, which is whose decision it
        # is.
        [envelope, nil]
      else
        # UNREACHABLE against a conforming reader: `I2Envelope::OUTCOMES` is closed at five and
        # `validate!` has already refused anything outside it, and all five are handled above
        # (`not ready` returns early, `ok`/`ok, partial`, `unknown`, `reload`). Kept as a
        # fail-closed floor so a future reader answering a SIXTH outcome is refused rather than
        # silently falling through to a success shape.
        raise Atomspace::ServiceUnavailable,
              "#{op} answered #{envelope['outcome'].inspect}, which this client has no handling for"
      end
    end

    # A state-bearing read answer must be ABOUT the participant that was requested.
    #
    # Applied when the payload carries a `participant` mapping with a key: if the server named a
    # participant, that name must be the requested one. An answer with no participant key at all is
    # left to the caller's own structural validation (`atoms_from_properties` REQUIRES a full
    # participant address and refuses without one), so this guard never has to invent a key to
    # compare against.
    def assert_participant_identity!(op, payload, requested_key)
      participant = payload["participant"]
      return unless participant.is_a?(Hash)

      answered = participant["key"]
      return unless Atomspace::I2Envelope.string_present?(answered)
      return if answered == requested_key

      contract_violation!(
        "#{op} answered for participant #{answered.inspect} but #{requested_key.inspect} was requested"
      )
    end

    # I2-09's `participant.properties` -> VIEW Atoms.
    #
    # `i2_read.py:554-563` `_participant(with_properties=True)` emits
    # `properties: [{"key","digest","head","value","copy-count"}, ...]`. Each becomes one Atom
    # carrying the card id, so `associated_card_ids` yields [card_id] (atom.rb:20-25) and the
    # controller's ACL filter can act on it.
    #
    # EVERY field is required. A property entry missing `head` or `value` RAISES: an atom with a
    # nil head is not a weaker atom, it is a malformed one, and emitting it would put a fabricated
    # shape on the wire.
    def atoms_from_properties(payload, card_id)
      participant = payload["participant"]
      unless participant.is_a?(Hash)
        contract_violation!("I2-09 answered without a participant mapping")
      end

      # The ADDRESS half is validated even on the open path, so an answer whose participant lacks
      # STORE's own key/digest is refused rather than partially used.
      Atomspace::I2Envelope.participant_address!(payload)

      properties = participant["properties"]
      unless properties.is_a?(Array)
        contract_violation!("I2-09 answered without a properties list")
      end

      properties.map do |prop|
        contract_violation!("an I2-09 property entry is not a mapping") unless prop.is_a?(Hash)

        head = prop["head"]
        key = prop["key"]
        digest = prop["digest"]
        unless Atomspace::I2Envelope.string_present?(head) &&
               Atomspace::I2Envelope.string_present?(key) &&
               Atomspace::I2Envelope.string_present?(digest) &&
               prop.key?("value")
          contract_violation!("an I2-09 property entry is missing head/key/digest/value")
        end

        Atomspace::Atom.new(
          type: "I2Property",
          card_id: card_id,
          fields: { "head" => head, "key" => key, "digest" => digest,
                    "value" => prop["value"], "copy_count" => prop["copy-count"] }
        )
      end
    end

    # One I2-03 entry -> one Atom.
    #
    # `i2_read.py:603-619` `_entry` emits {"key","digest","class","label","trash","link-count",
    # "link-copy-count","links"[, "links-continue"]}. The neighbour's DECKO CARD ID is parsed back
    # out of its key text so the controller's ACL filter has a card id to authorize -- and that is
    # the ONLY reason it is parsed.
    #
    # A KEY THAT IS NOT `(Card <int>)` YIELDS NO CARD ID, and the Atom then carries card_id nil ->
    # `associated_card_ids` is EMPTY -> `filter_by_read_auth` DROPS it
    # (atomspace_read_filter.rb:17 "next false if ids.empty?"). That is deliberate and it is the
    # safe direction: a participant VIEW cannot attribute to a readable card is never disclosed.
    # It is NOT invented a card id to make it pass.
    def atom_from_entry!(entry)
      contract_violation!("an I2-03 entry is not a mapping") unless entry.is_a?(Hash)

      key = entry["key"]
      digest = entry["digest"]
      unless Atomspace::I2Envelope.string_present?(key) && Atomspace::I2Envelope.string_present?(digest)
        contract_violation!("an I2-03 entry is missing STORE's own key or digest")
      end

      Atomspace::Atom.new(
        type: "I2Neighbour",
        card_id: card_id_from_participant_key(key),
        fields: { "key" => key, "digest" => digest, "class" => entry["class"],
                  "label" => entry["label"], "trash" => entry["trash"],
                  "link_count" => entry["link-count"],
                  "link_copy_count" => entry["link-copy-count"] }
      )
    end

    # `(Card 17120)` -> 17120, or nil. STRICT: the exact canonical text only, because that is the
    # only form `key_text` produces for a card participant (i2_read.py:178-190 over
    # v2_bootstrap.py:80-81). Anything else -- a Wanted target, a link key, whitespace variance --
    # is nil, which drops the atom at the ACL filter rather than guessing an id.
    def card_id_from_participant_key(key)
      match = /\A\(Card (0|[1-9][0-9]*)\)\z/.match(key)
      match && match[1].to_i
    end

    def contract_violation!(detail)
      raise Atomspace::I2Envelope::ContractViolation.new(REASON_CONTRACT, detail)
    end

    # EVERY address failure, one string. The real cause goes to `last_refusal` (server-side only).
    def refuse_address!(detail)
      @last_refusal = detail
      raise Atomspace::I3ReadPort::AddressUnavailable, ADDRESS_REASON
    end

    # Record an operator-facing cause WITHOUT raising, for the paths that answer nil rather than
    # refusing (#store_profile). SERVER-SIDE ONLY: `last_refusal` is never rendered.
    def record_refusal!(detail)
      @last_refusal = detail
      nil
    end

    def not_ready(reason, detail = nil)
      @last_refusal = detail
      Atomspace::MirrorReadiness::Result.new(ready: false, reason: reason)
    end

    # The server's error frame, defensively read. An error frame missing its own fields is still an
    # error -- it is never upgraded to a success -- so these two readers return a placeholder
    # rather than raising and losing the refusal.
    def error_kind(frame)
      err = frame["error"]
      err.is_a?(Hash) && Atomspace::I2Envelope.string_present?(err["kind"]) ? err["kind"] : "unspecified"
    end

    def error_reason(frame)
      err = frame["error"]
      err.is_a?(Hash) && Atomspace::I2Envelope.string_present?(err["reason"]) ? err["reason"] : "no reason given"
    end

    def next_id
      return @id_factory.call.to_s if @id_factory

      @counter += 1
      "i3-#{@counter}"
    end
  end
end
