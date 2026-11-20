module Telegram
  # What one Telegram update makes of the conversation (FR-19, ADR-0016,
  # ADR-0017), read by TelegramUpdateJob from the stored update, in order:
  #
  # 1. Only a message in a private chat whose id is its sender's, from a
  #    person, with Telegram's id of the message, is used: any other update,
  #    a group, a channel, another chat and a bot are dropped, with no visitor,
  #    no turn and no reply (threat model SR-42).
  # 2. A service message, which the app writes and not the person, gets no
  #    reply and counts in no limit. A message of a kind Bot API 10.4 does not
  #    list is something a person sent, as a kind Telegram adds later would
  #    be: it gets the line for a message that is not text (review finding M3
  #    of pull request #32).
  # 3. Every other message counts in FR-14's per-visitor limits, by the
  #    identity sha256(pepper || user id) (SR-10), whatever its kind and before
  #    the agreement too; past a limit nothing is read or stored, and the
  #    limit's own line goes at most once a minute.
  # 4. Agreement first (the owner, 2026-11-14): a person the bot holds no row
  #    of gets the ask, whatever they sent, /start first of all; nothing of
  #    them is stored and no model is called. /help and the delete command
  #    answer as always. One of the agreement's phrases, typed or sent by the
  #    ask's button (config/commands.yml), creates the visitor's row with the
  #    chat id a reply needs, encrypted (SR-41), and its first conversation in
  #    the language of the person's app; the greeting answers it, stored as
  #    the conversation's first reply, the notice having come with the ask.
  # 5. A visitor's text is a turn like the web chat's (Intake, ProcessTurnJob),
  #    keyed by the visitor and Telegram's message id (NFR-02, SR-07); a text
  #    over 1,000 characters and anything that is not text get a fixed line,
  #    and no file is fetched and no caption read.
  #
  # The outcome names the reply that is not stored, which TelegramUpdateJob
  # sends to the chat of the update it reads (Telegram::Outbound): the ask,
  # /help and the deletion before the agreement, the limit's line and the
  # fixed lines. A stored reply, the agreement's greeting, is sent by its
  # status, whatever read it (review finding T5 of pull request #32).
  class Inbound
    Outcome = Data.define(:name, :status, :reply, :language) do
      def self.drop(name) = new(name:, status: "ignored", reply: nil, language: nil)
    end

    # What a person sends, as against what the app writes (Telegram's service
    # messages): Bot API 10.4's Message fields for content.
    CONTENT = %w[
      text animation audio document live_photo paid_media photo sticker story video video_note voice widget
      rich_message checklist contact dice game poll venue location invoice giveaway giveaway_winners
    ].freeze
    # Bot API 10.4's Message fields of the messages the app writes, read on
    # 2026-11-14: a message is a service message when it holds one of these
    # and nothing of CONTENT.
    SERVICE = %w[
      new_chat_members left_chat_member chat_owner_left chat_owner_changed new_chat_title new_chat_photo
      delete_chat_photo group_chat_created supergroup_chat_created channel_chat_created
      message_auto_delete_timer_changed migrate_to_chat_id migrate_from_chat_id pinned_message successful_payment
      refunded_payment users_shared chat_shared gift unique_gift gift_upgrade_sent connected_website
      write_access_allowed passport_data proximity_alert_triggered boost_added chat_background_set
      checklist_tasks_done checklist_tasks_added community_chat_added community_chat_joined community_chat_removed
      direct_message_price_changed forum_topic_created forum_topic_edited forum_topic_closed forum_topic_reopened
      general_forum_topic_hidden general_forum_topic_unhidden giveaway_created giveaway_completed
      managed_bot_created paid_message_price_changed paid_messages_waived poll_option_added poll_option_deleted
      suggested_post_approved suggested_post_approval_failed suggested_post_declined suggested_post_paid
      suggested_post_refunded ton_wallet_transfer video_chat_scheduled video_chat_started video_chat_ended
      video_chat_participants_invited web_app_data
    ].freeze
    MAX_TEXT = 1_000
    LIMITS = %w[visitor/minute visitor/day].freeze

    def self.identity_of(user_id) = Digest::SHA256.hexdigest("#{Rails.configuration.x.identity_pepper}#{user_id}")

    def initialize(update, commands: CommandPhrases.current)
      @update = update.is_a?(Hash) ? update : {}
      @commands = commands
      @message = @update["message"] if @update["message"].is_a?(Hash)
    end

    # The hashed identity of the message's sender, for a usable message only.
    def identity = (@identity ||= self.class.identity_of(sender_id) if usable?)

    # Where a reply to this update goes, for a usable message only: the
    # sender's own chat (SR-42), held in memory while the update is read.
    def chat = (Chat.new(identity:, id: sender_id) if usable?)

    # NFR-03: where the line of a given-up update goes and what it says, the
    # fallback in the language a reply would have, for a message the bot
    # answers (a person's, with content; SR-42); nil for any other.
    def given_up
      return unless usable? && content?

      [ chat, FixedReply.fallback(known_language || app_language) ]
    end

    def call(event)
      return Outcome.drop(:dropped) unless usable?
      return Outcome.drop(:service) unless content?

      limited = limit
      return limited if limited

      visitor = Visitor.find_by(channel: "telegram", identity_hash: identity)
      visitor && seen(visitor) ? known(visitor, event) : unknown(event)
    end

    private

    # --- SR-42 ----------------------------------------------------------------

    def usable?
      return false unless @message

      chat, from = @message["chat"], @message["from"]
      chat.is_a?(Hash) && from.is_a?(Hash) && chat["type"] == "private" && from["is_bot"] == false &&
        from["id"].is_a?(Integer) && chat["id"] == from["id"] &&
        @message["message_id"].is_a?(Integer) && @message["message_id"].positive?
    end

    def sender_id = @message.dig("from", "id")

    def content? = CONTENT.any? { |key| @message.key?(key) } || SERVICE.none? { |key| @message.key?(key) }

    def text
      return @text if defined?(@text)

      raw = @message["text"]
      @text = raw.is_a?(String) ? raw.dup.force_encoding(Encoding::UTF_8).scrub.delete("\u0000").strip.presence : nil
    end

    # The language of the person's app, when it is one of the three (FR-19).
    def app_language = RequestLanguage::LOCALES.fetch(@message.dig("from", "language_code").to_s.downcase.split("-").first, I18n.default_locale).to_s

    # --- FR-14 ----------------------------------------------------------------

    def limit
      name = LIMITS.find { |limit| EdgeLimits.over?(limit, identity) } or return nil
      return Outcome.new(name: :limit_silent, status: "processed", reply: nil, language: nil) if EdgeLimits.over?("telegram/limit_line", identity)

      language = known_language || app_language
      Outcome.new(name: :limit, status: "processed", reply: I18n.t("limits.#{EdgeLimits::LIMITS.fetch(name).reply}", locale: language), language:)
    end

    def known_language
      visitor = Visitor.find_by(channel: "telegram", identity_hash: identity) or return nil
      visitor.conversations.current.pick(:language)
    end

    # --- Before the agreement -------------------------------------------------

    def unknown(event)
      language = app_language
      case text && @commands.match(text)
      when :help then reply(:help, FixedReply.help(language), language)
      when :delete then reply(:deleted, FixedReply.telegram_deleted(language), language)
      else text && @commands.agreement?(text) ? agree(event, language) : reply(:ask, FixedReply.ask(language), language)
      end
    end

    # The row, the first conversation, the agreement as its first message and
    # the greeting as its first reply, at once; a second agreement that raced
    # this one finds the message and its reply already stored (NFR-02). The
    # greeting is sent by its status (Telegram::Outbound), so the outcome
    # names nothing to send, and the turn's latency is written when it leaves
    # (NFR-01, Turn#reply_sent!).
    def agree(event, language)
      greeting = FixedReply.greeting(language)
      ApplicationRecord.transaction do
        visitor = Visitor.agree!(identity_hash: identity, chat_id: sender_id)
        conversation = Conversation.current_for!(visitor)
        conversation.update!(language:) unless conversation.messages.exists?
        inbound = Message.record_inbound!(conversation:, external_id: external_id(visitor), body: text, source: "command",
                                          webhook_event: event)
        turn = Turn.for_inbound!(inbound)
        unless Message.exists?(turn_id: turn.id)
          recorder = TraceRecorder.new(turn)
          span = recorder.start_span("balcao.command", started_at: inbound.received_at,
                                                       attributes: { "balcao.command.name" => "agree" })
          Message.record_outbound!(turn:, body: greeting, attendant_characters: 0)
          turn.update!(state: "replied")
          recorder.start_delivery(span)
          span.finish
        end
      end
      reply(:agreed, nil, language)
    end

    # --- After the agreement --------------------------------------------------

    # Marks the row seen (FR-15) and answers whether it is still there: a
    # deletion may commit between its read and now (the person's own delete
    # command, which runs under the conversation's lock, or the nightly
    # purge), and a row is never made here, only by the agreement (review
    # finding C1 of pull request #32). A deletion after this is met by the
    # foreign keys, and the read is tried again.
    def seen(visitor) = Visitor.where(id: visitor.id).update_all(last_seen_at: Time.current) == 1

    def known(visitor, event)
      language = visitor.conversations.current.pick(:language) || app_language
      return reply(:not_text, FixedReply.not_text(language), language) unless text
      return reply(:too_long, FixedReply.too_long(language), language) if text.length > MAX_TEXT

      Intake.new(visitor).receive!(external_id: external_id(visitor), body: text, webhook_event: event)
      Outcome.new(name: :turn, status: "processed", reply: nil, language:)
    end

    # A Telegram message id counts per chat: keyed with its visitor, never with
    # the raw chat id (FR-19, design §6.5).
    def external_id(visitor) = "#{visitor.id}:#{@message["message_id"]}"

    def reply(name, text, language) = Outcome.new(name:, status: "processed", reply: text, language:)
  end
end
