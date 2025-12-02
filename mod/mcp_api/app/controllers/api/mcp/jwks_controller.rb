# frozen_string_literal: true

module Api
  module Mcp
    class JwksController < ApplicationController
      # No authentication required for JWKS endpoint (public keys)
      skip_before_action :verify_authenticity_token

      # GET /api/mcp/.well-known/jwks.json
      # Returns JSON Web Key Set for JWT verification
      def show
        render json: McpApi::JwtService.jwks
      end
    end
  end
end
