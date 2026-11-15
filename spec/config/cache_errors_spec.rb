require "rails_helper"
require "open3"

# Review finding M4 of pull request #32: Solid Cache's failsafe answers nil
# for six transient errors of its database, and with no logger of its own it
# wrote nothing, so the limits' line said only that the cache did not answer
# (app/models/edge_limits.rb). Production gives it a handler that names the
# error by its class, never by its message, which may quote a key: an address
# or an identity's hash (threat model SR-30).
RSpec.describe "SR-30 FR-14 an error the cache's failsafe swallows, in production's log" do
  it "is named by its class alone" do
    probe = <<~RUBY
      raise "not Solid Cache: \#{Rails.cache.class}" unless Rails.cache.is_a?(SolidCache::Store)

      error = ActiveRecord::StatementTimeout.new("canceling statement: limits:ip/requests:203.0.113.9")
      Rails.cache.send(:error_handler).call(method: :increment, returning: nil, exception: error)
    RUBY
    env = ProductionEnv.complete
      .merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "warn")

    out, err, status = Open3.capture3(env, "bin/rails", "runner", probe, chdir: Rails.root.to_s)

    expect(status).to be_success, err
    messages = out.lines.filter_map { |line| JSON.parse(line)["message"] if line.start_with?("{") }
    expect(messages).to include("cache: increment failed, answered nil: ActiveRecord::StatementTimeout")
    expect(out).not_to include("203.0.113.9")
  end
end
