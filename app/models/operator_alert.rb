# The operator's alerts through the bot (threat model SR-35, ADR-0020,
# ADR-0022): FR-14's at the cap from M3-1, FR-10's handoff from M2-9, and the
# runbook's test of the path. Each is a row written where the event happens,
# keyed by its kind and what it is about, so it is sent once (NFR-02), and
# sent by OperatorAlertJob to the operator's linked chat (OperatorChat) as
# plain text, with the link preview off, through the Bot API client
# (Telegram::Client, SR-22, SR-43). Its text is fixed, from config/locales,
# and carries no visitor's words: the cap's names the month, the cap and the
# spend; a handoff's will name a conversation's id and a console link alone.
#
# An attempt claims the row for LEASE (claim), so the job and NFR-03's sweep
# never send it twice at once, and counts on the row as it starts. A failure
# of the way there or a 429 is tried again by the job, after 3 s and 18 s or
# the wait the 429 names, ATTEMPTS in all; Telegram's refusal (the operator
# blocked the bot, a chat that is gone) and a chat never linked fail it at
# once. What is no answer of Telegram's (a local bug, a certificate that does
# not prove the host) breaks the job and leaves the row claimed: the sweep
# takes it up once the lease and five minutes have passed, and its attempts
# count, so one that breaks every time fails at its fourth claim. An alert
# that cannot leave is one error line naming why, never its text or the chat
# (SR-30): an alert is never dropped in silence (NFR-03).
class OperatorAlert < ApplicationRecord
  ATTEMPTS = 3
  LEASE = 1.minute
  STATUSES = { pending: "pending", sent: "sent", failed: "failed" }.freeze

  enum :status, STATUSES, prefix: :status, validate: true

  validates :kind, :key, :text, presence: true

  # The row of this kind and key, written by the first call; a second finds
  # it, whatever text it carries (NFR-02).
  def self.record!(kind:, key:, text:) = create_or_find_by!(kind:, key:) { |alert| alert.text = text }

  # FR-14: the month reached its cap, once a month and cap, in the language
  # of the operator's chat: a cap a deploy raised and the month reaches again
  # is a new alert. The text says whether the demo paused, or which forced
  # mode serves past the cap, which the operator chose.
  def self.at_cap!(state, cap:, serving:)
    language = OperatorChat.language
    values = { month: state.month, cap: money(cap, language), spent: money(state.spent_usd, language) }
    text = if serving == "paused" then I18n.t("operator.cap.paused", locale: language, **values)
    else I18n.t("operator.cap.serving", locale: language, mode: I18n.t("operator.modes.#{serving}", locale: language), **values)
    end
    record!(kind: "budget_cap", key: "#{state.month}:#{cap.to_d.to_s("F")}", text:)
  end

  # The runbook's check of the path, sent at once rather than by the job, so
  # the command shows what became of it.
  def self.test!(at = Time.current)
    record!(kind: "test", key: at.utc.iso8601(6), text: I18n.t("operator.test", locale: OperatorChat.language)).tap(&:deliver).reload
  end

  # US$ amounts in the language's decimal mark, two places.
  def self.money(amount, language) = format("%.2f", amount).tr(".", I18n.t("operator.decimal_mark", locale: language))

  # The job, once the row is committed. A queue that does not take it leaves
  # the row pending for NFR-03's sweep, with a line, and never breaks the
  # turn whose read of the month wrote the alert.
  def deliver_later
    OperatorAlertJob.perform_later(id) || Rails.logger.error("operator alert #{id} (#{kind}): not enqueued; the sweep takes it up")
  rescue StandardError => e
    Rails.logger.error("operator alert #{id} (#{kind}): not enqueued, #{e.class}; the sweep takes it up")
  end

  # One attempt, when the row is pending and due and this call claims it.
  def deliver(client: Telegram::Client.new)
    return unless claim
    return give_up("its attempts are spent") if attempts > ATTEMPTS

    chat = OperatorChat.chat_id or return give_up("no operator chat is linked", error: "unlinked")
    client.send_message(chat_id: chat, text:)
    update!(status: "sent", sent_at: Time.current, next_attempt_at: nil, error: nil)
    Rails.logger.info("operator alert #{id} (#{kind}): sent")
  rescue Telegram::Client::Error => e
    failed(e)
  end

  private

  # The conditional write that makes this call the one attempt: pending, due,
  # and claimed for LEASE, its attempt counted as it starts.
  def claim
    now = Time.current
    claimed = self.class.status_pending.where(id:).where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
                  .update_all([ "attempts = attempts + 1, next_attempt_at = ?, updated_at = ?", now + LEASE, now ])
    claimed == 1 && reload
  end

  def failed(error)
    return give_up("Telegram refused it (#{error.code})", error: error.code.to_s) if error.refused?

    cause = error.failure || error.code.to_s
    return give_up("the way there failed at each of its #{ATTEMPTS} attempts (#{cause})", error: cause) if attempts >= ATTEMPTS

    wait = error.retry_after || ((attempts**4) + 2)
    update!(next_attempt_at: Time.current + wait, error: cause)
    OperatorAlertJob.set(wait_until: next_attempt_at).perform_later(id)
  end

  def give_up(why, error: why)
    update!(status: "failed", next_attempt_at: nil, error:)
    Rails.logger.error("operator alert #{id} (#{kind}): not sent, #{why}")
  end
end
