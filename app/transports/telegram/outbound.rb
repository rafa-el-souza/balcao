module Telegram
  # FR-19's outbound side: a reply leaves for the visitor's chat with
  # sendMessage (Client), as plain text with the link preview off (threat
  # model SR-43).
  #
  # - A stored reply (a turn's, the agreement's greeting) is sent by its
  #   status, never by what made it (review finding T5 of pull request #32):
  #   the visitor's pending replies, oldest first, each marked sent when
  #   Telegram answers ok, part by part when it was cut, so a new attempt
  #   starts at the first part not sent; one marked sent is never sent again
  #   (NFR-02). A send whose answer was lost may arrive twice: sendMessage
  #   takes no idempotency key. When the last part leaves, the reply's turn
  #   gets its latency, from the message's receipt to that moment (NFR-01).
  # - A reply that is not stored (the ask, /help and the deletion before the
  #   agreement, the fixed lines, the deletion's confirmation) is sent where
  #   it is made, to the chat of the update or of the row, before the
  #   deletion takes it: the chat id is kept on the visitor's row alone
  #   (SR-10, SR-41), so it never goes into a job's arguments.
  #
  # Both are sent under a lock keyed by the person's hashed identity, so one
  # person's replies leave one at a time and in order: a reply that is not
  # stored goes after the person's stored replies still pending, in the same
  # hold of the lock (review finding C2 of pull request #33), unless one of
  # them waits for its time or their sending breaks, which is raised once the
  # reply has left, as StoredBroke (the fix review's R1 on pull request #47).
  # Nothing here waits:
  # each call tries each part once, so neither the lock nor a worker's thread
  # is held through a wait (review finding C3 of pull request #33).
  # - A stored reply Telegram asked to wait for (a 429) or that failed on the
  #   way is tried again by TelegramReplyJob, scheduled for the time the 429
  #   names or after the job's backoff (Active Job's polynomially_longer
  #   without its jitter: 3 s, then 18 s), three attempts in all, counted for
  #   each part of a reply cut in parts; until then it and the person's later
  #   replies stay pending, in order, and a drain meanwhile leaves them be.
  # - A reply that is not stored is tried once: nothing keeps its chat to try
  #   it again. The deletion's confirmation is the exception: it leaves
  #   before the deletion, from the row that keeps the chat, and the turn's
  #   job tries it again (TurnProcessor, FR-05).
  # Any other answer that is not ok fails a reply at once. A failed reply is
  # marked failed with one line that names the error by its class (NFR-03,
  # SR-30); the chat and the text never reach a line. What breaks a stored
  # reply's attempt and is no answer of Telegram's (what the client raises as
  # itself, not being the network: a local bug, a certificate that does not
  # prove the host, Client::NETWORK, review finding H7 of pull request #33;
  # or the reply's buttons) leaves it pending and breaks the job that sends,
  # whose own retries carry it (ProcessTurnJob's delivery tries again a
  # minute later), and counts among its three attempts, so one that breaks
  # every time fails at the third and holds the person's later replies no
  # longer (review finding C6 of pull request #47; the owner, 2026-11-15).
  # NFR-03's sweep (StrandedSweepJob) sends again a reply left pending past
  # its time, whatever stranded it.
  #
  # A stored reply's way to the chat is a span of its turn's trace, which its
  # run opened: it closes when Telegram takes the reply's last part, or with
  # the error that failed the reply (TraceRecorder.delivered; FR-12, #45's
  # verifier, V4).
  #
  # The ask shows the agreement's button (FR-19). A stored reply carries the
  # buttons of what it writes (Telegram::Buttons): the greeting FR-21's
  # openers, in the agreement's button's place; a reservation's code its copy
  # button; /trace's link its button; any other reply, and a fixed line to a
  # person who agreed, take the reply keyboard away. A reply cut in parts
  # carries its buttons on its last part, the parts before it taking the
  # keyboard away.
  class Outbound
    LIMIT = 4_096
    ATTEMPTS = 3
    REMOVE_KEYBOARD = { remove_keyboard: true }.freeze
    # Where a long reply is cut, in order: between paragraphs, lines, words.
    SEPARATORS = [ "\n\n", "\n", " " ].freeze

    # The ask's one button (FR-19), in the ask's locale: its tap sends the
    # agreement's phrase of the language as ordinary text (config/commands.yml).
    def self.agreement_keyboard(locale)
      phrase = CommandPhrases.current.agreement(AgentRunner::LANGUAGES.key(locale.to_s))
      { keyboard: [ [ { text: phrase } ] ], resize_keyboard: true }
    end

    # The text in parts of at most LIMIT UTF-16 units, the strictest way the
    # reference's "characters" can be read, cut between paragraphs where it
    # can, then between lines, then words; no part is blank.
    def self.parts(text, limit = LIMIT) = cut(text.to_s, 0, limit).reject { |part| part.strip.empty? }

    def self.units(text) = text.encode(Encoding::UTF_16LE, invalid: :replace, undef: :replace).bytesize / 2

    def self.cut(text, level, limit)
      return [ text ] if units(text) <= limit
      return hard_cut(text, limit) if level == SEPARATORS.size

      separator = SEPARATORS[level]
      text.split(separator).flat_map { |piece| units(piece) > limit ? cut(piece, level + 1, limit) : [ piece ] }
          .each_with_object([]) do |piece, parts|
            joined = parts.last && "#{parts.last}#{separator}#{piece}"
            joined && units(joined) <= limit ? parts[-1] = joined : parts << piece
          end
    end
    private_class_method :cut

    # A word longer than the limit, cut between grapheme clusters.
    def self.hard_cut(text, limit)
      text.each_grapheme_cluster.each_with_object([ +"" ]) do |cluster, parts|
        parts << +"" if units(parts.last) + units(cluster) > limit
        parts.last << cluster
      end
    end
    private_class_method :hard_cut

    def initialize(client: Client.new)
      @client = client
    end

    # Sends a Telegram visitor's pending replies, oldest first, up to the
    # first one that waits for its time. A Telegram visitor whose chat cannot
    # be read (Chat.of: it does not decrypt) can be sent nothing, so their
    # pending replies fail, each with a line, rather than stay pending for
    # NFR-03's sweep to take up every minute (review finding V3 of pull
    # request #48).
    def deliver_pending(visitor)
      chat = Chat.of(visitor)
      return unreadable(visitor) if chat.nil? && visitor&.channel == "telegram"
      return unless chat

      AdvisoryLock.hold(lock(chat)) { drain(visitor, chat) }
    end

    # Raised by send_fixed when the person's stored replies before its reply
    # broke, its cause the drain's error: the reply was not held back (it
    # left, or failed with its own line), and the caller says so and tries the
    # stored ones again (TelegramUpdateJob; the close's C2s of M4-6a).
    class StoredBroke < StandardError; end

    # Sends a reply that is not stored, trying each part once, after the
    # pending replies of the visitor given; answers whether it left. The
    # attempt, when the caller tries it again (the deletion's confirmation,
    # by the turn's job, FR-05), is named in the line of a send that failed.
    # A drain that breaks (the database, or what the client raises as itself)
    # does not hold the reply back: it leaves, and StoredBroke is raised
    # after it, for the caller's line and its retry of the stored replies
    # (TelegramUpdateJob; the fix review's R1 on pull request #47).
    def send_fixed(chat, text, keyboard: nil, name: :reply, visitor: nil, attempt: nil)
      AdvisoryLock.hold(lock(chat)) do
        stored = visitor && Chat.of(visitor)
        broken = drained(visitor, stored) if stored
        left = send_parts(chat, text, keyboard, name, attempt)
        raise StoredBroke, "the person's stored replies broke before a reply that is not stored", cause: broken if broken

        left
      end
    end

    private

    def lock(chat) = "telegram-send:#{chat.identity}"

    # The pending replies of a visitor whose chat cannot be read, failed under
    # the person's lock, each with its line and its trace's way closed.
    def unreadable(visitor)
      AdvisoryLock.hold("telegram-send:#{visitor.identity_hash}") do
        pending(visitor).each do |message|
          finished(message, error: "Telegram::Chat::Unreadable", status: "failed", next_attempt_at: nil)
          Rails.logger.error("telegram reply #{message.id}: failed, the visitor's chat cannot be read")
        end
      end
    end

    # A reply's new status and the close of its way in its turn's trace, in
    # one transaction, so a worker stopped between them leaves neither: the
    # reply still pending, its way still open, for the next drain (the fix
    # review's sister on pull request #48). The trace reads the turn by its
    # id inside its own rescue (the hunter's H3 on the same review), and
    # writes in a savepoint, so its failure never undoes the status.
    def finished(message, at: Time.current, error: nil, **columns)
      Message.transaction do
        message.update_columns(**columns, updated_at: at)
        TraceRecorder.delivered(message.turn_id, at:, error:)
      end
    end

    # The drain's error when it broke, else nil.
    def drained(visitor, chat)
      drain(visitor, chat)
      nil
    rescue StandardError => e
      e
    end

    # A reply that is not stored, each part tried once; false at the first
    # part that fails, with its line.
    def send_parts(chat, text, keyboard, name, attempt)
      parts = self.class.parts(text)
      parts.each_with_index do |part, index|
        error = send_part(chat, part, keyboard) or next
        return failed("telegram fixed reply #{name}", error, 1, part: [ index + 1, parts.size ], at: attempt)
      end
      true
    end

    def drain(visitor, chat)
      pending(visitor).each do |message|
        break if message.next_attempt_at&.future? || !deliver(message, chat, visitor)
      end
    end

    def pending(visitor)
      Message.outbound.status_pending.where(channel: "telegram").joins(:conversation)
             .where(conversations: { visitor_id: visitor.id }).order(:created_at, :id).to_a
    end

    # The parts not sent yet, each tried once. Answers true when the person's
    # next reply may go (this one sent, or failed for good), false when this
    # one waits for its time. The three attempts count for each part: a part
    # that leaves starts the count again for the next (FR-19, the owner,
    # 2026-11-15).
    def deliver(message, chat, visitor)
      parts = self.class.parts(message.body)
      buttons = Buttons.for(message)
      parts.drop(message.parts_sent).each do |part|
        error = send_part(chat, part, message.parts_sent == parts.size - 1 ? buttons : REMOVE_KEYBOARD)
        next message.update_columns(parts_sent: message.parts_sent + 1, send_attempts: 0, updated_at: Time.current) unless error

        return again_or_failed(message, error, visitor, [ message.parts_sent + 1, parts.size ])
      end
      sent_at = Time.current
      finished(message, at: sent_at, status: "sent", next_attempt_at: nil)
      latency(message, sent_at)
      true
    rescue StandardError => e
      broke(message, e)
    end

    # An attempt that broke with what is no answer of Telegram's: counted, and
    # raised for the job that sends; at the third the reply fails, so the
    # person's next one may go (review finding C6 of pull request #47).
    def broke(message, error)
      attempts = message.send_attempts + 1
      if attempts < ATTEMPTS
        message.update_columns(send_attempts: attempts, updated_at: Time.current)
        raise error
      end

      finished(message, error: error.class.name, status: "failed", send_attempts: attempts, next_attempt_at: nil)
      Rails.logger.error("telegram reply #{message.id}: failed after #{attempts} attempts that broke, #{error.class}")
      true
    end

    # NFR-01's figure for the reply's turn (Turn#reply_sent!). A measure never
    # holds a delivery back: one that cannot be written is a line naming the
    # reply and the error's class, and the person's next replies go on.
    def latency(message, sent_at)
      message.turn&.reply_sent!(sent_at)
    rescue StandardError => e
      Rails.logger.error("telegram reply #{message.id}: its turn's latency not written, #{e.class}")
    end

    # nil once the part left, else the error.
    def send_part(chat, text, keyboard)
      @client.send_message(chat_id: chat.id, text:, reply_markup: keyboard)
      nil
    rescue Client::Error => e
      e
    end

    # A refusal, or a third attempt, fails the reply; any other failure
    # schedules the next attempt for the time it names, or the job's backoff.
    def again_or_failed(message, error, visitor, part)
      attempts = message.send_attempts + 1
      if error.refused? || attempts >= ATTEMPTS
        finished(message, error: error.class.name, status: "failed", send_attempts: attempts, next_attempt_at: nil)
        return !failed("telegram reply #{message.id}", error, attempts, part:)
      end

      at = Time.current + wait_after(error, attempts)
      TelegramReplyJob.set(wait_until: at).perform_later(visitor.id)
      message.update_columns(send_attempts: attempts, next_attempt_at: at, updated_at: Time.current)
      false
    end

    def wait_after(error, attempts)
      error.rate_limited? && error.retry_after.to_i.positive? ? error.retry_after.to_i : (attempts**4) + 2
    end

    # One line: the reply, its attempts (or the caller's attempt, at), the
    # error's class and Telegram's code or the failure's class, the wait a 429
    # named and, for a reply cut in parts, the part that failed (review
    # finding H11 of pull request #33). Never the chat or the text (SR-30).
    def failed(what, error, attempts, part:, at: nil)
      reason = [ error.code || error.failure, ("retry after #{error.retry_after} s" if error.rate_limited? && error.retry_after) ]
      where = ", part #{part.first} of #{part.last}" if part.last > 1
      tried = at ? "at #{at}" : "after #{attempts} #{"attempt".pluralize(attempts)}"
      Rails.logger.error("#{what}: failed #{tried}, #{error.class} (#{reason.compact.join(", ")})#{where}")
      false
    end
  end
end
