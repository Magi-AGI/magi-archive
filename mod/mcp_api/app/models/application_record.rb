# frozen_string_literal: true

# Base class for all ActiveRecord models in MCP API
# Decko uses Cards instead of ActiveRecord, but MCP API needs traditional models
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  # Ensure database connection is established when models are loaded
  # This is needed because models are loaded early via require_relative
  begin
    establish_connection if Rails.application && !connected?
  rescue StandardError => e
    Rails.logger&.warn("ApplicationRecord: Could not establish connection at load time: #{e.message}")
  end
end
