# frozen_string_literal: true

module Api
  module Mcp
    class AuthController < BaseController
      # POST /api/mcp/auth
      # Issues JWT token for specified role
      #
      # User role: API key only
      # GM/Admin roles: Require username + password authentication
      def create
        api_key = params[:api_key] || request.headers["X-API-Key"]
        role = params[:role]
        username = params[:username]
        password = params[:password]

        # Validate inputs
        return render_error("validation_error", "Missing api_key") unless api_key
        return render_error("validation_error", "Missing role") unless role
        return render_error("validation_error", "Invalid role", { valid_roles: %w[user gm admin] }) unless valid_role?(role)

        # Verify API key
        unless valid_api_key?(api_key)
          return render_error("invalid_credentials", "Invalid API key", {}, status: :unauthorized)
        end

        # For elevated roles (gm, admin), require username/password authentication
        if role != "user"
          unless username && password
            return render_error(
              "authentication_required",
              "Username and password required for role '#{role}'",
              { hint: "Provide username and password for the service account" },
              status: :unauthorized
            )
          end

          # Authenticate the user account
          unless authenticate_user(username, password, role)
            return render_error(
              "invalid_credentials",
              "Invalid username or password for role '#{role}'",
              {},
              status: :unauthorized
            )
          end
        end

        # Generate token
        token = generate_token(role, api_key)
        expires_in = token_ttl

        render json: {
          token: token,
          role: role,
          expires_in: expires_in,
          expires_at: (Time.now.to_i + expires_in)
        }, status: :created
      end

      private

      def valid_role?(role)
        %w[user gm admin].include?(role)
      end

      def valid_api_key?(api_key)
        # Check against configured API keys
        # For MVP: Single API key from env; Phase 2: Database-backed keys
        configured_key = ENV["MCP_API_KEY"]
        return false unless configured_key

        # Constant-time comparison to prevent timing attacks
        ActiveSupport::SecurityUtils.secure_compare(api_key, configured_key)
      end

      def authenticate_user(username, password, expected_role)
        # Find the user account
        user = Card[username]
        return false unless user

        # Verify this is actually a User type card
        return false unless user.type_name == "User"

        # Get the account and password cards
        account_card = Card["#{username}+*account"]
        password_card = Card["#{username}+*account+*password"]
        status_card = Card["#{username}+*account+*status"]

        return false unless account_card && password_card && status_card

        # Check account is active
        return false unless status_card.content == "active"

        # Authenticate using Decko's account authentication
        # Note: This uses Decko's built-in password verification which handles hashing
        Card::Auth.authenticate(username, password)

        # Verify the user has the expected role
        verify_user_role(user, expected_role)
      rescue StandardError => e
        Rails.logger.error("Authentication error for #{username}: #{e.message}")
        false
      end

      def verify_user_role(user, expected_role)
        # Map API roles to Decko roles
        role_name = case expected_role
                    when "admin"
                      "Administrator"
                    when "gm"
                      "Game Master"
                    else
                      return true # User role doesn't need special role check
                    end

        # Check if user is a member of the required role
        role_card = Card.fetch(role_name)
        return false unless role_card

        members_card = Card["#{role_name}+*members"]
        return false unless members_card

        members = members_card.item_names || []
        members.include?(user.name)
      end

      def generate_token(role, api_key)
        # Phase 2: Use JWT by default, fallback to MessageVerifier if JWT disabled
        if jwt_enabled?
          generate_jwt_token(role, api_key)
        else
          generate_message_verifier_token(role, api_key)
        end
      end

      def generate_jwt_token(role, api_key)
        # Use JWT service for RS256 signed tokens
        McpApi::JwtService.generate_token(
          role: role,
          api_key_id: api_key.slice(0, 8),
          expires_in: token_ttl
        )
      end

      def generate_message_verifier_token(role, api_key)
        # Fallback to MessageVerifier (Phase 1 compatibility)
        payload = {
          role: role,
          api_key: api_key.slice(0, 8),
          iat: Time.now.to_i,
          exp: (Time.now.to_i + token_ttl)
        }

        verifier = Rails.application.message_verifier(:mcp_auth)
        verifier.generate(payload)
      end

      def jwt_enabled?
        ENV.fetch("MCP_JWT_ENABLED", "true") == "true"
      end

      def token_ttl
        # Default: 1 hour; configurable via ENV
        (ENV["MCP_TOKEN_TTL"] || ENV["JWT_EXPIRY"] || 3600).to_i
      end
    end
  end
end
