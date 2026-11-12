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
    get "trace", to: "traces#show"
  end

  # The web app's pages (design §6.7), each sent as its own shell; the others
  # join here as they arrive (web/src/pages.ts lists the same ones, and
  # spec/requests/spa_spec.rb holds the two lists together).
  root "spa#landing"
  get "chat", to: "spa#chat"
  get "trace", to: "spa#trace"
  # A trace's link carries its token after the "#", which no browser sends
  # (review finding V3 of pull request #17). A link given before then is moved
  # there by a plain answer: Rails' redirect would log the new address whole,
  # and the request's own line masks the token (SR-30).
  get "trace/:token", constraints: { token: /[1-9A-HJ-NP-Za-km-z]{24}/ }, format: false,
                      to: ->(env) { [ 301, { "location" => "/trace##{env["action_dispatch.request.path_parameters"][:token]}" }, [] ] }
end
