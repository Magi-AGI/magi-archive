# -*- encoding : utf-8 -*-

# Manually require MCP API controllers before routing
# Load base controller and concerns first
require Rails.root.join('mod/mcp_api/app/controllers/concerns/rate_limitable.rb')
require Rails.root.join('mod/mcp_api/app/controllers/api/mcp/base_controller.rb')

# Then load all other controllers
Dir[Rails.root.join('mod/mcp_api/app/controllers/api/mcp/*_controller.rb')].sort.each do |f|
  require f unless f.include?('base_controller')
end

Decko.application.routes.draw do
  # MCP API routes - must be before Decko::Engine mount to take precedence
  namespace :api do
    namespace :mcp do
      # Auth endpoint
      post 'auth', to: 'auth#create'

      # JWKS endpoint (public key distribution)
      get '.well-known/jwks.json', to: 'jwks#show'

      # Types endpoints
      get 'types', to: 'types#index'
      get 'types/:name', to: 'types#show'

      # Cards endpoints
      resources :cards, param: :name, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :children
          get :referers
          get :nested_in
          get :nests
          get :links
          get :linked_by
        end

        collection do
          post :batch
        end
      end

      # Render endpoints (Phase 2)
      namespace :render do
        post '/', to: 'render#html_to_markdown', as: :html_to_markdown
        post 'markdown', to: 'render#markdown_to_html'
      end

      # Validation endpoints
      namespace :validation do
        post 'tags', to: 'validation#validate_tags'
        post 'structure', to: 'validation#validate_structure'
        get 'requirements/:type', to: 'validation#requirements'
        post 'recommend_structure', to: 'validation#recommend_structure'
        post 'suggest_improvements', to: 'validation#suggest_improvements'
      end
    end
  end
  
  mount Decko::Engine => '/'
end
