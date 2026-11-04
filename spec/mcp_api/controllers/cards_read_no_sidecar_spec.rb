# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("mod/mcp_api/lib/atomspace/sidecar_read_client").to_s

# Reading a card comes from Postgres and never touches the sidecar. Reading an atom goes through the sidecar. The gem side of this
# split is spec/magi/archive/mcp/read_routing_spec.rb in magi-archive-mcp.
#
# With the real SidecarReadClient bound, every way to the sidecar is a trap, so a sidecar call is a test failure rather than a slow
# path. The denials here prove that neither route opened.
#   Atom route: the ACL itself is covered by spec/mcp_api/atomspace/magi_security_spec.rb (T2-T8, T17-T20, T27, T28),
#     controllers/atomspace_mirror_controller_spec.rb, spec/atomspace_mirror/read_rule_determinism_spec.rb and the live matrix
#     logs/impl9/p39_deck_matrix.rb. These examples don't duplicate that; they add the real SidecarReadClient in the path.
#   Ordinary route: these examples are the coverage that passes. cards_rendered_permission_spec.rb and cards_role_filtering_spec.rb
#     are aimed at it, but all 12 of their failing examples fail before any ACL runs (Card.fetch_id is undefined; a 401 from the test
#     token), and did before this work.
RSpec.describe "Card reads and the sidecar", type: :request do
  def bot(&block) = Card::Auth.as_bot(&block)
  def body = JSON.parse(response.body)

  def auth(sub: "user:Joe User", scope: "mcp:atomspace:read")
    allow(McpApi::JwtService).to receive(:verify_token).and_return("sub" => sub, "role" => "user", "scope" => scope)
    { "Authorization" => "Bearer test-token" }
  end

  def restricted_card(name)
    bot do
      card = Card.create!(name: name, type: "Basic", content: "private")
      Card.create!(name: "#{name}+*self+*read", type: "List", content: "[[Administrator]]")
      Card.fetch(card.id)
    end
  end

  let(:suffix) { SecureRandom.hex(4) }
  let(:name) { "RoutingParent#{suffix}" }
  let!(:parent) do
    bot do
      card = Card.create!(name: name, type: "Basic", content: "parent")
      Card.create!(name: "#{name}+RoutingChild", type: "Basic", content: "child")
      Card.create!(name: "RoutingReferer#{suffix}", type: "RichText", content: "see [[#{name}]]")
      card
    end
  end
  let(:sidecar_calls) { [] }

  around do |example|
    saved_impl = Atomspace::ReadClient.instance_variable_get(:@impl)
    saved_transport = Atomspace::SidecarReadClient.transport
    example.run
  ensure
    Atomspace::ReadClient.bind!(saved_impl)
    Atomspace::SidecarReadClient.transport = saved_transport
    Card::Cache.reset_all
  end

  before do
    Atomspace::ReadClient.bind!(Atomspace::SidecarReadClient)
    allow(SidecarUnixHttp).to receive(:exchange) do |*args|
      sidecar_calls << [:socket, args[1], args[2]]
      raise "the sidecar socket was touched"
    end
  end

  describe "(a) ordinary card reads bypass the sidecar entirely" do
    before do
      Atomspace::SidecarReadClient.transport = lambda do |verb, path, _body|
        sidecar_calls << [verb, path]
        raise "the sidecar transport was touched: #{verb} #{path}"
      end
    end

    after { expect(sidecar_calls).to eq([]) }

    it "cards#show returns 200" do
      get "/api/mcp/cards/#{name}", headers: auth
      expect(response).to have_http_status(:ok), response.body
      expect(body["name"]).to eq(name)
    end

    it "cards#index returns 200" do
      get "/api/mcp/cards", params: { q: name, limit: 5 }, headers: auth
      expect(response).to have_http_status(:ok), response.body
      # The default name search is built to find compound names, so the child is what it returns here.
      expect(body["cards"].map { |c| c["name"] }).to include("#{name}+RoutingChild")
    end

    it "cards#children returns 200" do
      get "/api/mcp/cards/#{name}/children", headers: auth
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("RoutingChild")
    end

    it "cards#referers returns 200" do
      get "/api/mcp/cards/#{name}/referers", headers: auth
      expect(response).to have_http_status(:ok), response.body
      expect(response.body).to include("RoutingReferer#{suffix}")
    end

    context "(c) when the reader may not read the card" do
      let(:secret_name) { "RoutingSecret#{suffix}" }
      let!(:secret) { restricted_card(secret_name) }

      it "cards#show refuses it" do
        get "/api/mcp/cards/#{secret_name}", headers: auth
        expect(response).to have_http_status(:forbidden), response.body
        expect(response.body).not_to include("private")
      end

      # The administrator's result is the control: without it, an empty result would pass for the wrong reason.
      it "cards#index leaves it out for the reader and returns it to an administrator" do
        detail = "#{secret_name}+RoutingDetail"
        bot { Card.create!(name: detail, type: "Basic", content: "private") }

        get "/api/mcp/cards", params: { q: secret_name, limit: 5 }, headers: auth
        expect(response).to have_http_status(:ok), response.body
        expect(body["cards"].map { |c| c["name"] }).not_to include(detail)

        get "/api/mcp/cards", params: { q: secret_name, limit: 5 }, headers: auth(sub: "user:Joe Admin")
        expect(response).to have_http_status(:ok), response.body
        expect(body["cards"].map { |c| c["name"] }).to include(detail)
      end

      it "an administrator can still read it, so the refusal is the ACL and not a broken route" do
        get "/api/mcp/cards/#{secret_name}", headers: auth(sub: "user:Joe Admin")
        expect(response).to have_http_status(:ok), response.body
      end
    end
  end

  describe "(b) atom reads do use the sidecar" do
    def wire_card(card)
      { "atom" => "DeckoCard", "fields" => [["Id", card.id], ["Name", card.name.to_s], ["Content", "from the Space"]] }
    end

    def serve_from_sidecar(card)
      Atomspace::SidecarReadClient.transport = lambda do |verb, path, sent|
        sidecar_calls << [verb, path, sent]
        case path
        when "/read" then [200, { "results" => [wire_card(card)] }]
        when "/health/watermark" then [200, { "last_applied_action_id" => 1 }]
        else [404, nil]
        end
      end
    end

    before { allow(Atomspace::MirrorReadiness).to receive(:check).and_return(Atomspace::MirrorReadiness::READY) }

    it "get_card_atom reaches the sidecar's read endpoint through the transport" do
      serve_from_sidecar(parent)
      get "/api/mcp/atomspace_mirror/get_card_atom", params: { card_id: parent.id }, headers: auth
      expect(response).to have_http_status(:ok), response.body

      read = sidecar_calls.find { |_verb, path, _sent| path == "/read" }
      expect(read).to match([:post, "/read", include(op: "get_card_atom", card_id: parent.id)])
      expect(body["results"].map { |r| r["card_id"] }).to eq([parent.id])
    end

    it "(c) drops a card the reader may not read, even though the sidecar returned it" do
      secret = restricted_card("RoutingSecret#{suffix}")
      serve_from_sidecar(secret)
      get "/api/mcp/atomspace_mirror/get_card_atom", params: { card_id: secret.id }, headers: auth
      expect(response).to have_http_status(:ok), response.body

      expect(sidecar_calls.map { |_verb, path, _sent| path }).to include("/read")
      expect(body["results"]).to eq([])
    end

    it "(c) refuses a caller with no atom scope before it reaches the sidecar" do
      serve_from_sidecar(parent)
      get "/api/mcp/atomspace_mirror/get_card_atom", params: { card_id: parent.id }, headers: auth(scope: nil)
      expect(response).to have_http_status(:forbidden), response.body
      expect(sidecar_calls).to eq([])
    end
  end
end
