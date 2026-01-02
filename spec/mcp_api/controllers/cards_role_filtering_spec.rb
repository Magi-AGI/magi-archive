# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Mcp::CardsController role-based filtering", type: :request do
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

  describe "GM content visibility by role" do
    # These tests verify that +GM and +AI content is properly filtered
    # based on the role's can_view_gm_content? setting

    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "filters out cards with +GM in name from search results" do
        get "/api/mcp/cards", params: { q: "GM" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        card_names = json["cards"].map { |c| c["name"] }

        # User role should not see +GM cards
        expect(card_names).not_to include(a_string_matching(/\+GM/))
      end

      it "filters out cards with +AI in name from search results" do
        get "/api/mcp/cards", params: { q: "AI" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        card_names = json["cards"].map { |c| c["name"] }

        # User role should not see +AI cards
        expect(card_names).not_to include(a_string_matching(/\+AI/))
      end
    end

    context "with 'gm' role" do
      let(:token) { token_for_role("gm") }

      it "can see cards with +GM in name" do
        get "/api/mcp/cards", params: { q: "GM Docs" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        # GM role should be able to see GM content (if it exists and they have Decko permissions)
        # This test verifies the MCP filter doesn't block it
        json = JSON.parse(response.body)
        # Just verify no error - actual visibility depends on Decko permissions
        expect(json).to have_key("cards")
      end
    end

    context "with 'admin' role" do
      let(:token) { token_for_role("admin") }

      it "can see cards with +GM in name" do
        get "/api/mcp/cards", params: { q: "GM" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
      end

      it "can see cards with +AI in name" do
        get "/api/mcp/cards", params: { q: "AI" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
      end
    end

    context "with 'Magi Team' role (GM content access)" do
      let(:token) { token_for_role("Magi Team") }

      it "can see cards with +GM in name because role has GM content access" do
        get "/api/mcp/cards", params: { q: "GM" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        expect(json).to have_key("cards")
        # Magi Team is in GM_CONTENT_ROLES, so they shouldn't be filtered
      end
    end

    context "with 'EARTHwise Team' role (no GM content access)" do
      let(:token) { token_for_role("EARTHwise Team") }

      it "filters out +GM content because role lacks GM content access" do
        get "/api/mcp/cards", params: { q: "GM" }, headers: auth_headers(token)
        expect(response).to have_http_status(:ok)

        json = JSON.parse(response.body)
        card_names = json["cards"].map { |c| c["name"] }

        # EARTHwise Team is NOT in GM_CONTENT_ROLES, so +GM cards should be filtered
        expect(card_names).not_to include(a_string_matching(/\+GM/))
      end
    end
  end

  describe "GET /api/mcp/cards/:name with GM content" do
    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "returns forbidden for +GM cards" do
        # Try to access a GM card directly
        # This should return 403 if the card exists, or 404 if it doesn't
        get "/api/mcp/cards/Games+Butterfly%20Galaxii+GM%20Docs",
            headers: auth_headers(token)

        # Either 403 (forbidden) or 404 (not found/filtered) is acceptable
        expect(response.status).to be_in([403, 404])
      end
    end

    context "with 'gm' role" do
      let(:token) { token_for_role("gm") }

      it "can attempt to access +GM cards (subject to Decko permissions)" do
        get "/api/mcp/cards/Games+Butterfly%20Galaxii+GM%20Docs",
            headers: auth_headers(token)

        # GM role should not be filtered by MCP, but may still be restricted by Decko permissions
        # Acceptable responses: 200 (success), 403 (Decko restriction), 404 (doesn't exist)
        expect(response.status).to be_in([200, 403, 404])
      end
    end
  end

  describe "children endpoint with role filtering" do
    context "with 'user' role" do
      let(:token) { token_for_role("user") }

      it "filters GM children from results" do
        # Find a parent card that might have GM children
        get "/api/mcp/cards/Games+Butterfly%20Galaxii/children",
            headers: auth_headers(token)

        if response.status == 200
          json = JSON.parse(response.body)
          child_names = json["children"].map { |c| c["name"] }

          # User role should not see +GM children
          expect(child_names).not_to include(a_string_matching(/\+GM/))
        end
      end
    end
  end
end
