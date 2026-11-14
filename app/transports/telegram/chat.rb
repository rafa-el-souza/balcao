module Telegram
  # Where a reply goes (FR-19): the chat to send to, which in a private chat
  # is the person's own id (threat model SR-42), and the person's hashed
  # identity, which keys the lock that keeps their replies in order. The id
  # lives encrypted on the visitor's row alone (SR-10, SR-41), or in the
  # update being read for a person the bot holds no row of; it is never
  # stored anywhere else, so a reply is sent where it is made, never handed
  # to a later job by its chat.
  Chat = Data.define(:identity, :id) do
    # A Telegram visitor's chat, or nil for a visitor of another channel.
    def self.of(visitor)
      return unless visitor&.channel == "telegram" && visitor.telegram_chat_id.present?

      new(identity: visitor.identity_hash, id: Integer(visitor.telegram_chat_id))
    end

    # Written in a log line as the person's place, never the chat.
    def inspect = "#<Telegram::Chat>"
  end
end
