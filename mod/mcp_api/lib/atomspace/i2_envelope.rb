# frozen_string_literal: true

require_relative "errors"

module Atomspace
  # STRICT VALIDATION of STORE's I2 response envelope. This file is the FAIL-CLOSED GATE that every
  # frame from the reader process must pass before any value in it reaches the I3 surface.
  #
  # WHY IT IS A SEPARATE FILE AND NOT AN `if` INSIDE THE CLIENT. The central requirement of a live
  # reader is that a MISSING OR MALFORMED METADATUM IS A REFUSAL, never a default. That is one rule
  # applied to four fields in five outcome shapes, and it is the rule most likely to be quietly
  # relaxed later by someone adding a `|| Time.now` or a `.to_i`. Isolating it means the rule has
  # exactly one implementation, it is unit-testable without a transport, and a grep for the
  # forbidden constructs in THIS file is a meaningful audit.
  #
  # THE ENVELOPE, from STORE's own source (not from a summary):
  #
  #   * `i2_read.py:515-518` `_envelope` -> {"outcome", "epoch", "position", "read-at"} and nothing
  #     else; every answering operation spreads exactly that.
  #   * `record_store.py:196-201` `no_state_envelope` -> on "not ready" (and "unavailable")
  #     `epoch`, `position` and `read-at` are ALL PRESENT and EXACTLY None. Its own docstring:
  #     "A known epoch is never reported."
  #   * `record_store.py:126` NOT_READY = "not ready"; `:133` SCHEMA_VERSION = "decko-atomschema-v2".
  #   * outcomes this slice emits: "ok" | "ok, partial" | "unknown" | "reload" | "not ready"
  #     (STORE handoff 022b §1).
  #   * `read-at` is `record_store.py:157-165` `format_instant_ns` ->
  #     `datetime.isoformat(timespec="microseconds")` on a tz-aware instant, i.e. ISO-8601 with a
  #     timezone and EXACTLY six fractional digits. STORE-SAMPLED: VIEW never stamps it.
  #
  # WHAT THIS MODULE WILL NEVER DO, and each of these is the defect it exists to prevent:
  #
  #   * never supply a default for a missing field (no `||`, no `fetch(k, fallback)`);
  #   * never coerce a wrong-typed field (no `.to_i`, no `.to_s`, no `Integer()` rescue);
  #   * never stamp a `read-at` of its own (no Time/DateTime/clock call anywhere in this file);
  #   * never mint or derive an `epoch`;
  #   * never accept a partially-null no-state envelope (a "not ready" carrying a real epoch is a
  #     CONTRACT VIOLATION, because that would leak a known epoch the store refuses to report);
  #   * never accept a real-state envelope carrying a null (that is the inverse violation).
  module I2Envelope
    # Raised when a frame's envelope is absent, incomplete or malformed. Distinct from
    # Atomspace::ServiceUnavailable so the client can map it to its OWN reason string rather than
    # letting it reach the controller as a generic backend outage.
    class ContractViolation < Atomspace::Error
      # @return [String] a short, STABLE token naming which rule failed. Operator-facing only: the
      #   client collapses every one of these into its own small set of wire reasons.
      attr_reader :rule

      def initialize(rule, detail = nil)
        @rule = rule
        super(detail ? "#{rule}: #{detail}" : rule)
      end
    end

    # STORE's five emitted outcomes (handoff 022b §1). An outcome outside this set is a violation,
    # NOT an unknown-but-tolerable value: tolerating one would mean acting on a state whose
    # meaning VIEW does not know.
    NOT_READY = "not ready"
    OUTCOMES = ["ok", "ok, partial", "unknown", "reload", NOT_READY].freeze

    # The outcomes that carry a real published state, and therefore REQUIRE all three metadata.
    STATEFUL_OUTCOMES = ["ok", "ok, partial", "unknown", "reload"].freeze

    # STORE's schema constant (record_store.py:133). A frame claiming another schema is refused:
    # the atom vocabulary VIEW maps is cp022 v2's, so a different schema is a different corpus.
    SCHEMA_VERSION = "decko-atomschema-v2"

    # ISO-8601, timezone-bearing, EXACTLY six fractional digits -- the shape
    # `format_instant_ns` produces and the only shape accepted. `Z` is accepted alongside the
    # `+00:00` Python's `isoformat` actually emits, because both are the same instant and STORE
    # may legitimately switch formatter; a MISSING offset is refused, since a naive timestamp is
    # not an instant.
    #
    # THE PATTERN IS A SHAPE CHECK ONLY, NOT A VALIDITY CHECK. `\d{2}` matches `99`, so this regex
    # alone admits `2026-99-99T99:99:99.123456+99:99` -- a string that looks like an instant and
    # denotes none. Shape is therefore necessary but NOT sufficient: `read_at_instant!` parses the
    # matched text into a real instant and refuses what cannot exist. Both gates run.
    READ_AT_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|[+-]\d{2}:\d{2})\z/

    # The same shape, CAPTURING, so `read_at_instant!` can range-check each component without a
    # second parse. Kept beside the pattern above so the two cannot drift.
    READ_AT_COMPONENTS =
      /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})(Z|[+-]\d{2}:\d{2})\z/

    # The four envelope keys. Named so a spec can assert the set, and so a frame carrying a FIFTH
    # envelope key is refused rather than silently ignored -- an unexpected envelope field means
    # VIEW and STORE disagree about the contract, which is exactly when guessing is worst.
    KEYS = %w[outcome epoch position read-at].freeze

    class << self
      # Validate one envelope hash and return it FROZEN and UNCHANGED on success.
      #
      # @param envelope [Object] whatever came off the wire -- deliberately typed as Object,
      #   because "it was not even a Hash" is one of the cases that must fail closed.
      # @return [Hash] the same values, verbatim. NOTHING is added, removed or coerced.
      # @raise [ContractViolation] with a `rule` naming the first failed rule.
      def validate!(envelope)
        raise ContractViolation.new("envelope_not_a_mapping", envelope.class.name) unless envelope.is_a?(Hash)

        extra = envelope.keys.map(&:to_s) - KEYS
        raise ContractViolation.new("envelope_unexpected_keys", extra.sort.join(",")) unless extra.empty?

        missing = KEYS.reject { |k| envelope.key?(k) }
        raise ContractViolation.new("envelope_missing_keys", missing.join(",")) unless missing.empty?

        outcome = envelope["outcome"]
        unless OUTCOMES.include?(outcome)
          raise ContractViolation.new("envelope_outcome_unknown", outcome.inspect)
        end

        outcome == NOT_READY ? validate_no_state!(envelope) : validate_stateful!(envelope)

        envelope
      end

      # True only for an envelope that has ALREADY passed validate!. Kept as a predicate so call
      # sites read as a question rather than a string comparison on a raw hash.
      def not_ready?(envelope)
        envelope["outcome"] == NOT_READY
      end

      # Extract a validated envelope + payload split from a whole response frame.
      #
      # The wire frame is `{"v", "id", "ok", "envelope", "payload"}` (see I2StdioTransport's
      # contract). The split is the SERVER's, not VIEW's: VIEW does not pick the envelope fields
      # out of a flat payload, because doing so would require VIEW to know which keys are
      # envelope keys for an operation it may not have seen before.
      #
      # @return [Array(Hash, Hash)] [validated envelope, payload]
      def split!(frame)
        raise ContractViolation.new("frame_not_a_mapping", frame.class.name) unless frame.is_a?(Hash)

        envelope = validate!(frame["envelope"])

        payload = frame["payload"]
        # An ABSENT payload key is refused rather than treated as {}. A reader that answered an
        # operation but emitted no payload slot is malformed, and {} would read downstream as a
        # legitimately empty answer.
        raise ContractViolation.new("frame_payload_missing") unless frame.key?("payload")
        raise ContractViolation.new("frame_payload_not_a_mapping", payload.class.name) unless payload.is_a?(Hash)

        [envelope, payload]
      end

      # STORE's own key and digest for a participant, verbatim, or a refusal.
      #
      # THE CENTRAL NON-FABRICATION RULE. `i2_read.py:554-557` `_participant` emits
      # {"key", "digest", "class", ...} where the digest is `index.digest_fn(key)` -- the STORE's
      # own `record_digest` (record_store.py:145-154, first 32 hex of SHA-256 over the key's UTF-8
      # bytes). VIEW is FORBIDDEN to compute that value (i3_read_port.rb:20-25), so a payload that
      # omits either half is a REFUSAL and never an invitation to derive the missing one.
      #
      # There is deliberately NO digest arithmetic in this file. A grep of this module for
      # Digest/SHA/hexdigest returns nothing, and a spec asserts that.
      #
      # @return [Array(String, String)] [key, digest] exactly as STORE sent them.
      def participant_address!(payload)
        participant = payload["participant"]
        unless participant.is_a?(Hash)
          raise ContractViolation.new("participant_not_a_mapping", participant.class.name)
        end

        key = participant["key"]
        digest = participant["digest"]
        # STRING-TYPED and NON-EMPTY, both. The controller re-checks this (i3_read_controller.rb
        # :334-345) and a failure there renders the same 503; checking here as well means the
        # client never HOLDS a half-address, so there is no window in which one could be logged,
        # cached or completed.
        unless string_present?(key) && string_present?(digest)
          raise ContractViolation.new("participant_address_incomplete")
        end

        [key, digest]
      end

      # A non-empty, exactly-String value. `blank?` is deliberately not used: it is ActiveSupport,
      # which this file must load without (the proofs run with no Rails), and it would accept 0.
      def string_present?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      private

      # "not ready" => NO state exists, so all three metadata are EXACTLY nil. A "not ready"
      # carrying a real epoch/position/read-at is refused: `no_state_envelope`'s own contract is
      # that a known epoch is never reported, so such a frame did not come from that function and
      # VIEW cannot tell what it means.
      def validate_no_state!(envelope)
        offenders = %w[epoch position read-at].reject { |k| envelope[k].nil? }
        return if offenders.empty?

        raise ContractViolation.new("not_ready_envelope_carries_state", offenders.join(","))
      end

      # Any state-bearing outcome => all three metadata PRESENT, CORRECTLY TYPED and PLAUSIBLE.
      def validate_stateful!(envelope)
        epoch = envelope["epoch"]
        unless string_present?(epoch)
          raise ContractViolation.new("epoch_missing_or_malformed", epoch.inspect)
        end

        position = envelope["position"]
        # EXACTLY an Integer, and >= 1. STORE: "position = an int from 1" (handoff 022b §1).
        # `true` is rejected because Ruby's TrueClass is not Integer -- stated so the intent is
        # explicit rather than incidental. A Float (1.0) is also refused: JSON cannot tell a
        # truncated float from an int, and a position is a discrete counter.
        unless position.is_a?(Integer) && !position.is_a?(TrueClass) && position >= 1
          raise ContractViolation.new("position_missing_or_malformed", position.inspect)
        end

        read_at = envelope["read-at"]
        unless read_at.is_a?(String) && READ_AT_PATTERN.match?(read_at)
          raise ContractViolation.new("read_at_missing_or_malformed", read_at.inspect)
        end

        # AND IT MUST DENOTE A REAL INSTANT. The pattern above is lexical; this parses. An
        # impossible month, day, hour, minute, second or UTC offset is refused with the SAME
        # fail-closed reason, because a `read-at` that cannot exist is not a weaker timestamp --
        # it is a malformed one, and acting on it would mean VIEW accepted a provenance stamp it
        # cannot place in time.
        read_at_instant!(read_at)
      end

      # Parse a shape-valid `read-at` into its components and verify it denotes a REAL instant,
      # or refuse.
      #
      # `Date.valid_date?` does the calendar arithmetic a regex cannot: it knows February has 28
      # days in 2026 and 29 in 2024, and that month 13 and day 0 do not exist. The remaining
      # components are range-checked explicitly.
      #
      # IT IS A VALIDATION, NOT A CLOCK READ AND NOT A REWRITE. No current time is consulted
      # (`Date.valid_date?` takes only the supplied numbers), nothing is stamped, and no parsed
      # object is returned or stored -- the envelope's own `read-at` STRING continues downstream
      # verbatim. `Time.new`/`DateTime` are deliberately NOT used: `Time.new(2026,2,30)` silently
      # ROLLS OVER to March 2nd rather than refusing, which would have let an impossible date pass
      # while looking validated. Verified on this host.
      #
      # `Integer(str, 10)` NOT `.to_i`: this file forbids coercion, and a strict base-10 parse of
      # digits the regex already matched is a range read, not a silent conversion of a
      # wrong-typed field.
      #
      # THE ACCEPTED SET IS THE PRODUCING FORMATTER'S RANGE, NOT ISO-8601'S OUTER EDGE. STORE's
      # `format_instant_ns` (record_store.py:157-165) is `datetime.isoformat` on a tz-aware
      # `datetime`, so the values it can emit are exactly Python's `datetime` domain: seconds 0-59
      # and a `timezone` offset strictly inside +/-24h. Two values this gate once tolerated are
      # therefore outside it:
      #
      #   * SECOND 60. A leap second was previously allowed on the grounds that UTC emits one.
      #     Python's `datetime` cannot REPRESENT :60 (`datetime(..., second=60)` raises
      #     ValueError), so no `isoformat` call ever produces it and no STORE sample can carry it.
      #     Accepting it widened the accepted set to a string no instant of ours denotes.
      #   * OFFSET +24:00 / -24:00. Previously allowed when the minutes were zero. `timezone`
      #     refuses a 24h offset (strictly less than one day is required), so again STORE cannot
      #     emit it, and "+24:00" names a wall-clock a full day from UTC that no zone keeps.
      #
      # So seconds are 0-59 and offset hours are 0-23 with minutes 0-59. The real-world maximum
      # offset in use (+14:00, Kiritimati) is comfortably inside that and still PASSES -- the
      # narrowing refuses impossible values, not remote ones. No timezone DATABASE is consulted:
      # this is arithmetic on the supplied digits, so there is no tzdata dependency and no
      # vulnerability to a zone whose rules changed.
      def read_at_instant!(read_at)
        require "date"

        parts = READ_AT_COMPONENTS.match(read_at)
        refuse_read_at!(read_at) unless parts

        year = Integer(parts[1], 10)
        month = Integer(parts[2], 10)
        day = Integer(parts[3], 10)
        hour = Integer(parts[4], 10)
        minute = Integer(parts[5], 10)
        second = Integer(parts[6], 10)

        # `::Date::GREGORIAN` pins the PROLEPTIC GREGORIAN calendar. Ruby's `Date` defaults to
        # Date::ITALY, which applies the 1582 Julian->Gregorian reform and so reports the ten
        # skipped days (1582-10-05..14) as INVALID -- while ISO-8601, which is what `read-at` is,
        # defines them proleptically and permits them. Verified on this host (Ruby 3.4.7):
        # `Date.valid_date?(1582,10,10)` => false but
        # `Date.valid_date?(1582,10,10, Date::GREGORIAN)` => true, and the argument is accepted
        # (arity -1). The leap arithmetic that matters here is unaffected: under GREGORIAN,
        # 2024-02-29 is still true, 2026-02-30 still false, and 1900-02-29 still false.
        refuse_read_at!(read_at) unless ::Date.valid_date?(year, month, day, ::Date::GREGORIAN)
        refuse_read_at!(read_at) unless hour.between?(0, 23)
        refuse_read_at!(read_at) unless minute.between?(0, 59)
        # 0-59, NOT 0-60: see the note above -- the formatter cannot emit a 60th second.
        refuse_read_at!(read_at) unless second.between?(0, 59)

        offset = parts[8]
        unless offset == "Z"
          offset_hours = Integer(offset[1, 2], 10)
          offset_minutes = Integer(offset[4, 2], 10)
          # Hours 0-23 and minutes 0-59: a whole-day offset (+/-24:00) is NOT a real instant's
          # offset and is not a value `datetime.isoformat` can produce. +14:00 still passes.
          unless offset_hours.between?(0, 23) && offset_minutes.between?(0, 59)
            refuse_read_at!(read_at)
          end
        end

        read_at
      rescue ArgumentError, TypeError
        refuse_read_at!(read_at)
      end

      def refuse_read_at!(read_at)
        raise ContractViolation.new("read_at_missing_or_malformed", read_at.inspect)
      end
    end
  end
end
