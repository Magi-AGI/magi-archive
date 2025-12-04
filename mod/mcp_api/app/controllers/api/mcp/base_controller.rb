# frozen_string_literal: true

module Api
  module Mcp
    class BaseController < ApplicationController
      include RateLimitable

      # Disable CSRF for API endpoints
      skip_before_action :verify_authenticity_token

      # Authentication for all MCP API endpoints (except auth)
      before_action :authenticate_mcp_request!, unless: :auth_endpoint?

      rescue_from StandardError, with: :handle_error

      private

      def auth_endpoint?
        controller_name == "auth"
      end

      def authenticate_mcp_request!
        token = extract_token_from_header
        return render_unauthorized("Missing authorization token") unless token

        @current_mcp_payload = verify_token(token)
        return render_unauthorized("Invalid or expired token") unless @current_mcp_payload

        @current_mcp_role = @current_mcp_payload["role"]
        @current_mcp_account = find_mcp_account(@current_mcp_payload)

        render_unauthorized("Account not found") unless @current_mcp_account
      end

      def extract_token_from_header
        auth_header = request.headers["Authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        auth_header.split(" ", 2).last
      end

      def verify_token(token)
        verifier = Rails.application.message_verifier(:mcp_auth)
        verifier.verify(token)
      rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
        nil
      end

      def find_mcp_account(payload)
        account_name = case payload["role"]
                       when "user"
                         ENV.fetch("MCP_USER_NAME", "mcp-user")
                       when "gm"
                         ENV.fetch("MCP_GM_NAME", "mcp-gm")
                       when "admin"
                         ENV.fetch("MCP_ADMIN_NAME", "mcp-admin")
                       end

        Card[account_name] if account_name
      end

      def current_role
        @current_mcp_role
      end

      def current_account
        @current_mcp_account
      end

      def render_error(code, message, details = {}, status: :bad_request)
        render json: {
          error: {
            code: code,
            message: message,
            details: details
          }
        }, status: status
      end

      def render_unauthorized(message)
        render json: {
          error: {
            code: "unauthorized",
            message: message
          }
        }, status: :unauthorized
      end

      def render_forbidden(message, details = {})
        render_error("permission_denied", message, details, status: :forbidden)
      end

      def handle_error(exception)
        Rails.logger.error("MCP API Error: #{exception.message}")
        Rails.logger.error(exception.backtrace.join("\n"))

        render_error(
          "internal_error",
          "An unexpected error occurred",
          { exception: exception.class.name },
          status: :internal_server_error
        )
      end
    end
  end
end
