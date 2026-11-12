Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The public API (design §6.6); the cable is mounted at /cable by Action Cable.
  # No format extension: each endpoint has one path, the one the edge limits
  # count (review finding C1 of pull request #12, threat model SR-01).
  namespace :api, defaults: { format: :json }, format: false do
    resource :session, only: :create
    resources :messages, only: :create
    get "conversations/current", to: "conversations#current"
  end

  # The web app's pages (design §6.7), each sent as its own shell; the others
  # join here as they arrive (web/src/pages.ts lists the same ones).
  root "spa#landing"
  get "chat", to: "spa#chat"
end
