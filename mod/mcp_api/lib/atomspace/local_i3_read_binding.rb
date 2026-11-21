# frozen_string_literal: true

require_relative "i3_read_port"
require_relative "errors"

module Atomspace
  # THE LOCAL RUNTIME BINDING for `I3ReadPort`, which until now was bound ONLY inside specs.
  #
  # THE GAP THIS CLOSES, stated precisely. `I3ReadPort` is a port with a `bind!` seam and no
  # production caller: a grep for `I3ReadPort.bind!` outside `spec/` returned nothing, so every
  # deployment answered `503 i3_read_port_unwired` and the surface could not be exercised at all
  # outside a spec process. This file supplies a binding that a LOCAL DEVELOPER RUNTIME can
  # install from configuration.
  #
  # WHAT IT IS NOT, and these are hard boundaries:
  #
  #   * NOT a deployment. Nothing here edits a host, a service, a global config, a container or a
  #     database. `install!` is called by whoever boots a local process and does nothing until
  #     then. There is no initializer, no autoload hook, no `Rails.application.config` mutation.
  #   * NOT a fallback. If the configured backend is absent or unusable, `install!` binds NOTHING
  #     and the port stays unwired -> 503. It NEVER silently installs the fixture: a fixture
  #     binding must be asked for by name, and it stamps `data_origin: "fixture"` on every
  #     response regardless (fixture_i3_read_port.rb:8-10) so it cannot be mistaken for live.
  #   * NOT a digest computer. `resolve_backend_address` returns the STORE's own key and digest
  #     verbatim or raises `AddressUnavailable`. VIEW is forbidden to compute a digest deck-side,
  #     and there is no code path here that could.
  #   * NOT a new wire surface. This binds an EXISTING port consumed by an EXISTING controller.
  #     No route, param, field or endpoint is added (O25 is unauthorized).
  #
  # HOW THE BACKEND IS REACHED. Through an INJECTED callable (`reader`), exactly as the Python
  # side injects its transport. This class constructs no socket, no URL, no host and no
  # credential. The local runtime supplies something that answers the three store read calls; in
  # practice that is an in-process adapter over the STORE's own reader, which is why `origin` is
  # "live" only when the injected reader declares itself live.
  class LocalI3ReadBinding
    # The three calls this binding makes on the injected reader. Named as constants so a reader
    # that is missing one is rejected AT INSTALL TIME with a precise message, rather than
    # NoMethodError-ing mid-request into the controller's generic 500 path.
    REQUIRED_READER_METHODS = %i[open neighbours resolve_backend_address].freeze

    ORIGIN_LIVE = "live"
    ORIGIN_UNKNOWN = "unavailable"

    # @param reader an object answering REQUIRED_READER_METHODS. Injected; never built here.
    # @param origin [String] provenance stamped into every `_meta.data_origin`. Defaults to
    #   "live" ONLY because this class is for a real backend; a reader that is not live must say
    #   so, and `FixtureI3ReadPort` exists for the synthetic case.
    def initialize(reader:, origin: ORIGIN_LIVE)
      missing = REQUIRED_READER_METHODS.reject { |m| reader.respond_to?(m) }
      unless missing.empty?
        raise Atomspace::ServiceUnavailable,
              "the injected I3 reader is missing #{missing.join(', ')}; refusing to bind a " \
              "partial backend (an unbound port answers 503, which is correct; a half-bound " \
              "one would answer 500 mid-request)"
      end

      @reader = reader
      @origin = origin.to_s
    end

    def origin
      @origin.empty? ? ORIGIN_UNKNOWN : @origin
    end

    # Readiness is the READER's to answer, and a reader that cannot answer is NOT READY.
    #
    # A reader with no `readiness` is not assumed ready: it returns a not-ready Result with its
    # own distinct reason, so the controller's 503 names the actual condition. Shape and VALUE
    # type are then re-checked by `I3ReadPort.readiness` itself (i3_read_port.rb:66-73), so a
    # malformed answer cannot green-light the gate here either.
    def readiness
      unless @reader.respond_to?(:readiness)
        return Atomspace::MirrorReadiness::Result.new(
          ready: false, reason: "i3_reader_declares_no_readiness"
        )
      end

      @reader.readiness
    end

    # STORE's own key + digest, verbatim. NEVER computed, NEVER defaulted.
    #
    # A reader that answers nil/blank for an address is reported as `backend_digest_unavailable`
    # -- the SAME reason string the unwired and malformed cases use -- so a caller cannot tell an
    # unresolvable card from an unwired backend, and neither is ever downgraded to `unknown`.
    def resolve_backend_address(card_id:)
      address = @reader.resolve_backend_address(card_id: card_id)
      raise Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable" if address.nil?

      address
    end

    def open(card_id:)
      @reader.open(card_id: card_id)
    end

    def neighbours(card_id:, bucket: nil, limit: nil, after: nil)
      @reader.neighbours(card_id: card_id, bucket: bucket, limit: limit, after: after)
    end

    # ---- ENVELOPE-PRESERVING RELAY -----------------------------------------------------------
    #
    # VERBATIM PASS-THROUGH, exactly like the three above. The reading carries STORE's VALIDATED
    # envelope and this binding neither unwraps it, re-wraps it, nor substitutes anything: an
    # Atomspace::I3ReadResult goes in and the SAME object comes out. There is no `||`, no default
    # and no rescue-to-success anywhere on these paths.
    #
    # A READER THAT CANNOT CARRY AN ENVELOPE IS REFUSED, NOT COMPENSATED FOR. These methods are
    # DEFINED here (so I3ReadPort's `respond_to?` gate sees the binding's surface as complete) and
    # each one re-checks the WRAPPED reader before delegating. A reader lacking the method raises
    # the port's own `i3_read_port_envelope_unsupported` NotWired -- the controller's existing 503
    # path -- because the only alternatives would be to fall back to the bare atom form and
    # synthesise a state triple, or to answer a success default. Both are forbidden.
    ENVELOPE_READING_METHODS = %i[lookup_reading open_reading neighbours_reading].freeze

    def lookup_reading(card_id:)
      require_reader_method!(:lookup_reading)
      @reader.lookup_reading(card_id: card_id)
    end

    def open_reading(card_id:)
      require_reader_method!(:open_reading)
      @reader.open_reading(card_id: card_id)
    end

    # `after` relayed VERBATIM; this binding constructs no cursor and inspects none.
    def neighbours_reading(card_id:, bucket: nil, limit: nil, after: nil)
      require_reader_method!(:neighbours_reading)
      @reader.neighbours_reading(card_id: card_id, bucket: bucket, limit: limit, after: after)
    end

    # STORE's own schema-version + limits, verbatim. nil is relayed AS nil -- an honest absence,
    # never an empty-but-present limits block.
    def store_profile
      return nil unless @reader.respond_to?(:store_profile)

      @reader.store_profile
    end

    # STORE's published-state envelope, verbatim. nil relayed AS nil.
    def state_envelope
      return nil unless @reader.respond_to?(:state_envelope)

      @reader.state_envelope
    end

    # STORE's OWN I2-07 declarations, envelope AND payload, verbatim, for the unresolved-target
    # rule (N04).
    #
    # Relayed rather than interpreted: the projection needs to know which heads STORE DECLARED as
    # unresolved-target constructors, and this deck must not write that list down itself. A reader
    # without the method, or a failing read, answers nil -- and nil yields an EMPTY declared set
    # upstream, which is the fail-closed direction (every non-Card position stays denied).
    #
    # THE ENVELOPE TRAVELS WITH THE HEADS because these declarations AUTHORIZE: the consumer must
    # be able to require that they describe the SAME store state as the reading being projected.
    # @return [Array(Hash, Hash), nil] [envelope, payload], or nil.
    def declarations
      return nil unless @reader.respond_to?(:declarations!)

      @reader.declarations!
    rescue StandardError
      nil
    end

    private

    def require_reader_method!(name)
      return if @reader.respond_to?(name)

      raise Atomspace::I3ReadPort::NotWired, Atomspace::I3ReadPort::ENVELOPE_SURFACE_REASON
    end

    public

    # ---- the local install seam -----------------------------------------------------------
    #
    # EXPLICIT, LOCAL-ONLY, AND IT FAILS CLOSED. Call it from a local runtime's own boot code.
    # It is NOT wired into any initializer: nothing installs itself.
    class << self
      # @param reader the injected backend reader, or nil.
      # @return [Boolean] true when a binding was installed; false when the port was LEFT
      #   UNWIRED (which answers 503 -- the correct behaviour for a missing backend).
      #
      # A NIL READER RESETS THE PORT (round-23 finding 4). Returning false while leaving a
      # PREVIOUSLY bound reader in place was a stale-binding bug: install!(reader: a_reader)
      # followed by install!(reader: nil) reported failure, yet the OLD reader stayed bound and
      # kept serving reads. The documented contract for a missing backend is "unwired -> 503", so
      # the port is reset BEFORE the false is returned. Reset is unconditional and idempotent:
      # resetting an already-unwired port is a no-op, so the nil path always lands on the one
      # documented state rather than on whatever happened to be bound before.
      def install!(reader:, origin: ORIGIN_LIVE)
        if reader.nil?
          Atomspace::I3ReadPort.reset!
          return false
        end

        Atomspace::I3ReadPort.bind!(new(reader: reader, origin: origin))
        true
      rescue Atomspace::ServiceUnavailable
        # A partial/unusable reader leaves the port UNWIRED rather than half-bound. Re-raised to
        # the local operator who called install!, because a local runtime that asked for a
        # binding and did not get one must know; the PORT, meanwhile, is untouched.
        Atomspace::I3ReadPort.reset!
        raise
      end

      # Undo an install. Returns the port to its fail-closed default.
      def uninstall!
        Atomspace::I3ReadPort.reset!
      end
    end
  end
end
