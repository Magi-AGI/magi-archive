# frozen_string_literal: true

module Api
  module Mcp
    class AuthController < BaseController
      # POST /api/mcp/auth
      # Issues MessageVerifier token for specified role
      def create
        api_key = params[:api_key] || request.headers["X-API-Key"]
        role = params[:role]

        # Validate inputs
        return render_error("validation_error", "Missing api_key") unless api_key
        return render_error("validation_error", "Missing role") unless role
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

      def allowed_role_for_key?(api_key, role)
        # For MVP: Single API key has access to all roles
        # Phase 2: Implement per-key role restrictions
        true
      end

      def generate_token(role, api_key)
        payload = {
          role: role,
          api_key: api_key.slice(0, 8), # Store prefix only for audit
          iat: Time.now.to_i,
          exp: (Time.now.to_i + token_ttl)
        }

        verifier = Rails.application.message_verifier(:mcp_auth)
        verifier.generate(payload)
      end

      def token_ttl
        # Default: 1 hour; configurable via ENV
        (ENV["MCP_TOKEN_TTL"] || 3600).to_i
      end
    end
  end
end
