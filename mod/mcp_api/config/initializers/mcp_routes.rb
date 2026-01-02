# frozen_string_literal: true

# Mount MCP API routes - append to existing routes instead of redrawing
Rails.application.routes.append do
  namespace :api do
    namespace :mcp do
      # Auth endpoints
      scope :auth do
        post "/", to: "auth#create"
        post "debug", to: "auth#debug"  # Diagnostic endpoint for role detection
      end

      # JWKS endpoint (public key distribution)
      get ".well-known/jwks.json", to: "jwks#show"

      # Types endpoints
      get "types", to: "types#index"
      get "types/:name", to: "types#show"

      # Tags endpoints
      get "tags", to: "tags#index"
      get "tags/:tag_name/cards", to: "tags#cards"
      post "tags/suggest", to: "tags#suggest"

      # Cards endpoints
      resources :cards, param: :name, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :children
          # Relationship endpoints
          get :referers
          get :linked_by
          get :nested_in
          get :nests
          get :links
        end

        collection do
          post :batch
        end
      end

      # Rename endpoint - defined separately to handle complex card names
      # Using glob constraint to capture full path including encoded characters
      put "cards/*name/rename", to: "cards#rename", format: false, constraints: { name: /.*/ }

      # Render endpoints (Phase 2)
      namespace :render do
        post "/", to: "render#html_to_markdown", as: :html_to_markdown
        post "markdown", to: "render#markdown_to_html"
      end
    end
  end
end
