# Add your own tasks in files ending in .rake a mod or deck's lib/tasks directory.
#
# Deck example:  mydeck/lib/tasks/mytasks.rake
# Mod example    mydecko/mod/mymod/lib/tasks/mytasks.rake
#
# Tasks in these files will automatically be available to Rake.

# ---------------------------------------------------------------------------
# G-CACHE pre-boot guard.
#
# Every mirror_refresh:* task depends on :environment, so Decko -- and with it Card::Cache -- is
# fully initialized BEFORE any task body runs. The in-task isolate_refresh_cache! can clear the lazy
# memos the gem reads NO_RAILS_CACHE through (card-1.110.0 lib/card/cache/class_methods.rb:106), but
# it cannot undo shared-cache reads and writes that already happened during initialization. A staged
# refresh invoked directly as `rake mirror_refresh:...` without exporting NO_RAILS_CACHE would
# therefore boot against the LIVE deck's cache namespace (Cardio.database comes from database.yml;
# DATABASE_URL does not move it -- see mod/atomspace_mirror/lib/mirror_runtime_guards.rb G-CACHE).
#
# So the flag is established here, before config/application is required. This is the same lever and
# the same assignment the card gem itself uses for destructive maintenance tasks
# (card-1.110.0 mod/core/lib/tasks/card.rake:13 and mod/core/lib/tasks/card/migrate.rake:4,
# ENV["NO_RAILS_CACHE"] = "true"); the only difference is that those run after boot, which is exactly
# the gap being closed. An unsafe explicit caller value is forced to "true" rather than honored --
# see the FAIL-CLOSED note below.
#
# The in-task memo reset, Cardio.database namespace correction and fail-closed assertion all remain
# as the second defense layer: this guard is not a substitute for them.
#
# FAIL-CLOSED OVER AN EXPLICIT CALLER VALUE (impl8 review finding). An earlier revision deferred to
# ANY explicit NO_RAILS_CACHE value. That left the original defect wide open for
# `NO_RAILS_CACHE=false` (or any typo'd non-"true" value): boot then ran against the LIVE deck's
# cache namespace, and layer two cannot retroactively undo cache reads/writes that already happened
# during initialization. Isolation is not a caller preference for these tasks -- it is a
# precondition -- so a non-"true" value is FORCED to "true" here, before config/application.
#
# There is deliberately NO bypass. The regression suite proves this guard is load-bearing by running
# its negative control against a test-only fixture Rakefile that omits the guard entirely
# (spec/fixtures/unguarded/Rakefile), rather than through an opt-out shipped in this file.
# ---------------------------------------------------------------------------
if ARGV.any? { |arg| arg =~ /\Amirror_refresh:/ }
  # Provenance, so the task body can report -- and a regression test can prove -- that isolation was
  # established before application initialization rather than inside the task.
  caller_value = ENV["NO_RAILS_CACHE"]
  if caller_value.nil?
    ENV["NO_RAILS_CACHE"] = "true"
    ENV["MIRROR_REFRESH_PREBOOT_CACHE_GUARD"] = "rakefile"
  elsif caller_value == "true"
    # Already safe; the scripted entrypoints (R3.sh, run_ruby.sh) export exactly this.
    ENV["MIRROR_REFRESH_PREBOOT_CACHE_GUARD"] = "caller:true"
  else
    # An unsafe explicit value is overridden, not honored, and the override is recorded.
    # Whitespace is squeezed so the provenance line stays single-token-per-field parseable.
    ENV["NO_RAILS_CACHE"] = "true"
    ENV["MIRROR_REFRESH_PREBOOT_CACHE_GUARD"] =
      "rakefile:forced-over-caller:#{caller_value.to_s.gsub(/\s+/, '_')}"
    warn "[mirror_refresh] NO_RAILS_CACHE=#{caller_value} is unsafe for mirror_refresh:* tasks; " \
         "forcing cache isolation to \"true\" before application boot."
  end
end

require File.expand_path("../config/application", __FILE__)

MagiArchive::Application.load_tasks
