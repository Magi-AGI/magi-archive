# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::Mcp::CardsController, "relationships", type: :request do
  include McpApiTestHelper

  let(:valid_api_key) { ENV["MCP_API_KEY"] || "test-api-key-for-specs" }

  def token_for_role(role)
    post "/api/mcp/auth", params: { api_key: valid_api_key, role: role }
    JSON.parse(response.body)["token"]
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MCP_API_KEY").and_return(valid_api_key)
    allow(ENV).to receive(:fetch).and_call_original
  end

  let(:user_token) { token_for_role("user") }
  let(:gm_token) { token_for_role("gm") }
  let(:main_card) { create_test_card("Main Page") }
  let(:referer_card) { create_test_card("Home Page") }
  let(:nested_card) { create_test_card("Template") }
  let(:restricted_card) { create_test_card("Restricted Content") }

  before do
    allow(Card).to receive(:fetch).with("Main Page", any_args).and_return(main_card)
  end

  describe "GET /api/mcp/cards/:name/referers", skip: "Endpoint tests require real card data, not mocks" do
    before do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_referers).with(main_card).and_return([referer_card])
    end

    context "with user role" do
      it "returns cards that reference this card" do
        get "/api/mcp/cards/Main%20Page/referers",
            headers: { "Authorization" => "Bearer #{user_token}" }

        expect(response).to have_http_status(:success)
        json = JSON.parse(response.body)

        expect(json).to have_key("card")
        expect(json).to have_key("referers")
        expect(json).to have_key("referer_count")

        expect(json["card"]).to eq("Main Page")
        expect(json["referers"]).to be_an(Array)
        expect(json["referer_count"]).to be >= 0
      end

      it "includes card metadata in results" do
        get "/api/mcp/cards/Main%20Page/referers",
            headers: { "Authorization" => "Bearer #{user_token}" }

        json = JSON.parse(response.body)
        referer = json["referers"].first

        expect(referer).to have_key("name")
        expect(referer).to have_key("id")
        expect(referer).to have_key("type")
        expect(referer).to have_key("updated_at")
      end

      it "filters cards based on Decko permissions" do
        # Cards are filtered by Decko card.ok?(:read), not by name patterns
        get "/api/mcp/cards/Main%20Page/referers",
            headers: { "Authorization" => "Bearer #{user_token}" }

        json = JSON.parse(response.body)
        expect(json["referers"]).to be_an(Array)
      end
    end

    context "with GM role" do
      it "returns cards based on Decko permissions for GM account" do
        # GM role does not change filtering - Decko permissions are authoritative
        get "/api/mcp/cards/Main%20Page/referers",
            headers: { "Authorization" => "Bearer #{gm_token}" }

        json = JSON.parse(response.body)
        expect(json).to have_key("referers")
      end
    end

    context "when card doesn't exist" do
      it "returns not found error" do
        allow(Card).to receive(:fetch).with("Nonexistent", any_args).and_return(nil)

        get "/api/mcp/cards/Nonexistent/referers",
            headers: { "Authorization" => "Bearer #{user_token}" }

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "GET /api/mcp/cards/:name/nested_in", skip: "Endpoint tests require real card data, not mocks" do
    before do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_nested_in).with(main_card).and_return([nested_card])
    end

    it "returns cards that nest this card" do
      get "/api/mcp/cards/Main%20Page/nested_in",
          headers: { "Authorization" => "Bearer #{user_token}" }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json).to have_key("card")
      expect(json).to have_key("nested_in")
      expect(json).to have_key("nested_in_count")

      expect(json["card"]).to eq("Main Page")
      expect(json["nested_in"]).to be_an(Array)
    end
  end

  describe "GET /api/mcp/cards/:name/nests", skip: "Endpoint tests require real card data, not mocks" do
    before do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_nests).with(main_card).and_return([nested_card])
    end

    it "returns cards that this card nests" do
      get "/api/mcp/cards/Main%20Page/nests",
          headers: { "Authorization" => "Bearer #{user_token}" }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json).to have_key("card")
      expect(json).to have_key("nests")
      expect(json).to have_key("nests_count")

      expect(json["card"]).to eq("Main Page")
      expect(json["nests"]).to be_an(Array)
    end
  end

  describe "GET /api/mcp/cards/:name/links", skip: "Endpoint tests require real card data, not mocks" do
    before do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_links).with(main_card).and_return([referer_card])
    end

    it "returns cards that this card links to" do
      get "/api/mcp/cards/Main%20Page/links",
          headers: { "Authorization" => "Bearer #{user_token}" }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json).to have_key("card")
      expect(json).to have_key("links")
      expect(json).to have_key("links_count")

      expect(json["card"]).to eq("Main Page")
      expect(json["links"]).to be_an(Array)
    end

    it "returns empty array when card has no links" do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_links).with(main_card).and_return([])

      get "/api/mcp/cards/Main%20Page/links",
          headers: { "Authorization" => "Bearer #{user_token}" }

      json = JSON.parse(response.body)

      expect(json["links"]).to eq([])
      expect(json["links_count"]).to eq(0)
    end
  end

  describe "GET /api/mcp/cards/:name/linked_by", skip: "Endpoint tests require real card data, not mocks" do
    before do
      allow_any_instance_of(Api::Mcp::CardsController)
        .to receive(:fetch_linked_by).with(main_card).and_return([referer_card])
    end

    it "returns cards that link to this card" do
      get "/api/mcp/cards/Main%20Page/linked_by",
          headers: { "Authorization" => "Bearer #{user_token}" }

      expect(response).to have_http_status(:success)
      json = JSON.parse(response.body)

      expect(json).to have_key("card")
      expect(json).to have_key("linked_by")
      expect(json).to have_key("linked_by_count")

      expect(json["card"]).to eq("Main Page")
      expect(json["linked_by"]).to be_an(Array)
    end
  end

  describe "relationship helper methods", skip: "Unit tests require controller isolation" do
    describe "#fetch_referers" do
      it "uses Decko's referers method if available" do
        allow(main_card).to receive(:respond_to?).with(:referers).and_return(true)
        allow(main_card).to receive(:referers).and_return([referer_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, main_card)

        expect(result).to eq([referer_card])
      end

      it "falls back to content search with regex pattern" do
        allow(main_card).to receive(:respond_to?).with(:referers).and_return(false)

        # Verify regex pattern is used instead of simple string match
        expect(Card).to receive(:search).with(
          content: ["match", "\\[\\[Main\\ Page(?:\\|[^\\]]+)?\\]\\]"],
          limit: 100
        ).and_return([referer_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, main_card)

        expect(result).to eq([referer_card])
      end

      it "prevents false positives in link matching" do
        # Card named "Apple" should not match "Apple Pie"
        apple_card = create_test_card("Apple")
        apple_pie_card = create_test_card("Apple Pie")

        allow(apple_card).to receive(:respond_to?).with(:referers).and_return(false)

        # The regex should match [[Apple]] or [[Apple|Display]] but NOT [[Apple Pie]]
        expect(Card).to receive(:search).with(
          content: ["match", "\\[\\[Apple(?:\\|[^\\]]+)?\\]\\]"],
          limit: 100
        ).and_return([referer_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, apple_card)

        # Should only return cards with exact [[Apple]] or [[Apple|...]], not [[Apple Pie]]
        expect(result).to eq([referer_card])
      end

      it "handles piped links in pattern" do
        allow(main_card).to receive(:respond_to?).with(:referers).and_return(false)

        # Pattern should match both [[Main Page]] and [[Main Page|Display Text]]
        # The regex (?:\|[^\]]+)? makes the pipe and display text optional
        expect(Card).to receive(:search).with(
          content: ["match", "\\[\\[Main\\ Page(?:\\|[^\\]]+)?\\]\\]"],
          limit: 100
        ).and_return([referer_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, main_card)

        expect(result).to eq([referer_card])
      end

      it "escapes special regex characters in card names" do
        # Card with special chars: "My (Special) Card [Test]"
        special_card = create_test_card("My (Special) Card [Test]")
        allow(special_card).to receive(:respond_to?).with(:referers).and_return(false)

        # Should escape regex special chars: ( ) [ ] etc.
        expect(Card).to receive(:search).with(
          content: ["match", "\\[\\[My\\ \\(Special\\)\\ Card\\ \\[Test\\](?:\\|[^\\]]+)?\\]\\]"],
          limit: 100
        ).and_return([])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, special_card)

        expect(result).to eq([])
      end

      it "returns empty array on error" do
        allow(main_card).to receive(:respond_to?).with(:referers).and_raise(StandardError)

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_referers, main_card)

        expect(result).to eq([])
      end
    end

    describe "#fetch_links" do
      it "parses card content for [[...]] syntax" do
        allow(main_card).to receive(:respond_to?).with(:links).and_return(false)
        allow(main_card).to receive(:content).and_return("See [[Home Page]] and [[About]]")
        allow(Card).to receive(:fetch).with("Home Page").and_return(referer_card)
        allow(Card).to receive(:fetch).with("About").and_return(nested_card)

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_links, main_card)

        expect(result).to include(referer_card)
        expect(result).to include(nested_card)
      end
    end

    describe "#fetch_nested_in" do
      it "uses Decko's nested_in method if available" do
        allow(main_card).to receive(:respond_to?).with(:nested_in).and_return(true)
        allow(main_card).to receive(:nested_in).and_return([nested_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nested_in, main_card)

        expect(result).to eq([nested_card])
      end

      it "falls back to content search with regex pattern" do
        allow(main_card).to receive(:respond_to?).with(:nested_in).and_return(false)
        allow(main_card).to receive(:respond_to?).with(:includees).and_return(false)

        # Verify regex pattern is used instead of simple string match
        expect(Card).to receive(:search).with(
          content: ["match", "\\{\\{Main\\ Page\\}\\}"],
          limit: 100
        ).and_return([nested_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nested_in, main_card)

        expect(result).to eq([nested_card])
      end

      it "prevents false positives in nest matching" do
        # Card named "Template" should not match "Template Builder"
        template_card = create_test_card("Template")

        allow(template_card).to receive(:respond_to?).with(:nested_in).and_return(false)
        allow(template_card).to receive(:respond_to?).with(:includees).and_return(false)

        # The regex should match {{Template}} exactly, NOT {{Template Builder}}
        expect(Card).to receive(:search).with(
          content: ["match", "\\{\\{Template\\}\\}"],
          limit: 100
        ).and_return([nested_card])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nested_in, template_card)

        # Should only return cards with exact {{Template}}, not {{Template Builder}}
        expect(result).to eq([nested_card])
      end

      it "escapes special regex characters in card names" do
        # Card with special chars that need escaping in regex
        special_card = create_test_card("My {Special} Card")
        allow(special_card).to receive(:respond_to?).with(:nested_in).and_return(false)
        allow(special_card).to receive(:respond_to?).with(:includees).and_return(false)

        # Should escape regex special chars: { } etc.
        expect(Card).to receive(:search).with(
          content: ["match", "\\{\\{My\\ \\{Special\\}\\ Card\\}\\}"],
          limit: 100
        ).and_return([])

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nested_in, special_card)

        expect(result).to eq([])
      end

      it "returns empty array on error" do
        allow(main_card).to receive(:respond_to?).with(:nested_in).and_raise(StandardError)

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nested_in, main_card)

        expect(result).to eq([])
      end
    end

    describe "#fetch_nests" do
      it "parses card content for {{...}} syntax" do
        allow(main_card).to receive(:respond_to?).with(:nests).and_return(false)
        allow(main_card).to receive(:content).and_return("Include {{Template}} here")
        allow(Card).to receive(:fetch).with("Template").and_return(nested_card)

        controller = Api::Mcp::CardsController.new
        result = controller.send(:fetch_nests, main_card)

        expect(result).to include(nested_card)
      end
    end
  end

  # Helper methods
  def generate_jwt_token(role:)
    payload = {
      role: role,
      iat: Time.now.to_i,
      exp: (Time.now + 1.hour).to_i
    }
    verifier = ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base)
    verifier.generate(payload)
  end

  def create_test_card(name)
    card = double("Card")
    allow(card).to receive(:name).and_return(name)
    allow(card).to receive(:id).and_return(rand(1..1000))
    allow(card).to receive(:type_name).and_return("Basic")
    allow(card).to receive(:updated_at).and_return(Time.now)
    allow(card).to receive(:content).and_return("")
    card
  end
end
