# NFR-03's sweep (M4-4; the owner, 2026-11-15): "never a silent drop" covers
# every message the application accepted, so what a failure path left
# stranded is taken up again, every minute (config/recurring.yml):
#
# - a Telegram update left unread (a retry whose enqueue failed, a killed
#   worker, the queue down past Telegram's retries; review findings H1 and H3
#   of pull request #32): TelegramUpdateJob for the person's latest unread
#   update, which reads the earlier ones first, or for each update that names
#   no person;
# - a turn left without any reply (its job's dead letter that broke, a killed
#   worker; review findings of pull requests #11 and #18, whose page shows
#   "pensando…" until a reply comes, #18's V3): ProcessTurnJob for the
#   conversation's latest such turn, which answers the earlier ones first
#   (design §6.3), a deletion among them (FR-05);
# - a stored Telegram reply left pending past its time (a TelegramReplyJob
#   that was never enqueued or died): TelegramReplyJob for the visitor, which
#   sends the visitor's pending replies in order (FR-19);
# - an operator's alert left pending past its time (an OperatorAlertJob that
#   was never enqueued, or broke or died while it sent): OperatorAlertJob for
#   the alert, whose claim keeps two jobs from sending it at once (FR-14,
#   threat model SR-35).
#
# Stranded means stopped for more than five minutes, by the row's own clock
# (each read, run and attempt moves it), with nothing at work on it now: its
# lock is tried without waiting (AdvisoryLock.free?), so a burst that keeps a
# conversation busy past five minutes gets no second job. Whether a thing is
# run again or given up is the bound of the job that runs it, three reads,
# three runs, three attempts, counted on its row: the sweep takes it up, the
# job decides, and gives up with a fixed line (the fallback's; an alert's
# error line), never in silence.
#
# Each pass takes up at most LIMIT of each kind, oldest first; a pass that
# took something up writes one line, with counts alone (SR-30). Each of the
# four looks is apart: one that breaks is a line naming the error's class,
# and the others go on.
class StrandedSweepJob < ApplicationJob
  STOPPED = 5.minutes
  LIMIT = 100

  queue_as :default

  def perform
    counts = { updates:, conversations:, replies:, alerts: }
    return if counts.values.all?(&:zero?)

    Rails.logger.info("sweep: taken up again #{counts[:updates]} updates, #{counts[:conversations]} conversations, " \
                      "#{counts[:replies]} visitors' replies, #{counts[:alerts]} operator alerts")
  end

  private

  # The person's latest unread update stands for the person's others; an
  # update that names no person stands for itself.
  def updates
    looking(:updates) do
      latest = WebhookEvent.received.where(updated_at: ...STOPPED.ago).order(:update_id).limit(LIMIT * 10)
                           .group_by { |event| event.identity_hash || event.id }.values.map(&:last)
      latest.first(LIMIT).count do |event|
        key = event.identity_hash ? "telegram:#{event.identity_hash}" : "telegram-update:#{event.id}"
        AdvisoryLock.free?(key) && TelegramUpdateJob.perform_later(event.id)
      end
    end
  end

  def conversations
    looking(:conversations) do
      latest = Turn.where(state: %w[received running failed]).where.missing(:outbound_message)
                   .where(updated_at: ...STOPPED.ago).order(:created_at, :id).limit(LIMIT * 10)
                   .group_by(&:conversation_id).values.map(&:last)
      latest.first(LIMIT).count do |turn|
        AdvisoryLock.free?("conversation:#{turn.conversation_id}") && ProcessTurnJob.perform_later(turn.id)
      end
    end
  end

  def replies
    looking(:replies) do
      visitors = Visitor.where(channel: "telegram")
                        .where(id: Message.outbound.status_pending.where(channel: "telegram").where(updated_at: ...STOPPED.ago)
                                          .where("messages.next_attempt_at IS NULL OR messages.next_attempt_at <= ?", Time.current)
                                          .joins(:conversation).select("conversations.visitor_id"))
                        .order(:id).limit(LIMIT).to_a
      visitors.count do |visitor|
        AdvisoryLock.free?("telegram-send:#{visitor.identity_hash}") && TelegramReplyJob.perform_later(visitor.id)
      end
    end
  end

  def alerts
    looking(:alerts) do
      OperatorAlert.status_pending.where(updated_at: ...STOPPED.ago)
                   .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
                   .order(:created_at).limit(LIMIT).pluck(:id).count { |id| OperatorAlertJob.perform_later(id) }
    end
  end

  def looking(what)
    yield
  rescue StandardError => e
    Rails.logger.error("sweep: #{what} not looked at, #{e.class}")
    0
  end
end
