# frozen_string_literal: true
#
# Forward events must carry the state their action produced. On the dev host's real shared cache,
# Card::Action#card (a cached Card.fetch) returned the copy from before the save: event 20578 said
# Content="first" while its own provenance said first -> second, and a delete said Trash=false
# (logs/impl5/payload_inspect.log).
#
# THIS IS A SIMULATED-CACHE SPEC, NOT A REAL-CACHE REPRODUCTION. The test environment does not reproduce
# the stale read by itself, so it primes exactly what the real cache returned: the pre-save copy, from
# the same call Card::Action#card makes. It pins the behaviour, not the environment.

require "spec_helper"

RSpec.describe "Forward mirror events and a warm card cache" do
  def with_gate(value)
    old = ENV["ATOMSPACE_MIRRORING_ENABLED"]
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = value
    yield
  ensure
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = old
  end

  def bot(&block) = Card::Auth.as_bot(&block)
  def uniq(prefix) = "#{prefix} #{SecureRandom.hex(4)}"

  def atom_of(card_id, kind)
    row = MirrorOutbox.where(card_id: card_id).order(:id).last
    row.payload["atoms"].find { |a| a["atom"] == kind }["fields"].to_h
  end

  # Serves what the real cache served: the copy of this card from before the save.
  def serve_pre_save_copy(card_id)
    copy = Card.find(card_id)
    allow(Card).to receive(:fetch).and_call_original
    allow(Card).to receive(:fetch).with(card_id, look_in_trash: true).and_return(copy)
  end

  around { |example| with_gate("true") { example.run } }
  before { MirrorState.first.update!(bootstrap_a_start: Card::Action.maximum(:id)) }
  after { Card::Cache.reset_all }

  let(:card) { bot { Card.create!(name: uniq("Forward Event"), type: "Basic", content: "first") } }

  context "when the cached copy is from before the save (simulated)" do
    it "an update event's atom carries the new content, matching its own provenance" do
      serve_pre_save_copy(card.id)
      bot { Card.find(card.id).update!(content: "second") }

      provenance = atom_of(card.id, "DeckoProvenance")
      expect(provenance["changes"]).to include(include("field" => "db_content", "old" => "first", "new" => "second"))
      expect(atom_of(card.id, "DeckoCard")["Content"]).to eq("second")
    end

    it "a delete event's atom says Trash=true" do
      serve_pre_save_copy(card.id)
      bot { Card.find(card.id).delete! }

      expect(atom_of(card.id, "DeckoCard")["Trash"]).to be(true)
    end

    it "an update event's atom carries this action's UpdatedAt, not the previous one's" do
      before_save = Card.find(card.id).updated_at
      serve_pre_save_copy(card.id)
      sleep 1.1
      bot { Card.find(card.id).update!(content: "second") }

      expect(Time.iso8601(atom_of(card.id, "DeckoCard")["UpdatedAt"])).to be > before_save
    end
  end

  context "with no simulated staleness (control)" do
    it "an update event's atom carries the new content" do
      bot { Card.fetch(card.id).update!(content: "second") }
      expect(atom_of(card.id, "DeckoCard")["Content"]).to eq("second")
    end

    it "a rename event's atom carries the new name" do
      bot { Card.fetch(card.id).update!(name: "#{card.name} renamed") }
      expect(atom_of(card.id, "DeckoCard")["Name"]).to end_with(" renamed")
    end
  end
end
