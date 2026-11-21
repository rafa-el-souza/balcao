# The operator's own chat with the bot, where the operator's alerts go
# (threat model SR-35, ADR-0020, ADR-0022): one row, linked once by a deep link
# the runbook's command mints in the application's container (link_url!), so
# only someone who can run a command there can link a chat; M2-9's console
# button will mint the same link. Opening the link in Telegram sends
# "/start <token>" from the operator's private chat, which Telegram::Inbound
# hands to link! before anything else of a person is read: Telegram's own way
# to tie a chat to an account elsewhere (the Bot API's deep linking).
#
# The token is 256 random bits, good for LINK_TTL and once; the row keeps its
# SHA-256 alone, and a new link replaces a pending one. The chat id is kept
# encrypted at rest, as a visitor's is (SR-41), and the language of the
# operator's app at the link, which the alerts are written in.
class OperatorChat < ApplicationRecord
  ROLE = "operator".freeze
  LINK_TTL = 15.minutes
  # SecureRandom.urlsafe_base64(32): 43 characters of a deep link's alphabet.
  TOKEN = /\A[A-Za-z0-9_-]{43}\z/

  encrypts :chat_id

  # The row, made by the first command that asks for it; two first commands
  # racing meet the unique index, and the one that loses gets the row (NFR-02).
  def self.current = find_by(role: ROLE) || create_or_find_by!(role: ROLE)

  # The runbook's command: the deep link to the bot that links the chat which
  # opens it, within LINK_TTL.
  def self.link_url!(at = Time.current)
    token = SecureRandom.urlsafe_base64(32)
    current.update!(link_digest: digest(token), link_expires_at: at + LINK_TTL)
    "https://t.me/#{Telegram::Bot::USERNAME}?start=#{token}"
  end

  # The bot read "/start <token>" in a private chat (Telegram::Inbound): the
  # chat becomes the operator's when the token is the pending link's and has
  # not expired, and the token is spent under the row's lock, so two chats
  # sending it at once link one. Answers whether it linked; a token that is
  # not the pending link's, or anything that is not a token, is a /start like
  # any other, and the log says only that a link was refused.
  def self.link!(token, chat_id:, language:, at: Time.current)
    return false unless token.is_a?(String) && token.match?(TOKEN)

    linked = transaction do
      row = lock.find_by(link_digest: digest(token))
      unless row && row.link_expires_at > at
        Rails.logger.info("operator chat: a link refused, #{row ? "expired" : "not the pending one"}")
        next false
      end

      row.update!(chat_id: chat_id.to_s, language:, linked_at: at, link_digest: nil, link_expires_at: nil)
      Rails.logger.info("operator chat: linked")
      true
    end
    resend(at) if linked
    linked
  end

  # Review finding H3 of pull request #63: an alert written before a chat was
  # linked failed for want of one; once linked, the chat gets this month's
  # latest of each kind (OperatorAlert.resend_unlinked!). The chat is linked
  # whatever becomes of them: a failure here is a line, and the bot still
  # answers the link.
  def self.resend(at)
    OperatorAlert.resend_unlinked!(at)
  rescue StandardError => e
    Rails.logger.error("operator chat: linked, but the alerts that failed for want of a chat not sent again, #{e.class}")
  end
  private_class_method :resend

  # The runbook's command that takes the alerts away from the chat, and
  # revokes a link still pending, which would link a chat again (review
  # finding C5 of pull request #63).
  def self.unlink! = find_by(role: ROLE)&.update!(chat_id: nil, language: nil, linked_at: nil, link_digest: nil, link_expires_at: nil)

  # The chat the alerts go to, nil until one is linked. A chat that does not
  # decrypt (encryption keys other than the row's) is nil too, with a line, as
  # a visitor's is (Telegram::Chat.of).
  def self.chat_id
    id = find_by(role: ROLE)&.chat_id.presence or return nil
    Integer(id)
  rescue ActiveRecord::Encryption::Errors::Decryption => e
    Rails.logger.error("operator chat: the chat does not decrypt, #{e.class}")
    nil
  end

  # The language the alerts are written in: the operator's app's at the link,
  # the default before one.
  def self.language = find_by(role: ROLE)&.language.presence || I18n.default_locale.to_s

  def self.digest(token) = Digest::SHA256.hexdigest(token)
  private_class_method :digest
end
