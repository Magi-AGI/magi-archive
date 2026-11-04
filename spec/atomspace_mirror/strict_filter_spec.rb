# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s

# STRICT policy on real cards and real read rules (the DB is the disposable seeded test DB).
RSpec.describe MirrorStrictFilter do
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

  # Stale the denormalized cache without touching the effective rule (update_all skips callbacks).
  def stale_cache!(id, rule_id, rule_class = "*self")
    Card.where(id: id).update_all(read_rule_id: rule_id, read_rule_class: rule_class)
    Card::Cache.reset_all
  end

  def invoke_task(name, env = {})
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?(name)
    saved = env.keys.to_h { |k| [k, ENV[k]] }
    env.each { |k, v| ENV[k] = v }
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe "predicate B" do
    it "excludes a card readable solely by Administrator, solely by Nemquae, or by both" do
      ids = [locked("[[Administrator]]"), locked("[[Nemquae]]"), locked("[[Administrator]]\n[[Nemquae]]")]
      expect(described_class.manifest.read_locked_ids).to include(*ids)
    end

    it "keeps a card shared with another role" do
      shared = locked("[[Administrator]]\n[[Shark]]")
      expect(described_class.manifest.excluded_ids).not_to include(shared)
    end

    it "keeps a card readable by others and an ordinary public card" do
      other = locked("[[Shark]]")
      open_card = card(uniq("Open"))
      expect(described_class.manifest.excluded_ids).not_to include(other, open_card.id)
    end

    it "does not use content or names as the filter" do
      named = card(uniq("Administrator Nemquae"), "Administrator and Nemquae only")
      expect(described_class.manifest.excluded_ids).not_to include(named.id)
    end

    it "is not fooled by a write lock" do
      name = uniq("WriteLocked")
      made = card(name)
      bot { Card.create!(name: "#{name}+*self+*update", type: "List", content: "[[Administrator]]") }
      expect(described_class.manifest.excluded_ids).not_to include(made.id)
    end

    it "includes trashed locked cards" do
      id = locked("[[Administrator]]")
      bot { Card.fetch(id).delete! }
      expect(described_class.manifest.excluded_ids).to include(id)
    end
  end

  describe "predicate A" do
    let(:root) { Card["Administrator"] }

    it "excludes doc descendants even when their read rule names another principal" do
      doc = card("Administrator+#{uniq('Doc')}")
      grandchild = card("#{doc.name}+#{uniq('Sub')}")
      rule(doc.name, "[[Joe User]]")
      ids = described_class.manifest.ancestry_ids
      expect(ids).to include(doc.id, grandchild.id)
    end

    it "keeps the role and its authorization scaffolding" do
      members = Card["Administrator+*members"]
      plan = described_class.manifest
      expect(plan.excluded_ids).not_to include(root.id)
      expect(plan.excluded_ids).not_to include(members.id) if members
    end

    it "keeps the role's own read-rule scaffolding while excluding the doc tree it governs" do
      rule_card = rule("Administrator", "[[Joe User]]")
      doc = card("Administrator+#{uniq('Guarded')}")
      plan = described_class.manifest
      expect(plan.scaffold_ids).to include(rule_card.id)
      expect(plan.excluded_ids).not_to include(rule_card.id)
      expect(plan.excluded_ids).to include(doc.id)
    end
  end

  describe "the union and dependents" do
    it "unions both predicates and takes a locked card's children with it" do
      id = locked("[[Administrator]]")
      name = Card.fetch(id).name
      child = card("#{name}+#{uniq('Child')}")
      doc = card("Administrator+#{uniq('Doc')}")
      plan = described_class.manifest
      expect(plan.excluded_ids).to include(id, child.id, doc.id)
    end
  end

  describe "manifest safety" do
    it "reports ids and counts but no card content" do
      id = locked("[[Administrator]]")
      Card.where(id: id).update_all(db_content: "very-private-body")
      expect(described_class.manifest.to_h_report.to_json).not_to include("very-private-body")
    end

    it "changes nothing" do
      locked("[[Administrator]]")
      expect { described_class.manifest }.not_to(change { Card.count })
    end

    it "never excludes a codenamed system card, and reports it" do
      id = locked("[[Administrator]]")
      Card.where(id: id).update_all(codename: "test_system_#{SecureRandom.hex(3)}")
      plan = described_class.manifest
      expect(plan.excluded_ids).not_to include(id)
      expect(plan.protected_system_ids).to include(id)
    end

    it "reports a rule it cannot resolve instead of treating it as harmless" do
      id = card(uniq("Broken")).id
      Card.where(id: id).update_all(read_rule_id: 999_999_999)
      expect(described_class.manifest.unresolved_rule_ids).to include(999_999_999)
    end
  end

  describe "S-1 fidelity: selection must not trust a stale read-rule cache" do
    it "classifies by the effective read rule, not by a stale cached rule id" do
      decoy = uniq("Decoy")
      card(decoy)
      decoy_rule = rule(decoy, "[[Shark]]")
      id = locked("[[Administrator]]")
      stale_cache!(id, decoy_rule.id)
      expect(described_class.manifest.excluded_ids).to include(id)
    end

    it "reports stale cached rows instead of classifying them silently" do
      id = locked("[[Administrator]]")
      stale_cache!(id, nil, nil)
      expect(described_class.manifest.stale_read_cache_ids).to include(id)
    end

    it "refuses to select against an unaudited cache" do
      id = locked("[[Administrator]]")
      stale_cache!(id, nil, nil)
      expect { described_class.assert_audited_read_cache! }
        .to raise_error(described_class::Refused, /not audited/)
    end

    it "audits trashed rows by default, matching the scope selection covers" do
      expect(MirrorAclAudit.audit.checked).to eq(Card.where(trash: [false, true]).count)
    end

    it "separates a trashed row's unrepairable divergence from a live stale cache" do
      # A trashed card's rule card is trashed with it, so Decko resolves the deck default while the
      # cache keeps the real rule: no repair can make them agree. That must not read as an unaudited
      # cache, or apply! would refuse forever -- but it must still be reported, and the card must
      # still be excluded via its own +*self+*read.
      id = locked("[[Administrator]]")
      bot { Card.fetch(id).delete! }
      plan = described_class.manifest
      expect(plan.stale_read_cache_ids).not_to include(id)
      expect(plan.trashed_cache_divergence_ids).to include(id)
      expect(plan.excluded_ids).to include(id)
      audit = MirrorAclAudit.audit
      expect(audit.mismatched_ids).not_to include(id)
      expect(audit.trashed_divergence_ids).to include(id)
    end
  end

  describe "S-2 fidelity: NULL cached read rules are classified, not dropped" do
    it "excludes a NULL-cached card whose effective read rule is Admin-only" do
      id = locked("[[Administrator]]")
      stale_cache!(id, nil, nil)
      expect(described_class.manifest.read_locked_ids).to include(id)
    end

    it "reports a non-silent count of NULL-cached rows" do
      id = locked("[[Administrator]]")
      stale_cache!(id, nil, nil)
      report = described_class.manifest.to_h_report
      expect(report[:null_read_cache]).to be >= 1
      expect(report[:null_read_cache_ids]).to include(id)
    end
  end

  describe "S-3 fidelity: unresolved classifications are refused, not guessed" do
    it "distinguishes an absent rule card from a failed resolution" do
      expect(described_class.rule_principals(999_999_999)).to eq([:absent, nil])
    end

    it "reports a raised resolution as an error, never as an absent rule" do
      allow(Card).to receive(:fetch).and_raise(RuntimeError)
      expect(described_class.rule_principals(1)).to eq([:error, "RuntimeError"])
    end

    it "keeps a failed resolution out of the absent-rule bucket" do
      id = card(uniq("Broken")).id
      stale_cache!(id, 999_999_999)
      plan = described_class.manifest
      expect(plan.unresolved_rule_ids).to include(999_999_999)
      expect(plan.unresolved_rule_errors).to eq({})
    end
  end

  describe "S-4 fidelity: dependent closure covers type and read-rule references" do
    it "takes the instances of an excluded type with it and leaves no dangling type reference" do
      type_name = uniq("LockedType")
      type_card = bot { Card.create!(name: type_name, type: "Cardtype") }
      rule(type_name, "[[Administrator]]")
      instance = bot { Card.create!(name: uniq("Inst"), type_id: type_card.id, content: "y") }
      plan = described_class.manifest
      expect(plan.excluded_ids).to include(type_card.id, instance.id)
      expect(plan.dangling_type_ids).to be_empty
    end

    it "reports zero dangling type and read-rule references for an ordinary plan" do
      locked("[[Administrator]]")
      plan = described_class.manifest
      expect(plan.dangling_type_ids).to eq([])
      expect(plan.dangling_read_rule_ids).to eq([])
    end
  end

  describe "S-5 fidelity: codenamed candidates are reported, never silently retained" do
    it "names the codename of every protected candidate so it can be dispositioned" do
      id = locked("[[Administrator]]")
      codename = "test_system_#{SecureRandom.hex(3)}"
      Card.where(id: id).update_all(codename: codename)
      Card::Cache.reset_all
      expect(described_class.manifest.protected_system_codenames).to include(id => codename)
    end
  end

  describe "S-6 fidelity: scaffolding retention is an enumerated ACL/role rule" do
    it "excludes an all-asterisk chain that is not authorization scaffolding" do
      help = card("Administrator+*help")
      plan = described_class.manifest
      expect(plan.scaffold_ids).not_to include(help.id)
      expect(plan.excluded_ids).to include(help.id)
    end

    it "retains the enumerated ACL settings under the root" do
      members = Card["Administrator+*members"]
      skip "deck has no Administrator+*members" unless members
      expect(described_class.manifest.scaffold_ids).to include(members.id)
    end

    it "refuses to treat a documentation-typed card as scaffolding" do
      # Card 188 is a real enumerated scaffold card (Administrator+*self+*update). Retype it to a
      # documentation type in place: creating Administrator+*roles fails List validation, and the
      # point of the test is the TYPE gate, not the name.
      scaffold_id = described_class.manifest.scaffold_ids.first
      skip "deck has no retained scaffolding under the root" unless scaffold_id
      Card.where(id: scaffold_id).update_all(type_id: Card.where(key: "rich_text").pick(:id))
      Card::Cache.reset_all
      plan = described_class.manifest
      expect(plan.scaffold_ids).not_to include(scaffold_id)
      expect(plan.excluded_ids).to include(scaffold_id)
    end

    it "is not fooled by Decko singularizing a setting key" do
      # cards.key for the `members` setting is the SINGULAR "*member"; matching on key instead of
      # codename would drop real scaffolding (or, with a plural list, retain prod docs).
      members = Card["Administrator+*members"]
      skip "deck has no Administrator+*members" unless members
      expect(Card.where(id: members.right_id).pick(:key)).to eq("*member")
      expect(Card.where(id: members.right_id).pick(:codename)).to eq("members")
      expect(described_class.manifest.scaffold_ids).to include(members.id)
    end

    it "does not retain a *-suffix chain whose setting has no codename" do
      # An unknown/codename-less setting must fail CLOSED: scaffold is subtracted from the exclusion
      # set, so a permissive answer here silently retains prod data.
      setting = bot { Card.create!(name: "*uncodenamed_setting_#{SecureRandom.hex(3)}", type: "Set") }
      anchored = card("Administrator+#{setting.name}")
      Card.where(id: anchored.id).update_all(type_id: Card.where(key: "list").pick(:id))
      Card::Cache.reset_all
      plan = described_class.manifest
      expect(plan.scaffold_ids).not_to include(anchored.id)
      expect(plan.excluded_ids).to include(anchored.id)
    end
  end

  describe "S-7 fidelity: principal comparison is key-normalized" do
    it "excludes a card whose read rule names administrator in lower case" do
      # The card must exist BEFORE the manifest runs: Ruby evaluates the receiver of #to first, so
      # expect(manifest...).to include(locked(...)) would select against a DB without the card.
      id = locked("[[administrator]]")
      expect(described_class.manifest.excluded_ids).to include(id)
    end

    it "excludes a card whose read rule uses an underscore name variant" do
      id = locked("[[nemquae]]")
      expect(described_class.manifest.excluded_ids).to include(id)
    end

    it "still keeps a card shared with a lower-case third party" do
      id = locked("[[administrator]]\n[[shark]]")
      expect(described_class.manifest.excluded_ids).not_to include(id)
    end

    it "reports a disagreement between the cached and effective verdicts instead of hiding it" do
      # Trashing a locked card collapses its EFFECTIVE rule to the deck default while its own
      # +*self+*read still names Administrator: the two resolutions disagree, the union keeps the
      # card excluded, and the disagreement is reported rather than silently reconciled.
      id = locked("[[Administrator]]")
      bot { Card.fetch(id).delete! }
      plan = described_class.manifest
      expect(plan.excluded_ids).to include(id)
      expect(plan.verdict_disagreement_ids).to include(id)
      expect(plan.to_h_report[:verdict_disagreement]).to be >= 1
    end
  end

  describe "apply!" do
    def drop_mirror
      MirrorRuntimeGuards::MIRROR_TABLES.each { |t| conn.drop_table(t, force: :cascade) }
    end

    around do |ex|
      saved = ENV.delete("ATOMSPACE_MIRRORING_ENABLED")
      ex.run
      ENV["ATOMSPACE_MIRRORING_ENABLED"] = saved if saved
    end

    it "refuses a wrong database confirmation" do
      expect { described_class.apply!(confirm_db: "not-this-db") }.to raise_error(described_class::Refused, /does not match/)
    end

    it "refuses while mirror tables exist" do
      expect { described_class.apply!(confirm_db: conn.current_database) }
        .to raise_error(MirrorRuntimeGuards::RefreshPreconditionViolated)
    end

    it "refuses with unresolved rules" do
      Card.where(id: card(uniq("Broken")).id).update_all(read_rule_id: 999_999_999)
      drop_mirror
      expect { described_class.apply!(confirm_db: conn.current_database) }
        .to raise_error(described_class::Refused, /unresolved/)
    end

    it "S-3: strict_apply refuses unresolved rules the way strict_manifest does" do
      Card.where(id: card(uniq("Broken")).id).update_all(read_rule_id: 999_999_999)
      Card::Cache.reset_all
      drop_mirror
      expect { invoke_task("mirror_refresh:strict_apply", "CONFIRM_DB" => conn.current_database) }
        .to raise_error(SystemExit)
    end

    it "S-1: apply! refuses an unaudited read-rule cache" do
      id = locked("[[Administrator]]")
      stale_cache!(id, nil, nil)
      drop_mirror
      expect { described_class.apply!(confirm_db: conn.current_database) }
        .to raise_error(described_class::Refused, /not audited/)
    end

    it "S-4: apply! refuses a plan that would leave a dangling reference" do
      id = locked("[[Administrator]]")
      keeper = card(uniq("Keeper"))
      allow(described_class).to receive(:dependents_of).and_return([])
      Card.where(id: keeper.id).update_all(type_id: id)
      Card::Cache.reset_all
      drop_mirror
      expect { described_class.apply!(confirm_db: conn.current_database) }
        .to raise_error(described_class::Refused, /dangling/)
    end

    it "removes excluded cards with their history and references, and keeps everything else" do
      id = locked("[[Administrator]]")
      keeper = card(uniq("Keeper"))
      linker = card(uniq("Linker"), "see [[#{Card.fetch(id).name}]] and [[#{keeper.name}]]")
      doc = card("Administrator+#{uniq('Doc')}")
      root_id = Card["Administrator"].id
      action_ids = Card::Action.where(card_id: id).pluck(:id)
      expect(action_ids).not_to be_empty
      expect(conn.select_value("SELECT COUNT(*) FROM card_references WHERE referee_id = #{id}").to_i).to be >= 1

      drop_mirror
      described_class.apply!(confirm_db: conn.current_database)

      expect(Card.where(id: [id, doc.id])).to be_empty
      expect(Card.where(id: [keeper.id, linker.id, root_id]).count).to eq(3)
      expect(Card::Action.where(id: action_ids)).to be_empty
      expect(conn.select_value("SELECT COUNT(*) FROM card_changes WHERE card_action_id IN (#{action_ids.join(',')})").to_i).to eq(0)
      expect(conn.select_value("SELECT COUNT(*) FROM card_references WHERE referee_id = #{id} OR referer_id = #{id}").to_i).to eq(0)
      expect(conn.select_value("SELECT COUNT(*) FROM card_references WHERE referee_id = #{keeper.id}").to_i).to be >= 1
      expect(Card::Action.where(card_id: keeper.id)).to exist
      expect(described_class.manifest.read_locked_ids).not_to include(id)
    end
  end
end
