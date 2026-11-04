# frozen_string_literal: true
#
# The no-DB half of the stale-event fix, for the CI job, which runs no DB specs: the writer and the encoder use the
# card the hook read fresh, and fall back to action.card for callers that have none. forward_event_state_spec.rb
# covers the real hook. STANDALONE: no Decko boot.

require "ostruct"
require_relative "../../mod/atomspace_mirror/lib/card_atom_encoder"

RSpec.describe CardAtomEncoder, ".encode with a given card" do
  def card(content)
    OpenStruct.new(id: 1, name: "N", key: "n", codename: nil, type_id: 6, type_name: "RichText", left_id: nil,
                   right_id: nil, db_content: content, trash: false, created_at: Time.utc(2026, 1, 1),
                   updated_at: Time.utc(2026, 1, 2), creator_id: 3, updater_id: 3, references_out: [])
  end

  let(:act) { OpenStruct.new(id: 5, actor_id: 3, acted_at: Time.utc(2026, 1, 2), ip_address: nil) }
  let(:action) do
    OpenStruct.new(id: 100, action_type: :update, draft: false, super_action_id: nil, card_id: 1, act: act,
                   card_changes: [], card: card("stale"))
  end
  let(:auth) { { current_id: 3, as_id: 3 } }

  def content_of(atoms) = atoms.find { |a| a["atom"] == "DeckoCard" }["fields"].to_h["Content"]

  it "encodes the card it is given, not action.card" do
    expect(content_of(described_class.encode(action, auth: auth, card: card("fresh")))).to eq("fresh")
  end

  it "falls back to action.card when none is given" do
    expect(content_of(described_class.encode(action, auth: auth))).to eq("stale")
  end
end
