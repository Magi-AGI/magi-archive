# frozen_string_literal: true

# MCP API Eager Loading for Production
#
# In production mode, Rails doesn't use autoloading for performance/security.
# This initializer ensures MCP API models and libs are loaded before the
# controllers try to reference them.

Rails.application.config.to_prepare do
  # Only eager load in production (development uses autoloading)
  if Rails.env.production?
    # Load MCP API models
    require_dependency Rails.root.join('mod/mcp_api/app/models/mcp_api_key.rb')

    # Load MCP API libs
    require_dependency Rails.root.join('mod/mcp_api/lib/mcp/user_authenticator.rb')
  end
end
