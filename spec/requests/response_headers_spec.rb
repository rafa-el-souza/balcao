require "rails_helper"
require "open3"
require_relative "../../config/required_environment"
require_relative "../../lib/edge_check/catalogue"

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
    get "/favicon.ico"

    expect(response).to have_http_status(:ok)
    expect(response.headers["X-Content-Type-Options"]).to eq "nosniff"
    expect(response.headers["Cache-Control"]).to start_with "public, max-age="
  end

  # #22's sister of C1 and #40's thirteenth line, settled in M3-6b: a crawler
  # keeps robots.txt for up to 24 hours (RFC 9309, 2.4), and Google may keep
  # it longer on a longer max-age, so the file is a route's answer with a
  # day's cache, never public/'s year. It allows every page: a rehearsal host
  # says noindex on every answer instead, which a crawler reads only on a page
  # it may fetch (design §8).
  it "sends robots.txt from its route, every page allowed, with a day's cache" do
    get "/robots.txt"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq "text/plain"
    expect(response.headers["Cache-Control"]).to eq "max-age=86400, public"
    expect(response.headers["X-Content-Type-Options"]).to eq "nosniff"
    rules = response.body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    expect(rules).to eq [ "User-agent: *", "Allow: /" ]
    expect(Rails.public_path.join("robots.txt")).not_to exist
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
    [ "/", "/up", "/api/conversations/current", "/robots.txt", "/favicon.ico", "/no-such-page" ].each do |path|
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
  # The catalogue is lib/edge_check/catalogue.rb's, which bin/edge-check asks
  # a deployed host from outside (M3-6).
  CATALOGUE = EdgeCheck::CATALOGUE
  # A header of the set an answer writes itself, which nothing overrides: the
  # trace page passes no referrer on, since its link is a credential (SR-11).
  OWN = { "GET /trace" => { "referrer-policy" => "no-referrer" } }.freeze

  PROBE = <<~'RUBY'
    # The pages' shells the spec wrote (spec/support/spa_shells.rb), so the
    # walk serves the pages with or without a build of web/.
    Rails.configuration.x.spa_shells = Pathname(ENV.fetch("SPA_SHELLS_DIR"))
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    answers = {}
    host = ENV.fetch("APP_HOST")
    call = lambda do |label, method, path, env = {}|
      request = Rack::MockRequest.env_for("https://#{host}#{path}",
                                          { method:, "HTTP_HOST" => host, "REMOTE_ADDR" => "203.0.113.#{answers.size + 1}" }.merge(env))
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
    call.("a static file", "GET", "/favicon.ico")
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

  # One walk per environment, each a production process of its own.
  WALKS = {}

  def walk(env)
    WALKS[env] ||= begin
      env = env.merge("RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "fatal",
                      "DB_HOST" => "/nonexistent/balcao-spec", "SPA_SHELLS_DIR" => Rails.configuration.x.spa_shells.to_s)
      out, err, status = Open3.capture3(env, "bin/rails", "runner", PROBE, chdir: Rails.root.to_s)
      raise "the walk failed: #{err}" unless status.success?

      JSON.parse(out.lines.grep(/\AANSWERS /).last.delete_prefix("ANSWERS "))
    end
  end

  # A rehearsal host's environment (ProductionEnv.complete: NOINDEX=true), on
  # a name of its own.
  def rehearsal_walk = walk(ProductionEnv.complete.merge("APP_HOST" => "demo.example"))

  it "sends SR-03's set on every answer, every route's and the catalogue's, from the production configuration", :aggregate_failures do
    probe = rehearsal_walk
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
    expect(answers.fetch("GET /robots.txt")["headers"]["cache-control"]).to eq "max-age=86400, public"
  end

  # Design §8 (M3-6b): a rehearsal host's name is in the certificate logs
  # within minutes, so every answer it writes says noindex, the static
  # files', the refusals' and the error pages' among them; the trace page's
  # own noindex, nofollow stays (SR-11). The demo's name says it only there.
  it "says noindex on every answer of a rehearsal host, and nowhere but the trace page on the public name", :aggregate_failures do
    rehearsal = rehearsal_walk.fetch("answers")
    public_name = walk(ProductionEnv.public_name).fetch("answers")

    expect(public_name.keys).to match_array(rehearsal.keys)
    rehearsal.each do |label, answer|
      expect(answer["headers"]["x-robots-tag"]).to eq(label == "GET /trace" ? "noindex, nofollow" : "noindex"), label
    end
    public_name.each do |label, answer|
      expect(answer["headers"]["x-robots-tag"]).to eq(label == "GET /trace" ? "noindex, nofollow" : nil), label
    end
  end
end
