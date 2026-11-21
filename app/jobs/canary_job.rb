# FR-17: the canary's run (Canary), every ten minutes (config/recurring.yml).
# Never tried again: the next run is ten minutes away, and one tried again
# would count twice. A run that cannot even start is a line and a failure
# told to the monitor, which hears silence only when no job runs at all.
class CanaryJob < ApplicationJob
  queue_as :default

  # Its time is its enqueueing (the scheduler's), so the queue's wait counts
  # in the canary's 20 seconds (review finding H6 of pull request #64).
  def perform
    Canary.new.run(due_at: enqueued_at)
  rescue StandardError => e
    Rails.logger.error("canary: not run, #{e.class}\n#{Canary.frames(e)}")
    Heartbeat.canary.failure("canary: not run, #{e.class}")
  end
end
