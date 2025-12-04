# frozen_string_literal: true

module Mcp
  # Authenticates Decko users and determines their MCP role
  # Integrates with Decko's Card-based user system
  class UserAuthenticator
    # Authentication error
    class AuthenticationError < StandardError; end

    # Role determination error
    class RoleError < StandardError; end

    # Authenticate a user with username and password
    #
    # @param username [String] The user's login name
    # @param password [String] The user's password
    # @return [Hash] { user: Card, role: String }
    # @raise [AuthenticationError] if authentication fails
    def self.authenticate(username, password)
      # Find user card by name
      user_card = find_user_card(username)
      raise AuthenticationError, "User not found" unless user_card

      # Verify password using Decko's authentication
      unless verify_password(user_card, password)
        raise AuthenticationError, "Invalid password"
      end

      # Determine MCP role from user permissions
      role = determine_role(user_card)

      { user: user_card, role: role }
    end

    # Find a user card by username
    #
    # @param username [String] The username
    # @return [Card, nil] The user card or nil
    def self.find_user_card(username)
      # Decko stores users as cards of type "User"
      # Try exact name match first
      user = Card.find_by_name(username)
      return user if user&.type_name == "User"

      # Try case-insensitive search
      Card.where("lower(name) = ? AND type_id = ?", username.downcase, Card::UserID).first
    rescue NameError
      # Fallback if Card::UserID constant not available
      Card.where("lower(name) = ?", username.downcase)
          .joins(:type_card)
          .where("cards.name = 'User'")
          .first
    end

    # Verify password for a user card
    #
    # @param user_card [Card] The user card
    # @param password [String] The password to verify
    # @return [Boolean] True if password is valid
    def self.verify_password(user_card, password)
      # Decko stores encrypted passwords in a subcard: "Username+*password"
      password_card = user_card.fetch(trait: :password)
      return false unless password_card

      # Get the encrypted password content
      encrypted = password_card.content
      return false if encrypted.blank?

      # Use Decko's password verification (BCrypt-based)
      # Decko uses Card::Auth for authentication
      if defined?(Card::Auth)
        Card::Auth.authenticate(user_card.name, password)
      else
        # Fallback: Direct BCrypt comparison
        require "bcrypt"
        BCrypt::Password.new(encrypted) == password
      end
    rescue BCrypt::Errors::InvalidHash, StandardError => e
      Rails.logger.error("Password verification failed for #{user_card.name}: #{e.message}")
      false
    end

    # Determine MCP role from user's Decko permissions
    #
    # @param user_card [Card] The user card
    # @return [String] "admin", "gm", or "user"
    def self.determine_role(user_card)
      # Check if user is admin
      return "admin" if admin?(user_card)

      # Check if user is GM
      return "gm" if gm?(user_card)

      # Default to user role
      "user"
    end

    # Check if user has admin permissions
    #
    # @param user_card [Card] The user card
    # @return [Boolean] True if admin
    def self.admin?(user_card)
      # Decko admin check methods:
      # 1. Check if user is in Admin role
      # 2. Check if user has :admin role
      # 3. Check if user has write permission on System cards

      # Method 1: Check role membership
      return true if has_role?(user_card, "Administrator")
      return true if has_role?(user_card, "Admin")

      # Method 2: Check Decko's built-in admin flag
      return true if user_card.respond_to?(:admin?) && user_card.admin?

      # Method 3: Check if user has roles card with admin
      roles_card = user_card.fetch(trait: :roles)
      return true if roles_card&.item_names&.include?("Administrator")

      false
    end

    # Check if user has GM (Game Master) permissions
    #
    # @param user_card [Card] The user card
    # @return [Boolean] True if GM
    def self.gm?(user_card)
      # Check if user is in GM role
      return true if has_role?(user_card, "Game Master")
      return true if has_role?(user_card, "GM")

      # Check roles card
      roles_card = user_card.fetch(trait: :roles)
      return true if roles_card && (
        roles_card.item_names.include?("Game Master") ||
        roles_card.item_names.include?("GM")
      )

      false
    end

    # Check if user has a specific role
    #
    # @param user_card [Card] The user card
    # @param role_name [String] The role name to check
    # @return [Boolean] True if user has role
    def self.has_role?(user_card, role_name)
      # Check if user has a +roles subcard
      roles_card = user_card.fetch(trait: :roles)
      return false unless roles_card

      # Check if role is in the pointer items
      roles_card.item_names.include?(role_name)
    rescue StandardError => e
      Rails.logger.warn("Role check failed for #{user_card.name}: #{e.message}")
      false
    end

    # Get user's display name
    #
    # @param user_card [Card] The user card
    # @return [String] Display name
    def self.display_name(user_card)
      user_card.name
    end

    # Get user's email (if available)
    #
    # @param user_card [Card] The user card
    # @return [String, nil] Email address
    def self.email(user_card)
      email_card = user_card.fetch(trait: :email)
      email_card&.content
    end
  end
end
