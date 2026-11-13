require "rails_helper"
require "yaml"

# A deploy stops the job container with SIGTERM and kills it once Kamal's stop
# timeout has passed: 30 s for a role without the proxy, its drain_timeout,
# which config/deploy.yml leaves unset. Solid Queue waits its shutdown timeout
# for the turns its workers run, and fails a job still running then without
# the job's own retries (SolidQueue::Processes::ProcessExitError), so the cut
# turn would wait for the visitor's next message (design §10, note of
# 2026-11-13).
RSpec.describe "NFR-03 a deploy lets the turn its worker is running finish" do
  def kamal_stop_timeout
    config = YAML.safe_load(Rails.root.join("config/deploy.yml").read, aliases: true)
    config.dig("servers", "job", "stop_timeout") || config["stop_timeout"] || config["drain_timeout"] || 30
  end

  it "waits for a running turn twice NFR-01's p95 of ten seconds, and stops before Kamal kills the container" do
    expect(SolidQueue.shutdown_timeout).to be >= 20.seconds
    expect(SolidQueue.shutdown_timeout).to be < kamal_stop_timeout.seconds
  end
end
