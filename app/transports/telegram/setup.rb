module Telegram
  # The task that sets the bot from the repository (FR-19, ADR-0017), run in
  # the application's container, where the token already is, so no
  # workstation runs repository code for it (SR-38): `bin/rails
  # telegram:setup`, the runbook's step.
  #
  # - The webhook is set at every run: Telegram never shows the secret back,
  #   so a run after the secret's rotation must register the new one (SR-06),
  #   and a run with nothing changed leaves the webhook as it was. A webhook
  #   Telegram refuses stops the task.
  # - The command menu of private chats and the profile (the name, the
  #   description an empty chat shows before Start, the short description of
  #   the profile page and of a shared link) are written from the locale
  #   files and config/commands.yml, for the empty language code in
  #   Portuguese, FR-02's default, which covers Portuguese and every language
  #   without its own, and for English and Spanish. Each is read first and
  #   written only where it differs, so a second run writes nothing and stays
  #   clear of Telegram's limits on these methods; one Telegram refuses (a
  #   429 on setMyName is common) is printed, and the others go on.
  # - It ends by printing getWebhookInfo, which the runbook's smoke reads;
  #   that answer holds neither the secret nor the token, and neither does
  #   any line here. The rake task fails when a setting was not written.
  #
  # The bot's photo, its privacy policy URL and the switch that keeps it out
  # of groups stay in BotFather (the runbook's checklist).
  class Setup
    SCOPE = { type: "all_private_chats" }.freeze
    # Telegram's language code, and the locale its texts come from.
    LANGUAGES = { "" => "pt-BR", "en" => "en", "es" => "es" }.freeze
    # The menu's commands, in order, the delete command last.
    MENU = %i[reset trace help delete].freeze
    PROFILE = %i[name description short_description].freeze

    Result = Data.define(:info, :failed)

    def initialize(client: Client.new, out: $stdout)
      @client = client
      @out = out
    end

    def call
      @client.set_webhook(url: "#{Rails.configuration.x.public_origin}#{Bot::WEBHOOK_PATH}",
                          secret_token: Rails.configuration.x.telegram_webhook_secret,
                          allowed_updates: Bot::ALLOWED_UPDATES, max_connections: Bot::MAX_CONNECTIONS)
      @out.puts("webhook: set")
      failed = LANGUAGES.flat_map { |code, locale| [ commands(code, locale), *PROFILE.map { |field| profile(field, code, locale) } ] }.compact
      info = @client.webhook_info
      @out.puts("getWebhookInfo:", JSON.pretty_generate(info))
      Result.new(info:, failed:)
    end

    # The menu of a language: each command's first phrase with a slash in
    # config/commands.yml, and its description in the locale files.
    def self.menu(locale)
      language = AgentRunner::LANGUAGES.key(locale)
      MENU.map do |name|
        phrase = CommandPhrases.current.phrases(name).fetch(language).find { |text| text.start_with?("/") }
        { command: phrase.delete_prefix("/"), description: I18n.t("telegram.menu.#{name}", locale:) }
      end
    end

    # A profile text of a language, with the store's name, the agreement's
    # phrase and the privacy page in it where it names them.
    def self.profile(field, locale)
      I18n.t("telegram.profile.#{field}", locale:, store: FixedReply.store_name, privacy: FixedReply.privacy_url,
                                          agree: CommandPhrases.current.agreement(AgentRunner::LANGUAGES.key(locale)))
    end

    private

    # Each answers nil when the bot holds the text, or after writing it, and
    # the setting's name when Telegram refused it.
    def commands(code, locale)
      wanted = self.class.menu(locale)
      write("commands", code) do
        next false if @client.my_commands(scope: SCOPE, language_code: code) == wanted.map(&:stringify_keys)

        @client.set_my_commands(commands: wanted, scope: SCOPE, language_code: code)
      end
    end

    def profile(field, code, locale)
      wanted = self.class.profile(field, locale)
      write(field.to_s, code) do
        next false if @client.public_send(:"my_#{field}", language_code: code) == wanted

        @client.public_send(:"set_my_#{field}", field => wanted, language_code: code)
      end
    end

    def write(what, code)
      name = "#{what} #{code.presence || "(default)"}"
      @out.puts("#{name}: #{yield ? "written" : "unchanged"}")
      nil
    rescue Client::Error => e
      @out.puts("#{name}: not written, #{e.message}")
      name
    end
  end
end
