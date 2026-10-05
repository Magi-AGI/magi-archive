# frozen_string_literal: true

# Bypass reCAPTCHA for authenticated MCP API requests
# Web forms still require reCAPTCHA validation
#
# Uses prepend via after_card hook because Decko set modules
# are loaded after standard Rails initializers, overriding class_eval patches.
module McpRecaptchaBypass
  def validate_recaptcha?
    # Skip reCAPTCHA if request is from MCP API controller
    controller = Card::Env.controller
    if controller && controller.class.name.to_s.start_with?("Api::Mcp::")
      return false
    end

    # Also skip if thread-local MCP flag is set (for batch operations)
    if Thread.current[:mcp_api_request]
      return false
    end

    super
  end
end

ActiveSupport.on_load :after_card do
  Card.prepend(McpRecaptchaBypass)
end
