# frozen_string_literal: true

# Base class for all ActiveRecord models in MCP API
# Decko uses Cards instead of ActiveRecord, but MCP API needs traditional models
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end
