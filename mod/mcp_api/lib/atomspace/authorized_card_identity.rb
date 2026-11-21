# frozen_string_literal: true

require_relative "errors"

module Atomspace
  # The (card_id, canonical_name) pair the Python resolver's `AuthorizedCard` requires.
  #
  # WHY THIS TYPE EXISTS AT ALL. VIEW's Python half
  # (`av-view/experiments/lane-d-adapter/name_resolver.py:250-272`) will not accept a bare card id
  # as proof of an ACL check: it needs the id AND the name the FRAMEWORK resolved, and it
  # HARD-REJECTS anything else. The deck already computes both -- `Card.fetch(name)` yields a card
  # whose `#id` and `#name` are both in scope -- and the existing
  # `I3ReadController#readable_card_id_for_name` discarded the name.
  #
  # THE CANONICAL NAME IS NOT THE REQUESTED NAME, and that distinction is this type's whole
  # purpose. `Cardname#simple_key` (cardname.rb:101-116) underscores and collapses every run of
  # non-key characters, so "mcp_admin", "mcp-admin", "MCP Admin" and "mcp--admin" are ONE card.
  # `Card.fetch` additionally resolves aliases and renames. So the string a caller asked with and
  # the name of the card they actually got can differ, and only the latter is a statement about
  # which card was authorized.
  #
  # IT IS CONSEQUENTLY NEVER BUILT FROM A REQUEST STRING. `from_card` reads `card.name` off the
  # fetched card and nothing else; there is no constructor that takes a requested name, and no
  # flag that substitutes one. Python refuses an echoed name as a fabricated authorization claim
  # (`decko_bridge.py:190-239`), so a deck that echoed it would simply be refused at the boundary
  # -- but the point is that the deck must not try.
  class AuthorizedCardIdentity
    # Raised when a card is authorized but one of the two required fields is unusable. This is a
    # FRAMEWORK CONTRACT VIOLATION (a card with no id, or a blank name), not a permission answer,
    # so it must never be collapsed into "not readable".
    class Incomplete < Atomspace::Error; end

    attr_reader :card_id, :canonical_name

    def initialize(card_id:, canonical_name:)
      unless card_id.is_a?(Integer) && !card_id.is_a?(TrueClass) && !card_id.is_a?(FalseClass)
        raise Incomplete, "card_id must be Decko's persisted Integer id, got #{card_id.class}"
      end
      # A negative or zero id is not a persisted row. Decko ids are positive.
      raise Incomplete, "card_id must be a positive persisted id, got #{card_id}" unless card_id.positive?
      raise Incomplete, "canonical_name must be a String, got #{canonical_name.class}" unless canonical_name.is_a?(String)
      raise Incomplete, "canonical_name must be non-blank" if canonical_name.strip.empty?

      @card_id = card_id
      @canonical_name = canonical_name.freeze
      freeze
    end

    # Build from a FETCHED CARD. The only supported construction path.
    #
    # `card.name` is read through `#to_s` because Decko's `#name` is a `Cardname`, not a String,
    # and the Python side requires string text. `#to_s` is Cardname's own rendering of ITSELF --
    # it is not a VIEW-side re-derivation, no separator or case is altered here, and no
    # normalisation is applied (STORE declares none, so VIEW introduces none).
    def self.from_card(card)
      raise Incomplete, "no card" if card.nil?

      new(card_id: card.id, canonical_name: card.name.to_s)
    end

    # The payload the Python bridge consumes. The field names are
    # `decko_bridge.CARD_ID_FIELDS[0]` and `decko_bridge.CANONICAL_NAME_FIELDS[0]`.
    #
    # NOTE WHAT IS ABSENT: no "name" key. `decko_bridge.ECHOED_REQUEST_NAME_FIELDS` enumerates
    # "name"/"requested_name"/"query" precisely so they are IGNORED, and the deployed I3 `lookup`
    # renders the request string under exactly that key. Emitting one here would be harmless (the
    # bridge ignores it) but would invite the next reader to treat it as canonical, so it is not
    # emitted at all.
    def to_authorization_payload
      { "card_id" => card_id, "canonical_name" => canonical_name }
    end
  end
end
