module Telegram
  # FR-19, NFR-03: Telegram's typing status in the visitor's chat while a
  # turn's model works, the bot's "pensando…" (design §6.3, the transport
  # port's sign that a reply is on its way). Telegram clears the status after
  # five seconds or when a message arrives, so a thread of its own sends it
  # at once and again every INTERVAL seconds until the block ends; it touches
  # no database. A status that fails to send never fails the turn: the
  # thread logs the first failure by its class and goes on.
  class Typing
    INTERVAL = 4
    # How long the block's end waits for a status already on its way, so it
    # does not arrive after the reply.
    SETTLE = 2

    # The typing status of a Telegram visitor's chat; for another channel,
    # whose page draws its own, a block run as it is.
    def self.for(visitor) = (chat = Chat.of(visitor)) ? new(chat) : NONE

    NONE = Class.new { def during = yield }.new.freeze

    def initialize(chat, client: Client.new, interval: INTERVAL)
      @chat = chat
      @client = client
      @interval = interval
    end

    def during
      stop = Thread::Queue.new
      thread = Thread.new { renew(stop) }
      yield
    ensure
      stop&.close
      thread&.join(SETTLE)
    end

    private

    def renew(stop)
      logged = false
      loop do
        begin
          @client.send_chat_action(chat_id: @chat.id)
        rescue StandardError => e
          Rails.logger.warn("telegram typing: not sent, #{e.class} (#{e.try(:code) || e.try(:failure)})") unless logged
          logged = true
        end
        stop.pop(timeout: @interval)
        break if stop.closed?
      end
    end
  end
end
