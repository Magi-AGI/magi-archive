# frozen_string_literal: true

require "spec_helper"
require "open3"
require "shellwords"

# G-CACHE pre-boot regression (the startup half of the fix).
#
# The in-process examples in cache_isolation_spec.rb exercise MirrorRuntimeGuards inside an
# ALREADY-BOOTED application. They structurally cannot show WHEN isolation was established, and the
# residual defect was exactly an ordering defect: every mirror_refresh:* task depends on
# :environment, so Decko (and Card::Cache) initialize BEFORE any task body runs. A staged invocation
# that forgot to export NO_RAILS_CACHE booted against the LIVE deck's shared cache namespace, and
# clearing the lazy memos afterwards cannot undo accesses that already happened during boot.
#
# The fix is the pre-boot guard in the deck Rakefile, which sets NO_RAILS_CACHE before
# config/application is required -- the same lever and assignment the card gem uses for its own
# destructive maintenance tasks (card-1.110.0 mod/core/lib/tasks/card.rake:13,
# mod/core/lib/tasks/card/migrate.rake:4), hoisted ahead of initialization.
#
# Proving that requires a REAL SUBPROCESS: a second rake process, with NO_RAILS_CACHE deliberately
# UNSET, whose own boot is the thing under test. These examples shell out and read the task's
# emitted provenance line.
#
# The staged condition is reproduced without creating a second database by booting with
# RAILS_ENV=development (so database.yml, and therefore Cardio.database and every shared-cache key
# prefix, names magi_archive_development) while DATABASE_URL points the real connection at the
# ephemeral fixture database. That divergence -- namespace_db_at_boot != connected_db -- IS the
# contamination condition the guard exists for.
RSpec.describe "mirror_refresh rake entrypoint", "G-CACHE pre-boot cache isolation" do
  # Plain methods, not `let`: the subprocess is launched from a before(:context) hook (booting Decko
  # costs real seconds, so one child is shared by the whole describe block) and RSpec forbids `let`
  # there.

  # The database the connection is actually pointed at (the "staged copy" in this reproduction).
  def staged_db
    ActiveRecord::Base.connection.current_database.to_s
  end

  # The database database.yml names for the environment the subprocess boots in. Deliberately NOT
  # the staged one: this is the live deck's name, which is what the cache namespace would use.
  def live_namespace_db
    ActiveRecord::Base.configurations
                      .configs_for(env_name: "development")
                      .first
                      .configuration_hash[:database].to_s
  end

  # Environment for the child rake process. Every variable the cache guard cares about is set
  # explicitly so the example cannot accidentally pass because of something the parent exported.
  def child_env(extra = {})
    {
      "RAILS_ENV" => "development",
      "DATABASE_URL" => staged_database_url,
      "DB_HOST" => ENV["DB_HOST"],
      "DB_USERNAME" => ENV["DB_USERNAME"],
      "DATABASE_PASSWORD" => ENV["DATABASE_PASSWORD"],
      "PGPASSWORD" => ENV["PGPASSWORD"] || ENV["DATABASE_PASSWORD"],
      # The whole point: the child is NOT told to disable the cache. Only the Rakefile can.
      "NO_RAILS_CACHE" => nil,
      "MIRROR_REFRESH_PREBOOT_CACHE_GUARD" => nil,
      # Keep the mirror dormant so the precondition's cache gate is the gate under test.
      "ATOMSPACE_MIRRORING_ENABLED" => nil
    }.merge(extra)
  end

  def staged_database_url
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    host = cfg[:host] || ENV["DB_HOST"] || "localhost"
    port = cfg[:port] || 5432
    user = cfg[:username] || ENV["DB_USERNAME"]
    pass = cfg[:password] || ENV["DATABASE_PASSWORD"]
    "postgres://#{user}:#{pass}@#{host}:#{port}/#{staged_db}"
  end

  # Run `rake <task>` as a genuine child process from the deck root. Returns [output, status].
  # The parent's bundler environment is kept (the container's gems live under a non-default
  # BUNDLE_PATH, so a fully unbundled child cannot resolve them), but RUBYOPT is cleared so the
  # child performs its own bundler/setup and, crucially, parses the Rakefile itself.
  def run_rake(task, extra_env = {})
    cmd = ["bundle", "_2.7.2_", "exec", "rake", task]
    env = child_env(extra_env).merge("RUBYOPT" => nil)
    Open3.capture2e(env, *cmd, chdir: Rails.root.to_s)
  end

  # The provenance line the task emits after isolating. Parsed into a hash of key => value.
  def parse_cache_line(output)
    line = output.lines.find { |l| l.start_with?("cache isolated:") }
    raise "no 'cache isolated:' line in rake output:\n#{output}" unless line

    line.sub("cache isolated:", "").strip.split(/\s+/).to_h { |pair| pair.split("=", 2) }
  end

  describe "a direct `rake mirror_refresh:assert_precondition` with NO_RAILS_CACHE unset" do
    # One subprocess, several assertions about it: booting the deck costs real seconds, so the run
    # is memoized for the whole describe block rather than repeated per example.
    before(:all) do
      @out, @status = run_rake("mirror_refresh:assert_precondition")
    end

    it "emits the cache-isolation provenance line" do
      expect(@out).to include("cache isolated:")
    end

    it "reports the shared cache was ALREADY OFF when the application finished booting" do
      fields = parse_cache_line(@out)
      # THE load-bearing assertion. This value is sampled at the very top of the task body, which is
      # the first user code to run after :environment completed. "off" can only be true if
      # NO_RAILS_CACHE was already in place during initialization -- i.e. set pre-boot by the
      # Rakefile, since the child was not given it.
      expect(fields["shared_cache_at_boot"]).to eq("off")
    end

    it "attributes the isolation to the pre-boot Rakefile guard, not to the task body" do
      fields = parse_cache_line(@out)
      expect(fields["preboot_guard"]).to eq("rakefile")
    end

    it "booted with a cache namespace that did NOT name the connected database" do
      fields = parse_cache_line(@out)
      # Confirms the example really did reproduce the staged condition rather than passing
      # vacuously: at boot the namespace named the live deck while the connection was elsewhere.
      expect(fields["namespace_db_at_boot"]).to eq(live_namespace_db)
      expect(fields["connected_db"]).to eq(staged_db)
      expect(fields["namespace_db_at_boot"]).not_to eq(fields["connected_db"])
    end

    it "ends with a non-contaminated namespace pointed at the staged database" do
      fields = parse_cache_line(@out)
      expect(fields["shared_cache"]).to eq("off")
      expect(fields["namespace_db"]).to eq(staged_db)
      expect(fields["namespace_db"]).to eq(fields["connected_db"])
    end

    it "never raises CacheContamination" do
      expect(@out).not_to include("CacheContamination")
      expect(@out).not_to include("DATABASE_URL does not move the cache namespace")
    end
  end

  describe "the pre-boot guard is load-bearing, not decorative" do
    # The negative control. With NO_RAILS_CACHE explicitly set to something other than "true", the
    # Rakefile defers to the caller (`||=` semantics) and the shared cache IS live through boot.
    # If this example reported "off" the positive example above would be meaningless, because it
    # would mean something other than the guard was turning the cache off.
    it "shows the shared cache live at boot when the caller overrides the flag" do
      out, = run_rake("mirror_refresh:assert_precondition", "NO_RAILS_CACHE" => "false")
      fields = parse_cache_line(out)
      expect(fields["shared_cache_at_boot"]).to eq("on")
      expect(fields["preboot_guard"]).to eq("caller:false")
      # Layer two still rescues the run: the task body isolates even when boot did not.
      expect(fields["shared_cache"]).to eq("off")
      expect(fields["namespace_db"]).to eq(fields["connected_db"])
    end
  end

  describe "the guard is scoped to mirror_refresh tasks only" do
    # Evaluates the REAL guard block as shipped -- the Rakefile text up to (but excluding) the
    # `require config/application` line -- in a child ruby with a controlled ARGV. Testing the actual
    # file rather than a restatement of its logic, and without paying for a Rails boot.
    def guard_result_for(argv, preset = nil)
      guard_src = Rails.root.join("Rakefile").read.split(/^require File\.expand_path/).first
      script = <<~RUBY
        ARGV.replace(#{argv.inspect})
        #{guard_src}
        puts "NO_RAILS_CACHE=" + ENV.fetch("NO_RAILS_CACHE", "<unset>")
        puts "GUARD=" + ENV.fetch("MIRROR_REFRESH_PREBOOT_CACHE_GUARD", "<unset>")
      RUBY
      env = { "NO_RAILS_CACHE" => preset, "MIRROR_REFRESH_PREBOOT_CACHE_GUARD" => nil }
      out = nil
      Bundler.with_unbundled_env { out, = Open3.capture2e(env, "ruby", "-e", script) }
      out
    end

    it "arms for any mirror_refresh:* task" do
      expect(guard_result_for(["mirror_refresh:strict_apply"]))
        .to include("NO_RAILS_CACHE=true", "GUARD=rakefile")
    end

    it "arms when the mirror_refresh task is not the first argument" do
      # The runner stages pass VAR=value pairs and flags alongside the task name.
      expect(guard_result_for(["--trace", "OUT=/tmp/x", "mirror_refresh:strict_manifest"]))
        .to include("NO_RAILS_CACHE=true", "GUARD=rakefile")
    end

    it "leaves unrelated tasks completely alone" do
      out = guard_result_for(%w[card:migrate])
      expect(out).to include("NO_RAILS_CACHE=<unset>")
      expect(out).to include("GUARD=<unset>")
    end

    it "does not match a task that merely mentions mirror_refresh" do
      # Anchored match: only a task in the mirror_refresh namespace arms the guard.
      out = guard_result_for(%w[db:mirror_refresh:bogus])
      expect(out).to include("NO_RAILS_CACHE=<unset>")
    end

    it "defers to an explicit caller value instead of overwriting it" do
      expect(guard_result_for(["mirror_refresh:acl_audit"], "false"))
        .to include("NO_RAILS_CACHE=false", "GUARD=caller:false")
    end
  end
end
