# frozen_string_literal: true

# Magi-specific runtime guards for the ported mirror. Both fail loudly rather than letting the mirror
# run in a state its invariants do not cover.
module MirrorRuntimeGuards
  class UnsafeRuntime < StandardError; end
  class RefreshPreconditionViolated < StandardError; end

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
  # dormant and its tables are absent (or dropped along with their schema_migrations rows).
  def assert_refresh_precondition!(enabled: MirrorOutboxWriter.enabled?, conn: ActiveRecord::Base.connection)
    raise RefreshPreconditionViolated, "ATOMSPACE_MIRRORING_ENABLED is set; disable the mirror first" if enabled

    present = MIRROR_TABLES.select { |t| conn.table_exists?(t) }
    return if present.empty?

    raise RefreshPreconditionViolated, "mirror tables still exist: #{present.join(', ')}"
  end
end
