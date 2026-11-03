# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s

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
