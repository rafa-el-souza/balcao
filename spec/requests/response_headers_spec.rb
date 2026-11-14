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

  # The request specs run the test environment; production has its own
  # file-server settings (config/environments/production.rb), so the same
  # headers are read from a production boot, as spec/requests/health_spec.rb does.
  it "sends the same headers from the production configuration" do
    probe = <<~RUBY
      call = ->(path) { Rails.application.call(Rack::MockRequest.env_for("https://demo.example\#{path}", "HTTP_HOST" => "demo.example")) }
      static = call.("/robots.txt")
      health = call.("/up")
      missing = call.("/no-such-page")
      puts JSON.generate(
        static: [ static[0], static[1]["x-content-type-options"], static[1]["cache-control"] ],
        policy: health[1]["permissions-policy"].to_s.split(",").map { |directive| directive.strip.split("=", 2) }.to_h,
        runtime: [ static, health, missing ].map { |answer| answer[1].key?("x-runtime") }
      )
    RUBY
    env = Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "x" ] }.merge("MODEL_ADAPTER" => "real", "BUDGET_CAP_USD" => "10")
      .merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "fatal")

    out, err, status = Open3.capture3(env, "bin/rails", "runner", probe, chdir: Rails.root.to_s)

    expect(status).to be_success, err
    answers = JSON.parse(out.lines.last)
    expect(answers["static"]).to eq [ 200, "nosniff", "public, max-age=#{1.year.to_i}" ]
    expect(answers["policy"]).to include("camera" => "()", "microphone" => "()", "geolocation" => "()")
    expect(answers["policy"].values).to all(eq "()")
    expect(answers["runtime"]).to eq [ false, false, false ]
  end
end
