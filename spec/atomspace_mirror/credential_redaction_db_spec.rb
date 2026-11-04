# frozen_string_literal: true
#
# The encoder's redaction on real cards, so the doubles in card_atom_encoder_spec.rb can't drift from Decko. Junction rows hold no name
# or key in Postgres, so what card.name returns and what Card::Codename maps have to be seen on real rows. Every value is synthetic.

require "spec_helper"
require Rails.root.join("mod/mcp_api/lib/atomspace/sidecar_read_client").to_s

RSpec.describe "Credential redaction on real cards" do
  marker = "SYNTHETIC-NOT-A-SECRET"
  sentinel = { "sym" => "Redacted" }

  def bot(&block) = Card::Auth.as_bot(&block)
  def hex = SecureRandom.hex(4)
  def encoder = CardAtomEncoder

  def with_gate(value)
    old = ENV["ATOMSPACE_MIRRORING_ENABLED"]
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = value
    yield
  ensure
    ENV["ATOMSPACE_MIRRORING_ENABLED"] = old
  end

  def latest_atoms(card_id)
    atoms = MirrorOutbox.where(card_id: card_id).order(:id).last.payload["atoms"]
    atoms.to_h { |a| [a["atom"], a["fields"].to_h] }
  end

  after { Card::Cache.reset_all }

  describe "the classifier" do
    it "recognises a real account's password and salt rows by codename" do
      password = Card.fetch("Joe User+*account+*password")
      salt = Card.fetch("Joe User+*account+*salt")
      skip "the seed has no account rows for Joe User" unless password && salt
      expect(encoder.credential_bearing?(password)).to be(true)
      expect(encoder.credential_bearing?(salt)).to be(true)
    end

    it "recognises a right part with the secret_key codename" do
      right = Card::Codename.id(:secret_key)
      expect(right).to be_a(Integer)
      card = bot { Card.create!(name: "RecaptchaProbe#{hex}+#{Card.find(right).name}", type: "Phrase", content: marker) }
      expect(card.right_id).to eq(right)
      expect(encoder.credential_bearing?(card)).to be(true)
    end

    it "recognises real API key records, whose rows hold no name or key column" do
      name = "MCP API Keys+probe#{hex}"
      cards = bot do
        [Card.create!(name: name, type: "Basic", content: marker),
         Card.create!(name: "#{name}+key_hash", type: "Phrase", content: marker),
         Card.create!(name: "#{name}+metadata", type: "PlainText", content: marker)]
      end
      expect(Card.where(id: cards.map(&:id)).pluck(:name, :key).flatten.compact.reject(&:empty?)).to eq([])
      cards.each { |c| expect(encoder.credential_bearing?(Card.find(c.id))).to be(true) }
    end

    it "recognises a real OAuth client record, whose derived key is not what its name suggests" do
      card = bot { Card.create!(name: "MCP OAuth Clients+probe#{hex}", type: "PlainText", content: marker) }
      fresh = Card.find(card.id)
      expect(fresh.key).to start_with("mcp_o_auth_client+")
      expect(encoder.credential_bearing?(fresh)).to be(true)
    end

    it "leaves an ordinary card alone, including one with a credential-sounding right part and no codename" do
      plain = bot { Card.create!(name: "Ordinary#{hex}", type: "Basic", content: "real content") }
      lookalike = bot { Card.create!(name: "Ordinary#{hex}+metadata", type: "Basic", content: "real content") }
      expect(encoder.credential_bearing?(plain)).to be(false)
      expect(encoder.credential_bearing?(Card.find(lookalike.id))).to be(false)
    end

    it "leaves the containers themselves alone" do
      container = bot { Card["MCP API Keys"] || Card.create!(name: "MCP API Keys", type: "Basic", content: "about") }
      expect(encoder.credential_bearing?(container)).to be(false)
    end
  end

  describe "a real save, through the real outbox writer" do
    around { |example| with_gate("true") { example.run } }
    before { MirrorState.first.update!(bootstrap_a_start: Card::Action.maximum(:id)) }

    let(:record) { bot { Card.create!(name: "MCP API Keys+probe#{hex}+key_hash", type: "Phrase", content: "#{marker}-first") } }

    it "a create carries the sentinel and no value" do
      atoms = latest_atoms(record.id)
      expect(atoms["DeckoCard"]["Content"]).to eq(sentinel)
      expect(atoms.to_json).not_to include(marker)
    end

    it "an update carries the sentinel in old and new, and keeps the field's name" do
      bot { Card.find(record.id).update!(content: "#{marker}-second") }
      atoms = latest_atoms(record.id)
      expect(atoms["DeckoCard"]["Content"]).to eq(sentinel)
      expect(atoms["DeckoProvenance"]["changes"]).to include("field" => "db_content", "old" => sentinel, "new" => sentinel)
      expect(atoms.to_json).not_to include(marker)
    end

    it "the value stays in Postgres, where logins and the deck still need it" do
      expect(Card.find(record.id).db_content).to eq("#{marker}-first")
    end

    it "the row is queued, not failed: the drain will carry it" do
      record
      expect(MirrorOutbox.where(card_id: record.id).order(:id).last.status).to eq("queued")
    end

    it "an ordinary card's event is unchanged" do
      card = bot { Card.create!(name: "Ordinary#{hex}", type: "Basic", content: "first") }
      bot { Card.find(card.id).update!(content: "second") }
      atoms = latest_atoms(card.id)
      expect(atoms["DeckoCard"]["Content"]).to eq("second")
      expect(atoms["DeckoProvenance"]["changes"]).to include("field" => "db_content", "old" => "first", "new" => "second")
    end
  end

  describe "what a reader gets" do
    it "the read client decodes the sentinel to its name" do
      atom = Atomspace::SidecarReadClient.new(account: nil).send(
        :to_atom, { "atom" => "DeckoCard", "fields" => [["Id", 1], ["Content", sentinel]] }
      )
      expect(atom.to_h).to include("Content" => "Redacted").or include(Content: "Redacted")
    end
  end

  describe "the drift sweep's Postgres side" do
    it "hashes a real credential card with the sentinel in place and the 14 fields intact" do
      card = bot { Card.create!(name: "MCP API Keys+probe#{hex}+key_hash", type: "Phrase", content: marker) }
      atoms = encoder.encode_card_snapshot(Card.find(card.id))
      expect(atoms.first["fields"].size).to eq(14)
      expect(CanonicalProjection.serialize(atoms)).to include('["Content",{"sym":"Redacted"}]')
      expect(CanonicalProjection.serialize(atoms)).not_to include(marker)
    end
  end
end
