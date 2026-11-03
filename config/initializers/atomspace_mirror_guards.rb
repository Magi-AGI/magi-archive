# frozen_string_literal: true

# Loads after atomspace_mirror.rb (alphabetical). Cardio config is only final once the app has
# initialized, so the G-DELAY assertion runs then. A failure stops the boot on purpose.
guards = File.expand_path("../../mod/atomspace_mirror/lib/mirror_runtime_guards.rb", __dir__)
if File.exist?(guards) && defined?(MirrorOutboxWriter)
  require guards
  Rails.application.config.after_initialize { MirrorRuntimeGuards.assert_inline_integrate! }
end
