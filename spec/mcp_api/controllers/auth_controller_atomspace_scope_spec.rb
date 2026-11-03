# frozen_string_literal: true

require "spec_helper"

# Mint-path proof for the Magi grant policy: the scope claim that actually lands in the issued JWT.
# The grant matrix itself is unit-tested in spec/mcp_api/lib/atomspace_grants_spec.rb.
RSpec.describe Api::Mcp::AuthController, type: :request do
  let(:user_card) { double("user_card", name: "Alice") }

  read_scope  = "mcp:atomspace:read"
  write_scope = "mcp:atomspace:write"
  admin_scope = "mcp:atomspace:admin"

  around do |example|
    vars = %w[ATOMSPACE_READ_GRANTS ATOMSPACE_ADMIN_GRANTS MCP_API_KEY]
    saved = vars.each_with_object({}) { |var, memo| memo[var] = ENV[var] }
    example.run
  ensure
    vars.each { |var| saved[var].nil? ? ENV.delete(var) : ENV[var] = saved[var] }
  end

  before do
    ENV.delete("ATOMSPACE_READ_GRANTS")
    ENV.delete("ATOMSPACE_ADMIN_GRANTS")
    allow(::Mcp::UserAuthenticator).to receive(:check_admin_status).and_return(false)
    allow(::Mcp::UserAuthenticator).to receive(:get_user_roles).and_return([])
  end

  # Scopes carried by the minted token, read back through the real verifier.
  def minted_scopes
    json = JSON.parse(response.body)
    payload = McpApi::JwtService.verify_token(json.fetch("token"))
    (payload["scope"] || "").split
  end

  def authenticate_as(role:)
    allow(::Mcp::UserAuthenticator).to receive(:authenticate)
      .and_return({ user: user_card, role: role })
    post "/api/mcp/auth", params: { username: "Alice", password: "pw" }, as: :json
  end

  describe "human principals" do
    it "mints NO atomspace scope for an admin who is not allowlisted" do
      allow(::Mcp::UserAuthenticator).to receive(:check_admin_status).with(user_card).and_return(true)

      authenticate_as(role: "admin")

      expect(response).to have_http_status(:created)
      expect(minted_scopes.grep(/atomspace/)).to be_empty
    end

    it "mints NO atomspace scope for a Raw Data Analyst who is not allowlisted" do
      allow(::Mcp::UserAuthenticator).to receive(:get_user_roles)
        .with(user_card).and_return(["Raw Data Analyst"])

      authenticate_as(role: "user")

      expect(response).to have_http_status(:created)
      expect(minted_scopes.grep(/atomspace/)).to be_empty
    end

    it "mints read only for a read-listed user" do
      ENV["ATOMSPACE_READ_GRANTS"] = "user:Alice"

      authenticate_as(role: "user")

      expect(minted_scopes).to eq([read_scope])
    end

    it "mints read + atomspace admin, never write or generic admin, for an admin-listed user" do
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "user:Alice"

      authenticate_as(role: "admin")

      expect(minted_scopes).to eq([read_scope, admin_scope])
      expect(minted_scopes).not_to include(write_scope, "mcp:admin")
    end
  end

  describe "API-key principals" do
    let(:legacy_key) { "abcd1234efgh5678" }

    before do
      # Force the legacy ENV-key branch so the spec does not depend on API-key cards in the DB.
      allow(::Mcp::ApiKeyManager).to receive(:authenticate).and_return(nil)
      ENV["MCP_API_KEY"] = legacy_key
    end

    it "mints NO atomspace scope for a role:admin API key" do
      post "/api/mcp/auth", params: { api_key: legacy_key, role: "admin" }, as: :json

      expect(response).to have_http_status(:created)
      expect(minted_scopes.grep(/atomspace/)).to be_empty
    end

    it "mints NO atomspace scope even when the key principal is in both lists" do
      ENV["ATOMSPACE_READ_GRANTS"] = "key:#{legacy_key.slice(0, 8)}"
      ENV["ATOMSPACE_ADMIN_GRANTS"] = "key:#{legacy_key.slice(0, 8)}"

      post "/api/mcp/auth", params: { api_key: legacy_key, role: "admin" }, as: :json

      expect(response).to have_http_status(:created)
      expect(minted_scopes.grep(/atomspace/)).to be_empty
    end
  end
end
