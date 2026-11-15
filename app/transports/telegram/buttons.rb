module Telegram
  # The bot's finish (FR-19's part for M4, ADR-0017): what a stored reply
  # carries under it, sendMessage's reply_markup, read from what the reply
  # writes when it is sent (Telegram::Outbound), as the web chat stamps the
  # codes a reply writes (Message#stream_payload), so both channels send the
  # same text and only the channel draws its buttons (ADR-0017's fifth test).
  #
  # - Each code of the visitor's own reservations that the reply writes, as a
  #   word of its own, gets a button that copies it (copy_text; FR-07), in
  #   the order the reply writes them.
  # - A reply that writes the conversation's trace link (FR-12's /trace) gets
  #   a button that opens it (url).
  # - The greeting, as the agreement and /start store it, with or without
  #   FR-01's notice before it, gets FR-21's openers as a reply keyboard
  #   (config/openers.yml), whose tap sends the opener's text as an ordinary
  #   message, so only a listed text has a button. It hides once tapped, and
  #   the next reply takes it away.
  # - Any other reply takes the reply keyboard away: the agreement's button,
  #   or the openers.
  #
  # No button adds a kind of update (ADR-0017's first test, threat model
  # SR-42): one copies a text or opens a link on the visitor's own device, or
  # sends ordinary text down the path every message takes. None carries the
  # model's words (SR-43): a code that is no reservation of the visitor's, or
  # any other link, gets none. A message carries one keyboard, so a reply
  # with a button cannot take the openers away; the next reply without one
  # does.
  module Buttons
    # The keyboard of a stored reply.
    def self.for(message)
      conversation = message.conversation
      language = conversation.language
      rows = codes(message.body, conversation.visitor_id).map do |code|
        [ { text: I18n.t("telegram.buttons.copy_code", code:, locale: language), copy_text: { text: code } } ]
      end
      rows << [ { text: I18n.t("telegram.buttons.trace", locale: language), url: conversation.trace_url } ] if trace?(message.body, conversation)
      return { inline_keyboard: rows } if rows.any?
      return openers if greeting?(message.body)

      Outbound::REMOVE_KEYBOARD
    end

    # FR-21's openers, one a row, as the greeting's reply keyboard.
    def self.openers
      { keyboard: Openers.current.all.map { |opener| [ { text: opener.text } ] }, resize_keyboard: true, one_time_keyboard: true }
    end

    # The visitor's codes the body writes, as words of their own, in order.
    def self.codes(body, visitor_id)
      Reservation.where(visitor_id:).pluck(:code)
                 .filter_map { |code| (at = body.index(word(code))) && [ at, code ] }.sort.map(&:last)
    end
    private_class_method :codes

    def self.trace?(body, conversation) = body.match?(/#{Regexp.escape(conversation.trace_url)}(?![[:alnum:]])/)
    private_class_method :trace?

    # A code inside a longer word is not one, as the web chat stamps it.
    def self.word(code) = /(?<![[:alnum:]])#{Regexp.escape(code)}(?![[:alnum:]])/
    private_class_method :word

    # The greeting as the system stores it: alone (the agreement's, and
    # /start's after a conversation's first reply) or after the notice
    # (/start's as a conversation's first reply), in any of the languages.
    def self.greeting?(body)
      AgentRunner::LANGUAGES.each_value.any? do |locale|
        greeting = FixedReply.greeting(locale)
        body == greeting || body == FixedReply.with_notice(greeting, locale)
      end
    end
    private_class_method :greeting?
  end
end
