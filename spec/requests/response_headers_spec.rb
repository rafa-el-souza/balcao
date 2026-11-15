require "rails_helper"
require "open3"
require_relative "../../config/required_environment"

# Threat model SR-03: what the browser is told besides the policy of
# spec/requests/content_security_policy_spec.rb. A static file is never read
# as another type; the pages are denied the browser features the web app does
# not use, by the standard header (Rails' own middleware for it still writes
# the legacy Feature-Policy name); and no answer says how long the server took.
RSpec.describe "SR-03 the response headers", :spa_shells, type: :request do
  def permissions_policy
    response.headers["Permissions-Policy"].split(",").to_h { |directive| directive.strip.split("=", 2) }
  end

  it "sends a static file with nosniff, beside its cache-control" do
    get "/robots.txt"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Content-Type-Options"]).to eq "nosniff"
    expect(response.headers["Cache-Control"]).to start_with "public, max-age="
  end

  it "denies the pages every browser feature it names, the powerful ones among them" do
    get "/"

    expect(permissions_policy.keys).to include("camera", "microphone", "geolocation", "payment", "usb", "serial", "hid")
    expect(permissions_policy.values).to all(eq "()")
    expect(response.headers).not_to have_key("Feature-Policy")
  end

  it "sends the same policy with the API's answers" do
    get "/api/conversations/current"

    expect(permissions_policy).to include("camera" => "()", "microphone" => "()")
  end

  it "says nowhere how long the server took" do
    [ "/", "/up", "/api/conversations/current", "/robots.txt", "/no-such-page" ].each do |path|
      get path

      expect(response.headers).not_to have_key("X-Runtime"), path
    end
  end

  # The owner's word of 2026-11-15 (question 31: "SIM", then "Fecha" to the
  # method): every answer the application writes carries SR-03's set, read
  # here from the production configuration, which has its own middleware
  # (host authorization, SSL) and file server. The walk covers every route
  # the router draws, a route added later included, and the catalogue the
  # answers no route's endpoint writes; a new answer outside a route joins
  # the catalogue in the pull request that adds it. The database is a
  # socket that does not exist, so nothing here reaches one.
  CATALOGUE = {
    "an unknown path" => 404, "a route's constraint not met" => 404, "another host" => 403, "a static file" => 200,
    "a body over 16 KB" => 413, "a request past the edge's limit" => 429,
    "the cable's handshake of another version" => 426, "the cable's handshake without a key" => 400,
    "the cable's socket past a source's cap" => 429, "the cable's socket past the process's cap" => 503
  }.freeze
  # A header of the set an answer writes itself, which nothing overrides: the
  # trace page passes no referrer on, since its link is a credential (SR-11).
  OWN = { "GET /trace" => { "referrer-policy" => "no-referrer" } }.freeze

  PROBE = <<~'RUBY'
    # The pages' shells the spec wrote (spec/support/spa_shells.rb), so the
    # walk serves the pages with or without a build of web/.
    Rails.configuration.x.spa_shells = Pathname(ENV.fetch("SPA_SHELLS_DIR"))
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    answers = {}
    call = lambda do |label, method, path, env = {}|
      request = Rack::MockRequest.env_for("https://demo.example#{path}",
                                          { method:, "HTTP_HOST" => "demo.example", "REMOTE_ADDR" => "203.0.113.#{answers.size + 1}" }.merge(env))
      status, headers, body = Rails.application.call(request)
      body.close if body.respond_to?(:close)
      answers[label] = { "status" => status, "headers" => headers.to_h.transform_keys(&:downcase) }
    end

    # Every route, with a sample for each part of its path.
    samples = { token: "1" * 24 }
    Rails.application.routes.routes.each do |route|
      missing = route.required_parts - samples.keys
      raise "the route #{route.path.spec} needs a sample for #{missing.join(", ")}" if missing.any?

      method = route.verb.empty? ? "GET" : route.verb
      path = route.format(samples.slice(*route.required_parts))
      call.("#{method} #{path}", method, path)
    end

    # The catalogue. The cable gate's caps are lowered on the mounted gate
    # itself, so its refusal crosses the whole stack (spec/channels/gate_spec.rb
    # holds the caps).
    websocket = { "HTTP_UPGRADE" => "websocket", "HTTP_CONNECTION" => "Upgrade" }
    handshake = websocket.merge("HTTP_SEC_WEBSOCKET_VERSION" => "13", "HTTP_SEC_WEBSOCKET_KEY" => "#{"a" * 22}==")
    gate = Rails.application.routes.routes.find { |route| route.path.spec.to_s == "/cable" }.app.app
    call.("an unknown path", "GET", "/no-such-page")
    call.("a route's constraint not met", "GET", "/trace/abc")
    call.("another host", "GET", "/", "HTTP_HOST" => "elsewhere.example")
    call.("a static file", "GET", "/robots.txt")
    call.("a body over 16 KB", "POST", "/api/messages", "CONTENT_TYPE" => "application/json", input: "x" * 20_000)
    Rack::Attack.cache.store.write("limits:ip/anonymous:198.51.100.7", 60, expires_in: 60)
    call.("a request past the edge's limit", "GET", "/api/conversations/current", "REMOTE_ADDR" => "198.51.100.7")
    call.("the cable's handshake of another version", "GET", "/cable", websocket.merge("HTTP_SEC_WEBSOCKET_VERSION" => "12"))
    call.("the cable's handshake without a key", "GET", "/cable", websocket.merge("HTTP_SEC_WEBSOCKET_VERSION" => "13"))
    gate.instance_variable_set(:@per_source, 0)
    call.("the cable's socket past a source's cap", "GET", "/cable", handshake)
    gate.instance_variable_set(:@max, 0)
    call.("the cable's socket past the process's cap", "GET", "/cable", handshake)

    puts "ANSWERS #{JSON.generate(policy: answers.fetch("GET /up")["headers"]["content-security-policy"], answers:)}"
  RUBY

  it "sends SR-03's set on every answer, every route's and the catalogue's, from the production configuration", :aggregate_failures do
    env = ProductionEnv.complete.merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil,
                                       "RAILS_LOG_LEVEL" => "fatal", "DB_HOST" => "/nonexistent/balcao-spec",
                                       "SPA_SHELLS_DIR" => Rails.configuration.x.spa_shells.to_s)

    out, err, status = Open3.capture3(env, "bin/rails", "runner", PROBE, chdir: Rails.root.to_s)

    expect(status).to be_success, err
    probe = JSON.parse(out.lines.grep(/\AANSWERS /).last.delete_prefix("ANSWERS "))
    answers = probe.fetch("answers")
    routes = Rails.application.routes.routes.map { |route| route.verb.empty? ? "GET" : route.verb }
    expect(answers.size).to eq(routes.size + CATALOGUE.size)
    expect(answers.slice(*CATALOGUE.keys).transform_values { |answer| answer["status"] }).to eq(CATALOGUE)
    # A route that broke would be read as its error page, not as its own
    # answer: give the walk what the route needs instead.
    expect(answers.except(*CATALOGUE.keys).select { |_, answer| answer["status"] >= 500 }.keys).to eq([])
    defaults = Rails.application.config.action_dispatch.default_headers.transform_keys(&:downcase)
    expect(defaults.keys).to include("x-content-type-options", "x-frame-options", "referrer-policy", "permissions-policy")
    expect(probe.fetch("policy")).to include("default-src 'self'", "frame-ancestors 'none'")
    answers.each do |label, answer|
      headers = answer["headers"]
      expect(headers).to include(defaults.merge(OWN.fetch(label, {}))), "#{label}: #{headers.keys.sort.join(", ")}"
      expect(headers["content-security-policy"]).to eq(probe.fetch("policy")), label
      expect(headers).not_to have_key("x-runtime"), label
    end
    expect(answers.fetch("a static file")["headers"]["cache-control"]).to eq "public, max-age=#{1.year.to_i}"
  end
end
