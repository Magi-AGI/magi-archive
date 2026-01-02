# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Mcp::AuthController role handling", type: :request do
  let(:valid_api_key) { ENV["MCP_API_KEY"] || "test-api-key-for-specs" }

  before do
    # Ensure MCP_API_KEY is set for API key auth tests
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MCP_API_KEY").and_return(valid_api_key)
    allow(ENV).to receive(:fetch).and_call_original
  end

  describe "POST /api/mcp/auth with role parameter" do
    context "with legacy MCP roles" do
      it "accepts 'user' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "user" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("user")
      end

      it "accepts 'gm' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "gm" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("gm")
      end

      it "accepts 'admin' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "admin" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("admin")
      end
    end

    context "with Decko role names" do
      it "accepts 'Administrator' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "Administrator" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("Administrator")
      end

      it "accepts 'Game Master' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "Game Master" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("Game Master")
      end

      it "accepts 'Magi Team' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "Magi Team" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("Magi Team")
      end

      it "accepts 'EARTHwise Team' role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "EARTHwise Team" }
        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["role"]).to eq("EARTHwise Team")
      end
    end

    context "with invalid roles" do
      it "rejects non-existent role" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "superuser" }
        expect(response).to have_http_status(:bad_request)
        json = JSON.parse(response.body)
        expect(json["error"]["code"]).to eq("validation_error")
        expect(json["error"]["message"]).to include("Invalid role")
      end

      it "includes valid roles in error response" do
        post "/api/mcp/auth", params: { api_key: valid_api_key, role: "nonexistent" }
        expect(response).to have_http_status(:bad_request)
        json = JSON.parse(response.body)
        expect(json["error"]["details"]["valid_roles"]).to be_an(Array)
        expect(json["error"]["details"]["valid_roles"]).to include("Administrator")
      end
    end
  end

  describe "token payload contains role" do
    it "includes the requested role in the JWT payload" do
      post "/api/mcp/auth", params: { api_key: valid_api_key, role: "gm" }
      expect(response).to have_http_status(:created)

      json = JSON.parse(response.body)
      token = json["token"]

      # Verify the token contains the role
      payload = McpApi::JwtService.verify_token(token)
      expect(payload["role"]).to eq("gm")
    end

    it "includes Decko role name in the JWT payload" do
      post "/api/mcp/auth", params: { api_key: valid_api_key, role: "Magi Team" }
      expect(response).to have_http_status(:created)

      json = JSON.parse(response.body)
      token = json["token"]

      payload = McpApi::JwtService.verify_token(token)
      expect(payload["role"]).to eq("Magi Team")
    end
  end
end
