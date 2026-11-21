# frozen_string_literal: true

require_relative "errors"
require_relative "mirror_readiness"

module Atomspace
  # SEAM to the STORE's I2 read slice, consumed by VIEW's I3 surface
  # (Api::Mcp::I3ReadController). This file is a PORT, not an implementation: nothing here talks to a
  # backend, and with no implementation bound every call FAILS CLOSED.
  #
  # WHY A SEAM AND NOT A REAL CLIENT (read this before "finishing" it):
  #
  #   * The STORE's card-scoped read ops are NUMERIC-KEY-ADDRESSED. A participant address is
  #     `{"key" => <text>}` or `{"digest" => <hex>}` (av-store-sidecar/.../i2_read.py:474-482).
  #     There is NO name->key and NO decko-card-id->key resolver anywhere in the store: a grep for
  #     resolve_name / name_to_card / lookup_name / by_name across i2_read.py, record_store.py,
  #     reads.py and ipc.py returns ZERO hits. So the mapping this port needs DOES NOT EXIST
  #     UPSTREAM YET. #resolve_backend_address is therefore an UNFILLED BACKEND REQUEST, declared
  #     as such, rather than a locally-invented mapping.
  #
  #   * The digest is the STORE's, computed over its COMPLETE key index before participant
  #     eligibility (i2_read.py:51, :333-:420 `keys_by_digest` / `digest_fn`). VIEW is FORBIDDEN to
  #     compute a digest deck-side: a deck-side digest is a DIFFERENT VALUE from the store's and
  #     would silently disagree with every other endpoint. #digest_for consequently has no local
  #     fallback -- unwired means `backend_digest_unavailable`, never a computed stand-in.
  #
  #   * The health slice is O23-gated upstream and deliberately absent ("Absent, not fabricated:
  #     health (O23 gated)" -- i2_read.py:60). There is no #health here AT ALL, so no handler can
  #     accidentally answer one.
  #
  # FAIL CLOSED: `readiness` defaults to not-ready `i3_read_port_unwired`, and every read raises
  # NotWired when no implementation is bound. Readiness reuses Atomspace::MirrorReadiness::Result
  # (the existing Result struct -- deliberately NOT a forked readiness type) so the controller's
  # 503 contract is shape-identical to the mirror surface's: ONE distinct reason string per failure.
  module I3ReadPort
    # Distinct from ServiceUnavailable so the controller can map an UNWIRED port (a deployment
    # gap) separately from a bound-but-unreachable backend (an outage).
    class NotWired < Atomspace::Error; end

    # Raised by an implementation when the backend cannot address the requested target. Carries a
    # reason string the controller surfaces verbatim as the refusal reason.
    class AddressUnavailable < Atomspace::Error; end

    UNWIRED_REASON = "i3_read_port_unwired"

    # A bound implementation that cannot answer with an envelope-bearing reading. DISTINCT from
    # UNWIRED_REASON because the conditions differ operationally: unwired is "no backend
    # configured", this is "a backend is configured but cannot carry STORE's envelope", which is a
    # version/deployment mismatch. One reason string per failure, per this file's header.
    #
    # DEFINED AT MODULE SCOPE, not inside `class << self`: a constant declared in the singleton
    # class would not be reachable as `Atomspace::I3ReadPort::ENVELOPE_SURFACE_REASON`, which is how
    # LocalI3ReadBinding refers to it.
    ENVELOPE_SURFACE_REASON = "i3_read_port_envelope_unsupported"

    class << self
      # Test/dev seam. Production binds a real client or stays unbound (-> fail closed).
      def bind!(impl)
        @impl = impl
      end

      def reset!
        @impl = nil
      end

      def impl
        @impl
      end

      # @return [Atomspace::MirrorReadiness::Result] reusing the mirror's Result struct.
      def readiness
        return not_ready(UNWIRED_REASON) unless @impl

        result = @impl.readiness
        # A malformed implementation answer is NOT a green light.
        return not_ready("i3_readiness_contract_violation") unless result.respond_to?(:ready?)

        # SHAPE IS NOT ENOUGH -- the VALUE's type matters too. MirrorReadiness::Result#ready?
        # (mirror_readiness.rb:33-35) returns the struct member UNCOERCED, so `ready: "false"` or
        # `ready: 0` answers a respond_to? check happily and is TRUTHY in Ruby. A non-boolean
        # readiness verdict is a contract violation, not a green light.
        answer = result.ready?
        return not_ready("i3_readiness_contract_violation") unless [true, false].include?(answer)

        result
      rescue StandardError => e
        # Mirrors MirrorReadiness' blanket rescue: never a false green, one reason per class.
        not_ready("i3_readiness_probe_error:#{e.class}")
      end

      # Provenance of the payload, stamped into every success _meta so a FIXTURE answer can never be
      # read as live. Unbound/unknown implementations are reported as "unavailable", never "live".
      def origin
        return "unavailable" unless @impl
        return "unavailable" unless @impl.respond_to?(:origin)

        @impl.origin.to_s
      end

      # UNFILLED BACKEND REQUEST (see header): decko card id -> store participant address.
      # @return [Hash] {"key" => String, "digest" => String} -- the digest is the STORE's own.
      def resolve_backend_address(card_id:)
        require_impl!
        @impl.resolve_backend_address(card_id: card_id)
      end

      def open(card_id:)
        require_impl!
        @impl.open(card_id: card_id)
      end

      def neighbours(card_id:, bucket: nil, limit: nil, after: nil)
        require_impl!
        @impl.neighbours(card_id: card_id, bucket: bucket, limit: limit, after: after)
      end

      # ---- THE ENVELOPE-PRESERVING SURFACE (what the I3 controller actually calls) -------------
      #
      # The three methods above answer with BARE atoms / a bare address and therefore cannot carry
      # STORE's own `outcome`, `epoch`, `position` and `read-at`. K8 §5.2 requires all four on
      # every I3 response and this deck is forbidden to invent any of them, so the controller reads
      # through the `*_reading` forms, which answer with an Atomspace::I3ReadResult holding the
      # VALIDATED STORE envelope by reference.
      #
      # FAIL CLOSED ON AN IMPLEMENTATION THAT CANNOT CARRY AN ENVELOPE. A bound implementation
      # without these methods is a CONTRACT GAP, not something to paper over by falling back to the
      # bare form and synthesising a triple. It raises NotWired with its own distinct reason, so the
      # controller's existing 503 path reports it as the deployment gap it is.
      # (ENVELOPE_SURFACE_REASON is declared at module scope above.)

      def lookup_reading(card_id:)
        require_envelope_impl!(:lookup_reading)
        @impl.lookup_reading(card_id: card_id)
      end

      def open_reading(card_id:)
        require_envelope_impl!(:open_reading)
        @impl.open_reading(card_id: card_id)
      end

      # `after` is I3-03's governing continuation input (`k8-draft-2.md:567`), relayed VERBATIM to
      # the implementation. The port constructs nothing: a cursor reaching here is one STORE issued
      # and the controller already authorized, and it is passed through unmodified.
      def neighbours_reading(card_id:, bucket: nil, limit: nil, after: nil)
        require_envelope_impl!(:neighbours_reading)
        @impl.neighbours_reading(card_id: card_id, bucket: bucket, limit: limit, after: after)
      end

      # STORE's own `schema-version` + `limits`, or nil when they cannot be obtained.
      #
      # nil is a HONEST ABSENCE, rendered as two present-but-null envelope fields. It is NOT an
      # error: the client checks PRESENCE of these keys (live-bridge.mjs:777), and a null is a
      # truthful "the store did not report its ceilings on this request".
      def store_profile
        require_impl!
        return nil unless @impl.respond_to?(:store_profile)

        @impl.store_profile
      end

      # STORE's current published-state envelope, read WITHOUT any card-scoped read.
      #
      # Used by the answers that deliberately never touch the backend for the subject card -- the
      # lookup miss and the ACL-empty result -- which still owe the caller a real state triple.
      # The epoch/position/read-at of the published state are identical for every caller, so
      # reporting them discloses nothing about the requested card.
      #
      # @return [Hash, nil] a VALIDATED four-key STORE envelope, or nil when none can be read.
      def state_envelope
        require_impl!
        return nil unless @impl.respond_to?(:state_envelope)

        @impl.state_envelope
      end

      private

      def require_impl!
        raise NotWired, UNWIRED_REASON unless @impl
      end

      # An implementation that cannot answer with an envelope-bearing reading is refused with its
      # OWN distinct reason, per this file's one-reason-per-failure discipline. No fallback to the
      # bare form: that would mean rendering an envelope whose state triple had to be invented.
      def require_envelope_impl!(method_name)
        require_impl!
        raise NotWired, ENVELOPE_SURFACE_REASON unless @impl.respond_to?(method_name)
      end

      def not_ready(reason)
        Atomspace::MirrorReadiness::Result.new(ready: false, reason: reason)
      end
    end
  end
end
