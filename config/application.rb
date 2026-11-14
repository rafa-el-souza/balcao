require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require_relative "../lib/middleware/api_body_limit"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Balcao
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # lib/evals is bin/evals' own code, required by it and by its specs, so
    # the app process never loads it (evals/README.md, Running).
    config.autoload_lib(ignore: %w[assets middleware tasks evals logging])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    # The visitor cookie (design FR-18, threat model SR-03) and the policy of
    # config/initializers/content_security_policy.rb, which API-only apps leave out.
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::ContentSecurityPolicy::Middleware

    # SR-03: every page and answer denies the browser features the web app
    # never uses, so a script that got in could not ask for them either. A
    # literal header beside Rails' defaults: Rails' own middleware for it
    # (actionpack 8.1) still writes the legacy Feature-Policy name. Each name
    # is one Chromium knows; an unknown one only warns in the console (Linux
    # Chromium does not know web-share, so it is left out).
    config.action_dispatch.default_headers["Permissions-Policy"] = %w[
      accelerometer autoplay camera display-capture encrypted-media fullscreen
      geolocation gyroscope hid idle-detection magnetometer microphone midi
      payment picture-in-picture publickey-credentials-get screen-wake-lock
      serial usb xr-spatial-tracking
    ].map { |feature| "#{feature}=()" }.join(", ")

    # SR-03: static files (public/, the web app's hashed scripts and styles)
    # leave before any controller, so none of the headers above reach them;
    # nosniff keeps a browser from reading one as another type. Each
    # environment adds its cache-control to this hash.
    config.public_file_server.headers = { "x-content-type-options" => "nosniff" }

    # X-Runtime told anyone how long the server took over each request, to
    # the microsecond and free of the network's noise, which is what a timing
    # attack measures; nothing reads it.
    config.middleware.delete Rack::Runtime

    # Business time is São Paulo's; timestamps are stored in UTC (design §1.4, NFR-02).
    config.time_zone = "America/Sao_Paulo"

    # A deploy stops the job container and kills it after Kamal's 30 s. The
    # worker waits this long for the turn it runs; one still running then is
    # handed back to the queue and runs again from its start in the new
    # container, billed again (design NFR-03, §10 note of 2026-11-13).
    config.solid_queue.shutdown_timeout = 25.seconds

    # The public surface is trilingual and pt-BR is the default (design NFR-09, FR-02).
    config.i18n.available_locales = [ :"pt-BR", :en, :es ]
    config.i18n.default_locale = :"pt-BR"
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]

    # The web app's HTML shells, one per page and language, built by Vite; the
    # image keeps them at the same path and their hashed assets under
    # public/assets (Dockerfile, design §6.7).
    config.x.spa_shells = Rails.root.join("web/dist/shells")

    # Where a visitor opens the web app, for the links the server writes (the
    # trace link of FR-12), the Origin the API accepts and the cable's allowed
    # origin (SR-03): the Vite dev server here, the public name in production
    # (config/environments/production.rb).
    config.x.public_origin = "http://127.0.0.1:5173"

    # The month's budget cap in US dollars (FR-14): ADR-0003's default here,
    # BUDGET_CAP_USD in each destination (config/environments/production.rb).
    config.x.budget_cap_usd = BigDecimal("100")
  end
end
