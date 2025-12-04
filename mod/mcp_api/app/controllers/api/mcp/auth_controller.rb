# frozen_string_literal: true

require_relative "../../../lib/mcp/user_authenticator"

module Api
  module Mcp
    class AuthController < BaseController
      # POST /api/mcp/auth
      # Issues MessageVerifier token using username/password OR API key
      #
      # Method 1: Username/Password (Recommended for human users)
      # {
      #   "username": "john_doe",
      #   "password": "their-password",
      #   "role": "user" # Optional: will auto-determine if not provided
      # }
      #
      # Method 2: API Key (For service accounts/automation)
      # {
      #   "api_key": "64-char-key",
      #   "role": "user" # Required with API key
      # }
      def create
        # Determine authentication method
        if username_provided?
          authenticate_with_username
        elsif api_key_provided?
          authenticate_with_api_key
        else
          render_error("validation_error", "Must provide either (username + password) or api_key")
        end
      end

      private

      # ==================== Username/Password Authentication ====================

      def username_provided?
        params[:username].present? && params[:password].present?
      end

      def authenticate_with_username
        username = params[:username]
        password = params[:password]
        requested_role = params[:role] # Optional

        # Authenticate user with Decko
        begin
          result = Mcp::UserAuthenticator.authenticate(username, password)
        rescue Mcp::UserAuthenticator::AuthenticationError => e
          return render_error("authentication_failed", e.message, {}, status: :unauthorized)
        end

        user_card = result[:user]
        auto_role = result[:role] # Role determined from user permissions

        # Determine final role
        final_role = if requested_role.present?
                       # User requested specific role - verify they have permission
                       validate_requested_role(requested_role, auto_role, user_card)
                     else
                       # No role requested - use auto-determined role
                       auto_role
                     end

        return unless final_role # Error already rendered if validation failed

        # Generate token
        token = generate_token_for_user(final_role, user_card)
        expires_in = token_ttl

        render json: {
          token: token,
          role: final_role,
          username: user_card.name,
          expires_in: expires_in,
          expires_at: (Time.now.to_i + expires_in),
          auth_method: "username"
        }, status: :created
      end

      # Validate that user has permission for requested role
      def validate_requested_role(requested_role, auto_role, user_card)
        unless valid_role?(requested_role)
          render_error("validation_error", "Invalid role", { valid_roles: %w[user gm admin] })
          return nil
        end

        # Role hierarchy: admin > gm > user
        user_level = role_level(auto_role)
        requested_level = role_level(requested_role)

        if requested_level > user_level
          render_error(
            "permission_denied",
            "User '#{user_card.name}' does not have permission for role '#{requested_role}'. " \
            "Maximum allowed role: '#{auto_role}'",
            { user_role: auto_role, requested_role: requested_role },
            status: :forbidden
          )
          return nil
        end

        requested_role
      end

      # Map role to numeric level for comparison
      def role_level(role)
        { "admin" => 3, "gm" => 2, "user" => 1 }[role] || 0
      end

      # ==================== API Key Authentication ====================

      def api_key_provided?
        (params[:api_key] || request.headers["X-API-Key"]).present?
      end

      def authenticate_with_api_key
        api_key = params[:api_key] || request.headers["X-API-Key"]
        role = params[:role]

        # Validate inputs
        return render_error("validation_error", "Missing role (required with API key)") unless role
        return render_error("validation_error", "Invalid role", { valid_roles: %w[user gm admin] }) unless valid_role?(role)

        # Verify API key
        unless valid_api_key?(api_key)
          return render_error("invalid_credentials", "Invalid API key", {}, status: :unauthorized)
        end

        # Check role permissions for this API key
        unless allowed_role_for_key?(api_key, role)
          return render_error("permission_denied", "API key not authorized for role '#{role}'", {}, status: :forbidden)
        end

        # Generate token
        token = generate_token_for_api_key(role, api_key)
        expires_in = token_ttl

        render json: {
          token: token,
          role: role,
          expires_in: expires_in,
          expires_at: (Time.now.to_i + expires_in),
          auth_method: "api_key"
        }, status: :created
      end

      def valid_api_key?(api_key)
        # Phase 2: Try database-backed keys first
        @api_key_record = McpApiKey.authenticate(api_key)
        return true if @api_key_record

        # Phase 1 fallback: Single API key from env (for backwards compatibility)
        configured_key = ENV["MCP_API_KEY"]
        return false unless configured_key

        # Constant-time comparison to prevent timing attacks
        if ActiveSupport::SecurityUtils.secure_compare(api_key, configured_key)
          @api_key_record = nil  # Mark as legacy key
          return true
        end

        false
      end

      def allowed_role_for_key?(api_key, role)
        # Phase 2: Check database key permissions
        if @api_key_record
          return @api_key_record.role_allowed?(role)
        end

        # Phase 1 fallback: Single API key has access to all roles
        true
      end

      # ==================== Token Generation ====================

      def generate_token_for_user(role, user_card)
        payload = {
          role: role,
          username: user_card.name,
          auth_method: "username",
          iat: Time.now.to_i,
          exp: (Time.now.to_i + token_ttl)
        }

        # Add email if available
        email = Mcp::UserAuthenticator.email(user_card)
        payload[:email] = email if email

        verifier = Rails.application.message_verifier(:mcp_auth)
        verifier.generate(payload)
      end

      def generate_token_for_api_key(role, api_key)
        payload = {
          role: role,
          api_key_prefix: api_key.slice(0, 8), # Store prefix only for audit
          auth_method: "api_key",
          iat: Time.now.to_i,
          exp: (Time.now.to_i + token_ttl)
        }

        # Add key name if database key
        payload[:api_key_name] = @api_key_record.name if @api_key_record

        verifier = Rails.application.message_verifier(:mcp_auth)
        verifier.generate(payload)
      end

      # ==================== Utilities ====================

      def valid_role?(role)
        %w[user gm admin].include?(role)
      end

      def token_ttl
        # Default: 1 hour; configurable via ENV
        (ENV["MCP_TOKEN_TTL"] || 3600).to_i
      end
    end
  end
end
