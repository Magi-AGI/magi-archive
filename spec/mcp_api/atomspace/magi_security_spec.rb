# frozen_string_literal: true
#
# Magi security acceptance for the L9 read surface (PLAN 4.4). DB-backed with real cards and read
# rules: T2-T8, T17-T20, T27, T28. FakeReadClient stands in for the sidecar; it applies `limit`
# before the ACL filter exactly as the sidecar does. Real-sidecar runs are V4/E14.

require "spec_helper"

RSpec.describe "AtomSpace L9 Magi security", type: :request do
  MEMBER = "Joe User"  # roles: Shark
  ADMIN  = "Joe Admin" # roles: Administrator, Help Desk, Shark
  READ   = "mcp:atomspace:read"
  QADMIN = "mcp:atomspace:admin"

  def auth(sub: "user:#{MEMBER}", scope: READ, role: "user")
    payload = { "sub" => sub, "role" => role }
    payload["scope"] = scope if scope
    allow(McpApi::JwtService).to receive(:verify_token).and_return(payload)
    { "Authorization" => "Bearer test-token" }
  end

  def bot(&block) = Card::Auth.as_bot(&block)
  def uniq(prefix) = "#{prefix} #{SecureRandom.hex(4)}"
  def body = JSON.parse(response.body)
  def atom(card, **fields) = Atomspace::Atom.new(type: "DeckoCard", card_id: card.id, fields: fields)

  def restricted_card(prefix = "Secret", readers: "Administrator")
    name = uniq(prefix)
    bot do
      card = Card.create!(name: name, type: "Basic", content: "private")
      Card.create!(name: "#{name}+*self+*read", type: "List", content: "[[#{readers}]]")
      Card.fetch(card.id)
    end
  end

  def public_card(prefix = "Open") = bot { Card.create!(name: uniq(prefix), type: "Basic", content: "open") }

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  before do
    Card::Cache.reset_all
    Atomspace::ReadClient.bind!(Atomspace::FakeReadClient)
    Atomspace::FakeReadClient.seed!([])
    allow(Atomspace::MirrorReadiness).to receive(:check).and_return(Atomspace::MirrorReadiness::READY)
  end

  after do
    Atomspace::FakeReadClient.seed!([])
    Atomspace::ReadConsistencyPort.reset!
    # Card's in-memory cache outlives the transaction rollback; stale entries make specs order-dependent.
    Card::Cache.reset_all
  end

  def card_atom_ids(card, as: MEMBER, **params)
    get "/api/mcp/atomspace_mirror/get_card_atom",
        params: { card_id: card.id }.merge(params), headers: auth(sub: "user:#{as}")
    expect(response).to have_http_status(:ok), response.body
    body["results"].map { |r| r["card_id"] }
  end

  describe "T3 real restricted card" do
    let(:card) { restricted_card }
    before { Atomspace::FakeReadClient.seed!([atom(card)]) }

    it "hides it from a member" do
      expect(card_atom_ids(card, as: MEMBER)).to eq([])
    end

    it "shows it to an administrator" do
      expect(card_atom_ids(card, as: ADMIN)).to eq([card.id])
    end

    it "hides it from Anonymous at the filter" do
      filter = Class.new { include AtomspaceReadFilter }.new
      anon = Card["Anonymous"]
      expect(filter.send(:filter_by_read_auth, [atom(card)], anon)).to eq([])
    end

    it "shows a public card to a member" do
      open_card = public_card
      Atomspace::FakeReadClient.seed!([atom(open_card)])
      expect(card_atom_ids(open_card, as: MEMBER)).to eq([open_card.id])
    end
  end

  describe "T4 reference edges" do
    it "drops a public referer's edge to a private referee for a least-privilege reader" do
      open_card = public_card
      secret = restricted_card
      Atomspace::FakeReadClient.seed!(
        [Atomspace::Atom.new(type: "DeckoReference", referer_id: open_card.id, referee_id: secret.id)]
      )
      get "/api/mcp/atomspace_mirror/list_references", params: { card_id: open_card.id }, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to eq([])
    end
  end

  describe "T5 trash" do
    it "returns no atom for a trashed card to a user or an admin, even with include_trash" do
      card = public_card
      Atomspace::FakeReadClient.seed!([atom(card)])
      bot { card.delete! }
      expect(card_atom_ids(card, as: MEMBER, include_trash: true)).to eq([])
      expect(card_atom_ids(card, as: ADMIN, include_trash: true)).to eq([])
    end
  end

  describe "T6 inherited restrictions" do
    it "hides a child created under a _left-governed restricted parent" do
      parent = restricted_card("Parent")
      right = uniq("Tagged")
      bot { Card.create!(name: "#{right}+*right+*read", type: "List", content: "_left") }
      child = bot { Card.create!(name: "#{parent.name}+#{right}", type: "Basic", content: "c") }
      Atomspace::FakeReadClient.seed!([atom(child)])
      expect(card_atom_ids(child, as: MEMBER)).to eq([])
    end

    it "hides an existing child when the parent's rule is saved afterwards" do
      parent = public_card("Later Parent")
      right = uniq("LaterTag")
      bot { Card.create!(name: "#{right}+*right+*read", type: "List", content: "_left") }
      child = bot { Card.create!(name: "#{parent.name}+#{right}", type: "Basic", content: "c") }
      bot { Card.create!(name: "#{parent.name}+*self+*read", type: "List", content: "[[Administrator]]") }
      Card::Cache.reset_all if defined?(Card::Cache)
      Atomspace::FakeReadClient.seed!([atom(child)])
      expect(card_atom_ids(child, as: MEMBER)).to eq([])
    end

    it "hides a card governed directly by a *right read rule" do
      right = uniq("AdminOnlyTag")
      bot { Card.create!(name: "#{right}+*right+*read", type: "List", content: "[[Administrator]]") }
      card = bot { Card.create!(name: "#{uniq('Base')}+#{right}", type: "Basic", content: "c") }
      Atomspace::FakeReadClient.seed!([atom(card)])
      expect(card_atom_ids(card, as: MEMBER)).to eq([])
    end
  end

  describe "T7 real roles confer nothing" do
    def scopes(name) = McpApi::AtomspaceGrants.scopes_for("user:#{name}", user_card: Card[name])

    around { |ex| with_env("ATOMSPACE_READ_GRANTS" => nil, "ATOMSPACE_ADMIN_GRANTS" => nil) { ex.run } }

    it "gives a real Administrator member nothing when not allowlisted" do
      expect(scopes(ADMIN)).to eq([])
    end

    it "gives a real member of a Raw Data Analyst role nothing (post-refresh negative)" do
      role = bot { Card.create!(name: "Raw Data Analyst", type: "Role") }
      bot { Card.fetch("#{role.name}+*members", new: {}).tap { |m| m.add_item!(MEMBER) } }
      expect(bot { Card[MEMBER].fetch("*roles")&.item_names }).to include("Raw Data Analyst")
      expect(scopes(MEMBER)).to eq([])
    end
  end

  describe "T8 quarantine matrix" do
    let(:path) { "/api/mcp/atomspace_mirror/quarantine/card/5" }

    { "read only" => READ, "admin only" => QADMIN, "read + generic mcp:admin" => "#{READ} mcp:admin" }.each do |label, scope|
      it "403s #{label}" do
        get path, headers: auth(sub: "user:#{ADMIN}", scope: scope, role: "admin")
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "allows read + atomspace admin" do
      get path, headers: auth(sub: "user:#{ADMIN}", scope: "#{READ} #{QADMIN}", role: "admin")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "T28 maintenance-only quarantine" do
    let(:card) { public_card }
    let(:path) { "/api/mcp/atomspace_mirror/quarantine/card/#{card.id}/delete" }
    let(:both) { auth(sub: "user:#{ADMIN}", scope: "#{READ} #{QADMIN}", role: "admin") }

    before { Atomspace::FakeReadClient.seed!([atom(card)]) }

    it "refuses delete with the flag unset and leaves the Space unchanged" do
      with_env("ATOMSPACE_QUARANTINE_DELETE_ENABLED" => nil) { post path, headers: both }
      expect(response).to have_http_status(:forbidden)
      expect(body["error"]).to eq("quarantine_delete_disabled")
      expect(Atomspace::FakeReadClient.atoms.size).to eq(1)
    end

    it "refuses delete before the readiness gate, so a refusal reveals no mirror state" do
      allow(Atomspace::MirrorReadiness).to receive(:check)
        .and_return(Atomspace::MirrorReadiness::Result.new(ready: false, reason: "mirroring_disabled"))
      with_env("ATOMSPACE_QUARANTINE_DELETE_ENABLED" => nil) { post path, headers: both }
      expect(body["error"]).to eq("quarantine_delete_disabled")
    end

    it "then fails reads closed with sidecar_below_expected once a window's delete drops below the baseline" do
      allow(Atomspace::MirrorReadiness).to receive(:check).and_call_original
      other = public_card
      Atomspace::FakeReadClient.seed!([atom(card), atom(other)])
      MirrorState.first.update!(bootstrap_a_start: 1, draining_enabled: true)
      MirrorBootstrapRun.create!(a_start: 1, status: "completed", cards_swept: 2)

      with_env("ATOMSPACE_MIRRORING_ENABLED" => "true", "ATOMSPACE_QUARANTINE_DELETE_ENABLED" => "true") do
        post path, headers: both
        expect(response).to have_http_status(:ok), response.body
        expect(body["results"]["removed_count"]).to eq(1)

        get "/api/mcp/atomspace_mirror/atom_types", headers: auth
        expect(response).to have_http_status(503)
        expect(body).to include("error" => "mirror_not_ready", "reason" => "sidecar_below_expected")

        post path, headers: auth(sub: "user:#{ADMIN}", scope: "#{READ} #{QADMIN}", role: "admin")
        expect(response).to have_http_status(503)
      end
    end
  end

  describe "T17 pre-auth limit (characterization of the accepted residual)" do
    let(:secret) { restricted_card }
    let(:marker) { public_card("Marker") }

    def query(limit:)
      get "/api/mcp/atomspace_mirror/query_atoms",
          params: { pattern: '{"fields":{"Content":"V"}}', limit: limit }, headers: auth
      expect(response).to have_http_status(:ok)
    end

    it "reports pre_auth_best_effort and lets an earlier private match suppress the marker" do
      Atomspace::FakeReadClient.seed!([atom(secret), atom(marker)])
      query(limit: 1)
      expect(body["results"]).to eq([])
      expect(body["_meta"]["limit_semantics"]).to eq("pre_auth_best_effort")

      Atomspace::FakeReadClient.seed!([atom(marker)])
      query(limit: 1)
      expect(body["results"].map { |r| r["card_id"] }).to eq([marker.id])
    end

    it "behaves the same on list_atoms_by_type" do
      Atomspace::FakeReadClient.seed!([atom(secret), atom(marker)])
      get "/api/mcp/atomspace_mirror/list_atoms_by_type",
          params: { type_name: "DeckoCard", limit: 1 }, headers: auth
      expect(body["results"]).to eq([])
      expect(body["_meta"]["limit_semantics"]).to eq("pre_auth_best_effort")
    end
  end

  describe "T18 read-your-writes authorization" do
    around { |ex| with_env("READ_YOUR_WRITES_MAX_WAIT_SECONDS" => "0.2", "READ_YOUR_WRITES_POLL_INTERVAL_MS" => "20") { ex.run } }
    before { Atomspace::ReadConsistencyPort.impl = ReadConsistency }

    def outbox(card, event_id, status)
      MirrorOutbox.create!(event_id: event_id, event_kind: "decko_action", action_id: rand(10**9..2 * 10**9),
                           card_id: card.id, status: status)
    end

    def ryw(card, event_id, as: MEMBER)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      get "/api/mcp/atomspace_mirror/get_card_atom",
          params: { card_id: card.id, wait_for_event_id: event_id }, headers: auth(sub: "user:#{as}")
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    let(:open_card) { public_card }
    let(:secret) { restricted_card }

    it "makes a private event indistinguishable from a nonexistent one for every status" do
      missing = "decko:action:999999999"
      ryw(open_card, missing) # the first request in a process is slower; do not time it
      missing_time = ryw(open_card, missing)
      missing_status = response.status
      missing_body = body.merge("event_id" => "X")

      %w[delivered failed queued].each do |status|
        event = "decko:action:#{SecureRandom.random_number(10**8) + 10**9}"
        outbox(secret, event, status)
        elapsed = ryw(open_card, event)
        expect(response.status).to eq(missing_status), "status #{status}: #{response.body}"
        expect(body.merge("event_id" => "X")).to eq(missing_body), "status #{status}"
        expect(elapsed).to be_within(0.15).of(missing_time)
      end
      expect(missing_status).to eq(503)
      expect(missing_body["error"]).to eq("staleness_timeout")
    end

    it "still reports the real status to an authorized reader" do
      failed = "decko:action:#{SecureRandom.random_number(10**8) + 10**9}"
      outbox(secret, failed, "failed")
      ryw(open_card, failed, as: ADMIN)
      expect(response).to have_http_status(503)
      expect(body["error"]).to eq("event_failed")

      delivered = "decko:action:#{SecureRandom.random_number(10**8) + 10**9}"
      outbox(open_card, delivered, "delivered")
      ryw(open_card, delivered, as: MEMBER)
      expect(response).to have_http_status(200)
    end

    it "stays fail-closed when the port is unbound" do
      Atomspace::ReadConsistencyPort.reset!
      ryw(open_card, "decko:action:1")
      expect(response).to have_http_status(503)
      expect(body["reason"]).to eq("read_consistency_not_wired")
    end
  end

  def seed_service_accounts
    %w[mcp-user mcp-gm mcp-admin].each { |n| bot { Card.create!(name: n, type: "User") } unless Card[n] }
  end

  describe "filter order" do
    it "still authenticates first when BaseController's filters have been re-registered behind ours" do
      allow(McpApi::JwtService).to receive(:verify_token).and_return(nil)
      get "/api/mcp/atomspace_mirror/atom_types", headers: { "Authorization" => "Bearer bad" }
      expect(response).to have_http_status(:unauthorized)

      get "/api/mcp/atomspace_mirror/atom_types"
      expect(response).to have_http_status(:unauthorized)

      get "/api/mcp/atomspace_mirror/atom_types", headers: auth
      expect(response).to have_http_status(:ok)
    end
  end

  describe "T19 unresolvable principals" do
    before { seed_service_accounts }

    %w[user:NoSuchPerson123 user:Administrator].each do |sub|
      it "401s #{sub} with no fallback to a service account" do
        get "/api/mcp/atomspace_mirror/atom_types", headers: auth(sub: sub, role: "user")
        expect(response).to have_http_status(:unauthorized)
        expect(body["error"]).to eq("principal_unresolved")
      end
    end

    it "401s a trashed user" do
      user = bot { Card.create!(name: uniq("Gone User"), type: "User") }
      name = user.name
      bot { user.delete! }
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth(sub: "user:#{name}")
      expect(response).to have_http_status(:unauthorized)
      expect(body["error"]).to eq("principal_unresolved")
    end

    it "leaves other mcp_api endpoints' fallback unchanged" do
      get "/api/mcp/types", headers: auth(sub: "user:NoSuchPerson123", role: "user", scope: nil)
      expect(response).not_to have_http_status(:unauthorized)
    end
  end

  describe "T27 non-user principals" do
    before { seed_service_accounts }

    [["key:deadbeef", "admin", "#{READ} #{QADMIN}"], ["key:deadbeef", "user", READ], ["svc:thing", "admin", READ]].each do |sub, role, scope|
      it "403s #{sub} role=#{role} on read and quarantine" do
        h = auth(sub: sub, role: role, scope: scope)
        get "/api/mcp/atomspace_mirror/atom_types", headers: h
        expect(response).to have_http_status(:forbidden)
        expect(body["error"]).to eq("principal_not_permitted")

        get "/api/mcp/atomspace_mirror/quarantine/card/5", headers: h
        expect(response).to have_http_status(:forbidden)
        expect(body["error"]).to eq("principal_not_permitted")
      end
    end

    it "never runs the filter as a role-fallback account" do
      expect(Card::Auth).not_to receive(:as).with("mcp-admin")
      get "/api/mcp/atomspace_mirror/get_card_atom", params: { card_id: 1 },
                                                     headers: auth(sub: "key:deadbeef", role: "admin")
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "B-3 no MCP state survives a halted request" do
    before { seed_service_accounts }

    # Card::Auth.current_id reads back as AnonymousID when unset, so check the stored value too.
    def expect_clean_state
      expect(Thread.current[:mcp_api_request]).to be_nil
      expect(Card::Auth.instance_variable_get(:@current_id)).to be_nil
      expect(Card::Auth.current_id).to eq(Card::AnonymousID)
    end

    it "clears it after a 403 key: admin rejection" do
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth(sub: "key:deadbeef", role: "admin", scope: "#{READ} #{QADMIN}")
      expect(response).to have_http_status(:forbidden)
      expect(body["error"]).to eq("principal_not_permitted")
      expect_clean_state
    end

    it "clears it after a 401 with no token" do
      get "/api/mcp/atomspace_mirror/atom_types"
      expect(response).to have_http_status(:unauthorized)
      expect_clean_state
    end

    it "clears it after a real user lacks the read scope" do
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth(scope: nil)
      expect(response).to have_http_status(:forbidden)
      expect_clean_state
    end

    it "clears it after a real user lacks the quarantine scope" do
      get "/api/mcp/atomspace_mirror/quarantine/card/5", headers: auth
      expect(response).to have_http_status(:forbidden)
      expect_clean_state
    end

    it "clears it after a refused quarantine delete" do
      with_env("ATOMSPACE_QUARANTINE_DELETE_ENABLED" => nil) do
        post "/api/mcp/atomspace_mirror/quarantine/card/5/delete", headers: auth(scope: "#{READ} #{QADMIN}")
      end
      expect(response).to have_http_status(:forbidden)
      expect_clean_state
    end

    it "clears it after the 503 readiness gate halts" do
      allow(Atomspace::MirrorReadiness).to receive(:check)
        .and_return(Atomspace::MirrorReadiness::Result.new(ready: false, reason: "mirroring_disabled"))
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect_clean_state
    end

    it "clears it after a request that succeeds, and after one that raises" do
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth
      expect(response).to have_http_status(:ok)
      expect_clean_state

      allow(Atomspace::ReadClient).to receive(:for).and_raise(Atomspace::ServiceUnavailable, "down")
      get "/api/mcp/atomspace_mirror/atom_types", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect_clean_state
    end
  end

  describe "T20 ACL-cache audit" do
    before { require Rails.root.join("mod/atomspace_mirror/lib/mirror_acl_audit").to_s }

    it "reports a stale read rule by id, repairs it to zero, and creates no card actions" do
      card = restricted_card
      good = public_card
      scope = Card.where(id: [card.id, good.id])
      expect(MirrorAclAudit.audit(scope: scope)).to be_clean

      stale_rule = Card.fetch(good.id).read_rule_id
      Card.where(id: card.id).update_all(read_rule_id: stale_rule)
      report = MirrorAclAudit.audit(scope: scope)
      expect(report.mismatched_ids).to eq([card.id])
      expect(report.checked).to eq(2)
      expect(report.to_h_report.to_s).not_to include("private")

      expect { MirrorAclAudit.repair!(report.mismatched_ids) }.not_to(change { Card::Action.count })
      expect(MirrorAclAudit.audit(scope: scope)).to be_clean
    end
  end

  describe "T11 quarantine routing" do
    it "does not route a non-integer card id to the quarantine actions" do
      recognized = begin
        Rails.application.routes.recognize_path("/api/mcp/atomspace_mirror/quarantine/card/1.9")
      rescue ActionController::RoutingError
        {}
      end
      expect(recognized[:controller]).not_to eq("api/mcp/atomspace_mirror")
    end
  end

  describe "T10 token and T13 sidecar defaults" do
    it "mints a scope claim with the magi-archive issuer" do
      token = McpApi::JwtService.generate_token(role: "user", api_key_id: "user:x", scopes: [READ])
      payload = JWT.decode(token, nil, false).first
      expect(payload["scope"]).to eq(READ)
      expect(payload["iss"]).to eq(ENV.fetch("JWT_ISSUER", "magi-archive"))
      expect(ENV["JWT_ISSUER"]).to be_nil
      expect(payload["iss"]).to eq("magi-archive")
    end

    it "defaults the sidecar client to loopback on 9407" do
      client = SidecarClient.new
      expect(client.instance_variable_get(:@host)).to eq("127.0.0.1")
      expect(client.instance_variable_get(:@port)).to eq(9407)
    end
  end

  describe "T2 hook phase" do
    around { |ex| with_env("ATOMSPACE_MIRRORING_ENABLED" => "true") { ex.run } }

    it "keeps the card save committed when the outbox writer raises after commit" do
      allow(MirrorOutboxWriter).to receive(:write).and_raise(StandardError, "writer down")
      name = uniq("T2")
      begin
        bot { Card.create!(name: name, type: "Basic", content: "kept") }
      rescue StandardError => e
        expect(e.message).to include("writer down")
      end
      expect(MirrorOutboxWriter).to have_received(:write)
      expect(Card.fetch(name)&.db_content).to eq("kept")
    end

    it "reports mirror_tables_unavailable when enabled before the tables exist" do
      allow(Atomspace::MirrorReadiness).to receive(:check).and_call_original
      conn = ActiveRecord::Base.connection
      MirrorRuntimeGuards::MIRROR_TABLES.each { |t| conn.drop_table(t, force: :cascade) }
      MirrorState.reset_column_information
      result = nil
      conn.transaction(requires_new: true) do
        result = Atomspace::MirrorReadiness.check
        raise ActiveRecord::Rollback # the probe's rescued PG error aborts this savepoint
      end
      expect(result.ready?).to be(false)
      expect(result.reason).to eq("mirror_tables_unavailable")
    end
  end
end
