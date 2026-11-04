# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s

# The persisted shape behind the R3 audit failure on dev and staged (logs/impl9/p27_first_placeholder.log):
#
#   8097  live     left 8095, right 8115
#   8116  TRASHED  left 8095, right 8115        <- same left and right as 8097: a trashed twin
#   ...   trashed  left 8116                    <- reading its name resolves the twin by id
#   8118  live     left 8097, its own read rule
#   9749  live     8118+*self
#   9750  live     8118+*self+*read
#
# Card::Lexicon.id_to_lex stores lex => id with no trash check, so scanning the twin's child points the live card's
# lex at the trashed twin. Every by-name lookup under it then misses, and Fetch caches a new-card placeholder for a
# real card, which lasts until a temporary cache hits MAX_KEYS. The shape alone is harmless: it takes the scan history
# to go wrong, which is why these specs run scans, and why they repeat them.
RSpec.describe "read rule resolution depends on persisted data alone" do
  Shape = Struct.new(:live, :twin, :twin_child, :child, :set, :rule, :field, keyword_init: true) do
    def ids = to_h.values
  end

  def bot(&block) = Card::Auth.as_bot(&block)
  def uniq(prefix) = "#{prefix} #{SecureRandom.hex(4)}"
  def make(name, content = "x") = Card.create!(name: name, type: "Basic", content: content)
  def columns(id) = Card.where(id: id).pick(:read_rule_id, :read_rule_class)
  def open_rule_id = bot { Card.fetch("*all+*read").id }

  before { Card::Cache.reset_all }
  after { Card::Cache.reset_all }

  # twin_first: the trashed row has the lower id, as 3512/3513 do on dev. Otherwise it has the higher id, as 8116/8097 do.
  def build_shape(readers: "[[Administrator]]", twin_first: false)
    shape = bot do
      root = make(uniq("Twin Root")).name
      crew = make(uniq("Crew")).name
      field_part = make(uniq("Backstory"))
      twin = make("#{uniq('Twin Source')}+#{uniq('Part')}") if twin_first
      live = make("#{root}+#{crew}")
      twin ||= make("#{uniq('Twin Source')}+#{uniq('Part')}")
      twin.update_columns(left_id: live.left_id, right_id: live.right_id, trash: true)
      twin_child = make("#{uniq('Twin Source')}+#{uniq('Part')}")
      twin_child.update_columns(left_id: twin.id, right_id: field_part.id, trash: true)
      Card::Cache.reset_all

      child = make("#{root}+#{crew}+#{field_part.name}")
      rule = Card.create!(name: "#{child.name}+*self+*read", type: "List", content: readers)
      set = Card.fetch("#{child.name}+*self")
      field = make("#{child.name}+#{uniq('Field')}")
      Shape.new(live: live.id, twin: twin.id, twin_child: twin_child.id, child: child.id, set: set.id,
                rule: rule.id, field: field.id)
    end
    Card::Cache.reset_all
    shape
  end

  def shape_scope(shape) = Card.where(id: shape.ids)

  # Leaves the caller's caches the way a scan over the twin's rows does.
  def poison_real_caches!(shape)
    bot do
      Card::Lexicon.name(shape.twin)
      name = Card::Lexicon.name(shape.child)
      Card.fetch(name, skip_modules: true, new: {})
      Card.fetch("#{name}+*self", skip_modules: true, new: {})
    end
  end

  # A real shared store, the way a deck outside the test environment has one. MemoryStore marshals what it is given.
  def with_shared_store
    store = ActiveSupport::Cache::MemoryStore.new
    saved = %i[@shared_cache @cache_by_class].to_h { |iv| [iv, Card::Cache.instance_variable_get(iv)] }
    saved_cardio = Cardio.instance_variable_get(:@cache)
    Cardio.instance_variable_set(:@cache, store)
    Card::Cache.instance_variable_set(:@shared_cache, store)
    Card::Cache.instance_variable_set(:@cache_by_class, {})
    yield store
  ensure
    saved&.each { |iv, value| Card::Cache.instance_variable_set(iv, value) }
    Cardio.instance_variable_set(:@cache, saved_cardio)
  end

  def isolated_like_the_rake_task
    saved_env = ENV["NO_RAILS_CACHE"]
    saved_db = Cardio.instance_variable_get(:@database)
    saved = %i[@shared_cache @cache_by_class].to_h { |iv| [iv, Card::Cache.instance_variable_get(iv)] }
    MirrorRuntimeGuards.isolate_cache!
    yield
  ensure
    saved_env.nil? ? ENV.delete("NO_RAILS_CACHE") : ENV["NO_RAILS_CACHE"] = saved_env
    Cardio.instance_variable_set(:@database, saved_db)
    saved&.each { |iv, value| Card::Cache.instance_variable_set(iv, value) }
  end

  describe MirrorReadRuleResolver do
    it "cold! drops cached cards and lex => id entries, and keeps what restates one row" do
      described_class.isolated do
        bot { Card.fetch("*all+*read") }
        Card::Rule.rule_cache
        rules = Card.cache.temp.read("RULES")
        lexicon = Card::Lexicon.cache.temp
        lexicon.write("L-1-2", 999, callback: false)
        lexicon.write("999", "A Name", callback: false)

        described_class.cold!

        expect(lexicon.exist?("L-1-2")).to be(false)
        expect(lexicon.read("999")).to eq("A Name")
        expect(Card.cache.temp.exist?(Card::Name["*all+*read"].key)).to be(false)
        expect(Card.cache.temp.read("RULES")).to equal(rules)
      end
    end

    it "isolated hands back the caller's cache objects, even when the block raises" do
      cache = Card::Cache[Card]
      expect { described_class.isolated { raise "boom" } }.to raise_error("boom")
      expect(Card::Cache[Card]).to equal(cache)
    end

    it "isolated has no shared store to read, whatever the caller has" do
      with_shared_store do
        expect(Card::Cache[Card].shared).not_to be_nil
        described_class.isolated { expect(Card::Cache[Card].shared).to be_nil }
        expect(Card::Cache[Card].shared).not_to be_nil
      end
    end
  end

  describe "canonical columns for the self-referential shape" do
    let(:shape) { build_shape }

    # permissions.rb:1-5, Decko's own set_read_rule event, stored these. They are what the audit has to agree with.
    it "stores the X+*self+*read rule's id on X, on X+*self and on the rule itself" do
      expect(columns(shape.child)).to eq([shape.rule, "*self"])
      expect(columns(shape.set)).to eq([shape.rule, "*all plus"])
      expect(columns(shape.rule)).to eq([shape.rule, "*all plus"])
    end

    it "stores the same rule on a field that inherits from X through _left" do
      expect(columns(shape.field)).to eq([shape.rule, "*all plus"])
    end

    it "resolves each row to its stored columns from a cold cache" do
      [shape.child, shape.set, shape.rule, shape.field].each do |id|
        card = Card.where(id: id).take
        resolved = bot { MirrorAclAudit.audit(scope: Card.where(id: id)) }
        expect(resolved.mismatched_ids).to eq([]), "row #{id}"
        expect(columns(id)).to eq(columns(card.id))
      end
    end
  end

  describe "MirrorAclAudit" do
    let(:shape) { build_shape }
    let(:report_keys) { %i[checked mismatched stale_fetch errors mismatched_ids stale_fetch_ids error_ids] }

    def verdict(scope) = MirrorAclAudit.audit(scope: scope).to_h_report.slice(*report_keys)

    it "is clean on the shape when the scan walks the trashed twin's rows first" do
      report = MirrorAclAudit.audit(scope: shape_scope(shape))
      expect(report.checked).to eq(shape.ids.size)
      expect(report.mismatched_ids).to eq([])
      expect(report.stale_fetch_ids).to eq([])
      expect(report).to be_clean
    end

    it "is clean on the shape with the trashed twin's id below the live card's" do
      twin_first = build_shape(twin_first: true)
      expect(twin_first.twin).to be < twin_first.live
      expect(MirrorAclAudit.audit(scope: shape_scope(twin_first))).to be_clean
    end

    it "gives the same verdict on every repeated scan in one process" do
      scope = shape_scope(shape)
      verdicts = Array.new(4) { verdict(scope) }
      expect(verdicts.uniq.size).to eq(1)
      expect(verdicts.first[:mismatched]).to eq(0)
      expect(verdicts.first[:stale_fetch]).to eq(0)
    end

    it "gives the same verdict on a full scan of the database, repeatedly" do
      id_list = shape.ids
      first = MirrorAclAudit.audit
      second = MirrorAclAudit.audit
      expect(first.mismatched_ids & id_list).to eq([])
      expect(first.stale_fetch_ids & id_list).to eq([])
      expect(second.to_h_report).to eq(first.to_h_report)
    end

    # Where a temporary cache evicts is what moved the verdict around on dev. These sizes put an eviction at different
    # points relative to the twin and the rows under it.
    [3, 7, 11, 20, 50, 200, 1000, 10_000].each do |max_keys|
      it "gives the same clean verdict when temporary caches evict at #{max_keys} keys" do
        scope = shape_scope(shape)
        stub_const("Card::Cache::Temporary::MAX_KEYS", max_keys)
        verdicts = Array.new(2) { verdict(scope) }
        expect(verdicts.uniq.size).to eq(1)
        expect(verdicts.first).to include(mismatched: 0, stale_fetch: 0, errors: 0)
      end
    end

    it "is not moved by what the caller's caches already hold" do
      poison_real_caches!(shape)
      expect(MirrorAclAudit.audit(scope: shape_scope(shape))).to be_clean
    end

    it "is not moved by a wrong rule cache in the caller's caches" do
      scope = shape_scope(shape)
      Card.cache.write("RULES", {})
      expect(MirrorAclAudit.audit(scope: scope)).to be_clean
      Card::Rule.clear_rule_cache
      expect(MirrorAclAudit.audit(scope: scope)).to be_clean
      Card::Rule.rule_cache
      expect(MirrorAclAudit.audit(scope: scope)).to be_clean
    end

    it "leaves the caller's caches exactly as it found them" do
      scope = shape_scope(shape)
      cache = Card::Cache[Card]
      lexicon = Card::Cache[Card::Lexicon]
      bot { Card.fetch("*all+*read") }
      keys = cache.temp.store.keys
      lex_keys = lexicon.temp.store.keys
      MirrorAclAudit.audit(scope: scope)
      expect(Card::Cache[Card]).to equal(cache)
      expect(Card::Cache[Card::Lexicon]).to equal(lexicon)
      expect(cache.temp.store.keys).to eq(keys)
      expect(lexicon.temp.store.keys).to eq(lex_keys)
    end

    it "gives the same verdict through the rake task's isolate_cache! and the plain path" do
      scope = shape_scope(shape)
      plain = verdict(scope)
      isolated = isolated_like_the_rake_task { verdict(scope) }
      shared = with_shared_store { verdict(scope) }
      expect(isolated).to eq(plain)
      expect(shared).to eq(plain)
      expect(plain).to include(mismatched: 0, stale_fetch: 0, errors: 0)
    end

    describe "a genuinely wrong read cache is still caught (N-9, SPEC 8.7)" do
      it "flags a live row whose cached rule is wrong" do
        Card.where(id: shape.child).update_all(read_rule_id: open_rule_id)
        report = MirrorAclAudit.audit(scope: shape_scope(shape))
        expect(report.mismatched_ids).to eq([shape.child])
        expect(report).not_to be_clean
      end

      it "flags a live row whose cached rule class alone is wrong" do
        Card.where(id: shape.set).update_all(read_rule_class: "*self")
        expect(MirrorAclAudit.audit(scope: shape_scope(shape)).mismatched_ids).to eq([shape.set])
      end

      it "flags a live row whose cached rule is NULL" do
        Card.where(id: shape.rule).update_all(read_rule_id: nil, read_rule_class: nil)
        expect(MirrorAclAudit.audit(scope: shape_scope(shape)).mismatched_ids).to eq([shape.rule])
      end

      # The dangerous direction. The poisoned lookup drops the *self rule, so Decko appears to resolve the open deck
      # default, which is exactly what this stale column says: the old audit passed a card it should have failed.
      it "flags a stale open rule on a field under the twin, which a poisoned lookup would call correct" do
        Card.where(id: shape.field).update_all(read_rule_id: open_rule_id, read_rule_class: "*all plus")
        report = MirrorAclAudit.audit(scope: shape_scope(shape))
        expect(report.mismatched_ids).to eq([shape.field])
        expect(report).not_to be_clean
      end

      it "repairs to the canonical columns, whatever the caller's caches hold" do
        corrupted = [shape.child, shape.set, shape.rule, shape.field]
        Card.where(id: corrupted).update_all(read_rule_id: open_rule_id, read_rule_class: "*all")
        scope = shape_scope(shape)
        report = MirrorAclAudit.audit(scope: scope)
        expect(report.mismatched_ids).to match_array(corrupted)

        poison_real_caches!(shape)
        expect { MirrorAclAudit.repair!(report.repair_ids) }.not_to(change { Card::Action.count })

        expect(columns(shape.child)).to eq([shape.rule, "*self"])
        expect(columns(shape.set)).to eq([shape.rule, "*all plus"])
        expect(columns(shape.rule)).to eq([shape.rule, "*all plus"])
        expect(columns(shape.field)).to eq([shape.rule, "*all plus"])
        expect(MirrorAclAudit.audit(scope: scope)).to be_clean
      end

      it "is a fixed point: repairing nothing changes nothing" do
        before = shape.ids.to_h { |id| [id, columns(id)] }
        scope = shape_scope(shape)
        MirrorAclAudit.repair!(MirrorAclAudit.audit(scope: scope).repair_ids)
        MirrorAclAudit.repair!(shape.ids - [shape.twin, shape.twin_child])
        expect(shape.ids.to_h { |id| [id, columns(id)] }).to eq(before)
      end
    end

    describe "the copy a shared cache would serve (dev evidence: logs/impl5/acl_repair.log)" do
      def stale_copy_in_store!(card_id)
        real = columns(card_id)
        Card.where(id: card_id).update_all(read_rule_id: open_rule_id, read_rule_class: "*all plus")
        Card::Cache.reset_temp
        bot { Card.fetch(card_id, skip_modules: true) }
        Card.where(id: card_id).update_all(read_rule_id: real.first, read_rule_class: real.last)
        Card::Cache.reset_temp
      end

      it "reports what the store holds, and says it could look" do
        with_shared_store do
          scope = Card.where(id: shape.child)
          stale_copy_in_store!(shape.child)
          report = MirrorAclAudit.audit(scope: scope)
          expect(report.mismatched_ids).to eq([])
          expect(report.stale_fetch_ids).to eq([shape.child])
          expect(report).not_to be_clean
          expect(report.to_h_report[:shared_cache_checked]).to be(true)
        end
      end

      it "repair! clears the stale copy so a reader gets the real rule" do
        with_shared_store do
          scope = Card.where(id: shape.child)
          stale_copy_in_store!(shape.child)
          MirrorAclAudit.repair!(MirrorAclAudit.audit(scope: scope).repair_ids)
          expect(MirrorAclAudit.audit(scope: scope)).to be_clean
          Card::Cache.reset_temp
          expect(Card.fetch(shape.child).read_rule_id).to eq(shape.rule)
          expect(Card::Auth.as("Anonymous") { Card.fetch(shape.child).ok?(:read) }).to be(false)
        end
      end

      it "reports a cached not-found placeholder for a real card" do
        with_shared_store do |_store|
          scope = Card.where(id: shape.set)
          key = Card::Lexicon.name(shape.set).key
          Card::Cache[Card].shared.write(key, Card.new(name: "Placeholder #{SecureRandom.hex(4)}", skip_modules: true))
          report = MirrorAclAudit.audit(scope: scope)
          expect(report.stale_fetch_ids).to eq([shape.set])
          MirrorAclAudit.repair!(report.repair_ids)
          expect(MirrorAclAudit.audit(scope: scope)).to be_clean
        end
      end

      it "does not flag a store that holds the right copy, or nothing" do
        with_shared_store do
          scope = shape_scope(shape)
          expect(MirrorAclAudit.audit(scope: scope)).to be_clean
          bot { Card.fetch(shape.child, skip_modules: true) }
          Card::Cache.reset_temp
          expect(MirrorAclAudit.audit(scope: scope)).to be_clean
        end
      end

      it "says so when no shared store exists to inspect" do
        report = MirrorAclAudit.audit(scope: Card.where(id: shape.child))
        expect(report.to_h_report[:shared_cache_checked]).to be(false)
        expect(report).to be_clean
      end
    end
  end

  describe MirrorStrictFilter do
    before { bot { Card.create!(name: "Nemquae", type: "User") } unless Card["Nemquae"] }

    let(:shape) { build_shape(readers: "[[Administrator]]") }

    def plan = described_class.manifest
    def selection(p) = { excluded: p.excluded_ids, stale: p.stale_read_cache_ids, disagree: p.verdict_disagreement_ids,
                         errors: p.unresolved_card_ids }

    it "excludes the locked card under the twin, and everything that inherits its rule" do
      shape
      result = plan
      expect(result.read_locked_ids).to include(shape.child, shape.set, shape.rule)
      # Under a poisoned lookup this field resolved the open deck default and would have been retained.
      expect(result.excluded_ids).to include(shape.field)
    end

    it "reports no stale cache on the self-referential rows" do
      shape
      expect(plan.stale_read_cache_ids & shape.ids).to eq([])
    end

    it "does not refuse selection on the shape alone" do
      shape
      expect { described_class.assert_audited_read_cache! }.not_to raise_error
    end

    it "gives the same selection on repeated manifests" do
      shape
      expect(selection(plan)).to eq(selection(plan))
    end

    [7, 50, 1000].each do |max_keys|
      it "gives the same selection when temporary caches evict at #{max_keys} keys" do
        shape
        baseline = selection(plan)
        stub_const("Card::Cache::Temporary::MAX_KEYS", max_keys)
        expect(selection(plan)).to eq(baseline)
      end
    end

    it "is not moved by what the caller's caches already hold" do
      shape
      baseline = selection(plan)
      poison_real_caches!(shape)
      expect(selection(plan)).to eq(baseline)
    end

    it "still refuses when a live row's cached rule is genuinely wrong" do
      shape
      Card.where(id: shape.field).update_all(read_rule_id: open_rule_id, read_rule_class: "*all plus")
      expect(plan.stale_read_cache_ids).to include(shape.field)
      expect { described_class.assert_audited_read_cache! }
        .to raise_error(described_class::Refused, /not audited/)
    end

    it "agrees with the audit on which rows are stale" do
      shape
      Card.where(id: shape.child).update_all(read_rule_id: open_rule_id)
      expect(plan.stale_read_cache_ids).to include(shape.child)
      expect(MirrorAclAudit.audit.mismatched_ids).to include(shape.child)
      expect(plan.stale_read_cache_ids.sort).to eq(MirrorAclAudit.audit.mismatched_ids.sort)
    end
  end
end
