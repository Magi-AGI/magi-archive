# frozen_string_literal: true

require "spec_helper"

# Routing-level contract for the I3 surface. The `format: false` assertion is a SECURITY test, not a
# cosmetic one: Rails applies the default trailing `(.:format)` segment BEFORE the :id constraint is
# matched, so without `format: false` a request for `card/1.9/open` parses as id="1", format="9" --
# the /\d+/ constraint passes on the TRUNCATED value and the surface SILENTLY ANSWERS FOR CARD 1
# instead of rejecting an ambiguous target (config/routes.rb:104-111 documents this for the mirror
# prefix).
RSpec.describe "I3 routing", type: :request do
  it "routes the canonical id-bearing paths" do
    expect(get: "/api/mcp/i3/card/1/open")
      .to route_to(controller: "api/mcp/i3_read", action: "open", id: "1")
    expect(get: "/api/mcp/i3/card/1/neighbours")
      .to route_to(controller: "api/mcp/i3_read", action: "neighbours", id: "1")
  end

  it "routes the non-id paths" do
    expect(get: "/api/mcp/i3/lookup")
      .to route_to(controller: "api/mcp/i3_read", action: "lookup")
    expect(get: "/api/mcp/i3/health")
      .to route_to(controller: "api/mcp/i3_read", action: "health")
  end

  # THE CORE ASSERTION: `card/1.9` must NOT answer for card 1.
  it "does NOT route card/1.9/open (format segment disabled)" do
    expect(get: "/api/mcp/i3/card/1.9/open").not_to be_routable
  end

  it "does NOT route card/1.9/neighbours (format segment disabled)" do
    expect(get: "/api/mcp/i3/card/1.9/neighbours").not_to be_routable
  end

  it "does NOT route a non-numeric card id" do
    expect(get: "/api/mcp/i3/card/abc/open").not_to be_routable
  end

  # Proof the suffix is rejected at the ROUTER, before any controller/auth code runs: an
  # unroutable path cannot reach the surface at all.
  it "404s card/1.9/open at the router even with a valid token" do
    allow(McpApi::JwtService).to receive(:verify_token)
      .and_return({ "sub" => "user:Joe User", "role" => "user", "scope" => "mcp:i3:read" })
    get "/api/mcp/i3/card/1.9/open", headers: { "Authorization" => "Bearer test-token" }
    expect(response).to have_http_status(:not_found)
  end

  # ====================================================================================
  # SOURCE-CARD AUTHORIZATION IS A CONTROLLER GATE, NOT A ROUTING ONE (fix b).
  #
  # The router only pins the id SHAPE (/\d+/ + format: false). It cannot know whether the caller
  # may read the card, so a syntactically valid id for a card the caller cannot read must still
  # ROUTE -- and then be refused inside the controller by the source-card gate. These assertions
  # exist so the two layers are not confused: a routing 404 would be an existence oracle, and a
  # routing pass is NOT an authorization decision.
  # ====================================================================================
  describe "source-card authorization is not a routing concern (fix b)" do
    it "routes a well-formed id for a card that does not exist" do
      expect(get: "/api/mcp/i3/card/99999999/open")
        .to route_to(controller: "api/mcp/i3_read", action: "open", id: "99999999")
      expect(get: "/api/mcp/i3/card/99999999/neighbours")
        .to route_to(controller: "api/mcp/i3_read", action: "neighbours", id: "99999999")
    end

    # A nonexistent card must NOT 404 at the router: it reaches the controller and is answered
    # with the same non-oracle empty result an unreadable card gets.
    it "answers a nonexistent card id inside the controller, not with a routing 404" do
      allow(McpApi::JwtService).to receive(:verify_token)
        .and_return({ "sub" => "user:Joe User", "role" => "user", "scope" => "mcp:i3:read" })
      Atomspace::I3ReadPort.bind!(Atomspace::FixtureI3ReadPort.new)

      get "/api/mcp/i3/card/99999999/open", headers: { "Authorization" => "Bearer test-token" }
      expect(response).not_to have_http_status(:not_found)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["results"]).to be_empty
    ensure
      Atomspace::I3ReadPort.reset!
    end
  end

  # ====================================================================================
  # K8 PATH-SHAPE CONFORMANCE (k8-draft-2.md §5.1, EXACT, :285): "Every endpoint is a GET at
  # `/atomspace/api/<endpoint>`"; :288: "All inputs are query parameters. No endpoint accepts a
  # body." Endpoint names are §5.5's EXACT table: I3-02 `open`, I3-03 `neighbours`, I3-10 `lookup`.
  #
  # These are ADDITIVE assertions: the /api/mcp/i3/... expectations above still hold, because the
  # K8 mount was added without removing the existing paths.
  # ====================================================================================
  describe "K8 /atomspace/api/<endpoint> path shape" do
    it "routes the K8 non-id endpoints" do
      expect(get: "/atomspace/api/lookup")
        .to route_to(controller: "api/mcp/i3_read", action: "lookup")
      expect(get: "/atomspace/api/health")
        .to route_to(controller: "api/mcp/i3_read", action: "health")
    end

    # On the K8 shape the subject id is a QUERY parameter (:288), not a path segment, so the path
    # itself is bare and the id rides in the params hash.
    #
    # REVIEWER BLOCKER 1: this expectation asserts controller/action ONLY, and deliberately does
    # NOT list `id`. `route_to` is a route-RECOGNITION assertion: it ends in
    # assert_recognizes, which strictly compares the expected hash against
    # `request.path_parameters` (actionpack-7.2.3.1 testing/assertions/routing.rb:176-181), and
    # only the explicit `extras` argument is merged into those parameters
    # (routing/route_set.rb:914-916). A query string appended to the path is parsed into
    # QUERY_STRING and never reaches path_parameters -- actionpack says so outright at
    # routing.rb:143-145: "To test query strings you must use the extras argument because
    # appending the query string on the path directly will not work." Asserting `id: "1"` here
    # would therefore fail on a correctly-drawn route. Query-parameter DELIVERY is covered by the
    # request examples below, which pass `params:` to a real request.
    it "routes the K8 card-scoped endpoints with the id as a query parameter" do
      expect(get: "/atomspace/api/open?id=1")
        .to route_to(controller: "api/mcp/i3_read", action: "open")
      expect(get: "/atomspace/api/neighbours?id=1")
        .to route_to(controller: "api/mcp/i3_read", action: "neighbours")
    end

    # The EXISTING query-parameter names are preserved verbatim -- this change is path-shape only.
    # `bucket` and `limit` are #neighbours' own inputs (i3_read_controller.rb:164-176) and `name` is
    # #lookup's (:129); none is renamed into K8 §5.5's `participant`/`bucket`/`after` vocabulary.
    #
    # REVIEWER BLOCKER 1 (same cause as above): what is assertable AT THE ROUTER is only that a
    # query-bearing path still recognizes to the same controller/action -- i.e. the router ignores
    # the query string rather than letting it change or defeat the match. The parameter NAMES are
    # not router-visible (they never enter path_parameters), so they are not asserted here; they
    # are enforced in the controller and exercised by request examples.
    it "recognizes the K8 endpoints regardless of the trailing query string" do
      expect(get: "/atomspace/api/neighbours?id=1&bucket=refs&limit=5")
        .to route_to(controller: "api/mcp/i3_read", action: "neighbours")
      expect(get: "/atomspace/api/lookup?name=Alpha")
        .to route_to(controller: "api/mcp/i3_read", action: "lookup")
    end

    # `format: false` is carried onto the K8 routes for the same reason it is on the id-bearing
    # paths (config/routes.rb:104-111): without it Rails' trailing `(.:format)` segment makes
    # `open.9` a match with format="9", so the endpoint NAME itself becomes suffix-ambiguous.
    #
    # REVIEWER BLOCKER 2: this is asserted as "does not reach THIS controller", not as
    # application-wide unroutability. `be_routable` would be the wrong claim: `format: false`
    # only stops the I3 aliases themselves from matching, and the request then falls through to
    # `mount Decko::Engine => '/'` (config/routes.rb:209), which recognize_path follows into the
    # engine's own route set (routing/route_set.rb:933-935). Decko ends that set with a
    # bad-address catch-all -- `get "*mark" => "card#read", view: "bad_address"`
    # (decko/config/engine_routes.rb:53-54) -- which matches ANY leftover path. So these URLs ARE
    # routable (to Decko's card#read); the security property is that they do not resolve to the
    # I3 surface, which is what is asserted here.
    #
    # REVIEWER BLOCKER 2 (second pass): the earlier form of this example negated `route_to`, which
    # was VACUOUS as a guard. `route_to`/assert_recognizes ends in an EXACT hash comparison --
    # `assert_equal(expected_options, request.path_parameters, msg)`
    # (actionpack-7.2.3.1 testing/assertions/routing.rb:181, with the expectation stringified at
    # :174 and the recognized params made indifferent-access at :331). So if `format: false` were
    # ever dropped from these routes, `open.9` WOULD reach I3 and recognize as
    # {controller: "api/mcp/i3_read", action: "open", format: "9"} -- and that hash is NOT EQUAL to
    # the expected controller/action-only hash because of the extra `format` key, so the NEGATIVE
    # assertion would still pass while the request was reaching the I3 surface. The assertion could
    # not fail for the reason it existed.
    #
    # The fix inspects the RECOGNIZED PARAMETERS directly and asserts only on `[:controller]`, so
    # any additional parameter (`format` or otherwise) is irrelevant to the verdict.
    # `recognize_path` returns the raw params hash with SYMBOL keys (routing.rb:328-331 calls it and
    # only then applies `.with_indifferent_access`) and RAISES ActionController::RoutingError when
    # nothing matches at all (routing/route_set.rb:939-941) -- "nothing matched" is an acceptable
    # outcome here, since an unrecognized path certainly did not reach I3, so it maps to nil.
    def recognized_controller_for(path, method: :get)
      params = Rails.application.routes.recognize_path(path, method: method)
      params[:controller] || params["controller"]
    rescue ActionController::RoutingError
      nil
    end

    it "does NOT route a format suffix to the I3 surface on the K8 endpoints" do
      expect(recognized_controller_for("/atomspace/api/open.9"))
        .not_to eq("api/mcp/i3_read")
      expect(recognized_controller_for("/atomspace/api/neighbours.json"))
        .not_to eq("api/mcp/i3_read")
      expect(recognized_controller_for("/atomspace/api/lookup.json"))
        .not_to eq("api/mcp/i3_read")
    end

    # The numeric-id invariant still holds on this shape, but it is enforced one layer in: a hash
    # constraint cannot gate a query parameter, so `?id=1.9` ROUTES and is then refused with 400
    # `card_id_invalid` by require_card_id!'s strict \A\d+\z parse (i3_read_controller.rb:233-239),
    # which never coerces with .to_i. The ambiguous target is still never answered for card 1.
    it "refuses a malformed query id in the controller, not at the router" do
      allow(McpApi::JwtService).to receive(:verify_token)
        .and_return({ "sub" => "user:Joe User", "role" => "user", "scope" => "mcp:i3:read" })
      Atomspace::I3ReadPort.bind!(Atomspace::FixtureI3ReadPort.new)

      get "/atomspace/api/open", params: { id: "1.9" },
                                 headers: { "Authorization" => "Bearer test-token" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["reason"]).to eq("card_id_invalid")
    ensure
      Atomspace::I3ReadPort.reset!
    end

    # Proof the K8 block is not shadowed by the Decko card catch-all mounted at '/': a path that
    # fell through to Decko would not route to this controller at all.
    it "is not shadowed by the Decko engine mount" do
      expect(get: "/atomspace/api/lookup")
        .to route_to(controller: "api/mcp/i3_read", action: "lookup")
    end
  end
end
