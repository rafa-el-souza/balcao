require "rails_helper"
require "yaml"

# A deploy stops the job container with SIGTERM and kills it once Kamal's stop
# timeout has passed: 30 s for a role without the proxy, its drain_timeout,
# which config/deploy.yml leaves unset. Solid Queue waits its shutdown timeout
# for the turns its workers run; a job still running then is handed back to
# the queue by the worker's deregistration, and its turn runs again from its
# start in the new container, the model called and billed again (design §10,
# note of 2026-11-13; review finding V2 of pull request #18). A container
# killed before Solid Queue lets go would leave its jobs to be failed.
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
