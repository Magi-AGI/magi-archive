# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/atomspace_mirror/lib/mirror_runtime_guards").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_strict_filter").to_s
require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s

# G-CACHE regression. The defect: Cardio.database is read from database.yml and memoized
# (card-1.110.0 lib/cardio.rb:44), and the shared cache namespace is derived from it
# (lib/card/cache/shared_class.rb:15 "#{Cardio.database}-stamp", lib/card/cache/shared.rb:29).
# DATABASE_URL moves the ActiveRecord connection but NOT that value, so a staged STRICT refresh
# invoked with DATABASE_URL=...staged shares ONE cache store with the live deck.
#
# These examples drive the real guard against the real Card::Cache, with the shared cache turned ON
# the way production has it (the test env turns it off), so the "safe" assertions are not vacuous.
RSpec.describe MirrorRuntimeGuards, "G-CACHE staged/live cache isolation" do
  let(:conn) { ActiveRecord::Base.connection }
  let(:live_db) { conn.current_database.to_s }
  let(:staged_db) { "#{live_db}_staged" }

  # Restore every global the examples touch, so a failure cannot leak cache state into the rest of
  # the suite.
  around do |example|
    saved_env = ENV["NO_RAILS_CACHE"]
    saved_db_memo = Cardio.instance_variable_get(:@database)
    saved_shared = Card::Cache.instance_variable_get(:@shared_cache)
    saved_by_class = Card::Cache.instance_variable_get(:@cache_by_class)
    saved_cfg = Cardio.config.shared_cache
    example.run
  ensure
    Cardio.config.shared_cache = saved_cfg
    saved_env.nil? ? ENV.delete("NO_RAILS_CACHE") : ENV["NO_RAILS_CACHE"] = saved_env
    Cardio.instance_variable_set(:@database, saved_db_memo)
    Card::Cache.instance_variable_set(:@shared_cache, saved_shared)
    Card::Cache.instance_variable_set(:@cache_by_class, saved_by_class)
    Card::Cache.reset_all
  end

  # Turn the shared cache on exactly as production does, clearing the lazy memos the gem reads
  # NO_RAILS_CACHE through (lib/card/cache/class_methods.rb:106).
  def with_production_shared_cache
    Cardio.config.shared_cache = true
    ENV.delete("NO_RAILS_CACHE")
    Card::Cache.instance_variable_set(:@shared_cache, nil)
    Card::Cache.instance_variable_set(:@cache_by_class, {})
    yield
  end

  # Pretend this process was pointed at a staged copy by DATABASE_URL: the connection is to one
  # database while Cardio.database (database.yml) still names the live deck. That IS the defect
  # condition, reproduced without needing two real databases.
  def as_if_pointed_at_staged
    Cardio.instance_variable_set(:@database, live_db)
    yield
  end

  describe "the defect is real and detected" do
    it "sees a live shared cache namespaced to database.yml, not to DATABASE_URL" do
      with_production_shared_cache do
        expect(described_class.shared_cache_live?).to be_truthy
        # The namespace database comes from database.yml via Cardio.database, which is what every
        # shared cache key is prefixed with.
        expect(described_class.cache_namespace_database).to eq(Cardio.database.to_s)
      end
    end

    it "refuses selection when the cache namespace does not name the connected database" do
      with_production_shared_cache do
        # Simulate the staged run: connection reports the real DB, the cache namespace names another.
        Cardio.instance_variable_set(:@database, staged_db)
        expect(described_class.cache_isolated?).to be false
        expect { described_class.assert_isolated_cache! }
          .to raise_error(described_class::CacheContamination, /DATABASE_URL does not move the cache namespace/)
      end
    end

    it "fails the refresh precondition on a contaminated cache, before any selection happens" do
      with_production_shared_cache do
        Cardio.instance_variable_set(:@database, staged_db)
        expect { described_class.assert_refresh_precondition!(enabled: false) }
          .to raise_error(described_class::CacheContamination)
      end
    end
  end

  describe "isolate_cache! actually takes effect at runtime" do
    it "turns the shared cache OFF, so no staged read can reach a shared store" do
      with_production_shared_cache do
        expect(described_class.shared_cache_live?).to be_truthy
        described_class.isolate_cache!
        # This is the load-bearing assertion: after isolation Card::Cache hands out no shared store,
        # so there is no cross-process store for staged data to land in.
        expect(Card::Cache.shared_cache).to be_falsey
        expect(described_class.shared_cache_live?).to be false
      end
    end

    it "re-points the cache namespace at the actually connected database" do
      with_production_shared_cache do
        Cardio.instance_variable_set(:@database, staged_db)
        settled = described_class.isolate_cache!
        # Both halves of the fix: the namespace now derives from the real target, not database.yml.
        expect(settled).to eq(live_db)
        expect(described_class.cache_namespace_database).to eq(live_db)
        expect(Card::Cache::Shared.stamp_key).to eq("#{live_db}-stamp")
      end
    end

    it "clears the cache-contamination refusal from the refresh precondition" do
      with_production_shared_cache do
        Cardio.instance_variable_set(:@database, staged_db)
        expect { described_class.assert_refresh_precondition!(enabled: false) }
          .to raise_error(described_class::CacheContamination)
        described_class.isolate_cache!
        # The cache gate is now satisfied. This seeded test DB still carries the mirror tables, so
        # the precondition legitimately stops at its NEXT gate -- which is the point: the refusal is
        # no longer about the cache. Asserting "no error at all" here would assert the test DB's
        # schema, not the fix, so assert the specific later gate instead of a negative match.
        expect { described_class.assert_refresh_precondition!(enabled: false) }
          .to raise_error(described_class::RefreshPreconditionViolated, /mirror tables still exist/)
        expect(described_class.cache_isolated?).to be true
      end
    end

    it "is idempotent" do
      with_production_shared_cache do
        first = described_class.isolate_cache!
        second = described_class.isolate_cache!
        expect(second).to eq(first)
        expect(Card::Cache.shared_cache).to be_falsey
      end
    end
  end

  describe "staged data cannot affect the live cache" do
    # The end-to-end property, exercised through the real cache API: a card fetched under isolation
    # must not be published into any shared store, and the live stamp key must be untouched by it.
    it "does not write a fetched card into a shared store while isolated" do
      name = "G-CACHE Probe #{SecureRandom.hex(4)}"
      Card::Auth.as_bot { Card.create!(name: name, type: "Basic", content: "x") }

      with_production_shared_cache do
        live_stamp_key = Card::Cache::Shared.stamp_key
        live_stamp_before = Cardio.cache.read(live_stamp_key)

        described_class.isolate_cache!
        # A "staged" read happens here. With the defect, this fetch would populate the shared store
        # under the LIVE namespace.
        Card::Auth.as_bot { Card.fetch(name) }

        expect(Card::Cache.shared_cache).to be_falsey
        # The live namespace's stamp was not rewritten by the staged-side read.
        expect(Cardio.cache.read(live_stamp_key)).to eq(live_stamp_before)
      end
    end

    it "keeps the live namespace distinct from a staged namespace" do
      with_production_shared_cache do
        Cardio.instance_variable_set(:@database, live_db)
        live_key = Card::Cache::Shared.stamp_key
        Cardio.instance_variable_set(:@database, staged_db)
        staged_key = Card::Cache::Shared.stamp_key
        # Proof that the namespace is derived from the database NAME: once isolate_cache! re-points
        # it at the staged target, the two stores cannot collide.
        expect(staged_key).not_to eq(live_key)
        expect(live_key).to eq("#{live_db}-stamp")
        expect(staged_key).to eq("#{staged_db}-stamp")
      end
    end
  end
end
