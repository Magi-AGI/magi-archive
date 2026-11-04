# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_runtime_guards").to_s

# R3 stage-ordering regression (Defect 2).
#
# The defect: R3.sh ran `REPAIR=1 mirror_refresh:acl_audit` AFTER strict_manifest / strict_apply.
# MirrorStrictFilter.assert_audited_read_cache! fails CLOSED on a stale live read-rule cache, and a
# pg_restore leaves cards.read_rule_id stale, so a legitimate staged dump aborted at selection and
# the repair that would have fixed it never ran.
#
# These examples assert the ORDER as a property of the data, driving the same real code the stages
# drive: repair-then-select succeeds, select-then-repair aborts, and a genuinely unaudited cache
# still aborts (the negative case -- the fail-closed guard must not have been weakened).
RSpec.describe "R3 ACL cache repair/audit stage ordering" do
  def bot(&block) = Card::Auth.as_bot(&block)
  def uniq(prefix) = "#{prefix} #{SecureRandom.hex(4)}"
  def rule(name, readers) = bot { Card.create!(name: "#{name}+*self+*read", type: "List", content: readers) }
  def card(name, content = "x") = bot { Card.create!(name: name, type: "Basic", content: content) }

  let(:conn) { ActiveRecord::Base.connection }

  before do
    Card::Cache.reset_all
    bot { Card.create!(name: "Nemquae", type: "User") } unless Card["Nemquae"]
  end

  after { Card::Cache.reset_all }

  def locked(readers)
    name = uniq("Locked")
    made = card(name)
    rule(name, readers)
    Card.where(id: made.id).pick(:id)
  end

  # What a pg_restore of a prod dump leaves behind: the row's denormalized read_rule_id disagrees
  # with what Decko resolves. update_all skips callbacks, so the effective rule is untouched.
  def restore_staleness!(id, rule_id = nil, rule_class = nil)
    Card.where(id: id).update_all(read_rule_id: rule_id, read_rule_class: rule_class)
    Card::Cache.reset_all
  end

  # The two orderings, as the stages run them.
  def stage_repair!
    result = MirrorAclAudit.audit
    MirrorAclAudit.repair!(result.repair_ids) if result.repair_ids.any?
    MirrorAclAudit.audit
  end

  def stage_select!
    MirrorStrictFilter.assert_audited_read_cache!
  end

  describe "the OLD order (manifest/apply before repair) is what broke" do
    it "aborts selection on a freshly restored, un-repaired staged dump" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)

      # Selection first == the old R3.sh:25-27 order. This is the abort the ordering defect caused.
      expect { stage_select! }
        .to raise_error(MirrorStrictFilter::Refused, /read-rule cache is not audited/)
    end

    it "names the repair command the operator must run first" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      expect { stage_select! }
        .to raise_error(MirrorStrictFilter::Refused, /REPAIR=1 mirror_refresh:acl_audit/)
    end
  end

  describe "the NEW order (repair/audit before manifest/apply) lets a legitimate dump through" do
    it "passes selection after the repair stage has run" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      expect { stage_select! }.to raise_error(MirrorStrictFilter::Refused)

      audit = stage_repair!

      # The repair stage cleaned the live staleness, so selection now proceeds.
      expect(audit.mismatched_ids).not_to include(id)
      expect { stage_select! }.not_to raise_error
      expect(MirrorStrictFilter.manifest.stale_read_cache_ids).to be_empty
    end

    it "still selects the card the locked policy excludes (repair did not change the verdict)" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      stage_repair!
      # The ordering fix must not change WHAT is selected, only whether selection is allowed to run.
      expect(MirrorStrictFilter.manifest.excluded_ids).to include(id)
    end

    it "lets manifest and apply run in sequence on the repaired staged copy" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      stage_repair!
      plan = MirrorStrictFilter.manifest
      # apply! re-asserts the same gate internally; proving the gate is satisfied is the contract
      # here (apply! itself also demands a dormant mirror, which this seeded DB does not provide).
      expect { MirrorStrictFilter.assert_audited_read_cache!(plan: plan) }.not_to raise_error
      expect(plan.stale_read_cache_ids).to be_empty
    end

    it "is idempotent: repairing a clean cache repairs nothing and stays clean" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      first = stage_repair!
      expect(first.repair_ids).to be_empty
      second = stage_repair!
      expect(second.repair_ids).to be_empty
      expect(second.mismatched_ids).to be_empty
      expect { stage_select! }.not_to raise_error
    end
  end

  describe "NEGATIVE case: the fail-closed guard was not weakened" do
    it "STILL aborts when the cache is genuinely unaudited and no repair ran" do
      id = locked("[[Administrator]]")
      restore_staleness!(id, nil, nil)
      # No stage_repair! here. The guard must still refuse.
      expect { stage_select! }
        .to raise_error(MirrorStrictFilter::Refused, /read-rule cache is not audited/)
      expect(MirrorStrictFilter.manifest.stale_read_cache_ids).to include(id)
    end

    it "STILL aborts when staleness is reintroduced after a clean audit" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      stage_repair!
      expect { stage_select! }.not_to raise_error

      # Something re-stales the row after the audit (a late restore, a manual write). Reordering must
      # not have made the gate a one-time check.
      other = locked("[[Administrator]]")
      restore_staleness!(other, nil, nil)
      expect { stage_select! }
        .to raise_error(MirrorStrictFilter::Refused, /read-rule cache is not audited/)
    end

    it "reports the offending ids rather than aborting blind" do
      id = locked("[[Administrator]]")
      restore_staleness!(id, nil, nil)
      expect { stage_select! }.to raise_error(MirrorStrictFilter::Refused, /#{id}/)
    end
  end

  describe "ordering is coherent with the cache-isolation guard (Defect 1 + Defect 2 together)" do
    it "the repair stage runs under an isolated cache" do
      id = locked("[[Administrator]]")
      restore_staleness!(id)
      # Both guards hold simultaneously: the stage isolates its cache, then repairs, then selects.
      MirrorRuntimeGuards.isolate_cache!
      expect(MirrorRuntimeGuards.cache_isolated?).to be true
      stage_repair!
      expect { stage_select! }.not_to raise_error
    end
  end
end
