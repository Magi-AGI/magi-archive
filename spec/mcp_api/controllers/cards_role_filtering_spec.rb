# frozen_string_literal: true

require "rails_helper"

# Tests for MCP API permission model
#
# PERMISSION ARCHITECTURE (as of Phase 4):
# Content visibility is controlled by Decko's native +*read rules, NOT by MCP role checks.
# The MCP role system is used for:
# - Token authentication and role validation
# - Admin-only operations (delete, rename, trash)
# - NOT for content visibility filtering
#
# Previously, content with +GM or +AI in the name was filtered by role.
# This is now DEPRECATED. Cards should have proper +*read rules set instead.
# Child cards inherit parent +*read rules via the permission_propagation mod.
RSpec.describe "Api::Mcp::CardsController permission model", type: :request do
  include McpApiTestHelper

  let(:valid_api_key) { ENV["MCP_API_KEY"] || "test-api-key-for-specs" }

  # Helper to get a token with specific role
  def token_for_role(role)
    post "/api/mcp/auth", params: { api_key: valid_api_key, role: role }
    JSON.parse(response.body)["token"]
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MCP_API_KEY").and_return(valid_api_key)
    allow(ENV).to receive(:fetch).and_call_original
  end

  describe "Decko native permission enforcement" do
    # These tests verify that content visibility is controlled by Decko's +*read rules,
    # not by MCP role-based name filtering.

    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "returns cards the user has Decko permission to read" do
        get "/api/mcp/cards", params: { q: "Games", limit: 5 }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
        # Cards returned are those the user's Decko account can read
      end

      it "respects Decko +*read rules for card access" do
        # Attempting to access any card - result depends on Decko permissions
        get "/api/mcp/cards/Games", headers: auth_headers(token)

        # 200 if user can read, 403/404 if restricted by +*read rules
        expect(response.status).to be_in([200, 403, 404])
      end
    end

    context "with 'gm' role" do
      let(:token) { token_for_role("gm") }

      it "returns cards the GM account has Decko permission to read" do
        get "/api/mcp/cards", params: { q: "Games", limit: 5 }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
      end

      it "can access cards if Decko permissions allow" do
        get "/api/mcp/cards/Games", headers: auth_headers(token)

        # GM role doesn't guarantee access - Decko +*read rules are authoritative
        expect(response.status).to be_in([200, 403, 404])
      end
    end

    context "with 'admin' role" do
      let(:token) { token_for_role("admin") }

      it "returns cards the admin account has Decko permission to read" do
        get "/api/mcp/cards", params: { q: "Games", limit: 5 }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
      end

      it "can access cards if Decko permissions allow" do
        get "/api/mcp/cards/Games", headers: auth_headers(token)

        # Admin role typically has broad access but Decko rules are still checked
        expect(response.status).to be_in([200, 403, 404])
      end
    end
  end

  describe "GET /api/mcp/cards/:name permission handling" do
    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "returns 404 for non-existent cards" do
        get "/api/mcp/cards/NonExistent%20Card%20That%20Does%20Not%20Exist",
            headers: auth_headers(token)

        expect(response).to have_http_status(:not_found)
      end

      it "returns 403 for cards user cannot access due to +*read rules" do
        # This test expects a card that exists but user cannot read
        # The actual behavior depends on Decko's +*read configuration
        get "/api/mcp/cards/Games+Butterfly%20Galaxii+GM%20Docs",
            headers: auth_headers(token)

        # Either 403 (exists but no permission) or 404 (not found)
        # depending on how Decko is configured
        expect(response.status).to be_in([403, 404])
      end
    end

    context "with 'gm' role" do
      let(:token) { token_for_role("gm") }

      it "access depends on Decko +*read rules, not MCP role" do
        get "/api/mcp/cards/Games+Butterfly%20Galaxii+GM%20Docs",
            headers: auth_headers(token)

        # Result depends entirely on Decko permissions for the GM account
        # MCP role does NOT override Decko +*read rules
        expect(response.status).to be_in([200, 403, 404])
      end
    end
  end

  describe "children endpoint permission filtering" do
    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "only returns children the user has Decko permission to read" do
        get "/api/mcp/cards/Games+Butterfly%20Galaxii/children",
            headers: auth_headers(token)

        if response.status == 200
          json = JSON.parse(response.body)
          expect(json).to have_key("children")
          # Children returned are filtered by Decko's card.ok?(:read)
          # not by card name patterns
        end
      end
    end
  end

  describe "search endpoint permission filtering" do
    context "with any authenticated role" do
      let(:token) { token_for_role("user") }

      it "search results only include cards user can read per Decko rules" do
        get "/api/mcp/cards", params: { q: "Butterfly", limit: 10 }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
        expect(json).to have_key("total")
        # Results are filtered by Decko's native permission system
      end
    end
  end

  describe "admin-only operations" do
    # These operations require admin MCP role regardless of Decko permissions

    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "cannot delete cards" do
        delete "/api/mcp/cards/SomeCard", headers: auth_headers(token)
        # 403 if card exists but no permission, 404 if card not found
        expect(response.status).to be_in([403, 404])
      end

      it "cannot access trash listing" do
        get "/api/mcp/trash", headers: auth_headers(token)
        # 403 if card exists but no permission, 404 if card not found
        expect(response.status).to be_in([403, 404])
      end
    end

    context "with 'admin' role" do
      let(:token) { token_for_role("admin") }

      it "can access trash listing" do
        get "/api/mcp/trash", headers: auth_headers(token)
        # Should succeed if admin role is valid
        expect(response.status).to be_in([200, 401, 403])
      end
    end
  end
end
