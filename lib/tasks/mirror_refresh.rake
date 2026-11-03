# frozen_string_literal: true

namespace :mirror_refresh do
  desc "Refuse a DB refresh unless the mirror is dormant and its tables are absent (SPEC 7.3)"
  task assert_precondition: :environment do
    MirrorRuntimeGuards.assert_refresh_precondition!
    puts "mirror refresh precondition holds"
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
