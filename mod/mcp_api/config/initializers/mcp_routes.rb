# frozen_string_literal: true

# Mount MCP API routes
Rails.application.routes.draw do
  namespace :api do
    namespace :mcp do
      # Auth endpoint
      post "auth", to: "auth#create"

      # Types endpoints
      get "types", to: "types#index"
      get "types/:name", to: "types#show"

      # Cards endpoints
      resources :cards, param: :name, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :children
        end

        collection do
          post :batch
        end
      end
    end
  end
end
