# frozen_string_literal: true

# Magi-specific runtime guards for the ported mirror. All of them fail loudly rather than letting the
# mirror run in a state its invariants do not cover.
module MirrorRuntimeGuards
  class UnsafeRuntime < StandardError; end
  class RefreshPreconditionViolated < StandardError; end
  class CacheContamination < StandardError; end

  MIRROR_TABLES = %w[mirror_state mirror_outbox mirror_bootstrap_runs mirror_reconcile_runs].freeze

  module_function

  # G-DELAY / T15. The integrate hook assumes integrate_with_delay runs inline in the saving request.
  # With delayed integration it would encode a later card state under an older action id. Dormant
  # decks are unaffected, so this only raises when the mirror is enabled.
  def assert_inline_integrate!(enabled: MirrorOutboxWriter.enabled?, delaying: Cardio.config.delaying)
    return unless enabled && delaying

    raise UnsafeRuntime,
          "ATOMSPACE_MIRRORING_ENABLED=true requires Cardio.config.delaying to be false"
  end

  # T14 / SPEC 7.3. A DB refresh invalidates mirror state, so it may only run while the mirror is
  # dormant and its tables are absent (or dropped along with their schema_migrations rows). A staged
  # refresh must also not share the live deck's cache namespace (G-CACHE, below).
  def assert_refresh_precondition!(enabled: MirrorOutboxWriter.enabled?, conn: ActiveRecord::Base.connection)
    raise RefreshPreconditionViolated, "ATOMSPACE_MIRRORING_ENABLED is set; disable the mirror first" if enabled

    assert_isolated_cache!(conn: conn)

    present = MIRROR_TABLES.select { |t| conn.table_exists?(t) }
    return if present.empty?

    raise RefreshPreconditionViolated, "mirror tables still exist: #{present.join(', ')}"
  end

  # ---------------------------------------------------------------------------
  # G-CACHE: staged/live shared-cache contamination.
  #
  # Verified against card-1.110.0 source, not assumed:
  #
  #   lib/cardio.rb:44              def database; @database ||= config.database_configuration
  #                                                               .dig(Rails.env, "database"); end
  #   lib/card/cache/shared_class.rb:15   def stamp_key; "#{Cardio.database}-stamp"; end
  #   lib/card/cache/shared.rb:29         @database = opts[:database] || Cardio.database
  #   lib/card/cache/class_methods.rb:106 @shared_cache = (ENV["NO_RAILS_CACHE"] != "true") && shared_on!
  #
  # Cardio.database is read from database.yml for the CURRENT Rails.env and memoized. DATABASE_URL
  # moves the ActiveRecord CONNECTION but never that value, so the cache stamp key and every shared
  # cache prefix keep naming the LIVE deck's database. A staged STRICT refresh invoked with
  # DATABASE_URL=...staged therefore reads and writes the live deck's cache namespace: staged rows can
  # be served to live readers, and deletes performed on the staged copy reset the live stamp.
  #
  # The only lever the gem itself offers is ENV["NO_RAILS_CACHE"], read lazily by
  # Card::Cache.shared_cache; because it is lazy, the memoized @shared_cache must also be cleared for
  # a process that has already touched the cache. isolate_cache! does both AND re-points the
  # Cardio.database memo at the actually-connected database, so any shared cache that is turned back
  # on later still namespaces to the staged target rather than to the live deck.
  #
  # assert_isolated_cache! is the fail-closed half: an env var that someone forgets to export is not
  # a safety property, so selection and apply refuse whenever a live shared cache is paired with a
  # connection to some other database.
  # ---------------------------------------------------------------------------

  # True when Card::Cache would actually hand out a shared (cross-process) store right now.
  def shared_cache_live?
    return false unless defined?(Card::Cache)

    !!Card::Cache.shared_cache
  end

  # The database whose name the cache namespace is derived from (database.yml, via Cardio.database).
  def cache_namespace_database
    Cardio.database.to_s
  end

  def connected_database(conn: ActiveRecord::Base.connection)
    conn.current_database.to_s
  end

  # Safe when the shared cache is off, or when the cache namespace already names the database we are
  # actually connected to.
  def cache_isolated?(conn: ActiveRecord::Base.connection)
    return true unless shared_cache_live?

    cache_namespace_database == connected_database(conn: conn)
  end

  def assert_isolated_cache!(conn: ActiveRecord::Base.connection)
    return if cache_isolated?(conn: conn)

    raise CacheContamination,
          "shared Rails cache is live and namespaced to #{cache_namespace_database.inspect} " \
          "(from database.yml via Cardio.database) while this process is connected to " \
          "#{connected_database(conn: conn).inspect}. DATABASE_URL does not move the cache namespace, " \
          "so a staged refresh would contaminate the live deck's cache. Run this stage with " \
          "NO_RAILS_CACHE=true (see MirrorRuntimeGuards.isolate_cache!)."
  end

  # Make the current process cache-isolated, and prove it. Belt and braces:
  #   (a) disable the shared cache for this process (NO_RAILS_CACHE, plus clearing the lazy memos the
  #       gem reads it through), and
  #   (b) re-point the Cardio.database memo at the real connected database, so the stamp key and every
  #       Card::Cache::Shared prefix derive from the staged target rather than from database.yml.
  # Returns the namespace database it settled on.
  def isolate_cache!(conn: ActiveRecord::Base.connection)
    target = connected_database(conn: conn)
    ENV["NO_RAILS_CACHE"] = "true"
    if defined?(Card::Cache)
      Card::Cache.instance_variable_set(:@shared_cache, nil)
      Card::Cache.instance_variable_set(:@cache_by_class, {})
    end
    Cardio.instance_variable_set(:@database, target)
    assert_isolated_cache!(conn: conn)
    target
  end
end
