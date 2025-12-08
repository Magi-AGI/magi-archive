# frozen_string_literal: true

# MCP API Autoload/Eager Load Configuration
#
# Configure Rails to recognize and load MCP API components from mod/ directory.
# This ensures models, libs, and controllers are available in all environments.

# Add MCP API paths to autoload paths (development) and eager load paths (production)
Rails.application.config.tap do |config|
  mcp_api_root = Rails.root.join('mod/mcp_api')

  # Models
  config.autoload_paths << mcp_api_root.join('app/models')
  config.eager_load_paths << mcp_api_root.join('app/models')

  # Libs (for Mcp::UserAuthenticator)
  config.autoload_paths << mcp_api_root.join('lib')
  config.eager_load_paths << mcp_api_root.join('lib')
end
