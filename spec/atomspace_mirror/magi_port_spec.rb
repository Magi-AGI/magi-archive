# frozen_string_literal: true
#
# Magi port acceptance (PLAN 4.4): T1, T14, T15, T16, T29 capture-gap part, T31. DB-backed, real cards.

require "spec_helper"

RSpec.describe "AtomSpace mirror on Magi" do
  def with_gate(value)
    old = ENV["ATOMSPACE_MIRRORING_ENABLED"]
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = value
    yield
  ensure
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = old
  end

  def bot(&block) = Card::Auth.as_bot(&block)
  def new_card(name) = bot { Card.create!(name: name, type: "Basic", content: "v1") }
  def last_action_id(card) = Card::Action.where(card_id: card.id).maximum(:id)
  def uniq(prefix) = "#{prefix} #{SecureRandom.hex(4)}"

  describe "T1 dormancy" do
    it "lets create, update and delete succeed with the gate unset and no mirror tables" do
      conn = ActiveRecord::Base.connection
      MirrorRuntimeGuards::MIRROR_TABLES.each { |t| conn.drop_table(t, force: :cascade) }
      with_gate(nil) do
        card = new_card(uniq("T1 no tables"))
        bot { card.update!(content: "v2") }
        expect(Card.fetch(card.id).db_content).to eq("v2")
        bot { card.delete! }
        expect(Card.fetch(card.id)).to be_nil
      end
    end

    it "writes no outbox rows with the gate unset" do
      with_gate(nil) do
        expect do
          card = new_card(uniq("T1 tables"))
          bot { card.update!(content: "v2") }
          bot { card.delete! }
        end.not_to(change { MirrorOutbox.count })
      end
    end
  end

  describe "T14 refresh precondition" do
    it "refuses when the gate is set" do
      expect { MirrorRuntimeGuards.assert_refresh_precondition!(enabled: true) }
        .to raise_error(MirrorRuntimeGuards::RefreshPreconditionViolated, /disable the mirror/)
    end

    it "refuses when mirror tables exist" do
      expect { MirrorRuntimeGuards.assert_refresh_precondition!(enabled: false) }
        .to raise_error(MirrorRuntimeGuards::RefreshPreconditionViolated, /mirror_outbox/)
    end

    it "passes when dormant with the tables dropped" do
      conn = ActiveRecord::Base.connection
      MirrorRuntimeGuards::MIRROR_TABLES.each { |t| conn.drop_table(t, force: :cascade) }
      expect { MirrorRuntimeGuards.assert_refresh_precondition!(enabled: false, conn: conn) }.not_to raise_error
    end
  end

  describe "T15 inline integrate guard" do
    it "fails loudly when enabled with delaying on" do
      expect { MirrorRuntimeGuards.assert_inline_integrate!(enabled: true, delaying: true) }
        .to raise_error(MirrorRuntimeGuards::UnsafeRuntime, /delaying/)
    end

    it "does not raise when dormant, or enabled without delaying" do
      expect { MirrorRuntimeGuards.assert_inline_integrate!(enabled: false, delaying: true) }.not_to raise_error
      expect { MirrorRuntimeGuards.assert_inline_integrate!(enabled: true, delaying: false) }.not_to raise_error
    end

    it "is satisfied by this deck's real config" do
      expect(Cardio.config.delaying).to be_falsey
    end
  end

  describe "T16 self-card exclusion" do
    it "covers every mod_atomspace codename present after boot" do
      codenames = Card.where("codename LIKE 'mod_atomspace%'").pluck(:codename).map(&:to_s)
      expect(codenames - MirrorOutboxWriter::SELF_CARD_CODENAMES).to be_empty
    end
  end

  describe "T29 capture gap after a disabled window" do
    it "records nothing while disabled, and hook-lag remediation finds and repairs the gap" do
      anchor = Card::Action.maximum(:id).to_i
      MirrorState.first.update!(bootstrap_a_start: anchor)

      card = with_gate("true") { new_card(uniq("T29")) }
      expect(MirrorOutbox.where(card_id: card.id, event_kind: "decko_action").count).to be >= 1

      with_gate(nil) { bot { card.update!(content: "edited while disabled") } }
      gap_action = last_action_id(card)
      expect(MirrorOutbox.where(action_id: gap_action)).to be_empty

      # Re-enabling alone captures nothing retroactively.
      with_gate("true") { expect(MirrorOutbox.where(action_id: gap_action)).to be_empty }

      report = DriftMonitor.coverage_gap(anchor)
      expect(report[:gap_count]).to be >= 1
      expect(report[:gap_action_ids]).to include(gap_action)

      with_gate("true") { Reconciler.remediate_hook_lag!(sidecar: double("unused sidecar")) }
      expect(MirrorOutbox.find_by(action_id: gap_action, event_kind: "decko_action")).to be_present
      expect(DriftMonitor.coverage_gap(anchor)[:gap_action_ids]).not_to include(gap_action)
    end
  end

  describe "T31 provenance agent fields (17184 jti item, deferred under W14)" do
    it "leaves the four agent fields null, keeping the unmet canonical item visible" do
      card = with_gate("true") { new_card(uniq("T31")) }
      row = MirrorOutbox.where(card_id: card.id, event_kind: "decko_action").order(:id).last
      prov = row.payload.fetch("atoms").find { |a| a.to_s.include?("DeckoProvenance") }
      fields = prov.fetch("fields").to_h
      expect(fields.values_at("agent_session_id", "agent_kind", "origin_system", "origin_request_id")).to all(be_nil)
      expect(fields["ip_address"]).to eq("sym" => "NoIP")
    end
  end
end
