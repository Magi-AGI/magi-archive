# frozen_string_literal: true

# MCP API Late Loading
#
# Load MCP API models after Rails has finished initializing.
# This ensures ApplicationRecord and other dependencies are available.

Rails.application.config.after_initialize do
  # Only in production - development uses autoloading
  if Rails.env.production?
    # Load model files that aren't in standard Rails autoload paths
    require_relative '../../mod/mcp_api/app/models/mcp_api_key.rb' unless defined?(::McpApiKey)
  end
end
