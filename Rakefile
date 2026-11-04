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
# the gap being closed. `||=` keeps an explicit caller setting authoritative (the scripted
# entrypoints dev-runner/stages/R3.sh and dev-runner/r3/run_ruby.sh already export it).
#
# The in-task memo reset, Cardio.database namespace correction and fail-closed assertion all remain
# as the second defense layer: this guard is not a substitute for them.
# ---------------------------------------------------------------------------
if ARGV.any? { |arg| arg =~ /\Amirror_refresh:/ }
  # Provenance, so the task body can report -- and a regression test can prove -- that isolation was
  # established before application initialization rather than inside the task.
  if ENV["NO_RAILS_CACHE"].nil?
    ENV["NO_RAILS_CACHE"] = "true"
    ENV["MIRROR_REFRESH_PREBOOT_CACHE_GUARD"] = "rakefile"
  else
    # An explicit caller value stays authoritative (the scripted entrypoints already export "true").
    ENV["MIRROR_REFRESH_PREBOOT_CACHE_GUARD"] = "caller:#{ENV['NO_RAILS_CACHE']}"
  end
end

require File.expand_path("../config/application", __FILE__)

MagiArchive::Application.load_tasks
