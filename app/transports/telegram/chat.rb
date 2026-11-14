module Telegram
  # Where a reply goes (FR-19): the chat to send to, which in a private chat
  # is the person's own id (threat model SR-42), and the person's hashed
  # identity, which keys the lock that keeps their replies in order. The id
  # lives encrypted on the visitor's row alone (SR-10, SR-41), or in the
  # update being read for a person the bot holds no row of; it is never
  # stored anywhere else, so a reply is sent where it is made, never handed
  # to a later job by its chat.
  Chat = Data.define(:identity, :id) do
    # A Telegram visitor's chat, or nil for a visitor of another channel. A
    # chat that does not decrypt (encryption keys other than the row's) is
    # nil too, with one line in the log: nothing is sent to that person, and
    # neither the read of their updates, nor their turns, nor their deletion
    # break on it (review findings V2 and L14 of pull request #33).
    def self.of(visitor)
      return unless visitor&.channel == "telegram"

      id = visitor.telegram_chat_id.presence or return
      new(identity: visitor.identity_hash, id: Integer(id))
    rescue ActiveRecord::Encryption::Errors::Decryption => e
      Rails.logger.error("telegram visitor #{visitor.id}: the chat does not decrypt, #{e.class}")
      nil
    end

    # Written in a log line as the person's place, never the chat.
    def inspect = "#<Telegram::Chat>"
  end
end
