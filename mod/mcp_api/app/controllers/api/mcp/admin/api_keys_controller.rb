# frozen_string_literal: true

module Api
  module Mcp
    module Admin
      # Admin controller for managing MCP API keys via web interface
      # Requires admin authentication (implement in BaseController or override here)
      class ApiKeysController < ApplicationController
        before_action :require_admin_authentication
        before_action :set_api_key, only: [:show, :update, :destroy]

        # GET /api/mcp/admin/api_keys
        # List all API keys
        def index
          @keys = McpApiKey.order(created_at: :desc)

          render json: {
            keys: @keys.map do |key|
              {
                id: key.id,
                name: key.name,
                key_prefix: key.key_prefix,
                allowed_roles: key.allowed_roles,
                status: key.status,
                rate_limit_per_hour: key.rate_limit_per_hour,
                last_used_at: key.last_used_at&.iso8601,
                created_at: key.created_at.iso8601,
                created_by: key.created_by,
                expires_at: key.expires_at&.iso8601,
                masked_key: key.masked_key
              }
            end,
            summary: {
              total: @keys.count,
              active: @keys.active.count,
              expired: @keys.expired.count,
              inactive: @keys.inactive.count
            }
          }
        end

        # GET /api/mcp/admin/api_keys/:id
        # Show specific API key details
        def show
          render json: {
            id: @key.id,
            name: @key.name,
            key_prefix: @key.key_prefix,
            allowed_roles: @key.allowed_roles,
            status: @key.status,
            active: @key.active,
            expired: @key.expired?,
            rate_limit_per_hour: @key.rate_limit_per_hour,
            last_used_at: @key.last_used_at&.iso8601,
            created_at: @key.created_at.iso8601,
            created_by: @key.created_by,
            contact_email: @key.contact_email,
            description: @key.description,
            expires_at: @key.expires_at&.iso8601,
            days_until_expiration: @key.days_until_expiration,
            usage_info: @key.usage_info,
            masked_key: @key.masked_key
          }
        end

        # POST /api/mcp/admin/api_keys
        # Generate a new API key
        def create
          result = McpApiKey.generate(
            name: params[:name] || "Key #{Time.current.to_i}",
            roles: Array(params[:roles]).presence || ["user"],
            rate_limit: params[:rate_limit]&.to_i || 1000,
            expires_in: params[:expires_in_days] ? params[:expires_in_days].to_i.days : nil,
            created_by: current_admin_name,
            contact_email: params[:contact_email],
            description: params[:description]
          )

          render json: {
            message: "API key generated successfully",
            key: {
              id: result[:record].id,
              name: result[:record].name,
              allowed_roles: result[:record].allowed_roles,
              api_key: result[:api_key],  # Only time this is returned!
              key_prefix: result[:record].key_prefix,
              rate_limit_per_hour: result[:record].rate_limit_per_hour,
              expires_at: result[:record].expires_at&.iso8601,
              created_at: result[:record].created_at.iso8601
            },
            warning: "Store this API key securely - it will never be shown again!"
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "validation_error",
            message: e.message,
            details: e.record.errors.as_json
          }, status: :unprocessable_entity
        end

        # PATCH /api/mcp/admin/api_keys/:id
        # Update API key settings
        def update
          update_params = {}
          update_params[:rate_limit_per_hour] = params[:rate_limit_per_hour].to_i if params[:rate_limit_per_hour]
          update_params[:active] = params[:active] if params.key?(:active)
          update_params[:expires_at] = parse_expiration(params[:expires_at]) if params.key?(:expires_at)
          update_params[:description] = params[:description] if params.key?(:description)
          update_params[:contact_email] = params[:contact_email] if params.key?(:contact_email)

          if update_params.empty?
            return render json: { error: "no_updates", message: "No valid update parameters provided" },
                          status: :bad_request
          end

          @key.update!(update_params)

          render json: {
            message: "API key updated successfully",
            key: {
              id: @key.id,
              name: @key.name,
              status: @key.status,
              active: @key.active,
              rate_limit_per_hour: @key.rate_limit_per_hour,
              expires_at: @key.expires_at&.iso8601,
              description: @key.description,
              contact_email: @key.contact_email
            }
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "validation_error",
            message: e.message,
            details: e.record.errors.as_json
          }, status: :unprocessable_entity
        end

        # DELETE /api/mcp/admin/api_keys/:id
        # Delete an API key
        def destroy
          @key.destroy!

          render json: {
            message: "API key deleted successfully",
            deleted_key: {
              id: @key.id,
              name: @key.name,
              key_prefix: @key.key_prefix
            }
          }
        end

        # POST /api/mcp/admin/api_keys/:id/deactivate
        # Deactivate an API key
        def deactivate
          set_api_key
          @key.deactivate!

          render json: {
            message: "API key deactivated",
            key: {
              id: @key.id,
              name: @key.name,
              status: @key.status,
              active: @key.active
            }
          }
        end

        # POST /api/mcp/admin/api_keys/:id/activate
        # Activate an API key
        def activate
          set_api_key
          @key.activate!

          render json: {
            message: "API key activated",
            key: {
              id: @key.id,
              name: @key.name,
              status: @key.status,
              active: @key.active
            }
          }
        end

        private

        def set_api_key
          @key = McpApiKey.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: {
            error: "not_found",
            message: "API key not found"
          }, status: :not_found
        end

        def require_admin_authentication
          # TODO: Implement admin authentication check
          # For now, this is a placeholder - implement according to your auth system
          #
          # Example:
          # unless current_user&.admin?
          #   render json: { error: "unauthorized", message: "Admin access required" }, status: :unauthorized
          # end
          #
          # Or use Decko's built-in authentication
        end

        def current_admin_name
          # TODO: Return current admin user's name
          # Example: current_user&.name || "admin"
          "admin"
        end

        def parse_expiration(value)
          return nil if value.blank? || value == "null" || value == "never"

          if value.is_a?(String) && value.match?(/^\d+$/)
            # Number of days from now
            Time.current + value.to_i.days
          elsif value.is_a?(String)
            # ISO8601 timestamp
            Time.zone.parse(value)
          else
            value
          end
        end
      end
    end
  end
end
