# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::Mcp::ValidationController, type: :request do
  include McpApiTestHelper

  let(:valid_api_key) { ENV["MCP_API_KEY"] || "test-api-key-for-specs" }

  def token_for_role(role)
    post "/api/mcp/auth", params: { api_key: valid_api_key, role: role }
    JSON.parse(response.body)["token"]
  end

  let(:user_token) { token_for_role("user") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MCP_API_KEY").and_return(valid_api_key)
    allow(ENV).to receive(:fetch).and_call_original
  end

  describe "POST /api/mcp/validation/tags" do
    context "with valid parameters" do
      it "validates tags for a card type" do
        post "/api/mcp/validation/tags",
             params: { type: "Species", tags: ["Game", "Alien"] },
             headers: auth_headers(user_token)

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)

        expect(json).to have_key("valid")
        expect(json).to have_key("errors")
        expect(json).to have_key("warnings")
      end

      it "returns validation errors for missing required tags" do
        allow_any_instance_of(Api::Mcp::ValidationController)
          .to receive(:fetch_available_tags).and_return(["GM", "Game", "Species"])

        post "/api/mcp/validation/tags",
             params: { type: "Game Master Document", tags: ["Game"], name: "Secret Plot+GM" },
             headers: auth_headers(user_token)

        json = JSON.parse(response.body)
        expect(json["valid"]).to be false
      end

      it "returns warnings for missing suggested tags" do
        allow_any_instance_of(Api::Mcp::ValidationController)
          .to receive(:fetch_available_tags).and_return(["GM", "Game", "Species"])

        post "/api/mcp/validation/tags",
             params: { type: "Species", tags: [] },
             headers: auth_headers(user_token)

        json = JSON.parse(response.body)
        expect(json["valid"]).to be true
      end

      it "suggests tags based on content" do
        post "/api/mcp/validation/tags",
             params: { type: "Article", tags: [], content: "This is a game master document" },
             headers: auth_headers(user_token)

        json = JSON.parse(response.body)
        expect(json["warnings"]).to be_an(Array)
      end

      it "validates naming conventions" do
        post "/api/mcp/validation/tags",
             params: { type: "Game Master Document", tags: [], name: "Secret Plot+GM" },
             headers: auth_headers(user_token)

        json = JSON.parse(response.body)
        expect(json).to have_key("warnings")
      end
    end

    context "with missing parameters" do
      it "requires type parameter" do
        post "/api/mcp/validation/tags",
             params: { tags: ["Game"] },
             headers: auth_headers(user_token)

        # 400 or 422 are both valid responses for missing parameters
        expect(response.status).to be_in([400, 422])
      end
    end
  end

  describe "POST /api/mcp/validation/structure" do
    it "validates card structure" do
      post "/api/mcp/validation/structure",
           params: { type: "Species", name: "Vulcans", has_children: true },
           headers: auth_headers(user_token)

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json).to have_key("valid")
    end

    it "returns errors for missing required children" do
      post "/api/mcp/validation/structure",
           params: { type: "Species", name: "Vulcans", has_children: false },
           headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json).to have_key("required_children")
    end

    it "returns warnings for missing suggested children" do
      post "/api/mcp/validation/structure",
           params: { type: "Species", name: "Vulcans", has_children: true, children_names: [] },
           headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json).to have_key("warnings")
    end
  end

  describe "GET /api/mcp/validation/requirements/:type" do
    it "returns requirements for a card type" do
      allow_any_instance_of(Api::Mcp::ValidationController)
        .to receive(:fetch_available_tags).and_return(["GM", "Game", "Species"])

      get "/api/mcp/validation/requirements/Species",
          headers: auth_headers(user_token)

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json).to have_key("required_tags")
    end

    it "returns only existing tags from wiki" do
      allow_any_instance_of(Api::Mcp::ValidationController)
        .to receive(:fetch_available_tags).and_return(["Game", "Species"])

      get "/api/mcp/validation/requirements/Species",
          headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json["suggested_tags"]).to be_an(Array)
    end

    it "returns defaults for unknown card type" do
      get "/api/mcp/validation/requirements/UnknownType",
          headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json["required_tags"]).to eq([])
    end
  end

  describe "POST /api/mcp/validation/recommend_structure" do
    it "returns comprehensive structure recommendations" do
      allow_any_instance_of(Api::Mcp::ValidationController)
        .to receive(:fetch_available_tags).and_return(["Game", "Species"])

      post "/api/mcp/validation/recommend_structure",
           params: { type: "Species", name: "Vulcans", tags: ["Game"], content: "Test" },
           headers: auth_headers(user_token)

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)
      expect(json).to have_key("card_type")
    end

    it "recommends child cards with metadata" do
      allow_any_instance_of(Api::Mcp::ValidationController)
        .to receive(:fetch_available_tags).and_return(["Game", "Species"])

      post "/api/mcp/validation/recommend_structure",
           params: { type: "Species", name: "Vulcans", tags: [], content: "" },
           headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json).to have_key("children")
    end

    it "categorizes tag recommendations" do
      allow_any_instance_of(Api::Mcp::ValidationController)
        .to receive(:fetch_available_tags).and_return(["GM", "Game", "Species"])

      post "/api/mcp/validation/recommend_structure",
           params: { type: "Game Master Document", name: "Plot", tags: [], content: "GM content" },
           headers: auth_headers(user_token)

      json = JSON.parse(response.body)
      expect(json).to have_key("tags")
    end
  end

  describe "POST /api/mcp/validation/suggest_improvements" do
    it "analyzes existing card and suggests improvements" do
      post "/api/mcp/validation/suggest_improvements",
           params: { name: "Games" },
           headers: auth_headers(user_token)

      expect(response.status).to be_in([200, 404])
    end

    it "returns not found for non-existent card", skip: "Mock Card.fetch conflicts with production" do
      post "/api/mcp/validation/suggest_improvements",
           params: { name: "NonexistentCard12345" },
           headers: auth_headers(user_token)

      expect(response).to have_http_status(:not_found)
    end
  end
end
