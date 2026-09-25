Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get "health" => "health#show", as: :health

  resources :projects, param: :key, only: %i[show new create edit update]
  resources :project_envs, only: %i[new create edit update destroy]
  resources :connections do
    member do
      get "login", to: "sessions#new"
      post "login", to: "sessions#create"
    end
  end
  delete "logout" => "sessions#destroy", as: :logout

  resource :hint_preference, only: :update

  resources :entities, only: %i[index show new create edit update destroy] do
    collection { post :sync }
  end

  resources :plugins, only: %i[new create]
  # R2: hand-made forms for a service, and for a route under its service.
  get "routes/overlap" => "routes#overlap", as: :routes_overlap
  resources :services, only: %i[new create]
  resources :routes, only: %i[new create]
  resources :certificates, only: [] do
    collection { get :expiring }
  end

  resources :change_plans, only: %i[index show] do
    member { post :apply }
  end

  # R8: a PR-mode connection's changes, collected into one branch and one PR.
  resources :changesets, only: %i[index show] do
    member do
      get :preview
      post :submit
      patch :pr_url
      post :abandon
    end
  end
  delete "/changesets/:changeset_id/items/:id" => "changeset_items#destroy", as: :changeset_item

  resources :audit_events, only: %i[index]

  resources :personal_access_tokens, only: %i[index new create] do
    member { post :revoke }
  end

  namespace :api do
    namespace :v1 do
      resources :entities, only: %i[index]
      resources :connections, only: %i[index]
      resources :certificates, only: [] do
        collection { get :expiring }
      end
      resources :change_plans, only: %i[create] do
        member { post :apply }
      end
    end
  end

  # Defines the root path route ("/")
  root "connections#index"
end
