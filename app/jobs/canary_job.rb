# FR-17: the canary's run (Canary), every ten minutes (config/recurring.yml).
# Never tried again: the next run is ten minutes away, and one tried again
# would count twice. A run that cannot even start is a line and a failure
# told to the monitor, which hears silence only when no job runs at all.
class CanaryJob < ApplicationJob
  queue_as :default

  def perform
    Canary.new.run
  rescue StandardError => e
    Rails.logger.error("canary: not run, #{e.class}")
    Heartbeat.canary.failure("canary: not run, #{e.class}")
  end
end
