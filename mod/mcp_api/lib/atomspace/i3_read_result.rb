# frozen_string_literal: true

require_relative "errors"
require_relative "i2_envelope"

module Atomspace
  # THE CARRIER that keeps the ACTUAL VALIDATED STORE ENVELOPE attached to the answer it describes,
  # all the way from Atomspace::I2ReaderProcessClient to Api::Mcp::I3ReadController's renderer.
  #
  # WHY THIS TYPE EXISTS -- the defect it repairs, stated exactly.
  #
  # Before this type, every public read method of I2ReaderProcessClient DISCARDED the envelope it
  # had just validated. `#open` (was :314-319) and `#neighbours` (was :331-351) called
  # `read_participant!`, which returns `[envelope, payload]` after `I2Envelope.split!` ->
  # `I2Envelope.validate!`, then used `envelope` for nothing but a `.nil?` test and returned a BARE
  # `Array<Atom>`. `#resolve_backend_address` likewise returned only `{"key"=>, "digest"=>}`.
  # The real `outcome`, `epoch`, `position` and `read-at` -- the four values STORE sampled and this
  # deck is FORBIDDEN to invent -- went out of scope at the end of each method.
  #
  # The controller therefore had nothing to render them from, and rendered a Rails-shaped
  # `{results:, _meta:}` wrapper instead of the K8 §5.2 envelope. That wrapper is NOT the
  # authoritative client interface: `av-client/src/demo/live-bridge.mjs:762-795` `checkI3Body`
  # requires a TOP-LEVEL `outcome` drawn from the nine, and the PRESENCE of all six of
  # `outcome, epoch, position, read-at, schema-version, limits`. A `{results:, _meta:}` body fails
  # that check on the first assertion.
  #
  # THE FIX IS DIRECTIONAL, and the direction matters: the deck is corrected to emit the contract
  # envelope. The client is NOT relaxed to accept the deck's wrapper. av-client is not modified.
  #
  # WHAT THIS TYPE WILL NEVER DO:
  #
  #   * never synthesise, default or coerce an envelope field -- it holds STORE's own validated
  #     hash BY REFERENCE and exposes it unchanged;
  #   * never replace a real outcome with a success default (the bug class the coordinator named);
  #   * never drop STORE's `omitted` / `cursor-stale` / `counts` metadata -- `payload` is retained
  #     whole so the renderer can forward the real omission report instead of an invented one;
  #   * never carry a VIEW-stamped `read-at` (no clock call exists in this file).
  class I3ReadResult
    class Contract < Atomspace::Error; end

    # @return [Hash] the VALIDATED four-key STORE envelope, verbatim: the exact hash
    #   I2Envelope.validate! returned. nil ONLY on a no-state/unwired reading built by
    #   .no_state, where there is no STORE envelope to carry.
    attr_reader :envelope

    # @return [Hash] STORE's payload for the answering op, whole and unmodified (participant,
    #   buckets, entries, omitted, cursor-stale, counts, ...). Empty hash when there is none.
    attr_reader :payload

    # @return [Array<Atomspace::Atom>, nil] the card-scoped atom list for open/neighbours; nil for
    #   lookup and for readings that carry no atom list at all.
    attr_reader :atoms

    # @return [Hash, nil] STORE's own {"key"=>String, "digest"=>String} for lookup; nil otherwise.
    #   NEVER a deck-computed digest (i3_read_port.rb:20-25 forbids one).
    attr_reader :address

    # @return [String, nil] a no-state reason for the operator. SERVER-SIDE ONLY: the renderer
    #   never puts it on the wire, because a reason string here would distinguish backend
    #   conditions a caller must not be able to tell apart.
    attr_reader :reason

    def initialize(envelope:, payload: {}, atoms: nil, address: nil, reason: nil)
      unless envelope.nil?
        raise Contract, "envelope must be a Hash, got #{envelope.class}" unless envelope.is_a?(Hash)

        # RE-ASSERT the envelope contract at the carrier boundary. The client validates on the way
        # in; this makes it impossible to construct a carrier around an unvalidated hash from some
        # future second call site. validate! returns the same values verbatim -- nothing is coerced.
        Atomspace::I2Envelope.validate!(envelope)
      end
      raise Contract, "payload must be a Hash, got #{payload.class}" unless payload.is_a?(Hash)
      raise Contract, "atoms must be an Array or nil, got #{atoms.class}" unless atoms.nil? || atoms.is_a?(Array)
      raise Contract, "address must be a Hash or nil, got #{address.class}" unless address.nil? || address.is_a?(Hash)

      @envelope = envelope
      @payload = payload
      @atoms = atoms
      @address = address
      @reason = reason
      freeze
    end

    # The outcome STORE actually answered. nil on a no-state reading with no STORE envelope, which
    # the renderer turns into the governing no-state outcome rather than a success default.
    def outcome
      @envelope && @envelope["outcome"]
    end

    # A reading built WITHOUT a STORE envelope: the reader was unwired, unreachable, or refused
    # before any frame arrived.
    #
    # It carries NO envelope at all rather than a fabricated one, so the renderer must supply the
    # governing no-state outcome explicitly and cannot accidentally emit a stateful triple.
    def self.no_state(reason:)
      new(envelope: nil, reason: reason)
    end

    def no_state?
      @envelope.nil? || Atomspace::I2Envelope.not_ready?(@envelope)
    end
  end
end
