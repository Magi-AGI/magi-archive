# frozen_string_literal: true

namespace :mirror_refresh do
  desc "Refuse a DB refresh unless the mirror is dormant and its tables are absent (SPEC 7.3)"
  task assert_precondition: :environment do
    MirrorRuntimeGuards.assert_refresh_precondition!
    puts "mirror refresh precondition holds"
  end

  desc "Write the STRICT filter manifest: ids and counts only, changes nothing (OUT=path)"
  task strict_manifest: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
    report = MirrorStrictFilter.manifest.to_h_report
    File.write(ENV.fetch("OUT"), JSON.pretty_generate(report))
    puts report.except(:excluded_ids, :attachment_card_ids).to_json
    abort "unresolved read rules: fix before any apply" if report[:unresolved_rule_ids].any?
  end

  desc "DESTRUCTIVE: apply the STRICT filter to a staged copy (CONFIRM_DB=<name of the live database>)"
  task strict_apply: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
    plan = MirrorStrictFilter.apply!(confirm_db: ENV.fetch("CONFIRM_DB"))
    puts plan.to_h_report.except(:excluded_ids, :attachment_card_ids).to_json
  end

  desc "Audit cached read rules against Decko's resolution; REPAIR=1 repairs and re-audits (SPEC 8.7)"
  task acl_audit: :environment do
    require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s
    result = MirrorAclAudit.audit
    puts result.to_h_report.to_json
    if ENV["REPAIR"] == "1" && result.mismatched_ids.any?
      MirrorAclAudit.repair!(result.mismatched_ids)
      result = MirrorAclAudit.audit
      puts result.to_h_report.to_json
    end
    abort "ACL cache audit is not clean; grant no AtomSpace scope" unless result.clean?
  end
end
