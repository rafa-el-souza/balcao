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
  #   takes no idempotency key.
  # - A reply that is not stored (the ask, /help and the deletion before the
  #   agreement, the fixed lines, the deletion's confirmation) is sent where
  #   it is made, to the chat of the update or of the row read before the
  #   deletion: the chat id is kept on the visitor's row alone (SR-10, SR-41),
  #   so it never goes into a job's arguments.
  #
  # Both are sent under a lock keyed by the person's hashed identity, so one
  # person's replies leave one at a time and in order. A send is tried three
  # times in all: after a 429, once the time it names has passed; after a
  # failure of the way there, after the job's backoff (Active Job's
  # polynomially_longer without its jitter: 3 s, then 18 s). The waits run
  # here, under the lock, so a later reply never overtakes one that waits;
  # a 429 that names more than LONGEST_WAIT fails the send at once, since the
  # worker's thread would wait with it. Any other answer that is not ok fails
  # it at once. A failed reply is marked failed with one line that names the
  # error by its class (NFR-03, SR-30); the chat and the text never reach a
  # line.
  #
  # A reply to a person who agreed takes the agreement's keyboard away, the
  # greeting first; the ask shows it (FR-19).
  class Outbound
    LIMIT = 4_096
    ATTEMPTS = 3
    LONGEST_WAIT = 30
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

    def initialize(client: Client.new, sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @sleeper = sleeper
    end

    # Sends a Telegram visitor's pending replies, oldest first.
    def deliver_pending(visitor)
      chat = Chat.of(visitor) or return

      AdvisoryLock.hold(lock(chat)) do
        pending(visitor).each { |message| deliver(message, chat) }
      end
    end

    # Sends a reply that is not stored; answers whether it left.
    def send_fixed(chat, text, keyboard: nil, name: :reply)
      AdvisoryLock.hold(lock(chat)) do
        failure = self.class.parts(text).lazy.filter_map { |part| attempt(chat, part, keyboard) }.first
        failure.nil? || failed("telegram fixed reply #{name}", failure)
      end
    end

    private

    def lock(chat) = "telegram-send:#{chat.identity}"

    def pending(visitor)
      Message.outbound.status_pending.where(channel: "telegram").joins(:conversation)
             .where(conversations: { visitor_id: visitor.id }).order(:created_at, :id).to_a
    end

    def deliver(message, chat)
      parts = self.class.parts(message.body)
      parts.drop(message.parts_sent).each do |part|
        failure = attempt(chat, part, REMOVE_KEYBOARD)
        next message.update_columns(parts_sent: message.parts_sent + 1, updated_at: Time.current) unless failure

        message.update_columns(status: "failed", updated_at: Time.current)
        return failed("telegram reply #{message.id}", failure)
      end
      message.update_columns(status: "sent", updated_at: Time.current)
    end

    Failure = Data.define(:error, :attempts)

    # One part, up to ATTEMPTS times; nil once it left, else the Failure.
    def attempt(chat, text, keyboard)
      1.upto(ATTEMPTS) do |count|
        @client.send_message(chat_id: chat.id, text:, reply_markup: keyboard)
        return nil
      rescue Client::Error => e
        wait = wait_after(e, count)
        return Failure.new(error: e, attempts: count) if wait.nil?

        @sleeper.call(wait)
      end
    end

    # The seconds to wait before the next attempt, or nil when there is none.
    def wait_after(error, count)
      return if error.refused? || count == ATTEMPTS
      return (count**4) + 2 unless error.rate_limited?

      error.retry_after.to_i if error.retry_after.to_i <= LONGEST_WAIT
    end

    def failed(what, failure)
      error = failure.error
      Rails.logger.error("#{what}: failed after #{failure.attempts} #{"attempt".pluralize(failure.attempts)}, " \
                         "#{error.class} (#{error.code || error.failure})")
      false
    end
  end
end
