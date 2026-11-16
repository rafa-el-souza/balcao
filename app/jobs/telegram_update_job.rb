# Reads one stored Telegram update (FR-19, threat model SR-09): the webhook
# stored it and answered 200; this job decides what it makes of the
# conversation (Telegram::Inbound), sends what answers it (Telegram::Outbound)
# and then strips it, so the stored row keeps its update_id and its kind, and
# nothing of the person or of what they wrote (FR-19; review finding RN3 of
# pull request #7).
#
# One person's updates are read one at a time and in the order Telegram
# numbered them, under an advisory lock keyed by the person's hashed identity:
# the job that gets the lock first reads the person's earlier updates still
# unread, oldest first, and then its own, so an agreement and the question
# after it are never read swapped (review finding T2 of pull request #32), as
# ProcessTurnJob answers a conversation's turns. While an earlier one that
# broke is still unread, this one waits, so the question is not read before
# the agreement (review finding R1 of the same review): a job of its own,
# scheduled after 3 s, 18 s and 83 s, so the wait spends none of this
# update's own attempts (review finding H6 of pull request #33); after the
# third wait it reads itself all the same. Each pass reads the earlier one
# again, so it is given up within the wait. An update with no usable sender
# is locked by its own row. An update read already is left alone, so a second
# job for it (a redelivery enqueued while it waited, the sweep) does nothing.
#
# The reply an update names is not stored (the ask, /help and the deletion
# before the agreement, the limit's line, the fixed lines), so it goes to the
# chat of the update, which nothing else keeps, after the person's stored
# replies still pending, which go by their status, the agreement's greeting
# among them (review finding T5 of the same review; finding C2 of pull
# request #33). Both before the strip: a read that breaks after a send sends
# again rather than never. A send that fails is logged and the read goes on,
# and so is one that breaks, whatever breaks it (what the client raises as
# itself, or the database while the person's replies drain): the update was
# read, and reading it again would count its message again in FR-14's limits
# and send its line again; a stored reply left pending goes with
# TelegramReplyJob a minute later, as a turn's does (review finding C2 of
# pull request #47).
#
# A read that breaks is tried again, three reads in all, counted on the
# update's row as each starts (WebhookEvent#reads), whoever reads it: its own
# job's attempts, a later update's job, NFR-03's sweep (StrandedSweepJob),
# which reads again an update left unread past five minutes, a read that
# killed its worker included. After the third the update is given up: the
# line, written first (review finding M1 of the same review), names the error
# by its class alone (SR-30); the person gets the fallback's line, so no
# message is dropped in silence (NFR-03; review findings H1 and H3 of pull
# request #32, H6 of #33), unless the update stored a message, whose turn
# answers it; and the update is stripped all the same and marked failed. The
# log names an update by its update_id and what it made, never by anything
# it held.
class TelegramUpdateJob < ApplicationJob
  ATTEMPTS = 3
  WAITS = 3

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: ATTEMPTS
  # Active Job raises the error after these, unless one of them raises its own.
  after_discard { |_job, error| give_up(error) }

  # Returns what the update made (Telegram::Inbound::Outcome), nil when it
  # was read already, waits for an earlier one or is given up. waits counts
  # the passes this update waited for an earlier one (H6).
  def perform(event_id, waits = 0)
    event = WebhookEvent.find_by(id: event_id)
    return unless event&.received?

    AdvisoryLock.hold(lock(event)) do
      next wait(event, waits) if event.identity_hash && waiting?(event, waits)

      event.reload
      read(event) if event.received?
    end
  end

  private

  def lock(event) = event.identity_hash ? "telegram:#{event.identity_hash}" : "telegram-update:#{event.id}"

  def earlier(event) = WebhookEvent.unread_of(event.identity_hash).where(update_id: ...event.update_id).to_a

  # Reads the person's earlier unread updates, and answers whether one is
  # still unread while this update has a wait left.
  def waiting?(event, waits)
    earlier(event).each { |unread| read_earlier(unread) }
    waits < WAITS && earlier(event).any?
  end

  # A pass of its own, 3 s, 18 s and 83 s later, so the wait spends no
  # attempt of this update's.
  def wait(event, waits)
    self.class.set(wait: ((waits + 1)**4) + 2).perform_later(event.id, waits + 1)
    nil
  end

  def read_earlier(event)
    read(event)
  rescue StandardError => e
    Rails.logger.error("telegram update #{event.update_id}: not read before a later one: #{e.class}")
  end

  def read(event)
    return given_up(event) if event.reads >= ATTEMPTS

    event.increment!(:reads, touch: true)
    inbound = Telegram::Inbound.new(event.update_hash)
    outcome = inbound.call(event)
    answer(inbound.chat, outcome, event.update_id)
    event.strip!(outcome.status)
    Rails.logger.info("telegram update #{event.update_id}: #{outcome.name}")
    outcome
  end

  # The ask carries the agreement's button; a reply to a person who agreed
  # takes it away; a reply before the agreement leaves it as it is.
  def answer(chat, outcome, update_id)
    return unless chat

    outbound = Telegram::Outbound.new
    visitor = Visitor.find_by(channel: "telegram", identity_hash: chat.identity)
    return sending(update_id, visitor) { outbound.deliver_pending(visitor) } if outcome.reply.nil? && visitor
    return unless outcome.reply

    keyboard = if outcome.name == :ask then Telegram::Outbound.agreement_keyboard(outcome.language)
    elsif visitor then Telegram::Outbound::REMOVE_KEYBOARD
    end
    # After the person's stored replies still pending (review finding C2 of
    # pull request #33).
    sending(update_id, visitor) { outbound.send_fixed(chat, outcome.reply, keyboard:, name: outcome.name, visitor:) }
  end

  # A send that breaks never breaks the read (the header; review finding C2
  # of pull request #47): one line naming the update and the error's class,
  # and the person's stored replies tried again a minute later.
  def sending(update_id, visitor)
    yield
  rescue StandardError => e
    Rails.logger.error("telegram update #{update_id}: replies not sent, #{e.class}")
    later(update_id, visitor) if visitor
  end

  def later(update_id, visitor)
    TelegramReplyJob.set(wait: 1.minute).perform_later(visitor.id)
  rescue StandardError => e
    Rails.logger.error("telegram update #{update_id}: replies not tried again, #{e.class}")
  end

  # The update was read three times: given up, with no fourth read (NFR-03).
  def given_up(event)
    Rails.logger.error("telegram update #{event.update_id}: given up after #{ATTEMPTS} reads")
    left(event)
    nil
  end

  # The job's last attempt failed. The line comes first, naming the update by
  # its update_id or, when the row cannot be read (the database being what
  # failed), by its row (review finding H4 of pull request #33); a row left as
  # it was, its payload still in it, is said so (finding R2 of the same
  # review), and the sweep takes it up again. The rest runs under the
  # person's lock, as a read does.
  def give_up(error)
    event, unread = read_row
    name = event ? event.update_id : "row #{arguments.first}"
    Rails.logger.error("telegram update #{name}: given up after #{executions} attempts, #{error.class}")
    return Rails.logger.error("telegram update #{name}: given up, not stripped: #{unread.class}") if unread
    return unless event&.received?

    AdvisoryLock.hold(lock(event)) { left(event.reload) if event.received? }
  rescue StandardError => e
    Rails.logger.error("telegram update #{name}: given up, not stripped: #{e.class}")
  end

  # A given-up update: the person's line, then the strip.
  def left(event)
    tell(event)
    event.strip!("failed")
  end

  # NFR-03: the fallback's line to the person, unless the update stored a
  # message, whose turn answers it (ProcessTurnJob, the sweep), or is none
  # the bot answers (Telegram::Inbound#given_up). A send that fails or breaks
  # is a line; the update is stripped all the same.
  def tell(event)
    return if event.messages.exists?

    chat, text = Telegram::Inbound.new(event.update_hash).given_up
    return unless chat

    visitor = Visitor.find_by(channel: "telegram", identity_hash: chat.identity)
    keyboard = Telegram::Outbound::REMOVE_KEYBOARD if visitor
    Telegram::Outbound.new.send_fixed(chat, text, keyboard:, name: :given_up, visitor:)
  rescue StandardError => e
    Rails.logger.error("telegram update #{event.update_id}: given up, its line not sent: #{e.class}")
  end

  # The row and nil, or nil and the error that kept it from being read.
  def read_row
    [ WebhookEvent.find_by(id: arguments.first), nil ]
  rescue StandardError => e
    [ nil, e ]
  end
end
