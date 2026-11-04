# frozen_string_literal: true
#
# L1 encoder specs (Lane A, Slice 2). The encoder is a PURE function, so these run standalone with
# OpenStruct doubles -- no Decko boot / test DB required (unlike the Slice 1 DB-gated specs).
# Maps to Card 17161 Level 1 + Section 11 Layer 1. Delete-first per the 2026-06-21 reviewer pass.

require "ostruct"
require "active_support/core_ext/object/blank"
require_relative "../../mod/atomspace_mirror/lib/card_atom_encoder"
require_relative "../../mod/atomspace_mirror/lib/canonical_projection"

RSpec.describe CardAtomEncoder do
  NO_AUTH = { current_id: nil, as_id: nil }.freeze

  # encode wrapper: auth is mandatory, so default tests to the explicit "unavailable" snapshot
  # unless a case overrides it.
  def enc(action_obj, **over)
    described_class.encode(action_obj, **{ auth: NO_AUTH }.merge(over))
  end

  def card(**over)
    OpenStruct.new({
      id: 17120, name: "Some Card", key: "some_card", codename: nil, type_id: 6,
      type_name: "RichText", left_id: nil, right_id: nil, db_content: "body",
      trash: false, created_at: Time.utc(2026, 1, 1, 0, 0, 0),
      updated_at: Time.utc(2026, 1, 2, 0, 0, 0), creator_id: 3, updater_id: 3,
      references_out: []
    }.merge(over))
  end

  def act(**over)
    OpenStruct.new({ id: 81234, actor_id: 3, acted_at: Time.utc(2026, 1, 2, 0, 0, 0),
                     ip_address: nil }.merge(over))
  end

  def action(card_obj, act_obj: act, **over)
    OpenStruct.new({ id: 129552, action_type: :update, draft: false, super_action_id: nil,
                     card_id: card_obj.id, act: act_obj, card_changes: [], card: card_obj }.merge(over))
  end

  def change(field, value)
    OpenStruct.new(field: field, value: value)
  end

  # Real Card::Reference rows carry a DEAD is_present column (nil on every row in card-1.110.0,
  # verified L2b 2026-06-21), so the double defaults it to nil; IsPresent is derived from referee_id.
  def ref(**over)
    OpenStruct.new({ referer_id: 17120, referee_key: "target", referee_id: 17117, ref_type: "L",
                     is_present: nil }.merge(over))
  end

  def atom_of(atoms, kind)
    atoms.find { |a| a["atom"] == kind }
  end

  def fields_of(atoms, kind)
    a = atom_of(atoms, kind)
    a && a["fields"].to_h
  end

  def order_of(atoms, kind)
    atom_of(atoms, kind)["fields"].map(&:first)
  end

  describe "input contract" do
    it "requires auth: (raises when omitted) so the dual-actor snapshot cannot silently regress" do
      expect { described_class.encode(action(card)) }.to raise_error(ArgumentError)
      expect { described_class.encode(action(card), auth: {}) }.to raise_error(ArgumentError, /current_id/)
    end
  end

  describe "delete actions" do
    let(:deleted_card) { card(trash: true, db_content: "", references_out: [ref]) }
    let(:atoms) { enc(action(deleted_card, action_type: :delete)) }

    it "emits a DeckoCard with Trash=true and the full ordered 14-field arity" do
      expect(order_of(atoms, "DeckoCard")).to eq(
        %w[Id Name Key Codename TypeId TypeName LeftId RightId Content Trash CreatedAt UpdatedAt CreatorId UpdaterId]
      )
      expect(fields_of(atoms, "DeckoCard")["Trash"]).to be(true)
    end

    it "still emits references for the deleted card" do
      expect(atoms.count { |a| a["atom"] == "DeckoReference" }).to eq(1)
    end

    it "tags provenance action as the :delete symbol" do
      expect(fields_of(atoms, "DeckoProvenance")["action"]).to eq("sym" => "delete")
    end
  end

  describe "draft actions" do
    it "emits zero atoms" do
      expect(enc(action(card, draft: true))).to eq([])
    end
  end

  describe "DeckoCard field encoding" do
    it "uses NoCodename when codename is nil, else the codename symbol" do
      expect(fields_of(enc(action(card)), "DeckoCard")["Codename"]).to eq("sym" => "NoCodename")
      expect(fields_of(enc(action(card(codename: "mod_x"))), "DeckoCard")["Codename"]).to eq("sym" => "mod_x")
    end

    it "uses NoLeft / NoRight sentinels when null, else the integer id" do
      f = fields_of(enc(action(card)), "DeckoCard")
      expect(f["LeftId"]).to eq("sym" => "NoLeft")
      expect(f["RightId"]).to eq("sym" => "NoRight")
      f2 = fields_of(enc(action(card(left_id: 5, right_id: 6))), "DeckoCard")
      expect(f2["LeftId"]).to eq(5)
      expect(f2["RightId"]).to eq(6)
    end

    it "encodes Trash as a native JSON boolean and Content as the raw db_content string" do
      f = fields_of(enc(action(card(db_content: "<h2>x</h2>"))), "DeckoCard")
      expect(f["Trash"]).to be(false)
      expect(f["Content"]).to eq("<h2>x</h2>")
    end
  end

  describe "DeckoReference encoding" do
    it "maps one ordered atom per reference; RefType symbol; Unresolved for nil referee_id" do
      c = card(references_out: [ref(ref_type: "I"), ref(referee_id: nil)])
      atoms = enc(action(c))
      refs = atoms.select { |a| a["atom"] == "DeckoReference" }
      expect(refs.size).to eq(2)
      expect(refs.first["fields"].map(&:first)).to eq(%w[RefererId RefereeKey RefereeId RefType IsPresent])
      expect(refs[0]["fields"].to_h["RefType"]).to eq("sym" => "I")
      expect(refs[1]["fields"].to_h["RefereeId"]).to eq("sym" => "Unresolved")
    end

    it "derives IsPresent from referee_id resolution (is_present column is dead in Decko)" do
      # resolved referee_id => IsPresent true even though the is_present column is nil;
      # nil referee_id (a wanted/unresolved link) => IsPresent false.
      c = card(references_out: [ref(referee_id: 521, is_present: nil), ref(referee_id: nil, is_present: nil)])
      refs = enc(action(c)).select { |a| a["atom"] == "DeckoReference" }
      expect(refs[0]["fields"].to_h["IsPresent"]).to be(true)
      expect(refs[1]["fields"].to_h["IsPresent"]).to be(false)
    end
  end

  describe "DeckoProvenance encoding" do
    it "emits the full ordered 21-field provenance envelope" do
      expect(order_of(enc(action(card)), "DeckoProvenance")).to eq(%w[
        source event_schema_version event_id action_id act_id super_action_id action draft card_id
        card_key actor_id auth_current_id auth_as_id acted_at ip_address stage changes
        agent_session_id agent_kind origin_system origin_request_id
      ])
    end

    it "carries the constants + event_id" do
      f = fields_of(enc(action(card)), "DeckoProvenance")
      expect(f["source"]).to eq("decko")
      expect(f["event_schema_version"]).to eq("decko-spaceevent-v1")
      expect(f["event_id"]).to eq("decko:action:129552")
      expect(f["stage"]).to eq("integrate_with_delay")
    end

    it "uses NoSuper / NoIP sentinels when null" do
      f = fields_of(enc(action(card)), "DeckoProvenance")
      expect(f["super_action_id"]).to eq("sym" => "NoSuper")
      expect(f["ip_address"]).to eq("sym" => "NoIP")
    end

    # T9 / D-5: editor IPs never enter the Space or mirror_outbox.payload, even when the act has one.
    it "emits the NoIP sentinel even when the act carries an IP address" do
      a = action(card, act_obj: act(ip_address: "203.0.113.7"))
      f = fields_of(enc(a), "DeckoProvenance")
      expect(f["ip_address"]).to eq("sym" => "NoIP")
      expect(enc(a).to_json).not_to include("203.0.113.7")
    end

    it "encodes the Source-5 dual-actor auth fields from the auth snapshot, distinct from actor_id" do
      a = action(card, act_obj: act(actor_id: 10))
      f = fields_of(enc(a, auth: { current_id: 3, as_id: 5 }), "DeckoProvenance")
      expect(f["actor_id"]).to eq(10)
      expect(f["auth_current_id"]).to eq(3)
      expect(f["auth_as_id"]).to eq(5)
    end

    it "uses JSON null (not a sentinel) for an explicitly-unavailable dual-actor + absent agent fields" do
      f = fields_of(enc(action(card)), "DeckoProvenance")
      %w[auth_current_id auth_as_id agent_session_id agent_kind origin_system origin_request_id].each do |k|
        expect(f[k]).to be_nil
      end
    end

    it "tags present agent_kind / origin_system as symbols and keeps ids/strings native" do
      ctx = { agent_kind: :external_mcp_agent, origin_system: :mcp,
              agent_session_id: "jwt-jti-7f3c2a", origin_request_id: "req-abc" }
      f = fields_of(enc(action(card), request_context: ctx), "DeckoProvenance")
      expect(f["agent_kind"]).to eq("sym" => "external_mcp_agent")
      expect(f["origin_system"]).to eq("sym" => "mcp")
      expect(f["agent_session_id"]).to eq("jwt-jti-7f3c2a")
    end

    it "builds the changes array from card_changes (name OR integer field) joined with pre_state" do
      a = action(card, card_changes: [change("db_content", "new body"), change(3, "t")]) # 3 => trash
      f = fields_of(enc(a, pre_state: { "db_content" => "old body" }), "DeckoProvenance")
      expect(f["changes"]).to eq([
        { "field" => "db_content", "old" => "old body", "new" => "new body" },
        { "field" => "trash", "old" => nil, "new" => "t" }
      ])
    end

    it "tolerates symbol-keyed pre_state" do
      a = action(card, card_changes: [change("db_content", "new")])
      f = fields_of(enc(a, pre_state: { db_content: "old" }), "DeckoProvenance")
      expect(f["changes"]).to eq([{ "field" => "db_content", "old" => "old", "new" => "new" }])
    end

    it "raises on a corrupt out-of-range integer card_changes.field index" do
      a = action(card, card_changes: [change(99, "x")])
      expect { enc(a) }.to raise_error(CardAtomEncoder::EncodingError, /card_changes.field/)
    end

    it "raises on an unknown card_changes.field name not in TRACKED_FIELDS" do
      a = action(card, card_changes: [change("codename", "x")]) # not a tracked field (V5-PROTOCOL-2)
      expect { enc(a) }.to raise_error(CardAtomEncoder::EncodingError, /not in TRACKED_FIELDS/)
    end
  end

  describe "referential transparency" do
    it "produces identical output for identical inputs" do
      c = card(left_id: 5, references_out: [ref])
      expect(enc(action(c))).to eq(enc(action(c)))
    end
  end

  describe "encode_card_snapshot (bootstrap bulk-load)" do
    it "emits DeckoCard + DeckoReference(s) and NO DeckoProvenance, no auth required" do
      atoms = described_class.encode_card_snapshot(card(references_out: [ref(ref_type: "I"), ref]))
      kinds = atoms.map { |a| a["atom"] }
      expect(kinds).to eq(%w[DeckoCard DeckoReference DeckoReference])
      expect(kinds).not_to include("DeckoProvenance")
    end

    it "emits just the DeckoCard (full 14-field arity) for a card with no references" do
      atoms = described_class.encode_card_snapshot(card)
      expect(atoms.map { |a| a["atom"] }).to eq(%w[DeckoCard])
      expect(atoms.first["fields"].map(&:first)).to eq(
        %w[Id Name Key Codename TypeId TypeName LeftId RightId Content Trash CreatedAt UpdatedAt CreatorId UpdaterId]
      )
    end

    it "produces the same DeckoCard/DeckoReference atoms as the forward encoder (PATCH-4 faithful)" do
      c = card(references_out: [ref])
      forward = enc(action(c)).reject { |a| a["atom"] == "DeckoProvenance" }
      expect(described_class.encode_card_snapshot(c)).to eq(forward)
    end
  end

  # L6 / Section 3: a reconcile event is DRAINED through /apply, so its payload must satisfy the L8
  # drain validator (exactly one DeckoProvenance, identity-matched to the reconcile outbox row).
  describe "encode_reconcile_snapshot (Level 6 synthetic reconcile event)" do
    let(:run_card) { card(references_out: [ref]) }
    let(:atoms) do
      described_class.encode_reconcile_snapshot(
        run_card, event_id: "reconcile:card:17120:7", actor_id: 3, acted_at: Time.utc(2026, 6, 26, 1, 0, 0)
      )
    end

    it "emits DeckoCard + DeckoReference(s) + EXACTLY ONE synthetic DeckoProvenance" do
      expect(atoms.map { |a| a["atom"] }).to eq(%w[DeckoCard DeckoReference DeckoProvenance])
      expect(atoms.count { |a| a["atom"] == "DeckoProvenance" }).to eq(1)
    end

    it "reuses the canonical DeckoCard/DeckoReference atoms (identical to encode_card_snapshot)" do
      card_and_refs = atoms.reject { |a| a["atom"] == "DeckoProvenance" }
      expect(card_and_refs).to eq(described_class.encode_card_snapshot(run_card))
    end

    it "carries the SAME 21-field provenance arity/order as the forward encoder" do
      forward_order = order_of(enc(action(card)), "DeckoProvenance")
      expect(order_of(atoms, "DeckoProvenance")).to eq(forward_order)
    end

    it "sets the three drain-validator identity fields to match a reconcile outbox row" do
      prov = fields_of(atoms, "DeckoProvenance")
      expect(prov["event_id"]).to eq("reconcile:card:17120:7")
      expect(prov["card_id"]).to eq(17120)
      expect(prov["action_id"]).to be_nil   # reconcile rows carry a NULL action_id (OQ#12); validator requires the match
    end

    it "marks it synthetic: action=reconcile, stage=reconcile, empty changes, NoSuper, NoIP" do
      prov = fields_of(atoms, "DeckoProvenance")
      expect(prov["action"]).to eq("sym" => "reconcile")
      expect(prov["stage"]).to eq("reconcile")
      expect(prov["changes"]).to eq([])
      expect(prov["super_action_id"]).to eq("sym" => "NoSuper")
      expect(prov["ip_address"]).to eq("sym" => "NoIP")
    end

    it "records the run's integer actor_id + timestamp and JSON-nulls every unsourceable request-time field" do
      prov = fields_of(atoms, "DeckoProvenance")
      expect(prov["actor_id"]).to eq(3)
      expect(prov["acted_at"]).to eq("2026-06-26T01:00:00Z")
      %w[act_id auth_current_id auth_as_id agent_session_id agent_kind origin_system origin_request_id].each do |f|
        expect(prov[f]).to be_nil
      end
    end

    it "defaults actor_id/acted_at to an honest nil when the run leaves them unattributed" do
      prov = fields_of(
        described_class.encode_reconcile_snapshot(run_card, event_id: "reconcile:card:17120:8"),
        "DeckoProvenance"
      )
      expect(prov["actor_id"]).to be_nil
      expect(prov["acted_at"]).to be_nil
    end

    it "rejects a STRING actor_id loudly (operator attribution belongs in the run row, not actor_id)" do
      expect do
        described_class.encode_reconcile_snapshot(run_card, event_id: "reconcile:card:17120:9", actor_id: "system")
      end.to raise_error(ArgumentError, /Integer/)
    end
  end

  # The fixtures here are synthetic. Every value a credential card holds in these examples carries SYNTHETIC_MARKER, and the last
  # examples in this block check that and scan this file for anything shaped like a real secret. Ids and codenames are the seed's.
  describe "credential-bearing cards" do
    SYNTHETIC_MARKER = "SYNTHETIC-NOT-A-SECRET"
    SENTINEL = { "sym" => "Redacted" }.freeze
    DECKO_CARD_FIELDS = %w[Id Name Key Codename TypeId TypeName LeftId RightId Content Trash CreatedAt UpdatedAt CreatorId UpdaterId].freeze
    CODENAMES = {
      216 => :password, 221 => :salt, 323 => :api_key, 519 => :secret_key, 901 => :token, 902 => :reset_token,
      903 => :key_hash, 904 => :metadata, 905 => :secret_hash, 906 => :mcp_oauth_clients, 907 => :mcp_api_keys, 7 => :read
    }.freeze
    NO_CODENAME = 999

    before { stub_const("Card::Codename", ->(id) { CODENAMES[id] }) }

    def fixture_value(tag = "body") = "#{SYNTHETIC_MARKER}-#{tag}"

    def credential(**over)
      card(**{ name: "Joe User+*account+*password", key: "joe_user+*account+*password", left_id: 500, right_id: 216,
               db_content: fixture_value }.merge(over))
    end

    def content_of(card_obj) = fields_of(described_class.encode_card_snapshot(card_obj), "DeckoCard")["Content"]
    def bearing?(**over) = described_class.credential_bearing?(card(**over))

    describe "1. Content" do
      CODENAMES.slice(216, 221, 323, 519, 901, 902, 903, 904, 905).each do |id, code|
        it "is the sentinel when the right part's codename is #{code}" do
          c = credential(name: "Someone+#{code}", right_id: id)
          expect(content_of(c)).to eq(SENTINEL)
          expect(described_class.encode_card_snapshot(c).to_json).not_to include(SYNTHETIC_MARKER)
        end
      end

      it "is a symbol, not an empty string, so it can't be mistaken for an empty card" do
        expect(content_of(credential)).to eq("sym" => "Redacted")
        expect(content_of(card(db_content: ""))).to eq("")
      end

      it "is the sentinel on a trashed credential card too" do
        expect(content_of(credential(trash: true))).to eq(SENTINEL)
      end

      it "is the sentinel in a forward event, a snapshot and a reconcile event alike" do
        c = credential
        forward = enc(action(c))
        reconcile = described_class.encode_reconcile_snapshot(c, event_id: "reconcile:card:17120:1")
        [forward, described_class.encode_card_snapshot(c), reconcile].each do |atoms|
          expect(fields_of(atoms, "DeckoCard")["Content"]).to eq(SENTINEL)
          expect(atoms.to_json).not_to include(SYNTHETIC_MARKER)
        end
      end

      it "hashes to the same projection however it was reached, which is what keeps a drift sweep clean" do
        c = credential
        forward = enc(action(c)).reject { |a| a["atom"] == "DeckoProvenance" }
        expect(CanonicalProjection.sha256(forward)).to eq(CanonicalProjection.sha256(described_class.encode_card_snapshot(c)))
        expect(CanonicalProjection.serialize(forward)).to include('["Content",{"sym":"Redacted"}]')
      end
    end

    describe "2. provenance on a forward update" do
      let(:atoms) do
        a = action(credential, card_changes: [change("db_content", fixture_value("new")), change("trash", false)])
        enc(a, pre_state: { "db_content" => fixture_value("old"), "trash" => true })
      end
      let(:changes) { fields_of(atoms, "DeckoProvenance")["changes"] }

      it "redacts old and new to the sentinel, and keeps the field's name" do
        expect(changes.first).to eq("field" => "db_content", "old" => SENTINEL, "new" => SENTINEL)
      end

      it "leaves the other tracked fields alone" do
        expect(changes.last).to eq("field" => "trash", "old" => true, "new" => false)
      end

      it "lets no value through anywhere in the event" do
        expect(atoms.to_json).not_to include(SYNTHETIC_MARKER)
      end

      it "redacts a change whose field arrives as the integer index" do
        a = action(credential, card_changes: [change(2, fixture_value("new"))]) # 2 => db_content
        f = fields_of(enc(a, pre_state: { db_content: fixture_value("old") }), "DeckoProvenance")
        expect(f["changes"]).to eq([{ "field" => "db_content", "old" => SENTINEL, "new" => SENTINEL }])
      end

      it "stays [] on a reconcile event, which has no changes to redact" do
        atoms = described_class.encode_reconcile_snapshot(credential, event_id: "reconcile:card:17120:2")
        expect(fields_of(atoms, "DeckoProvenance")["changes"]).to eq([])
      end
    end

    describe "3. OAuth client descendants" do
      let(:client_id) { "00000000-0000-4000-8000-000000000000" }

      it "the left-part arm: a client card whose right part has no codename" do
        expect(bearing?(name: "MCP OAuth Clients+#{client_id}", left_id: 10_954, right_id: NO_CODENAME)).to be(true)
      end

      it "the left-part arm reads the name, not the key Decko derives from it" do
        expect(bearing?(name: "MCP OAuth Clients+#{client_id}", key: "mcp_o_auth_client+#{client_id}", right_id: NO_CODENAME)).to be(true)
      end

      it "the left-part arm ignores case, as Decko's names do" do
        expect(bearing?(name: "mcp oauth clients+#{client_id}", right_id: NO_CODENAME)).to be(true)
      end

      it "the codename arm: a container that has a codename still counts after a rename" do
        expect(bearing?(name: "Renamed Container+#{client_id}", left_id: 906, right_id: NO_CODENAME)).to be(true)
      end

      it "the right-part codename arm also applies under the container" do
        expect(bearing?(name: "MCP OAuth Clients+#{client_id}+*salt", right_id: 221)).to be(true)
      end

      it "redacts Content on a client card" do
        c = credential(name: "MCP OAuth Clients+#{client_id}", left_id: 10_954, right_id: NO_CODENAME)
        expect(content_of(c)).to eq(SENTINEL)
      end
    end

    describe "4. API key descendants" do
      %w[key_hash metadata last_used_at].each do |right|
        it "MCP API Keys+<name>+#{right} is credential-bearing with no codename at all" do
          expect(bearing?(name: "MCP API Keys+a_key+#{right}", left_id: 8000, right_id: NO_CODENAME)).to be(true)
        end
      end

      it "the key card itself is credential-bearing" do
        expect(bearing?(name: "MCP API Keys+a_key", left_id: 3772, right_id: NO_CODENAME)).to be(true)
      end

      it "the codename arm: a container that has a codename still counts after a rename" do
        expect(bearing?(name: "Renamed Keys+a_key", left_id: 907, right_id: NO_CODENAME)).to be(true)
      end

      it "redacts Content and provenance on +key_hash" do
        c = credential(name: "MCP API Keys+a_key+key_hash", left_id: 8000, right_id: NO_CODENAME)
        atoms = enc(action(c, card_changes: [change("db_content", fixture_value("new"))]), pre_state: { "db_content" => fixture_value("old") })
        expect(fields_of(atoms, "DeckoCard")["Content"]).to eq(SENTINEL)
        expect(fields_of(atoms, "DeckoProvenance")["changes"].first).to include("old" => SENTINEL, "new" => SENTINEL)
        expect(atoms.to_json).not_to include(SYNTHETIC_MARKER)
      end
    end

    describe "5. non-credential cards" do
      it "keep their real Content and unredacted provenance" do
        a = action(card(db_content: "new body"), card_changes: [change("db_content", "new body")])
        atoms = enc(a, pre_state: { "db_content" => "old body" })
        expect(fields_of(atoms, "DeckoCard")["Content"]).to eq("new body")
        expect(fields_of(atoms, "DeckoProvenance")["changes"]).to eq([{ "field" => "db_content", "old" => "old body", "new" => "new body" }])
      end

      {
        "a card merely named like a right part, with no codename" => { name: "Games+metadata", left_id: 5, right_id: NO_CODENAME },
        "a card whose name contains a credential word" => { name: "Games+Old Salt", left_id: 5, right_id: NO_CODENAME },
        "a right part with an unrelated codename" => { name: "Games+*read", left_id: 5, right_id: 7 },
        "the container itself, which is not its own descendant" => { name: "MCP API Keys" },
        "a card that only starts with the container's name" => { name: "MCP API Keys Guide+intro", left_id: 5, right_id: NO_CODENAME },
        "the container's name lower in a compound name" => { name: "Notes+MCP API Keys+intro", left_id: 5, right_id: NO_CODENAME },
        "a simple card" => { name: "Home" }
      }.each do |label, attrs|
        it "#{label} is not credential-bearing" do
          expect(bearing?(**attrs)).to be(false)
        end
      end

      it "without a codename table, as when run standalone, the name arm still works" do
        hide_const("Card::Codename")
        expect(bearing?(name: "MCP API Keys+a_key", right_id: 216)).to be(true)
        expect(bearing?(name: "Games+x", right_id: 216)).to be(false)
      end
    end

    describe "6. the frozen shape" do
      it "keeps the 14 DeckoCard fields in order on a credential card and on an ordinary one" do
        [credential, card].each do |c|
          atoms = described_class.encode_card_snapshot(c)
          expect(order_of(atoms, "DeckoCard")).to eq(DECKO_CARD_FIELDS)
          expect(order_of(atoms, "DeckoCard").size).to eq(14)
        end
      end

      it "keeps the 21 provenance fields on a credential card" do
        expect(order_of(enc(action(credential)), "DeckoProvenance").size).to eq(21)
        expect(order_of(enc(action(credential)), "DeckoProvenance")).to eq(order_of(enc(action(card)), "DeckoProvenance"))
      end
    end

    describe "the value is never touched" do
      let(:tripwire) do
        Class.new(OpenStruct) do
          def db_content = raise("db_content was read")
        end
      end

      it "the classifier decides without reading db_content" do
        c = tripwire.new(name: "MCP API Keys+a_key", left_id: 3772, right_id: 216)
        expect(described_class.credential_bearing?(c)).to be(true)
        expect(described_class.credential_bearing?(tripwire.new(name: "Home"))).to be(false)
      end

      it "encoding a credential card never reads db_content or a change's value" do
        c = tripwire.new(card.to_h.except(:db_content).merge(name: "MCP API Keys+a_key", left_id: 3772, right_id: NO_CODENAME))
        value_tripwire = Class.new { def field = "db_content"; def value = raise("the change's value was read") }.new
        atoms = enc(action(c, card_changes: [value_tripwire]), pre_state: { "db_content" => fixture_value("old") })
        expect(fields_of(atoms, "DeckoProvenance")["changes"].first).to eq("field" => "db_content", "old" => SENTINEL, "new" => SENTINEL)
      end

      it "an EncodingError on a credential card names the field and carries no value" do
        c = credential
        expect { enc(action(c, card_changes: [change(99, fixture_value("new"))])) }
          .to raise_error(CardAtomEncoder::EncodingError) { |e| expect(e.message).not_to include(SYNTHETIC_MARKER) }
      end
    end

    describe "7. the fixtures" do
      it "every credential value used here carries the synthetic marker" do
        [credential.db_content, fixture_value, fixture_value("old"), fixture_value("new")].each do |value|
          expect(value).to start_with(SYNTHETIC_MARKER)
        end
      end

      it "this file holds nothing shaped like a real secret" do
        source = File.read(__FILE__)
        {
          "JWT" => /eyJ[\w-]{8,}\.[\w-]{8,}\./,
          "bcrypt hash" => /\$2[aby]\$\d\d\$/,
          "long hex digest" => /\b[0-9a-f]{40,}\b/,
          "reCAPTCHA key" => /\b6L[\w-]{38}\b/,
          "API key prefix" => /\b(?:sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,})\b/,
          "private key block" => /BEGIN [A-Z ]*PRIVATE KEY-{5}\n/
        }.each do |label, shape|
          expect(source).not_to match(shape), "found something shaped like a #{label}"
        end
      end
    end
  end
end
