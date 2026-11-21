# frozen_string_literal: true

require_relative "errors"
require_relative "authorized_card_identity"

module Atomspace
  # VIEW's CALLER-SCOPED CARD AUTHORIZATION BOUNDARY, extracted so it has exactly ONE
  # implementation and both consumers share it.
  #
  # WHAT THIS IS FOR. Two things need the same two primitives:
  #   * `Api::Mcp::I3ReadController` (name -> card id; card id -> readable?), which had them as
  #     PRIVATE CONTROLLER METHODS and therefore unreachable from anywhere else; and
  #   * the Ruby -> Python authorization bridge, which needs the SAME decisions plus the
  #     canonical name the controller discarded.
  # Two copies of an ACL check is how the two drift apart, so there is one module and the
  # controller delegates to it.
  #
  # THE INVARIANTS, every one inherited from the controller rather than re-decided here:
  #
  #   1. EVERY card touch runs under `Card::Auth.as(account.name)` -- the CALLER's identity.
  #   2. NO `Card::Auth.as_bot` ANYWHERE. A bot-scoped lookup inside a user request bypasses the
  #      caller's ACLs; the controller's own read path has zero such calls and this module
  #      introduces none.
  #   3. DEFAULT-DENY BEFORE asking `ok?(:read)`, via `AtomspaceReadFilter#readable_card?`
  #      (atomspace_read_filter.rb:26-30): nil / new / blank-read-rule cards are denied rather
  #      than asked, because asking would re-resolve the rule in a cache state that can yield the
  #      OPEN default.
  #   4. ABSENT AND UNREADABLE COLLAPSE. Both answer "no", indistinguishably. A distinguishable
  #      "you may not read card N" confirms card N exists and turns the surface into an
  #      existence/permission oracle (i3_read_controller.rb:217-223).
  #   5. A FRAMEWORK FAILURE IS NOT A DENIAL. See `readable_identity_for_name`: a card that is
  #      authorized but cannot produce its own id/name raises rather than answering "no".
  #
  # WHY IT IS NOT A CONCERN. `AtomspaceReadFilter` is an `ActiveSupport::Concern` mixed into
  # controllers, and its `readable_card?` is private. This module takes the readable-predicate as
  # an INJECTED callable so it can be driven by a plain lambda in a spec with no Rails, no Decko
  # and no DB, while production passes the concern's own method. That is the only reason the
  # predicate is a parameter -- it is NOT a seam for relaxing the check, and there is no default:
  # a caller that supplies none gets an ArgumentError, never an open answer.
  module CallerScopedCardAuthorization
    # Raised when the ACCOUNT is unusable (nil, or with no name to run `Card::Auth.as` under).
    # Distinct from a denial: nothing was asked, so nothing was answered about readability.
    class PrincipalUnusable < Atomspace::Error; end

    class << self
      # name -> AuthorizedCardIdentity | nil, under the CALLER's identity.
      #
      # @param name [String] the REQUESTED name. Used ONLY as the `Card.fetch` argument; never
      #   returned, never read as the canonical name.
      # @param account the caller's account card (must respond to #name).
      # @param readable [#call] the default-deny read predicate, card -> Boolean.
      # @return [AuthorizedCardIdentity, nil] nil when the card is ABSENT OR NOT READABLE,
      #   indistinguishably.
      # @raise [AuthorizedCardIdentity::Incomplete] when an AUTHORIZED card cannot supply its own
      #   id or name. This is a framework contract violation and is deliberately NOT collapsed to
      #   nil: nil means "absent or unreadable", and a card that passed the read check is
      #   demonstrably neither.
      def readable_identity_for_name(name, account:, readable:)
        require_account!(account)
        require_readable!(readable)
        # A blank name is not askable. Returning nil would state "absent or unreadable", which is
        # a claim about a card; nothing was looked up, so no such claim is made.
        raise Atomspace::InvalidRequest, "name_required" if name.to_s.strip.empty?

        Card::Auth.as(account.name) do
          card = Card.fetch(name)
          next nil unless readable.call(card)

          # Reached only for a card THIS CALLER MAY READ. If it cannot state its own identity
          # that is a framework fault, and `from_card` raises Incomplete rather than guessing.
          AuthorizedCardIdentity.from_card(card)
        end
      end

      # card_id -> Boolean, under the CALLER's identity. The per-neighbour gate.
      #
      # @return [Boolean] false when the card is ABSENT OR NOT READABLE by this caller.
      def readable_card_id?(card_id, account:, readable:)
        require_account!(account)
        require_readable!(readable)
        # Not an integer id -> nothing to fetch. Denied WITHOUT asking: a non-id cannot be
        # authorized, and coercing it (`.to_i`) would silently authorize card 0 or card 1.
        return false unless card_id.is_a?(Integer) && !card_id.is_a?(TrueClass) && card_id.positive?

        Card::Auth.as(account.name) do
          readable.call(Card.fetch(card_id)) ? true : false
        end
      end

      private

      def require_account!(account)
        raise PrincipalUnusable, "no account" if account.nil?
        raise PrincipalUnusable, "account has no name" if account.respond_to?(:name) && account.name.to_s.strip.empty?
        raise PrincipalUnusable, "account does not respond to #name" unless account.respond_to?(:name)
      end

      # NO DEFAULT. An omitted predicate is a programming error, and the fail-safe direction for
      # a missing read check is to refuse to run at all -- never to assume readable.
      def require_readable!(readable)
        raise ArgumentError, "a readable predicate is required; there is no default" unless readable.respond_to?(:call)
      end
    end
  end
end
