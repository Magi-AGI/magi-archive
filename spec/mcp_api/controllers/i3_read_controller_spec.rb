# frozen_string_literal: true

require "spec_helper"

# I3 read surface (VIEW, lane D) request specs.
#
# WHAT IS REAL vs STUBBED (important when reading a green run):
#   * REAL framework code under test: the whole before_action chain and its ORDER
#     (require_user_principal! -> require_i3_read_scope! -> require_i3_backend_ready!), the
#     principal gate that defeats BaseController's service-account fallback, the namespaced scope
#     gate, the strict param parse, the fail-closed readiness refusal, and the ACL filter
#     (AtomspaceReadFilter#filter_by_read_auth running under Card::Auth.as(account.name) with
#     Decko's real ok?(:read) and real +*read rules).
#   * STUBBED: only McpApi::JwtService.verify_token (so no RS256 keypair is minted -- the repo's
#     established pattern, atomspace_mirror_controller_spec.rb:19-29) and the I3 backend port (so
#     no store/sidecar process is needed). The auth/ACL decisions themselves are NOT stubbed.
RSpec.describe Api::Mcp::I3ReadController, type: :request do
  I3_SCOPE = "mcp:i3:read"

  # Stub the REAL verify path (string-keyed payload, as the controller reads it). `sub` resolves
  # @current_mcp_account through BaseController#find_mcp_account, so the principal gate runs for real.
  def auth(role: "user", scope: I3_SCOPE, sub: "user:Joe User")
    payload = { "sub" => sub, "role" => role }
    payload["scope"] = scope if scope
    allow(McpApi::JwtService).to receive(:verify_token).and_return(payload)
    { "Authorization" => "Bearer test-token" }
  end

  # A port stub standing in for the store. Readiness green by default so the other tiers exercise
  # their own behaviour.
  def bind_port(ready: true, reason: nil, addresses: {}, open_entries: {}, neighbour_entries: {})
    readiness = ready ? Atomspace::MirrorReadiness::READY
                      : Atomspace::MirrorReadiness::Result.new(ready: false, reason: reason)
    port = Atomspace::FixtureI3ReadPort.new(addresses: addresses, open_entries: open_entries,
                                            neighbour_entries: neighbour_entries)
    allow(port).to receive(:readiness).and_return(readiness)
    Atomspace::I3ReadPort.bind!(port)
    port
  end

  before { bind_port }
  after { Atomspace::I3ReadPort.reset! }

  def body
    JSON.parse(response.body)
  end

  # ====================================================================================
  # Authentication / principal
  # ====================================================================================
  describe "authentication" do
    it "401s with no Authorization header" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when the token does not verify" do
      allow(McpApi::JwtService).to receive(:verify_token).and_return(nil)
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: { "Authorization" => "Bearer bogus" }
      expect(response).to have_http_status(:unauthorized)
    end

    # The key-token path: role is SELF-ASSERTED on a key token, so a non-user subject is refused
    # outright regardless of the role claim.
    it "403s principal_not_permitted for a non-user: subject even with role admin and the scope" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(role: "admin", sub: "key:12345")
      expect(response).to have_http_status(:forbidden)
      expect(body["error"]).to eq("principal_not_permitted")
    end

    # THE SERVICE-ACCOUNT FALLBACK TEST. BaseController#find_mcp_account (base_controller.rb:81-91)
    # falls back to MCP_USER_NAME / MCP_GM_NAME / MCP_ADMIN_NAME when the subject does not resolve.
    # require_user_principal! must refuse that: the fallback account's id != the token subject.
    it "401s principal_unresolved when the subject does not resolve to a live User card" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(sub: "user:No Such Person At All")
      expect(response).to have_http_status(:unauthorized)
      expect(body["error"]).to eq("principal_unresolved")
    end

    it "does not let a service-account fallback stand in for the real user" do
      saved = ENV["MCP_USER_NAME"]
      ENV["MCP_USER_NAME"] = "Joe User" # a real card, but NOT the token's subject
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(sub: "user:Nonexistent Principal")
      ENV["MCP_USER_NAME"] = saved
      # Even though a usable account was found by the fallback, the principal gate refuses.
      expect(response).to have_http_status(:unauthorized)
      expect(body["error"]).to eq("principal_unresolved")
    end

    # ----------------------------------------------------------------------------------
    # FIX (a) REGRESSION: SERVICE ACCOUNT NAMED DIRECTLY AS THE SUBJECT.
    #
    # The id-comparison check above only defeats the MISMATCHED fallback. A token whose sub is
    # literally "user:<service account name>" takes find_mcp_account's DIRECT-SUBJECT branch
    # (base_controller.rb:73-79, which RETURNS at :78), so the role fallback is never entered;
    # the service accounts are real type:User cards, so user_account_for returns the SAME card and
    # the ids MATCH. Before the fix these requests SUCCEEDED as the administrative service account.
    # ----------------------------------------------------------------------------------
    describe "service account named directly as the token subject (fix a)" do
      def with_service_account(env_var, name)
        saved = ENV[env_var]
        ENV[env_var] = name
        account = Card::Auth.as_bot do
          Card[name] || Card.create!(name: name, type: "User")
        end
        yield account
      ensure
        saved.nil? ? ENV.delete(env_var) : ENV[env_var] = saved
      end

      # Each configured service account must be refused BY NAME, on its own subject, with the
      # EXISTING principal_not_permitted code (no new wire vocabulary).
      {
        "MCP_USER_NAME" => "mcp-user",
        "MCP_GM_NAME" => "mcp-gm",
        "MCP_ADMIN_NAME" => "mcp-admin"
      }.each do |env_var, default_name|
        it "403s principal_not_permitted for #{default_name} as its own subject (#{env_var} default)" do
          with_service_account(env_var, default_name) do |account|
            get "/api/mcp/i3/lookup", params: { name: "Anything" },
                headers: auth(sub: "user:#{account.name}")
            expect(response).to have_http_status(:forbidden)
            expect(body["error"]).to eq("principal_not_permitted")
          end
        end
      end

      it "refuses an ENV-OVERRIDDEN service-account name, not just the defaults" do
        with_service_account("MCP_ADMIN_NAME", "I3 Svc Admin #{SecureRandom.hex(4)}") do |account|
          get "/api/mcp/i3/lookup", params: { name: "Anything" },
              headers: auth(sub: "user:#{account.name}")
          expect(response).to have_http_status(:forbidden)
          expect(body["error"]).to eq("principal_not_permitted")
        end
      end

      # --------------------------------------------------------------------------------
      # ROUND-19 F1 REGRESSION: CANONICAL-ALIAS SERVICE PRINCIPALS.
      #
      # The previous guard compared the configured name to the card name with `casecmp?`, i.e.
      # case-insensitive DISPLAY-STRING equality. Decko does not identify cards that way:
      # Cardname#simple_key (cardname.rb:101-116) underscores, collapses every run of non-key
      # characters to "_" and stable-keys each part, so "mcp_admin", "mcp-admin", "MCP Admin"
      # and "mcp--admin" ALL resolve to ONE card.
      #
      # So a configured MCP_ADMIN_NAME="mcp_admin" resolves the STORED card "mcp-admin" through
      # BaseController's `Card[account_name]` (base_controller.rb:91), while casecmp? compared
      # "mcp_admin" to "mcp-admin", found them unequal, and ADMITTED the administrative service
      # identity. The fix compares PERSISTED CARD IDS -- the framework's own canonical identity --
      # so every alias collapses onto the same id and is refused.
      #
      # NOTE ON PREREQUISITES: these requests still carry a validly-signed I3-scoped token. This
      # is a SERVICE-EXCLUSION regression, not a signature-bypass test.
      # --------------------------------------------------------------------------------
      describe "canonical-alias service principals (round-19 F1)" do
        # The card is stored under its CANONICAL name; ENV configures a separator/case ALIAS.
        # Card[alias] must resolve the same card, and the guard must refuse it.
        [
          ["an underscore alias of a hyphenated card", "mcp-admin", "mcp_admin"],
          ["a hyphen alias of an underscored card",    "mcp_admin", "mcp-admin"],
          ["an uppercased alias",                      "mcp-admin", "MCP-ADMIN"],
          ["a space-separated alias",                  "mcp-admin", "mcp admin"],
          ["a doubled-separator alias",                "mcp-admin", "mcp--admin"],
          ["a surrounding-whitespace alias",           "mcp-admin", "  mcp-admin  "]
        ].each do |label, stored_name, configured_alias|
          it "403s principal_not_permitted for #{label}" do
            account = Card::Auth.as_bot do
              Card[stored_name] || Card.create!(name: stored_name, type: "User")
            end

            saved = ENV["MCP_ADMIN_NAME"]
            ENV["MCP_ADMIN_NAME"] = configured_alias
            begin
              # PRECONDITION: the alias really does resolve to the same stored card. If this
              # fails the test is not exercising the aliasing defect at all.
              resolved = Card::Auth.as_bot { Card[configured_alias] }
              expect(resolved&.id).to eq(account.id)

              get "/api/mcp/i3/lookup", params: { name: "Anything" },
                  headers: auth(sub: "user:#{account.name}")
              expect(response).to have_http_status(:forbidden)
              expect(body["error"]).to eq("principal_not_permitted")
              # A pre-authorization denial must still carry NO backend signal.
              expect(body["_meta"]).to eq("surface" => "i3")
            ensure
              saved.nil? ? ENV.delete("MCP_ADMIN_NAME") : ENV["MCP_ADMIN_NAME"] = saved
            end
          end
        end

        # The exclusion must not over-block: a real user whose name merely RESEMBLES a service
        # account but canonicalizes differently must still be admitted past the principal gate.
        it "does NOT refuse a real user whose name only resembles a service account" do
          user = Card::Auth.as_bot do
            Card["mcp-administrator-person"] ||
              Card.create!(name: "mcp-administrator-person", type: "User")
          end
          Card::Auth.as_bot { Card["mcp-admin"] || Card.create!(name: "mcp-admin", type: "User") }

          saved = ENV["MCP_ADMIN_NAME"]
          ENV["MCP_ADMIN_NAME"] = "mcp_admin"
          begin
            get "/api/mcp/i3/lookup", params: { name: "Anything" },
                headers: auth(sub: "user:#{user.name}")
            # Past the principal gate: NOT a principal refusal of any kind.
            expect(body["error"]).not_to eq("principal_not_permitted")
            expect(body["error"]).not_to eq("principal_unresolved")
          ensure
            saved.nil? ? ENV.delete("MCP_ADMIN_NAME") : ENV["MCP_ADMIN_NAME"] = saved
          end
        end

        # A configured name that resolves to NOTHING must exclude nobody -- the guard may not
        # fall back to string matching or guess an identity.
        it "excludes nobody when the configured service-account name resolves to no card" do
          user = Card::Auth.as_bot do
            Card["I3 Plain User"] || Card.create!(name: "I3 Plain User", type: "User")
          end

          saved = ENV["MCP_ADMIN_NAME"]
          ENV["MCP_ADMIN_NAME"] = "no-such-service-account-#{SecureRandom.hex(4)}"
          begin
            get "/api/mcp/i3/lookup", params: { name: "Anything" },
                headers: auth(sub: "user:#{user.name}")
            expect(body["error"]).not_to eq("principal_not_permitted")
          ensure
            saved.nil? ? ENV.delete("MCP_ADMIN_NAME") : ENV["MCP_ADMIN_NAME"] = saved
          end
        end
      end

      # The refusal must not depend on the self-asserted role claim.
      it "refuses the admin service account regardless of the role claim" do
        with_service_account("MCP_ADMIN_NAME", "mcp-admin") do |account|
          %w[user gm admin].each do |role|
            get "/api/mcp/i3/lookup", params: { name: "Anything" },
                headers: auth(role: role, sub: "user:#{account.name}")
            expect(response).to have_http_status(:forbidden)
            expect(body["error"]).to eq("principal_not_permitted")
          end
        end
      end

      # The refusal happens on the FIRST gate, so it must also apply to the card-scoped reads and
      # must never emit a backend/readiness signal (see the fix-d group below).
      it "refuses the service-account subject on every action, never reaching the backend" do
        with_service_account("MCP_ADMIN_NAME", "mcp-admin") do |account|
          headers = auth(sub: "user:#{account.name}")
          ["/api/mcp/i3/lookup", "/api/mcp/i3/card/1/open",
           "/api/mcp/i3/card/1/neighbours", "/api/mcp/i3/health"].each do |path|
            get path, headers: headers
            expect(response).to have_http_status(:forbidden)
            expect(body["error"]).to eq("principal_not_permitted")
            expect(body["_meta"]).not_to have_key("data_origin")
          end
        end
      end

      # A REAL user must still be admitted -- the name exclusion must not over-reject.
      it "still admits a real non-service user" do
        with_service_account("MCP_ADMIN_NAME", "mcp-admin") do
          get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth(sub: "user:Joe User")
          expect(response).not_to have_http_status(:forbidden)
          expect(response).not_to have_http_status(:unauthorized)
        end
      end
    end
  end

  # ====================================================================================
  # Scope denial -- namespaced, and NOT satisfied by mcp:atomspace:read
  # ====================================================================================
  describe "scope gate" do
    it "403s when no scope claim is present" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth(scope: nil)
      expect(response).to have_http_status(:forbidden)
      expect(body["error"]).to eq("forbidden")
    end

    it "403s a caller holding only mcp:atomspace:read (no widening)" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(scope: "mcp:atomspace:read mcp:atomspace:admin")
      expect(response).to have_http_status(:forbidden)
    end

    it "admits a caller holding mcp:i3:read" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth
      expect(response).not_to have_http_status(:forbidden)
      expect(response).not_to have_http_status(:unauthorized)
    end

    # Gate ORDER: scope is checked before readiness, so an unauthorized caller never learns
    # backend state.
    it "prefers 403 over the 503 readiness signal" do
      bind_port(ready: false, reason: "i3_read_port_unwired")
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(scope: "mcp:atomspace:read")
      expect(response).to have_http_status(:forbidden)
    end
  end

  # ====================================================================================
  # Malformed parameters -> 400 (never a 500)
  # ====================================================================================
  describe "malformed parameters" do
    it "400s a blank lookup name" do
      get "/api/mcp/i3/lookup", params: { name: "   " }, headers: auth
      expect(response).to have_http_status(:bad_request)
      expect(body["reason"]).to eq("name_required")
    end

    it "400s a missing lookup name" do
      get "/api/mcp/i3/lookup", headers: auth
      expect(response).to have_http_status(:bad_request)
      expect(body["reason"]).to eq("name_required")
    end

    it "400s a non-numeric limit on neighbours" do
      get "/api/mcp/i3/card/1/neighbours", params: { limit: "abc" }, headers: auth
      expect(response).to have_http_status(:bad_request)
      expect(body["reason"]).to eq("limit_invalid")
    end

    it "400s a zero limit on neighbours" do
      get "/api/mcp/i3/card/1/neighbours", params: { limit: "0" }, headers: auth
      expect(response).to have_http_status(:bad_request)
    end
  end

  # ====================================================================================
  # Backend not ready -> 503, fail closed, one distinct reason per mode
  # ====================================================================================
  describe "backend readiness (fail closed)" do
    it "503s with i3_read_port_unwired when no port is bound" do
      Atomspace::I3ReadPort.reset!
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_read_port_unwired")
    end

    it "503s and surfaces the port's distinct reason" do
      bind_port(ready: false, reason: "store_head_unavailable")
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["error"]).to eq("i3_backend_not_ready")
      expect(body["reason"]).to eq("store_head_unavailable")
    end

    it "503s rather than 500s when a readiness probe raises" do
      port = bind_port
      allow(port).to receive(:readiness).and_raise(RuntimeError, "boom")
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_readiness_probe_error:RuntimeError")
    end
  end

  # ====================================================================================
  # lookup: unknown vs backend-unavailable must be DISTINGUISHABLE; no deck-side digest
  # ====================================================================================
  describe "lookup" do
    it "reports an unknown name as a 200 unknown, not an error" do
      get "/api/mcp/i3/lookup", params: { name: "No Such Card Name Here" }, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to include("found" => false, "unknown" => true)
    end

    # VIEW is FORBIDDEN to compute a digest deck-side (adapter.py:1473-1476). A card that EXISTS and
    # is readable but has no backend address must be a 503, explicitly NOT an `unknown` and
    # explicitly NOT a locally-computed digest.
    it "503s backend_digest_unavailable for a readable card the backend cannot address" do
      card = Card::Auth.as_bot { Card.create!(name: "I3 Lookup Open #{SecureRandom.hex(4)}", type: "Basic") }
      get "/api/mcp/i3/lookup", params: { name: card.name }, headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("backend_digest_unavailable")
      expect(body["results"]).to be_nil
    end

    it "returns the backend's OWN key and digest when the port supplies them" do
      card = Card::Auth.as_bot { Card.create!(name: "I3 Lookup Addr #{SecureRandom.hex(4)}", type: "Basic") }
      bind_port(addresses: { card.id.to_s => { "key" => "(name card)", "digest" => "deadbeef" } })
      get "/api/mcp/i3/lookup", params: { name: card.name }, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to include("key" => "(name card)", "digest" => "deadbeef")
    end

    # The name resolution runs under the CALLER's authority, so a name the caller cannot read is
    # indistinguishable from one that does not exist -- this endpoint is not a permission oracle.
    it "reports a readable-to-nobody card as unknown rather than leaking its existence" do
      hidden = Card::Auth.as_bot do
        c = Card.create!(name: "I3 Hidden #{SecureRandom.hex(4)}", type: "Basic")
        Card.create!(name: "#{c.name}+*self+*read", type: "Pointer", content: "[[Administrator]]")
        c
      end
      bind_port(addresses: { hidden.id.to_s => { "key" => "(name hidden)", "digest" => "cafe" } })
      get "/api/mcp/i3/lookup", params: { name: hidden.name }, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to include("found" => false, "unknown" => true)
      expect(response.body).not_to include("cafe")
    end
  end

  # ====================================================================================
  # ACL filtering -- the security proof: a non-readable card is EXCLUDED from the payload
  # ====================================================================================
  describe "ACL filtering of card-scoped reads" do
    it "excludes an atom whose card the caller may not read, keeping the readable one" do
      readable, restricted = Card::Auth.as_bot do
        r = Card.create!(name: "I3 Public #{SecureRandom.hex(4)}", type: "Basic", content: "open")
        x = Card.create!(name: "I3 Secret #{SecureRandom.hex(4)}", type: "Basic", content: "shh")
        Card.create!(name: "#{x.name}+*self+*read", type: "Pointer", content: "[[Administrator]]")
        [r, x]
      end

      bind_port(neighbour_entries: {
        "1" => [
          Atomspace::Atom.new(type: "DeckoCard", card_id: readable.id, fields: { "Name" => readable.name }),
          Atomspace::Atom.new(type: "DeckoCard", card_id: restricted.id, fields: { "Name" => restricted.name })
        ]
      })

      get "/api/mcp/i3/card/1/neighbours", headers: auth
      expect(response).to have_http_status(:ok)
      ids = body["results"].map { |a| a["card_id"] }
      expect(ids).to include(readable.id)
      expect(ids).not_to include(restricted.id)
      expect(response.body).not_to include("shh")
    end

    it "excludes an atom with an unresolvable card id (default deny)" do
      bind_port(open_entries: {
        "1" => [Atomspace::Atom.new(type: "DeckoCard", card_id: 99_999_999)]
      })
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
    end
  end

  # ====================================================================================
  # FIX (b) REGRESSION: SOURCE-CARD AUTHORIZATION on open / neighbours.
  #
  # The output filter CANNOT cover this. filter_by_read_auth selects on
  # atom.associated_card_ids, and for a non-reference atom atom.rb:20-25 returns [@card_id] --
  # the NEIGHBOUR's id, never the SOURCE's. So before the fix, requesting the neighbours of a
  # card the caller may NOT read returned that card's READABLE neighbours: an existence /
  # permission oracle on the source card.
  #
  # The fix authorizes the requested source card BEFORE the backend call and collapses
  # "not readable" into the SAME response as "no readable atoms" -- an empty result in the
  # normal success shape, so nothing distinguishes a forbidden card from an empty one.
  # ====================================================================================
  describe "source-card authorization (fix b)" do
    # A restricted SOURCE card with a perfectly READABLE neighbour. The neighbour would pass the
    # output filter on its own merits, so only a source-card gate can suppress it.
    let!(:restricted_source) do
      Card::Auth.as_bot do
        c = Card.create!(name: "I3 Src Secret #{SecureRandom.hex(4)}", type: "Basic", content: "shh")
        Card.create!(name: "#{c.name}+*self+*read", type: "Pointer", content: "[[Administrator]]")
        c
      end
    end

    let!(:public_neighbour) do
      Card::Auth.as_bot do
        Card.create!(name: "I3 Nbr Public #{SecureRandom.hex(4)}", type: "Basic", content: "visible")
      end
    end

    it "does not disclose the readable neighbours of an unreadable source card" do
      bind_port(neighbour_entries: {
        restricted_source.id.to_s => [
          Atomspace::Atom.new(type: "DeckoCard", card_id: public_neighbour.id,
                              fields: { "Name" => public_neighbour.name })
        ]
      })

      get "/api/mcp/i3/card/#{restricted_source.id}/neighbours", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
      # The readable neighbour must NOT appear merely because the source was named.
      expect(response.body).not_to include(public_neighbour.name)
      expect(response.body).not_to include("visible")
    end

    it "does not disclose the atoms of an unreadable source card on open" do
      bind_port(open_entries: {
        restricted_source.id.to_s => [
          Atomspace::Atom.new(type: "DeckoCard", card_id: restricted_source.id,
                              fields: { "Name" => restricted_source.name })
        ]
      })

      get "/api/mcp/i3/card/#{restricted_source.id}/open", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
      expect(response.body).not_to include("shh")
    end

    # THE ORACLE TEST: an unreadable source and a nonexistent id must be BYTE-IDENTICAL, so the
    # response cannot be used to test for a card's existence.
    it "answers an unreadable source identically to a nonexistent card (no oracle)" do
      bind_port
      get "/api/mcp/i3/card/#{restricted_source.id}/neighbours", headers: auth
      restricted_status = response.status
      restricted_body = response.body

      get "/api/mcp/i3/card/99999999/neighbours", headers: auth
      expect(response.status).to eq(restricted_status)
      expect(response.body).to eq(restricted_body)
    end

    it "answers an unreadable source identically to a nonexistent card on open (no oracle)" do
      bind_port
      get "/api/mcp/i3/card/#{restricted_source.id}/open", headers: auth
      restricted_status = response.status
      restricted_body = response.body

      get "/api/mcp/i3/card/99999999/open", headers: auth
      expect(response.status).to eq(restricted_status)
      expect(response.body).to eq(restricted_body)
    end

    # The gate must run BEFORE the backend is consulted: no read reaches the port at all.
    it "never calls the backend for an unreadable source card" do
      port = bind_port
      expect(port).not_to receive(:neighbours)
      expect(port).not_to receive(:open)

      get "/api/mcp/i3/card/#{restricted_source.id}/neighbours", headers: auth
      get "/api/mcp/i3/card/#{restricted_source.id}/open", headers: auth
    end

    # And the READABLE path must still work -- the gate must not over-reject.
    it "still serves a readable source card's neighbours" do
      readable = Card::Auth.as_bot do
        Card.create!(name: "I3 Src Public #{SecureRandom.hex(4)}", type: "Basic", content: "open")
      end
      bind_port(neighbour_entries: {
        readable.id.to_s => [
          Atomspace::Atom.new(type: "DeckoCard", card_id: public_neighbour.id,
                              fields: { "Name" => public_neighbour.name })
        ]
      })

      get "/api/mcp/i3/card/#{readable.id}/neighbours", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(public_neighbour.id)
    end

    it "still serves a readable source card's own atoms on open" do
      readable = Card::Auth.as_bot do
        Card.create!(name: "I3 Src Open #{SecureRandom.hex(4)}", type: "Basic", content: "open")
      end
      bind_port(open_entries: {
        readable.id.to_s => [
          Atomspace::Atom.new(type: "DeckoCard", card_id: readable.id,
                              fields: { "Name" => readable.name })
        ]
      })

      get "/api/mcp/i3/card/#{readable.id}/open", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(readable.id)
    end

    # The source gate runs under the CALLER's identity -- never as_bot, never a service account.
    it "authorizes the source card as the caller, not as a bot" do
      expect(Card::Auth).not_to receive(:as_bot)
      bind_port
      get "/api/mcp/i3/card/#{restricted_source.id}/neighbours", headers: auth
      expect(body["results"]).to be_empty
    end
  end

  # ====================================================================================
  # FIX (c) REGRESSION: STRICT readiness, not Ruby truthiness.
  #
  # MirrorReadiness::Result#ready? (mirror_readiness.rb:33-35) returns the struct member
  # UNCOERCED, so Result.new(ready: "false") and ready: 0 are TRUTHY in Ruby. The old gate was a
  # bare `return if result.ready?`, so a malformed backend answer READ AS READY.
  # ====================================================================================
  describe "strict readiness (fix c)" do
    [["the STRING \"false\"", "false"], ["the INTEGER 0", 0], ["the STRING \"true\"", "true"]]
      .each do |label, value|
      it "503s rather than serving when the readiness verdict is #{label}" do
        port = Atomspace::FixtureI3ReadPort.new(open_entries: {
          "1" => [Atomspace::Atom.new(type: "DeckoCard", card_id: 1)]
        })
        allow(port).to receive(:readiness)
          .and_return(Atomspace::MirrorReadiness::Result.new(ready: value, reason: "synthetic"))
        Atomspace::I3ReadPort.bind!(port)

        get "/api/mcp/i3/card/1/open", headers: auth
        expect(response).to have_http_status(:service_unavailable)
        expect(body["error"]).to eq("i3_backend_not_ready")
        # The port rejects the non-boolean verdict as a contract violation.
        expect(body["reason"]).to eq("i3_readiness_contract_violation")
      end
    end

    it "still serves normally on a real boolean-true verdict" do
      bind_port(open_entries: { "1" => [] })
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:ok)
    end
  end

  # ====================================================================================
  # FIX (d) REGRESSION: no backend/origin signal on PRE-AUTHORIZATION denials.
  #
  # i3_meta carries data_origin ("fixture"/"live"/"unavailable") -- a backend signal. It was
  # emitted on three pre-auth paths (both principal refusals and the scope refusal), which
  # contradicted the surface's own order-of-gates contract: "An unauthorized caller therefore
  # never receives a readiness/backend signal."
  # ====================================================================================
  describe "pre-authorization denials leak no backend origin (fix d)" do
    it "omits data_origin on the principal_not_permitted refusal" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(role: "admin", sub: "key:12345")
      expect(response).to have_http_status(:forbidden)
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(body["_meta"]).not_to have_key("data_origin")
    end

    it "omits data_origin on the principal_unresolved refusal" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(sub: "user:No Such Person At All")
      expect(response).to have_http_status(:unauthorized)
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(body["_meta"]).not_to have_key("data_origin")
    end

    it "omits data_origin on the scope refusal" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(scope: "mcp:atomspace:read")
      expect(response).to have_http_status(:forbidden)
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(body["_meta"]).not_to have_key("data_origin")
    end

    # The leak was observable: an unauthorized caller could distinguish a bound port from an
    # unbound one. Both must now produce the SAME _meta.
    it "gives an unauthorized caller the same _meta whether or not a port is bound" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth(scope: nil)
      bound_meta = body["_meta"]

      Atomspace::I3ReadPort.reset!
      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth(scope: nil)
      expect(body["_meta"]).to eq(bound_meta)
      expect(response.body).not_to include("unavailable")
      expect(response.body).not_to include("fixture")
    end

    # POST-authorization responses must KEEP the full i3_meta: the fixture-labelling guarantee
    # (a fixture payload can never be read as live) depends on data_origin being present.
    it "still stamps data_origin on authorized responses" do
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(body["_meta"]["data_origin"]).to eq("fixture")

      get "/api/mcp/i3/lookup", params: { name: "No Such Card Name Here" }, headers: auth
      expect(body["_meta"]["data_origin"]).to eq("fixture")
    end

    it "still stamps data_origin on the readiness 503 (a post-auth refusal)" do
      bind_port(ready: false, reason: "store_head_unavailable")
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["_meta"]).to have_key("data_origin")
    end

    it "still stamps data_origin on a post-auth 400" do
      get "/api/mcp/i3/lookup", params: { name: "   " }, headers: auth
      expect(response).to have_http_status(:bad_request)
      expect(body["_meta"]).to have_key("data_origin")
    end
  end

  # ====================================================================================
  # ROUND-19 F4 REGRESSION: NO BACKEND/ORIGIN SIGNAL ON ANY PRE-AUTHORIZATION FAILURE,
  # INCLUDING THE EXCEPTIONAL ONE.
  #
  # The fix-d group above covers the three ORDINARY pre-auth denials. This group covers the two
  # paths that re-opened the same disclosure:
  #
  #   (1) AN EXCEPTION RAISED BEFORE AUTHORIZATION COMPLETED. It lands in
  #       render_unexpected_error (i3_read_controller.rb:502-512), which used to build its
  #       response with i3_meta -- so a caller who was NEVER authorized received the port's
  #       data_origin, exactly the signal the DENIED_META split removed.
  #
  #   (2) A REQUEST-ORIGIN FAILURE. If Atomspace::I3ReadPort.origin is ITSELF what raises, a
  #       handler that calls i3_meta RE-ENTERS the failing method and the fixed error response
  #       is never produced at all.
  #
  # The fix is the frozen ERROR_META constant (:71), derived from neither the request, the
  # exception nor the backend. Both paths must answer 500 i3_internal_error /
  # i3_unexpected_error with _meta == {"surface" => "i3"} and nothing else.
  # ====================================================================================
  describe "pre-authorization and origin failures leak nothing (round-19 F4)" do
    # F4: an exception DURING the principal gate -- i.e. before authorization succeeded.
    # user_account_for is called by require_user_principal! (i3_read_controller.rb:356), the
    # FIRST before_action, so nothing downstream has run and no gate has passed.
    it "contains a pre-authorization exception without consulting the backend" do
      port = bind_port
      # The port must not be asked ANYTHING on a path that never completed authorization.
      expect(port).not_to receive(:origin)
      expect(port).not_to receive(:readiness)
      expect(port).not_to receive(:open)
      expect(port).not_to receive(:neighbours)
      expect(port).not_to receive(:resolve_backend_address)

      allow_any_instance_of(Api::Mcp::I3ReadController)
        .to receive(:user_account_for)
        .and_raise(RuntimeError, "SECRET principal detail Card 42 +*read")

      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth

      expect(response).to have_http_status(:internal_server_error)
      expect(body["error"]).to eq("i3_internal_error")
      expect(body["reason"]).to eq("i3_unexpected_error")
      # CONSTANT metadata only: no data_origin on a caller who was never authorized.
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(body["_meta"]).not_to have_key("data_origin")
      # No backend labels and no inherited exception disclosure.
      expect(response.body).not_to include("fixture")
      expect(response.body).not_to include("unavailable")
      expect(body).not_to have_key("details")
      expect(response.body).not_to include("SECRET principal detail")
      expect(response.body).not_to include("RuntimeError")
      expect(response.body).not_to include("exception_message")
    end

    # F4: an exception in the SCOPE gate -- still before authorization completed.
    it "contains an exception raised in the scope gate with no backend signal" do
      port = bind_port
      expect(port).not_to receive(:origin)
      expect(port).not_to receive(:readiness)

      allow_any_instance_of(Api::Mcp::I3ReadController)
        .to receive(:token_scopes)
        .and_raise(RuntimeError, "SECRET scope internals")

      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth

      expect(response).to have_http_status(:internal_server_error)
      expect(body["error"]).to eq("i3_internal_error")
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(response.body).not_to include("SECRET scope internals")
      expect(response.body).not_to include("fixture")
    end

    # F4 ORDERING PROOF: the exceptional pre-auth response must be INDISTINGUISHABLE in its
    # _meta from the ordinary pre-auth denials -- one constant shape for every unauthorized
    # outcome, so no unauthorized caller can tell a bound port from an unbound one.
    it "gives an exceptional pre-auth failure the same _meta as an ordinary pre-auth denial" do
      get "/api/mcp/i3/lookup", params: { name: "Anything" },
          headers: auth(role: "admin", sub: "key:12345")
      expect(response).to have_http_status(:forbidden)
      denied_meta = body["_meta"]

      allow_any_instance_of(Api::Mcp::I3ReadController)
        .to receive(:user_account_for).and_raise(RuntimeError, "boom")
      get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: auth
      expect(response).to have_http_status(:internal_server_error)
      expect(body["_meta"]).to eq(denied_meta)
    end

    # F4: ORDINARY pre-auth denials must not consult the port AT ALL -- the ordering contract,
    # asserted on the port itself rather than only on the rendered _meta.
    it "never consults the port on an ordinary pre-authorization denial" do
      [
        -> { auth(role: "admin", sub: "key:12345") },      # principal_not_permitted
        -> { auth(sub: "user:No Such Person At All") },     # principal_unresolved
        -> { auth(scope: "mcp:atomspace:read") }            # scope forbidden
      ].each do |headers_proc|
        port = bind_port
        expect(port).not_to receive(:origin)
        expect(port).not_to receive(:readiness)
        expect(port).not_to receive(:resolve_backend_address)

        get "/api/mcp/i3/lookup", params: { name: "Anything" }, headers: headers_proc.call
        expect(response.status).to be_between(401, 403)
        expect(body["_meta"]).to eq("surface" => "i3")
      end
    end

    # F4 (2): THE REQUEST-ORIGIN FAILURE. origin is what raises, so a handler that called
    # i3_meta would re-enter it and never produce a response. ERROR_META is a constant, so the
    # fixed refusal is still produced.
    it "still produces the fixed refusal when the port's origin itself raises" do
      port = Atomspace::FixtureI3ReadPort.new
      allow(port).to receive(:origin).and_raise(RuntimeError, "SECRET origin internals")
      Atomspace::I3ReadPort.bind!(port)

      # A name that resolves to nothing: render_unknown is where i3_meta -- and therefore the
      # failing origin -- is reached on an otherwise entirely successful request.
      get "/api/mcp/i3/lookup", params: { name: "No Such Card Name Here" }, headers: auth

      expect(response).to have_http_status(:internal_server_error)
      expect(body["error"]).to eq("i3_internal_error")
      expect(body["reason"]).to eq("i3_unexpected_error")
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(response.body).not_to include("SECRET origin internals")
      expect(body).not_to have_key("details")
    end

    it "still produces the fixed refusal when origin raises on a card-scoped read" do
      readable = Card::Auth.as_bot do
        Card.create!(name: "I3 Origin Fail #{SecureRandom.hex(4)}", type: "Basic", content: "open")
      end
      port = Atomspace::FixtureI3ReadPort.new(open_entries: { readable.id.to_s => [] })
      allow(port).to receive(:origin).and_raise(RuntimeError, "SECRET origin internals")
      Atomspace::I3ReadPort.bind!(port)

      get "/api/mcp/i3/card/#{readable.id}/open", headers: auth

      expect(response).to have_http_status(:internal_server_error)
      expect(body["error"]).to eq("i3_internal_error")
      expect(body["_meta"]).to eq("surface" => "i3")
      expect(response.body).not_to include("SECRET origin internals")
    end

    # The last-resort metadata must be a FROZEN CONSTANT, so no handler can mutate the shared
    # hash into carrying a backend field on a later request.
    it "exposes frozen, backend-independent constants for both refusal metadata" do
      expect(Api::Mcp::I3ReadController::ERROR_META).to eq(surface: "i3")
      expect(Api::Mcp::I3ReadController::ERROR_META).to be_frozen
      expect(Api::Mcp::I3ReadController::DENIED_META).to eq(surface: "i3")
      expect(Api::Mcp::I3ReadController::DENIED_META).to be_frozen
      expect(Api::Mcp::I3ReadController::ERROR_META).not_to have_key(:data_origin)
      expect(Api::Mcp::I3ReadController::DENIED_META).not_to have_key(:data_origin)
    end
  end

  # ====================================================================================
  # Health: DECLARED capability-missing, never an invented health block
  # ====================================================================================
  describe "health (I3-01 / I3-09)" do
    it "refuses with a declared capability-missing reason instead of a health payload" do
      get "/api/mcp/i3/health", headers: auth
      expect(response).to have_http_status(:not_implemented)
      expect(body["error"]).to eq("capability_missing")
      expect(body["reason"]).to eq("i3_health_slice_unavailable_o23_gated")
      expect(body.keys).not_to include("epoch", "position", "read_at", "coverage", "health")
    end

    it "still requires auth and scope for the refusal" do
      get "/api/mcp/i3/health"
      expect(response).to have_http_status(:unauthorized)
      get "/api/mcp/i3/health", headers: auth(scope: "mcp:atomspace:read")
      expect(response).to have_http_status(:forbidden)
    end
  end

  # ====================================================================================
  # Fixture provenance: a fixture payload must never read as live data
  # ====================================================================================
  describe "fixture provenance" do
    it "stamps data_origin=fixture so a fixture response cannot pass as live" do
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(body["_meta"]["data_origin"]).to eq("fixture")
    end

    it "reports data_origin=unavailable when nothing is bound" do
      Atomspace::I3ReadPort.reset!
      get "/api/mcp/i3/health", headers: auth
      expect(body["_meta"]["data_origin"]).to eq("unavailable")
    end
  end

  # ====================================================================================
  # FIX (e) REGRESSION: PORT RESULT SHAPE VALIDATION.
  #
  # render_card_scoped used to be `Array(atoms)`, which maps nil -> [] and therefore turned a
  # MALFORMED/ABSENT upstream answer into a SUCCESSFUL 200 with an empty results list --
  # indistinguishable from a card that genuinely has no readable atoms. The empty case must stay
  # a normal 200; only a non-Array (or an element failing the atom contract) is a backend failure.
  # ====================================================================================
  describe "port result shape validation (fix e)" do
    def bind_raw(open_result)
      port = Atomspace::FixtureI3ReadPort.new
      allow(port).to receive(:open).and_return(open_result)
      allow(port).to receive(:neighbours).and_return(open_result)
      Atomspace::I3ReadPort.bind!(port)
    end

    # THE DISTINCTION THAT MATTERS: empty stays 200.
    it "renders a genuinely EMPTY array as a normal successful empty result" do
      bind_port(open_entries: { "1" => [] })
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]).to eq([])
      expect(body["_meta"]["limit_semantics"]).to eq("pre_auth_best_effort")
    end

    it "refuses a nil open result as a typed backend failure, NOT an empty 200" do
      bind_raw(nil)
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["error"]).to eq("i3_backend_unavailable")
      expect(body["reason"]).to eq("i3_backend_result_contract_violation")
      expect(body).not_to have_key("results")
    end

    it "refuses a nil neighbours result as a typed backend failure" do
      bind_raw(nil)
      get "/api/mcp/i3/card/1/neighbours", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_backend_result_contract_violation")
    end

    [["a Hash", { "atoms" => [] }], ["a String", "atoms"], ["a bare Integer", 3]].each do |label, value|
      it "refuses #{label} in place of an atom list" do
        bind_raw(value)
        get "/api/mcp/i3/card/1/open", headers: auth
        expect(response).to have_http_status(:service_unavailable)
        expect(body["reason"]).to eq("i3_backend_result_contract_violation")
      end
    end

    # An element that does not satisfy the contract the FILTER calls would otherwise
    # NoMethodError into the generic 500 path.
    it "refuses an array whose elements fail the atom contract" do
      bind_raw([Object.new])
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_backend_atom_contract_violation")
    end

    it "refuses a MIXED array where only one element fails the contract" do
      bind_raw([Atomspace::Atom.new(type: "DeckoCard", card_id: 1), Object.new])
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_backend_atom_contract_violation")
    end
  end

  # ====================================================================================
  # FIX (e) REGRESSION: ADDRESS TYPE VALIDATION on #lookup.
  #
  # The old check tested PRESENCE of key/digest only. A wrongly-TYPED address must fail closed
  # through the EXISTING 503 backend_digest_unavailable path -- never a partial or nil-valued
  # success, and never a locally-computed digest.
  # ====================================================================================
  describe "lookup address type validation (fix e)" do
    # Returns the PORT so an example can assert the backend was ACTUALLY consulted. Without that
    # assertion an unreadable subject card would collapse to `unknown` (a 200) and the address
    # validation under test would silently never run -- see the F5 fixture note on `target` below.
    def bind_address(address)
      port = Atomspace::FixtureI3ReadPort.new
      allow(port).to receive(:resolve_backend_address).and_return(address)
      Atomspace::I3ReadPort.bind!(port)
      port
    end

    # ROUND-19 F5 FIXTURE CORRECTION: the subject card is established through the spec's OWN
    # as_bot fixture mechanism (the pattern every other card-creating example here uses), and its
    # READABILITY TO THE CALLER is then proven per-example by asserting the port was reached --
    # the previous fixture leaned on an id whose readability was never established, so an example
    # could pass for the wrong reason (name -> `unknown`, validation never exercised).
    let!(:target) do
      Card::Auth.as_bot do
        Card.create!(name: "I3 Addr Target #{SecureRandom.hex(4)}", type: "Basic", content: "open")
      end
    end

    it "renders found:true for a well-typed String key and digest" do
      port = bind_address("key" => "(Card 724)", "digest" => "abc123")
      get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["results"]["found"]).to be(true)
      expect(body["results"]["key"]).to eq("(Card 724)")
      expect(body["results"]["digest"]).to eq("abc123")
      # The caller's own authority resolved the name, so the backend WAS asked for the address.
      expect(port).to have_received(:resolve_backend_address).with(card_id: target.id)
    end

    [
      ["an Integer key", { "key" => 724, "digest" => "abc123" }],
      ["an Integer digest", { "key" => "(Card 724)", "digest" => 999 }],
      ["an Array key", { "key" => ["(Card 724)"], "digest" => "abc123" }],
      ["a Hash digest", { "key" => "(Card 724)", "digest" => { "hex" => "abc" } }],
      ["a whitespace-only key", { "key" => "   ", "digest" => "abc123" }],
      ["a whitespace-only digest", { "key" => "(Card 724)", "digest" => "  " }],
      ["a nil digest", { "key" => "(Card 724)", "digest" => nil }],
      ["a missing digest key entirely", { "key" => "(Card 724)" }],
      ["a true digest", { "key" => "(Card 724)", "digest" => true }]
    ].each do |label, address|
      it "503s backend_digest_unavailable for #{label}, never a partial success" do
        port = bind_address(address)
        get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth
        expect(response).to have_http_status(:service_unavailable)
        expect(body["error"]).to eq("i3_backend_unavailable")
        expect(body["reason"]).to eq("backend_digest_unavailable")
        # No partial address, and NO SYNTHESISED DIGEST, on the wire.
        expect(body).not_to have_key("results")
        # F5 FIXTURE PROOF: the subject card really was readable by the caller and the port
        # really was consulted, so this 503 is the ADDRESS VALIDATION refusing -- not a name
        # that collapsed to `unknown` with the validation never reached.
        expect(port).to have_received(:resolve_backend_address).with(card_id: target.id)
      end
    end

    # ----------------------------------------------------------------------------------
    # ROUND-19 F5b REGRESSION: A STRING MUST NEVER BECOME A SUCCESSFUL ADDRESS.
    #
    # The old guard was `address.respond_to?(:[])`, which does NOT establish a mapping. Ruby
    # Strings answer `[]` with SUBSTRING SEARCH, so the malformed single-string address
    # "key digest" satisfied every downstream check:
    #   "key digest"["key"]    => "key"      (a String, non-blank)
    #   "key digest"["digest"] => "digest"   (a String, non-blank)
    # and #lookup rendered found:true carrying an address EXTRACTED FROM MALFORMED INPUT --
    # an authoritative-looking address no backend ever issued. Arrays answer `[]` too.
    #
    # The fix requires the DECLARED MAPPING TYPE (`address.is_a?(Hash)`,
    # i3_read_controller.rb:316) BEFORE any extraction, so these fail closed on the TYPED
    # AddressUnavailable -> 503 backend_digest_unavailable path -- never a success, and never
    # the generic 500 i3_internal_error path.
    # ----------------------------------------------------------------------------------
    [
      ["the exact string \"key digest\" the old respond_to?(:[]) check ADMITTED", "key digest"],
      ["a plain String address", "(Card 724)"],
      ["an Array address", ["(Card 724)", "abc123"]],
      ["an Array of pairs", [%w[key (Card724)], %w[digest abc123]]],
      ["a bare Integer address", 724],
      ["a Symbol-keyed non-Hash (a Struct)", Struct.new(:key, :digest).new("(Card 724)", "abc123")]
    ].each do |label, address|
      it "503s backend_digest_unavailable for #{label}" do
        port = bind_address(address)
        get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth

        # TYPED 503, not success and not the generic 500.
        expect(response).to have_http_status(:service_unavailable)
        expect(body["error"]).to eq("i3_backend_unavailable")
        expect(body["reason"]).to eq("backend_digest_unavailable")
        expect(body["error"]).not_to eq("i3_internal_error")

        # NOTHING extracted from the malformed input reaches the wire: no found:true, no
        # fabricated key/digest, no substring-derived address.
        expect(body).not_to have_key("results")
        expect(response.body).not_to include("\"found\":true")
        expect(response.body).not_to include("\"key\"")
        expect(response.body).not_to include("\"digest\"")

        # And the refusal is the ADDRESS VALIDATION's, on a genuinely readable subject card.
        expect(port).to have_received(:resolve_backend_address).with(card_id: target.id)
      end
    end

    # The substring-extraction defect, asserted on its own terms: the two tokens the old check
    # pulled out of "key digest" must appear NOWHERE in the response.
    it "never renders the substrings the old check extracted from \"key digest\"" do
      bind_address("key digest")
      get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["results"]).to be_nil
      expect(response.body).not_to include("key digest")
    end

    it "503s rather than rendering when the address is not Hash-like at all" do
      bind_address("(Card 724)")
      get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("backend_digest_unavailable")
    end

    it "503s when the port answers nil instead of an address" do
      bind_address(nil)
      get "/api/mcp/i3/lookup", params: { name: target.name }, headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("backend_digest_unavailable")
    end
  end

  # ====================================================================================
  # FIX (e) REGRESSION: an UNEXPECTED error must not leak the inherited exception detail.
  #
  # BaseController#handle_error (base_controller.rb:125-137) renders
  # details: { exception: <class>, exception_message: exception.message } -- deliberately, per its
  # own T2 comment. On this surface that message is a disclosure channel, so I3 registers its own
  # StandardError handler. base_controller.rb is NOT modified.
  # ====================================================================================
  describe "unexpected error containment (fix e)" do
    it "returns a typed non-detailed refusal and leaks no exception message" do
      port = Atomspace::FixtureI3ReadPort.new
      allow(port).to receive(:open).and_raise(RuntimeError, "SECRET Card 42 read_rule leaked")
      Atomspace::I3ReadPort.bind!(port)

      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:internal_server_error)
      expect(body["error"]).to eq("i3_internal_error")
      expect(body["reason"]).to eq("i3_unexpected_error")
      # NOTHING derived from the exception: no inherited details block, no class, no message.
      expect(body).not_to have_key("details")
      expect(response.body).not_to include("SECRET Card 42")
      expect(response.body).not_to include("RuntimeError")
      expect(response.body).not_to include("exception_message")
    end

    it "does not swallow the typed backend handlers it must not outrank" do
      port = Atomspace::FixtureI3ReadPort.new
      allow(port).to receive(:open).and_raise(Atomspace::ServiceUnavailable, "boom")
      Atomspace::I3ReadPort.bind!(port)

      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["error"]).to eq("i3_backend_unavailable")
      expect(body["reason"]).to eq("i3_backend_unavailable")
    end

    it "still maps an unwired port to its own typed 503, not the unexpected-error path" do
      Atomspace::I3ReadPort.reset!
      get "/api/mcp/i3/card/1/open", headers: auth
      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_read_port_unwired")
    end
  end

  # ====================================================================================
  # `participant=` SUBJECT ADDRESSING -- the `~k` KEY-TEXT REPAIR.
  #
  # WHY THIS BLOCK EXISTS: the entire `participant` resolution path shipped with ZERO coverage.
  # No spec in this file mentioned `participant`, `require_subject_card_id!` or
  # `resolve_participant_reference!`, which is exactly how two defects shipped together:
  #
  #   BUG 1 (the key text sent to the NAME resolver). `~k` is the STRUCTURAL store-key prefix, so
  #   what follows is STORE's key TEXT -- `(Card 2)`, the form `participant_key_for` produces to
  #   ADDRESS the store. The controller stripped `~k` and handed `(Card 2)` to
  #   #readable_identity_for_name, a DECKO NAME resolver. `(Card 2)` is not a card name, so it
  #   returned nil FOREVER and every key-addressed request answered empty -- while the card id sat
  #   in plain sight inside the text, never extracted. The repair recovers the id through the SAME
  #   single mapper #store_identity_readable? uses and authorizes it with #readable_source?.
  #
  #   BUG 2 (the untyped empty). The nil branch called `render_card_scoped([])`, but that renderer
  #   now REQUIRES an Atomspace::I3ReadResult and answers 503 `i3_backend_result_contract_violation`
  #   on a bare Array. The correct typed empty is `render_acl_empty`.
  #
  # THE PROPERTY THAT MATTERS MOST is the last test in this block: absent, unreadable and
  # unmappable-key must be BYTE-IDENTICAL, or the parameter becomes an existence/permission oracle.
  # ====================================================================================
  describe "participant subject addressing (~k key-text repair)" do
    # A readable subject card with one atom of its own, so a SUCCESSFUL resolution is visible in
    # the results rather than being indistinguishable from the empty answer.
    let!(:addressable) do
      Card::Auth.as_bot do
        Card.create!(name: "I3 Participant Public #{SecureRandom.hex(4)}", type: "Basic",
                     content: "addressable")
      end
    end

    # A subject card the CALLER may not read, with a perfectly readable atom attached. Only a
    # source-card gate on the resolved id can suppress it.
    let!(:restricted) do
      Card::Auth.as_bot do
        c = Card.create!(name: "I3 Participant Secret #{SecureRandom.hex(4)}", type: "Basic",
                         content: "shh-participant")
        Card.create!(name: "#{c.name}+*self+*read", type: "Pointer", content: "[[Administrator]]")
        c
      end
    end

    def atoms_for(card)
      [Atomspace::Atom.new(type: "DeckoCard", card_id: card.id, fields: { "Name" => card.name })]
    end

    # ----------------------------------------------------------------------------------
    # BUG 1: the repaired happy path. `~k(Card <id>)` must actually resolve.
    # ----------------------------------------------------------------------------------
    it "resolves `~k(Card <id>)` to that card id and serves its atoms" do
      bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })

      get "/atomspace/api/open", params: { participant: "~k(Card #{addressable.id})" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(addressable.id)
    end

    it "resolves the key form on neighbours too" do
      bind_port(neighbour_entries: { addressable.id.to_s => atoms_for(addressable) })

      get "/atomspace/api/neighbours", params: { participant: "~k(Card #{addressable.id})" },
          headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(addressable.id)
    end

    # THE REGRESSION ITSELF: before the repair the port was reached with NO card (the name resolver
    # answered nil first), so asserting the port saw the RESOLVED ID pins the actual fix.
    it "reaches the backend with the id recovered from the key text" do
      port = bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })
      allow(port).to receive(:open_reading).and_call_original

      get "/atomspace/api/open", params: { participant: "~k(Card #{addressable.id})" }, headers: auth

      expect(port).to have_received(:open_reading).with(card_id: addressable.id)
    end

    # A key text is NOT a Decko name and must never be looked up as one. This is the defect stated
    # directly: the NAME resolver must not be consulted for a `~k` reference at all.
    it "never hands the key text to the name resolver" do
      bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })
      expect(Card).not_to receive(:fetch).with("(Card #{addressable.id})", any_args)

      get "/atomspace/api/open", params: { participant: "~k(Card #{addressable.id})" }, headers: auth
      expect(response).to have_http_status(:ok)
    end

    # ----------------------------------------------------------------------------------
    # PER-CARD ACL PRESERVED: resolution does not bypass the source gate.
    # ----------------------------------------------------------------------------------
    it "answers the empty shape for a key naming a card the caller may not read" do
      bind_port(open_entries: { restricted.id.to_s => atoms_for(restricted) })

      get "/atomspace/api/open", params: { participant: "~k(Card #{restricted.id})" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
      expect(response.body).not_to include("shh-participant")
      expect(response.body).not_to include(restricted.name)
    end

    it "never calls the backend for a key naming an unreadable card" do
      port = bind_port
      expect(port).not_to receive(:open_reading)
      expect(port).not_to receive(:neighbours_reading)

      get "/atomspace/api/open", params: { participant: "~k(Card #{restricted.id})" }, headers: auth
      get "/atomspace/api/neighbours", params: { participant: "~k(Card #{restricted.id})" },
          headers: auth
    end

    it "authorizes the key-resolved card as the caller, never as a bot" do
      expect(Card::Auth).not_to receive(:as_bot)
      bind_port
      get "/atomspace/api/open", params: { participant: "~k(Card #{restricted.id})" }, headers: auth
      expect(body["results"]).to be_empty
    end

    # ----------------------------------------------------------------------------------
    # FAIL-CLOSED: anything that is not the ONE documented `(Card <digits>)` form.
    # ----------------------------------------------------------------------------------
    MALFORMED_KEYS = {
      "a non-positive card id" => "~k(Card 0)",
      "a decko link key, not a participant key" => "~krich_text+description",
      "a non-numeric card id" => "~k(Card abc)",
      "an empty key text" => "~k",
      "a wanted-card expr" => "~k(Wanted \"missing_card\")",
      "trailing junk after the form" => "~k(Card 2)x",
      "a bare name wearing the key prefix" => "~kHome"
    }.freeze

    MALFORMED_KEYS.each do |label, reference|
      it "answers the empty shape for #{label} (#{reference})" do
        bind_port
        get "/atomspace/api/open", params: { participant: reference }, headers: auth

        # 200 + empty, NOT the 503 contract violation bug 2 produced, and NOT a 400 that would
        # tell the caller its key was the problem.
        expect(response).to have_http_status(:ok)
        expect(body["results"]).to be_empty
        expect(body["error"]).to be_nil
      end

      it "attempts no card read for #{label} (#{reference})" do
        port = bind_port
        expect(port).not_to receive(:open_reading)

        get "/atomspace/api/open", params: { participant: reference }, headers: auth
      end
    end

    # BUG 2 stated on its own terms: the empty answer must be the TYPED one.
    it "never answers the i3_backend_result_contract_violation 503 on an unresolvable participant" do
      bind_port
      ["~k(Card 0)", "~krich_text+description", "~k", "No Such Participant Name"].each do |ref|
        get "/atomspace/api/open", params: { participant: ref }, headers: auth
        expect(response).not_to have_http_status(:service_unavailable)
        expect(body["reason"]).not_to eq("i3_backend_result_contract_violation")
      end
    end

    # The envelope is STORE's, not fabricated: render_acl_empty derives its triple from the I2-01
    # status, so the empty answer still carries a real state triple rather than an invented one.
    it "carries a real envelope on the empty answer without fabricating store metadata" do
      bind_port
      get "/atomspace/api/open", params: { participant: "~k(Card 0)" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["epoch"]).to eq(Atomspace::FixtureI3ReadPort::FIXTURE_ENVELOPE["epoch"])
      expect(body["position"]).to eq(Atomspace::FixtureI3ReadPort::FIXTURE_ENVELOPE["position"])
    end

    # ----------------------------------------------------------------------------------
    # THE NO-ORACLE PROPERTY. The whole point: these cases must be INDISTINGUISHABLE.
    # ----------------------------------------------------------------------------------
    it "answers absent, unreadable and unmappable-key BYTE-IDENTICALLY (no oracle)" do
      bind_port

      references = [
        "~k(Card 99999999)",             # maps to an id, but no such card
        "~k(Card #{restricted.id})",     # exists, readable id form, caller DENIED
        "~k(Card 0)",                    # unmappable: non-positive
        "~krich_text+description",       # unmappable: a link key
        "~k(Card abc)",                  # unmappable: non-numeric
        "~k",                            # unmappable: empty
        "No Such Participant Name"       # legacy bare-name miss
      ]

      answers = references.map do |ref|
        get "/atomspace/api/open", params: { participant: ref }, headers: auth
        [response.status, response.body]
      end

      # Every answer identical to the first -- same status, same bytes. A caller cannot tell which
      # condition it hit, so the parameter discloses neither existence nor permission.
      expect(answers.uniq.length).to eq(1), "distinguishable answers: #{answers.uniq.inspect}"
      expect(answers.first.first).to eq(200)
    end

    # ----------------------------------------------------------------------------------
    # THE UNCHANGED PATHS. The repair must not disturb the other three forms.
    # ----------------------------------------------------------------------------------
    it "still resolves a legacy bare name through the name resolver" do
      bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })

      get "/atomspace/api/open", params: { participant: addressable.name }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(addressable.id)
    end

    it "still answers the empty shape for a bare name the caller may not read" do
      bind_port(open_entries: { restricted.id.to_s => atoms_for(restricted) })

      get "/atomspace/api/open", params: { participant: restricted.name }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
      expect(response.body).not_to include("shh-participant")
    end

    it "still resolves the `~<id>` numeric reference form unchanged" do
      bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })

      get "/atomspace/api/open", params: { participant: "~#{addressable.id}" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(addressable.id)
    end

    it "still gates the `~<id>` numeric form on the source ACL" do
      bind_port(open_entries: { restricted.id.to_s => atoms_for(restricted) })

      get "/atomspace/api/open", params: { participant: "~#{restricted.id}" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"]).to be_empty
    end

    it "still reports the `~d` digest form as a declared capability gap" do
      bind_port
      get "/atomspace/api/open",
          params: { participant: "~d0123456789abcdef0123456789abcdef" }, headers: auth

      expect(response).to have_http_status(:service_unavailable)
      expect(body["reason"]).to eq("i3_participant_digest_resolution_unavailable")
    end

    it "still lets `id` win over `participant` when both are present" do
      bind_port(open_entries: { addressable.id.to_s => atoms_for(addressable) })

      get "/atomspace/api/open",
          params: { id: addressable.id.to_s, participant: "~k(Card #{restricted.id})" },
          headers: auth

      expect(response).to have_http_status(:ok)
      expect(body["results"].map { |a| a["card_id"] }).to include(addressable.id)
    end

    # String-level refusals are decided BEFORE any card is touched, so they disclose nothing and
    # must keep their existing 400s.
    it "still 400s a whitespace-only participant" do
      bind_port
      get "/atomspace/api/open", params: { participant: "   " }, headers: auth
      expect(response).to have_http_status(:bad_request)
      expect(body["reason"]).to eq("participant_required")
    end
  end

  # ====================================================================================
  # The SHARED key-text mapper, proven directly.
  #
  # #card_id_from_store_key_text is the single implementation used by BOTH the `~k` subject
  # addressing and #store_identity_readable? (continuation authorization). They MUST agree about
  # which keys are addressable -- two copies of this regex is how the two drift apart -- so the
  # mapper is asserted on its own rather than only through the two callers.
  # ====================================================================================
  describe "store key-text mapping (shared by ~k addressing and continuation authorization)" do
    let(:controller) { Api::Mcp::I3ReadController.new }

    {
      "(Card 2)" => 2,
      "(Card 17120)" => 17_120,
      "(Card 02)" => 2,
      "(Card 0)" => nil,
      "(Card -1)" => nil,
      "(Card abc)" => nil,
      "(Card 2) " => nil,
      " (Card 2)" => nil,
      "(Card 2)x" => nil,
      "(Wanted \"missing_card\")" => nil,
      "rich_text+description" => nil,
      "Card 2" => nil,
      "" => nil
    }.each do |text, expected|
      it "maps #{text.inspect} to #{expected.inspect}" do
        expect(controller.send(:card_id_from_store_key_text, text)).to eq(expected)
      end
    end

    it "refuses a non-String identity" do
      expect(controller.send(:card_id_from_store_key_text, nil)).to be_nil
      expect(controller.send(:card_id_from_store_key_text, 2)).to be_nil
      expect(controller.send(:card_id_from_store_key_text, :"(Card 2)")).to be_nil
    end
  end
end
