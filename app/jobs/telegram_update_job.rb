# Reads one stored Telegram update (FR-19, threat model SR-09): the webhook
# stored it and answered 200; this job decides what it makes of the
# conversation (Telegram::Inbound) and then strips it, so the stored row keeps
# its update_id and its kind, and nothing of the person or of what they wrote
# (FR-19; review finding RN3 of pull request #7).
#
# One person's updates are read one at a time and in the order Telegram
# numbered them, under an advisory lock keyed by the person's hashed identity:
# the job that gets the lock first reads the person's earlier updates still
# unread, oldest first, and then its own, so an agreement and the question
# after it are never read swapped (review finding T2 of pull request #32), as
# ProcessTurnJob answers a conversation's turns. An earlier one that breaks is
# left to its own job. An update with no usable sender is locked by its own
# row. An update read already is left alone, so a second job for it (a
# redelivery enqueued while it waited) does nothing.
#
# A read that breaks is tried again, three attempts in all; after the third
# the update is stripped all the same and marked failed, and the line names
# the error by its class alone (SR-30). The log names an update by its
# update_id and what it made, never by anything it held.
class TelegramUpdateJob < ApplicationJob
  ATTEMPTS = 3

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: ATTEMPTS
  # Active Job raises the error after these, unless one of them raises its own.
  after_discard { |_job, error| give_up(error) }

  # Returns what the update made (Telegram::Inbound::Outcome), nil when it
  # was read already.
  def perform(event_id)
    event = WebhookEvent.find_by(id: event_id)
    return unless event&.received?

    person = event.identity_hash
    AdvisoryLock.hold(person ? "telegram:#{person}" : "telegram-update:#{event.id}") do
      earlier(event).each { |waiting| read_earlier(waiting) } if person
      event.reload
      read(event) if event.received?
    end
  end

  private

  def earlier(event) = WebhookEvent.unread_of(event.identity_hash).where(update_id: ...event.update_id).to_a

  def read_earlier(event)
    read(event)
  rescue StandardError => e
    Rails.logger.error("telegram update #{event.update_id}: not read before a later one: #{e.class}")
  end

  def read(event)
    outcome = Telegram::Inbound.new(event.update_hash).call(event)
    event.strip!(outcome.status)
    Rails.logger.info("telegram update #{event.update_id}: #{outcome.name}")
    outcome
  end

  def give_up(error)
    event = WebhookEvent.find_by(id: arguments.first)
    event.strip!("failed") if event&.received?
    Rails.logger.error("telegram update #{event&.update_id}: given up after #{executions} attempts, #{error.class}")
  rescue StandardError => e
    Rails.logger.error("telegram update #{event&.update_id}: given up, not stripped: #{e.class}")
  end
end
