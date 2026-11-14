# FR-19: a Telegram visitor's stored replies, sent again once the time a
# failed send named has come (Telegram::Outbound): the wait a 429 names, or
# the job's backoff after a failure of the way there. Scheduled for that
# time, so no job waits for it holding a worker's thread or the person's lock
# (review finding C3 of pull request #33). Its argument is the visitor's row,
# never the chat (threat model SR-10, SR-41).
class TelegramReplyJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(visitor_id)
    visitor = Visitor.find_by(id: visitor_id) or return
    Telegram::Outbound.new.deliver_pending(visitor)
  end
end
