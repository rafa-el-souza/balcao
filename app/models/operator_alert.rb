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
# once; linking a chat sends the one the budget calls for now, if it failed
# for want of one (review finding H3 of pull request #63 and its fix review's
# R1 and R2). What is no answer of Telegram's (a local bug, a certificate that does
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

  # FR-14's alerts of the budget (Budget.alert), in the language of the
  # operator's chat: budget_cap, the month reached its cap, its text saying
  # whether the cap paused the demo, a forced mode keeps it paused, or a
  # forced mode serves past the cap; budget_month and budget_day, the month's economy and
  # the day's slice that ADR-0003's closed gate turned into pauses, until the
  # month ends and until midnight (review findings C1 = H1 and H4 of pull
  # request #63). None names a visitor or a conversation.
  def self.budget!(kind, key:, state:, cap:, slice:, day_spent:, serving:, day:)
    language = OperatorChat.language
    values = { month: state.month, day: day.iso8601, cap: money(cap, language), spent: money(state.spent_usd, language),
               slice: money(slice, language), day_spent: money(day_spent, language) }
    text = case kind
    when "budget_month" then I18n.t("operator.gate.month", locale: language, **values)
    when "budget_day" then I18n.t("operator.gate.day", locale: language, **values)
    when "budget_cap" then cap_text(serving, state.forced_mode, language, values)
    else raise ArgumentError, "#{kind} is no alert of the budget"
    end
    record!(kind:, key:, text:)
  end

  # Whether the cap paused the demo, a mode the operator forced keeps it
  # paused (a pause, or an economy the closed gate pauses), which holds
  # whatever the cap is (review finding C2 = H10 of pull request #63), or a
  # forced mode serves past the cap. No text names a deploy as the way to
  # resume: with the gate closed a raised cap may land the month in an
  # economy the gate pauses, so the runbook says what resumes it (V1).
  def self.cap_text(serving, forced, language, values)
    return I18n.t("operator.cap.paused", locale: language, **values) if serving == "paused" && forced.nil?
    return I18n.t("operator.cap.forced", locale: language, **values) if serving == "paused"

    I18n.t("operator.cap.serving", locale: language, mode: I18n.t("operator.modes.#{serving}", locale: language), **values)
  end
  private_class_method :cap_text

  # A budget alert's key: the month and the cap, so a cap a deploy raised and
  # the month reaches again is a new alert, or for the day's slice the day
  # and the cap, so each day it pauses is one.
  def self.budget_key(kind, month:, day:, cap:) = "#{kind == "budget_day" ? day.iso8601 : month}:#{cap.to_d.to_s("F")}"

  # Review finding H3 of pull request #63: an alert that failed for want of a
  # linked chat, or of a linked one that could be read (H5), is sent again
  # once one is linked (OperatorChat.link!) when it is the one the budget's
  # state calls for now (Budget.due_alert): an earlier one of its kind was
  # followed by the one now, and a pause that is over, a past day's or one at
  # a cap since changed, is no news (its fix review's R1 and R2). It is set
  # pending as new by a conditional write and enqueued.
  def self.resend_unlinked!(at = Time.current)
    kind, key = Budget.due_alert(at)
    return unless kind

    row = status_failed.find_by(kind:, key:, error: %w[unlinked unreadable]) or return
    pending = where(id: row.id, status: "failed")
                .update_all(status: "pending", attempts: 0, next_attempt_at: nil, error: nil, updated_at: Time.current)
    row.deliver_later if pending == 1
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
    return give_up([ "its attempts are spent", ("(last: #{error})" if error) ].compact.join(" ")) if attempts > ATTEMPTS

    chat = OperatorChat.chat_id or return unsendable
    client.send_message(chat_id: chat, text:)
    update!(status: "sent", sent_at: Time.current, next_attempt_at: nil, error: nil)
    Rails.logger.info("operator alert #{id} (#{kind}): sent")
  rescue Telegram::Client::Error => e
    failed(e)
  rescue StandardError => e
    broke(e)
    raise
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

    # A 429's wait only as a positive number of seconds, as Telegram::Outbound
    # takes it (review finding H9 of pull request #63); the backoff otherwise.
    wait = error.rate_limited? && error.retry_after.to_i.positive? ? error.retry_after.to_i : (attempts**4) + 2
    update!(next_attempt_at: Time.current + wait, error: cause)
    OperatorAlertJob.set(wait_until: next_attempt_at).perform_later(id)
  end

  # What broke an attempt and is no answer of Telegram's: its class kept on
  # the row, so the give-up at the claim after the last names it (review
  # finding H6 of pull request #63); the job breaks all the same, for the
  # sweep. A write that breaks too is a line.
  def broke(error)
    update_columns(error: error.class.name)
  rescue StandardError => e
    Rails.logger.error("operator alert #{id} (#{kind}): what broke the attempt, #{error.class}, not kept, #{e.class}")
  end

  # No chat to send to: none linked, or a linked one that cannot be read, which
  # linking again mends (review finding H5 of pull request #63).
  def unsendable
    return give_up("the linked chat cannot be read; link it again", error: "unreadable") if OperatorChat.linked?

    give_up("no operator chat is linked", error: "unlinked")
  end

  # The line first, so a write that breaks keeps the reason (review finding
  # H8 of pull request #63; TelegramUpdateJob#give_up's rule).
  def give_up(why, error: why)
    Rails.logger.error("operator alert #{id} (#{kind}): not sent, #{why}")
    update!(status: "failed", next_attempt_at: nil, error:)
  end
end
