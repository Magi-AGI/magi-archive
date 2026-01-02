# frozen_string_literal: true

module Mcp
  # Centralized role management that integrates with Decko's role system.
  #
  # Decko stores roles as cards of type "Role" and assigns them to users
  # via "Username+*roles" cards. This module queries Decko directly rather
  # than maintaining a hardcoded list of roles.
  #
  # Special MCP roles (admin, gm, user) are mapped from Decko roles for
  # backwards compatibility, but any valid Decko role can be used.
  class Roles
    # Legacy MCP role names for backwards compatibility
    ADMIN = "admin"
    GM = "gm"
    USER = "user"

    # Map Decko role names to MCP role names
    # Keys are Decko role names (case-insensitive), values are MCP role names
    DECKO_TO_MCP_MAP = {
      "administrator" => ADMIN,
      "admin" => ADMIN,
      "game master" => GM,
      "gm" => GM
    }.freeze

    # Roles that can see GM/restricted content (beyond what Decko permissions allow)
    # This is a fallback for content that uses naming conventions rather than proper +*read rules
    GM_CONTENT_ROLES = [ADMIN, GM, "game master", "administrator", "magi team"].freeze

    class << self
      # Check if a role name is valid (exists in Decko)
      #
      # @param role [String] Role name to check
      # @return [Boolean] True if role exists in Decko or is a legacy MCP role
      def valid?(role)
        return true if legacy_mcp_role?(role)
        decko_role_exists?(role)
      end

      # Get all valid role names from Decko
      #
      # @return [Array<String>] List of all role names
      def all
        @all_roles ||= fetch_decko_roles
      end

      # Clear cached roles (call when roles are added/removed in Decko)
      def clear_cache!
        @all_roles = nil
      end

      # Check if this is a legacy MCP role (admin, gm, user)
      #
      # @param role [String] Role name
      # @return [Boolean]
      def legacy_mcp_role?(role)
        [ADMIN, GM, USER].include?(role&.downcase)
      end

      # Normalize a Decko role name to MCP role name
      # Returns the original role if no mapping exists
      #
      # @param decko_role [String] Decko role name
      # @return [String] MCP role name
      def normalize(decko_role)
        return USER if decko_role.nil?
        DECKO_TO_MCP_MAP[decko_role.downcase] || decko_role.downcase
      end

      # Get the highest-privilege role from a list of roles
      # Uses Decko's permission system to determine hierarchy
      #
      # @param roles [Array<String>] List of role names
      # @return [String] Highest-privilege role
      def highest_role(roles)
        return USER if roles.empty?

        # Check for admin first
        return ADMIN if roles.any? { |r| normalize(r) == ADMIN }

        # Check for GM
        return GM if roles.any? { |r| normalize(r) == GM }

        # Return the first non-system role, or USER as default
        custom_role = roles.find { |r| !system_role?(r) }
        custom_role ? normalize(custom_role) : USER
      end

      # Check if a role can view GM-restricted content
      # This is for content using naming conventions (+GM, +AI) rather than proper +*read rules
      #
      # @param role [String] Role name
      # @return [Boolean] True if role can see GM content
      def can_view_gm_content?(role)
        return true if role.nil? # Nil role defers to Decko permissions
        GM_CONTENT_ROLES.include?(role.downcase)
      end

      # Get role hierarchy level for comparison
      # Higher number = more privileges
      #
      # @param role [String] Role name
      # @return [Integer] Hierarchy level (0 = unknown, 1 = user, 2 = gm, 3 = admin)
      def level(role)
        case normalize(role)
        when ADMIN then 3
        when GM then 2
        when USER then 1
        else
          # Custom roles default to user level unless they're in GM_CONTENT_ROLES
          can_view_gm_content?(role) ? 2 : 1
        end
      end

      # Check if user can request a specific role
      # User can request any role at or below their highest privilege level
      #
      # @param user_roles [Array<String>] User's Decko roles
      # @param requested_role [String] Role being requested
      # @return [Boolean] True if user can use this role
      def can_assume_role?(user_roles, requested_role)
        return false unless valid?(requested_role)

        user_level = level(highest_role(user_roles))
        requested_level = level(requested_role)

        requested_level <= user_level
      end

      private

      # Check if a role exists in Decko
      def decko_role_exists?(role_name)
        all.any? { |r| r.downcase == role_name.downcase }
      end

      # Fetch all roles from Decko
      def fetch_decko_roles
        Card::Auth.as_bot do
          # Get all cards of type Role
          role_type_id = Card.fetch("Role")&.id
          return [ADMIN, GM, USER] unless role_type_id

          roles = Card.where(type_id: role_type_id, trash: false).pluck(:name)
          roles.presence || [ADMIN, GM, USER]
        end
      rescue StandardError => e
        Rails.logger.error("Failed to fetch Decko roles: #{e.message}")
        [ADMIN, GM, USER] # Fallback to legacy roles
      end

      # Check if this is a Decko system role (Anyone, Anyone Signed In, etc.)
      def system_role?(role)
        %w[anyone anyone\ signed\ in].include?(role.downcase)
      end
    end
  end
end
