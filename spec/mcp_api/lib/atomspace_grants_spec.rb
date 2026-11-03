# frozen_string_literal: true

require "spec_helper"

# Magi grant policy for the AtomSpace scopes (SPEC 8.3, T7). Explicit allowlists only: no Decko role
# confers a scope. Principals must be a real user, for both lists.
RSpec.describe McpApi::AtomspaceGrants do
  let(:user_card) { double("user_card", name: "Alice") }

  read_scope  = "mcp:atomspace:read"
  write_scope = "mcp:atomspace:write"
  admin_scope = "mcp:atomspace:admin"

  around do |example|
    saved = %w[ATOMSPACE_READ_GRANTS ATOMSPACE_ADMIN_GRANTS].to_h { |v| [v, ENV[v]] }
    saved.each_key { |v| ENV.delete(v) }
    example.run
  ensure
    saved.each { |v, val| val.nil? ? ENV.delete(v) : ENV[v] = val }
  end

  describe "removed Hyperon role-derived grants" do
    it "has no policy grant or Raw Data Analyst role" do
      expect(described_class).not_to respond_to(:policy_granted_user?)
      expect(described_class).not_to respond_to(:raw_data_analyst?)
      expect(described_class.const_defined?(:RAW_DATA_ANALYST_ROLE)).to be(false)
    end

    it "never looks up the user's roles or admin status" do
      expect(::Mcp::UserAuthenticator).not_to receive(:check_admin_status)
      expect(::Mcp::UserAuthenticator).not_to receive(:get_user_roles)
      described_class.scopes_for("user:Alice", user_card: user_card)
    end
  end

  describe "read allowlist" do
    it "grants read only to a listed user" do
      ENV["ATOMSPACE_READ_GRANTS"] = " user:Alice , user:Bob "
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq([read_scope])
    end

    it "grants nothing to an unlisted user or with the list unset" do
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq([])
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Bob"
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq([])
    end
  end

  describe "admin allowlist" do
    it "grants read + atomspace admin to a listed user" do
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).to eq([read_scope, admin_scope])
    end

    it "does not grant admin from the read list" do
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Alice"
      expect(described_class.scopes_for("user:Alice", user_card: user_card)).not_to include(admin_scope)
    end
  end

  describe "non-user principals (API-key closure)" do
    it "ignores a key: entry in either list" do
      ENV["ATOMSPACE_READ_GRANTS"] = "key:9f3c"
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "key:9f3c"
      expect(described_class.scopes_for("key:9f3c")).to eq([])
      expect(described_class.scopes_for("key:9f3c", user_card: user_card)).to eq([])
    end

    it "requires a user card even for a listed user: principal" do
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Alice"
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"
      expect(described_class.scopes_for("user:Alice")).to eq([])
    end
  end

  describe "scopes that are never minted" do
    it "never mints write or the generic mcp:admin" do
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Alice"
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"
      scopes = described_class.scopes_for("user:Alice", user_card: user_card)
      expect(scopes).not_to include(write_scope)
      expect(scopes).not_to include("mcp:admin")
    end
  end

  it "keeps the SCOPE alias pointing at the read scope" do
    expect(described_class::SCOPE).to eq(read_scope)
  end
end
