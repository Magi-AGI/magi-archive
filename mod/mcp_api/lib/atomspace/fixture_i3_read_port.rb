# frozen_string_literal: true

require_relative "i3_read_port"
require_relative "i3_read_result"

module Atomspace
  # FIXTURE-ONLY I3 port. A SEPARATE REGRESSION PATH -- never bound in production.
  #
  # Everything it returns is synthetic. It declares `origin == "fixture"`, which
  # Api::Mcp::I3ReadController stamps into `_meta.data_origin` on every response built from it, so a
  # fixture payload is self-identifying at the wire and CANNOT be read as live backend data.
  #
  # It still does NOT invent a digest for an unknown target: unknown card ids raise
  # AddressUnavailable("backend_digest_unavailable"), exactly as an unwired real backend would, so the
  # fixture path cannot paper over the missing upstream resolver (see I3ReadPort header).
  class FixtureI3ReadPort
    ORIGIN = "fixture"

    # A SYNTHETIC envelope, and it is labelled as such by ORIGIN.
    #
    # The fixture path must be able to exercise the real renderer, which requires a contract-shaped
    # envelope. These values are DECLARED FIXTURE DATA, not a stand-in for a store reading: every
    # response built from this port carries `_meta.data_origin == "fixture"`, so a fixture envelope
    # can never be read as a live one. The `read-at` shape matches STORE's `format_instant_ns`
    # (six fractional digits, timezone-bearing) because I2Envelope validates it strictly.
    FIXTURE_ENVELOPE = {
      "outcome" => "ok",
      "epoch" => "fixture-epoch-1",
      "position" => 1,
      "read-at" => "2026-01-01T00:00:00.000000+00:00"
    }.freeze

    FIXTURE_PROFILE = {
      "schema-version" => "decko-atomschema-v2",
      "limits" => {
        "page-max-entries" => 100,
        "page-max-connections" => 100,
        "page-max-bytes" => 1_000_000,
        "per-neighbour-link-max" => 50,
        "refresh-max-participants" => 25,
        "poll-interval-ms" => nil,
        "fanout-limit" => 500,
        "state-retain-ms" => 60_000,
        "state-retain-positions" => 10,
        "label-bearing-properties" => %w[name type-name trash]
      }.freeze
    }.freeze

    def initialize(addresses: {}, open_entries: {}, neighbour_entries: {}, envelope: FIXTURE_ENVELOPE)
      @addresses = addresses
      @open_entries = open_entries
      @neighbour_entries = neighbour_entries
      @envelope = envelope
    end

    def origin
      ORIGIN
    end

    def readiness
      Atomspace::MirrorReadiness::READY
    end

    def resolve_backend_address(card_id:)
      @addresses.fetch(card_id.to_s) do
        raise Atomspace::I3ReadPort::AddressUnavailable, "backend_digest_unavailable"
      end
    end

    def open(card_id:)
      @open_entries.fetch(card_id.to_s, [])
    end

    def neighbours(card_id:, bucket: nil, limit: nil)
      entries = @neighbour_entries.fetch(card_id.to_s, [])
      entries = entries.select { |e| e["bucket"].to_s == bucket.to_s } if bucket
      limit ? entries.first(limit) : entries
    end

    # ---- the envelope-bearing surface the I3 controller uses ---------------------------------
    #
    # Present so the FIXTURE REGRESSION PATH exercises the SAME renderer as the live path. It still
    # does not invent a digest for an unknown target: #lookup_reading raises AddressUnavailable
    # exactly as the real client does, so the fixture cannot paper over the missing upstream
    # resolver.
    def lookup_reading(card_id:)
      Atomspace::I3ReadResult.new(
        envelope: @envelope, address: resolve_backend_address(card_id: card_id)
      )
    end

    def open_reading(card_id:)
      Atomspace::I3ReadResult.new(envelope: @envelope, atoms: open(card_id: card_id))
    end

    def neighbours_reading(card_id:, bucket: nil, limit: nil)
      Atomspace::I3ReadResult.new(
        envelope: @envelope,
        atoms: neighbours(card_id: card_id, bucket: bucket, limit: limit)
      )
    end

    def store_profile
      FIXTURE_PROFILE
    end

    def state_envelope
      @envelope
    end
  end
end
