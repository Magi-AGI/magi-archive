# frozen_string_literal: true

module McpApi
  # Decides which principals receive the AtomSpace scopes at token-mint time.
  #
  # Magi policy (SPEC 8.3): explicit allowlists of named users only.
  #
  #   ATOMSPACE_READ_GRANTS   "user:<name>,..."  -> mcp:atomspace:read
  #   ATOMSPACE_ADMIN_GRANTS  "user:<name>,..."  -> mcp:atomspace:read + mcp:atomspace:admin
  #
  # No Decko role or admin status confers a scope, and mcp:atomspace:write is never minted. A principal
  # qualifies only as a real user: a `user:` id WITH the authenticated user card. API keys therefore get
  # nothing, even when listed, because their role is caller-selected rather than proof of an identity.
  # Future key support needs an explicit stored principal-to-account binding, not an entry here.
  #
  # Holders of the read scope are trusted with the Space-global view (SPEC 8.2, G-AUDIENCE), so only
  # principals entitled to that view may be listed.
  module AtomspaceGrants
    READ_SCOPE  = "mcp:atomspace:read"
    ADMIN_SCOPE = "mcp:atomspace:admin"

    # Retained for callers that referenced the single read scope constant.
    SCOPE = READ_SCOPE

    # I3 (VIEW's Decko-mounted store-read surface) carries its OWN NAMESPACED scope and its OWN
    # allowlist, deliberately NOT a widening of mcp:atomspace:read:
    #
    #   I3_READ_GRANTS  "user:<name>,..."  -> mcp:i3:read
    #
    # The two surfaces read DIFFERENT backends (mirror Space vs record store) with different
    # audiences, so holding one must never confer the other. There is no mcp:i3:write and no
    # mcp:i3:admin: this module never mints a write scope for any surface.
    I3_READ_SCOPE = "mcp:i3:read"

    module_function

    # @param principal_id [String] the JWT `sub` ("user:<name>" or "key:<id>")
    # @param user_card [Card, nil] the authenticated Decko user card; nil for API-key principals
    # @return [Array<String>]
    def scopes_for(principal_id, user_card: nil)
      return [] unless user_card.present? && principal_id.to_s.start_with?("user:")

      scopes = []
      if admin_granted?(principal_id)
        scopes.concat([READ_SCOPE, ADMIN_SCOPE])
      elsif granted?(principal_id)
        scopes << READ_SCOPE
      end
      # Independent allowlist: an I3 grant neither requires nor implies an atomspace grant.
      scopes << I3_READ_SCOPE if i3_read_granted?(principal_id)
      scopes
    end

    def granted?(principal_id)
      list("ATOMSPACE_READ_GRANTS").include?(principal_id.to_s)
    end

    def admin_granted?(principal_id)
      list("ATOMSPACE_ADMIN_GRANTS").include?(principal_id.to_s)
    end

    def i3_read_granted?(principal_id)
      list("I3_READ_GRANTS").include?(principal_id.to_s)
    end

    def list(env_var)
      (ENV[env_var] || "").split(",").map(&:strip).reject(&:empty?)
    end
  end
end
