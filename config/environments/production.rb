require "active_support/core_ext/integer/time"
require_relative "../required_environment"
require_relative "../../lib/logging/json_log_formatter"

# Before anything below reads the environment (threat model SR-25).
Balcao::RequiredEnvironment.verify!(ENV)

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped. Added
  # to the static files' headers of config/application.rb (nosniff, SR-03).
  # robots.txt, whose name carries no digest, is a route's answer with a
  # day's cache instead (RobotsController).
  config.public_file_server.headers["cache-control"] = "public, max-age=#{1.year.to_i}"

  # A rehearsal host says noindex on every answer, its name being in the
  # certificate logs within minutes (design §8, M3-6b): beside Rails' default
  # headers, which a controller's answer carries and Balcao::ResponseHeaders
  # gives every other answer, the static files and the refusals among them.
  # The boot check holds NOINDEX to the name: true off the public one, blank
  # on it. The trace page sends its own noindex, nofollow everywhere.
  config.action_dispatch.default_headers["X-Robots-Tag"] = "noindex" if Balcao::RequiredEnvironment.noindex?

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT, one JSON object per line, with the current request's id as
  # a field (NFR-05; lib/logging/json_log_formatter.rb).
  config.log_tags = [ ->(request) { "request_id=#{request.request_id}" } ]
  config.logger   = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(STDOUT, formatter: Balcao::JsonLogFormatter.new))

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  # Its failsafe answers nil for six transient errors of its database, and the
  # limits then let the request through (app/models/edge_limits.rb); with no
  # logger of its own it wrote nothing. This line names the error by its class
  # alone, never by its message, which may quote a key: an address or an
  # identity's hash (threat model SR-30; review finding M4 of pull request #32).
  config.cache_store = :solid_cache_store, {
    error_handler: lambda do |method:, returning:, exception:|
      Rails.logger.warn("cache: #{method} failed, answered #{returning.inspect}: #{exception.class}")
    end
  }

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates (APP_HOST, design §8).
  config.action_mailer.default_url_options = { host: Balcao::RequiredEnvironment.read("APP_HOST") }
  config.x.public_origin = "https://#{Balcao::RequiredEnvironment.read("APP_HOST")}"
  # Each destination's own cap (FR-14), a positive decimal checked at boot
  # (config/required_environment.rb): 100 for production, 10 for the MVP host.
  config.x.budget_cap_usd = BigDecimal(ENV.fetch("BUDGET_CAP_USD"))

  # What visitors send is encrypted at rest with these keys, which live in the
  # env file and never in the database (threat model SR-41); a Telegram
  # identity is the user id hashed with the pepper (SR-10), and a web one is
  # a token in a cookie signed with the secret key base (SR-03). Each is read
  # without a paste's spaces or line break, as the boot check reads it, so a
  # paste mended later breaks no stored row and no identity (M3-6). The bot's
  # token and the webhook's secret are the Telegram channel's (FR-19, SR-06).
  config.active_record.encryption.primary_key = Balcao::RequiredEnvironment.read("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
  config.active_record.encryption.deterministic_key = Balcao::RequiredEnvironment.read("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
  config.active_record.encryption.key_derivation_salt = Balcao::RequiredEnvironment.read("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
  config.x.identity_pepper = Balcao::RequiredEnvironment.read("IDENTITY_PEPPER")
  config.secret_key_base = Balcao::RequiredEnvironment.read("SECRET_KEY_BASE")
  config.x.telegram_bot_token = ENV.fetch("TELEGRAM_BOT_TOKEN")
  config.x.telegram_webhook_secret = ENV.fetch("TELEGRAM_WEBHOOK_SECRET")
  # The Turnstile widget's secret, for siteverify (SR-39): the owner's on the
  # public name, Cloudflare's published test secret on a rehearsal host
  # (ADR-0012), which the boot refuses on the public name. Read without the
  # spaces or line break a paste may leave, as the boot check reads it (the
  # review of pull request #53).
  config.x.turnstile_secret_key = ENV.fetch("TURNSTILE_SECRET_KEY").strip
  # The external monitor's heartbeats (FR-17, NFR-04): the canary's and the
  # Telegram delivery watch's, required on the public name by the boot check
  # and blank on a rehearsal host, which sends none (Heartbeat).
  config.x.monitor_url = ENV.fetch("MONITOR_URL", "").strip.presence
  config.x.telegram_monitor_url = ENV.fetch("TELEGRAM_MONITOR_URL", "").strip.presence

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Answer only to the public name of this destination (APP_HOST, design §8),
  # which guards against DNS rebinding and Host header attacks. kamal-proxy's
  # health check reaches the container by its own address, so /up is exempt.
  config.hosts = [ Balcao::RequiredEnvironment.read("APP_HOST") ]
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
