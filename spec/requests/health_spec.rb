require "rails_helper"
require "open3"
require_relative "../../config/required_environment"

# /up is what kamal-proxy polls during a deploy and what the external monitor
# watches every five minutes (design §6.6, §8).
RSpec.describe "NFR-04 /up answers the proxy and the external monitor" do
  it "returns 200 once the app has booted", type: :request do
    get "/up"

    expect(response).to have_http_status(:ok)
  end

  # Production answers only to APP_HOST (design §8), but kamal-proxy's health
  # check reaches the container by its own address, so /up is exempt.
  it "answers in production whatever the Host header, while other paths answer only to APP_HOST" do
    probe = <<~RUBY
      status = ->(host, path) { Rails.application.call(Rack::MockRequest.env_for("http://\#{host}\#{path}", "HTTP_HOST" => host)).first }
      puts [ status.("10.0.1.5", "/up"), status.("10.0.1.5", "/nothing-here"), status.("demo.example", "/nothing-here") ].join(",")
    RUBY
    env = Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "x" ] }.merge("MODEL_ADAPTER" => "real", "BUDGET_CAP_USD" => "10")
      .merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "fatal")

    out, err, status = Open3.capture3(env, "bin/rails", "runner", probe, chdir: Rails.root.to_s)

    expect(status).to be_success, err
    expect(out.lines.last.chomp).to eq "200,403,404"
  end
end
