# frozen_string_literal: true

namespace :mirror_refresh do
  # G-CACHE. Cardio.database comes from database.yml, so DATABASE_URL moves the connection but NOT the
  # Rails cache namespace: a staged stage would otherwise read and write the LIVE deck's shared cache.
  # Every stage that may be pointed at a staged copy isolates its own cache first and says so, instead
  # of trusting the caller to have exported NO_RAILS_CACHE.
  def isolate_refresh_cache!
    # Layer one is the pre-boot guard in the deck Rakefile, which sets NO_RAILS_CACHE before
    # config/application is required, so initialization itself never touches the live shared store.
    # Reported here because only the task body can emit it, and the ordering is the safety property:
    # shared_cache_at_boot=off means the cache was already disabled when Decko finished booting,
    # i.e. BEFORE this helper ran. Layer two is everything below.
    at_boot = MirrorRuntimeGuards.shared_cache_live? ? "on" : "off"
    ns_at_boot = MirrorRuntimeGuards.cache_namespace_database
    preboot = ENV.fetch("MIRROR_REFRESH_PREBOOT_CACHE_GUARD", "absent")
    ns = MirrorRuntimeGuards.isolate_cache!
    puts "cache isolated: shared_cache=#{MirrorRuntimeGuards.shared_cache_live? ? 'on' : 'off'} " \
         "namespace_db=#{ns} connected_db=#{MirrorRuntimeGuards.connected_database} " \
         "shared_cache_at_boot=#{at_boot} namespace_db_at_boot=#{ns_at_boot} preboot_guard=#{preboot}"
  end

  desc "Refuse a DB refresh unless the mirror is dormant and its tables are absent (SPEC 7.3)"
  task assert_precondition: :environment do
    isolate_refresh_cache!
    MirrorRuntimeGuards.assert_refresh_precondition!
    puts "mirror refresh precondition holds"
  end

  desc "Write the STRICT filter manifest: ids and counts only, changes nothing (OUT=path)"
  task strict_manifest: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
    isolate_refresh_cache!
    plan = MirrorStrictFilter.manifest
    report = plan.to_h_report
    File.write(ENV.fetch("OUT"), JSON.pretty_generate(report))
    puts report.except(:excluded_ids, :attachment_card_ids).to_json
    # S-1/S-3/S-4/S-5: every refusal the apply path enforces is reported here first, so the manifest
    # never reads as a clean plan that apply would then reject.
    abort "unresolved read rules: fix before any apply" if plan.unresolved?
    abort "read-rule cache is not audited (#{plan.stale_read_cache_ids.size} stale); run " \
          "REPAIR=1 mirror_refresh:acl_audit before selection" if plan.stale_read_cache_ids.any?
    abort "dangling references would survive: fix before any apply" if plan.dangling?
    abort "scaffolding conflict: #{plan.scaffold_conflict_ids.join(',')}" if plan.scaffold_conflict_ids.any?
    # S-7: a cached/effective/self-rule disagreement is reported, never silently reconciled. The union
    # already failed closed, so this is a loud warning rather than a refusal.
    if plan.verdict_disagreement_ids.any?
      warn "read-rule verdict disagreement on #{plan.verdict_disagreement_ids.size} cards " \
           "(#{plan.verdict_disagreement_ids.first(20).join(',')}); the union kept them excluded"
    end
    if plan.protected_system_ids.any?
      abort "protected system cards match the exclusion policy: " \
            "#{plan.protected_system_codenames.inspect}; set ACK_PROTECTED to those ids to accept"
    end
  end

  desc "DESTRUCTIVE: apply the STRICT filter to a staged copy (CONFIRM_DB=<name of the live database>)"
  task strict_apply: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
    isolate_refresh_cache!
    ack = ENV["ACK_PROTECTED"].to_s.split(/[,\s]+/).reject(&:empty?).map(&:to_i)
    # S-3: the unresolved-rule refusal is binding on apply, not only on the manifest. MirrorStrictFilter
    # raises Refused; the task turns it into a non-zero exit so the runner stage stops.
    begin
      plan = MirrorStrictFilter.apply!(confirm_db: ENV.fetch("CONFIRM_DB"), ack_protected: ack)
    rescue MirrorStrictFilter::Refused => e
      abort "STRICT apply refused: #{e.message}"
    end
    puts plan.to_h_report.except(:excluded_ids, :attachment_card_ids).to_json
  end

  desc "Audit cached read rules against Decko's resolution; REPAIR=1 repairs and re-audits (SPEC 8.7)"
  task acl_audit: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s
    isolate_refresh_cache!
    result = MirrorAclAudit.audit
    puts result.to_h_report.to_json
    if ENV["REPAIR"] == "1" && result.repair_ids.any?
      MirrorAclAudit.repair!(result.repair_ids)
      result = MirrorAclAudit.audit
      puts result.to_h_report.to_json
    end
    abort "ACL cache audit is not clean; grant no AtomSpace scope" unless result.clean?
  end
end
