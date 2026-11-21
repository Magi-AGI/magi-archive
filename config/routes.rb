# -*- encoding : utf-8 -*-

# Manually require MCP API controllers before routing
# Load base controller and concerns first
require Rails.root.join('mod/mcp_api/app/controllers/concerns/rate_limitable.rb')
require Rails.root.join('mod/mcp_api/app/controllers/api/mcp/base_controller.rb')

# Then load all other controllers (including admin namespace)
Dir[Rails.root.join('mod/mcp_api/app/controllers/api/mcp/*_controller.rb')].sort.each do |f|
  require f unless f.include?('base_controller')
end
Dir[Rails.root.join('mod/mcp_api/app/controllers/api/mcp/admin/*_controller.rb')].sort.each do |f|
  require f
end

Decko.application.routes.draw do
  # MCP API routes - must be before Decko::Engine mount to take precedence
  namespace :api do
    namespace :mcp do
      # Health check endpoints (no auth required)
      get 'health', to: 'health#index'
      get 'health/ping', to: 'health#ping'

      # Auth endpoint
      post 'auth', to: 'auth#create'

      # JWKS endpoint (public key distribution)
      get '.well-known/jwks.json', to: 'jwks#show'

      # Types endpoints
      get 'types', to: 'types#index'
      get 'types/:name', to: 'types#show'

      # Jobs endpoints (async operations)
      post 'jobs/spoiler-scan', to: 'jobs#spoiler_scan'

      # Cards endpoints
      resources :cards, param: :name, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :children
          get :referers
          get :nested_in
          get :nests
          get :links
          get :linked_by
          put :rename
          get :search_content
          get :outline
          # History endpoints (Phase 4)
          get :history
          get 'history/:act_id', action: :revision, as: :revision
          post :restore
        end

        collection do
          post :batch
        end
      end

      # Trash listing (admin only, Phase 4)
      resources :trash, only: [:index]

      # File/image upload — standalone routes to avoid Decko member route conflicts
      post 'cards/:name/upload', to: 'cards#upload', constraints: { name: /[^\/]+/ }
      get 'cards/:name/file_url', to: 'cards#file_url', constraints: { name: /[^\/]+/ }

      # Render endpoints (Phase 2)
      post 'render', to: 'render#html_to_markdown'
      post 'render/markdown', to: 'render#markdown_to_html'

      # Query endpoint (Phase 3)
      post 'run_query', to: 'query#run'

      # Auto-link endpoint (cross-reference discovery)
      post 'auto_link', to: 'auto_link#create'

      # Validation endpoints
      scope :validation, controller: "validation" do
        post 'tags', action: :validate_tags
        post 'structure', action: :validate_structure
        get 'requirements/:type', action: :requirements
        post 'recommend_structure', action: :recommend_structure
        post 'suggest_improvements', action: :suggest_improvements
      end

      # AtomSpace mirror read API (Lane C, Level 9) -- Api::Mcp::AtomspaceMirrorController.
      # Gated by the mcp:atomspace:read scope; the card-scoped B3 quarantine surface additionally
      # requires the namespaced mcp:atomspace:admin scope (POLICY REV5).
      # MUST be drawn here (before `mount Decko::Engine => '/'`) so it isn't shadowed by the
      # Decko card catch-all -- an append-initializer runs after the mount and 404s to a card.
      scope :atomspace_mirror, controller: "atomspace_mirror" do
        get  'atom_types',            action: :atom_types
        get  'atom_count_by_type',    action: :atom_count_by_type
        get  'space_stats',           action: :space_stats
        get  'query_atoms',           action: :query_atoms
        get  'get_card_atom',         action: :get_card_atom
        get  'get_card_provenance',   action: :get_card_provenance
        get  'list_references',       action: :list_references
        get  'list_atoms_by_type',    action: :list_atoms_by_type
        # Card-scoped B3 admin quarantine (sidecar /admin/list_card_scoped_atoms +
        # /admin/quarantine_card_scoped_atoms). card_id is constrained to digits so a non-numeric
        # target 404s at the router rather than reaching a destructive action.
        #
        # `format: false` is REQUIRED, not cosmetic. Rails' default trailing `(.:format)` segment is
        # applied BEFORE the :card_id constraint is matched, so without it a request for
        # `quarantine/card/1.9` parses as card_id="1", format="9" -- the digit constraint passes on
        # the truncated value and the surface silently answers for card 1 instead of rejecting an
        # ambiguous target. That also bypasses the read client's deliberately strict card_id parse
        # (the one that refuses .to_i coercion at an admin boundary) because the router has already
        # discarded the suffix. Disabling the format segment makes `card/1.9` a 404 at the router,
        # which is the documented contract above.
        get  'quarantine/card/:card_id',        action: :quarantine_index,
                                                constraints: { card_id: /\d+/ }, format: false
        post 'quarantine/card/:card_id/delete', action: :quarantine_delete,
                                                constraints: { card_id: /\d+/ }, format: false
      end

      # I3 read surface (VIEW, lane D) -- Api::Mcp::I3ReadController. Minimal real-card path over
      # the STORE's I2 slice: lookup (by name) + open + neighbours, plus a declared
      # capability-missing health refusal (the store's health slice is O23-gated and absent).
      # Gated by the NAMESPACED mcp:i3:read scope; mcp:atomspace:read does NOT satisfy it.
      #
      # SAME-ORIGIN SESSION AUTHENTICATION ADDS NO ROUTE. The browser path authenticates with the
      # EXISTING Decko session cookie on EXACTLY THESE FOUR GETs -- there is no /session endpoint,
      # no second route family, no new query parameter and no new path. The controller selects the
      # session principal when the request carries no Authorization header
      # (i3_read_controller.rb#session_mode?), so the wire surface is byte-identical for both
      # mechanisms and O25's "no new wire surface" holds. Being same-origin is also what makes the
      # cookie reach these paths at all: the browser must be served from this same deck origin
      # (config.deck_origin, config/application.rb), because a cross-origin fetch would neither
      # send the SameSite=Lax cookie nor pass CORS (this deck configures none).
      #
      # Gated by the NAMESPACED mcp:i3:read scope on the token path; on the session path by
      # PERSISTED Decko role membership read from the framework (I3_SESSION_READ_ROLE), never by
      # anything the request asserts.
      #
      # MUST be drawn HERE, before `mount Decko::Engine => '/'`, for the same reason the
      # atomspace_mirror block is (see :89-90): Rails.application.routes.append in a mod
      # initializer runs AFTER the mount and is shadowed by the Decko card catch-all, so an
      # appended route 404s to a card instead of reaching the controller.
      scope :i3, controller: "i3_read" do
        get 'lookup',                action: :lookup
        get 'health',                action: :health
        # `format: false` is REQUIRED on every id-bearing path, not cosmetic (see :104-111):
        # Rails applies the default trailing `(.:format)` segment BEFORE the :id constraint, so
        # without it `card/1.9` parses as id="1", format="9" -- the digit constraint passes on the
        # TRUNCATED value and the surface SILENTLY ANSWERS FOR CARD 1 instead of rejecting an
        # ambiguous target. Disabling the format segment makes `card/1.9` a 404 at the router.
        get 'card/:id/open',         action: :open,
                                     constraints: { id: /\d+/ }, format: false
        get 'card/:id/neighbours',   action: :neighbours,
                                     constraints: { id: /\d+/ }, format: false
      end

      # Admin endpoints (admin role required)
      namespace :admin do
        resources :api_keys, only: [:index, :show, :create, :update, :destroy]
        
        # Database backup operations (flat routes, no nested namespace)
        get 'database/backup', to: 'database#backup'
        get 'database/backup/list', to: 'database#list_backups'
        get 'database/backup/download/:filename', to: 'database#download_backup', constraints: { filename: /[^\/]+/ }
        delete 'database/backup/:filename', to: 'database#delete_backup', constraints: { filename: /[^\/]+/ }
      end
    end
  end

  # ==================================================================================================
  # K8 PATH-SHAPE CONFORMANCE for the I3 read surface.
  #
  # CONTRACT (av-contract/contracts/k8-draft-2.md §5.1, marked EXACT):
  #   :285  "Every endpoint is a **GET** at `/atomspace/api/<endpoint>`, and calls only read
  #          operations of I2 (R14, `cp030` §2)."
  #   :288  "All inputs are query parameters. No endpoint accepts a body."
  # The endpoint NAMES come from §5.5's EXACT table (:563-574): I3-02 `open`, I3-03 `neighbours`,
  # I3-10 `lookup`.
  #
  # ADDITIVE, NOT A REPLACEMENT. The pre-existing /api/mcp/i3/... routes above are left intact. K8
  # fixes where an endpoint MUST be reachable; no clause of it says the endpoint must NOT be
  # reachable anywhere else, so deleting the old paths would be a breaking change the contract does
  # not ask for.
  #
  # PATH SHAPE ONLY. Same controller, same actions, same parameter names, same semantics. Nothing
  # here renames a parameter into K8's `participant` / `focus[]` / `after` / `distance` vocabulary,
  # and nothing here synthesises K8 §5.2 envelope fields (`epoch`, `position`, `read-at`,
  # `schema-version`, `limits`): all of those would require backend data this deck cannot obtain, and
  # fabricating any of them is forbidden (i3_read_controller.rb:45-47 -- "No handler fabricates an
  # epoch, position, read-at, coverage, health or configuration value to be able to answer").
  #
  # MUST BE DRAWN HERE, before `mount Decko::Engine => '/'` below, for exactly the reason the
  # atomspace_mirror and i3 blocks above are (see :89-90 and :123-126): the Decko card catch-all
  # mounted at '/' matches any path the router has not already matched, so a route drawn -- or
  # appended by a mod initializer -- AFTER the mount 404s to a card instead of reaching the
  # controller.
  #
  # `format: false` ON EVERY ROUTE, and it is REQUIRED rather than cosmetic (same reasoning as
  # :104-111 and :130-134). Rails' default trailing `(.:format)` segment would otherwise let
  # `/atomspace/api/open.9` match with format="9", reintroducing the suffix ambiguity the id-bearing
  # routes above exist to disable.
  #
  # WHERE THE CARD ID ARRIVES ON THIS SHAPE, and what stands in for the router's numeric gate.
  # K8 :288 puts EVERY input in the query string, so here the card id arrives as `?id=<n>` instead of
  # as a path segment. A Rails hash constraint (`constraints: { id: /\d+/ }`) CANNOT be applied to it,
  # because hash constraints match dynamic PATH segments only. The invariant is nevertheless
  # preserved, because it was never the router's alone: I3ReadController#require_card_id!
  # (i3_read_controller.rb:233-239) parses the id with a strict `\A\d+\z` and renders 400
  # `card_id_invalid` for anything else, explicitly refusing `.to_i` coercion. So `?id=1.9` is
  # REFUSED as a malformed id and is never silently answered for card 1 -- which is precisely the
  # property `format: false` + `/\d+/` protect on the path-segment shape.
  #
  # The parameter name stays `id` (the existing one). K8 §5.5 calls I3-02/I3-03's subject input
  # `participant` and addresses it by `key`/`digest`, but this surface addresses a Decko card by its
  # numeric id and the store has no name->key or card_id->key resolver (i3_read_controller.rb:119-127),
  # so renaming the input would promise a resolution that does not exist. Divergence recorded, not
  # papered over.
  scope path: "atomspace/api" do
    get 'lookup',     to: 'api/mcp/i3_read#lookup',     as: :atomspace_api_lookup,     format: false
    get 'health',     to: 'api/mcp/i3_read#health',     as: :atomspace_api_health,     format: false
    get 'open',       to: 'api/mcp/i3_read#open',       as: :atomspace_api_open,       format: false
    get 'neighbours', to: 'api/mcp/i3_read#neighbours', as: :atomspace_api_neighbours, format: false
  end

  mount Decko::Engine => '/'
end
