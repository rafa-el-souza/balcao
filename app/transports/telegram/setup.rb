module Telegram
  # The task that sets the bot from the repository (FR-19, ADR-0017), run in
  # the application's container, where the token already is, so no
  # workstation runs repository code for it (SR-38): `bin/rails
  # telegram:setup`. Day 11 brought the webhook; day 12 adds the command menu
  # and the profile, which the task reads first and writes only where they
  # differ.
  #
  # The webhook is set at every run: Telegram never shows the secret back, so
  # a run after the secret's rotation must register the new one (SR-06), and a
  # run with nothing changed leaves the webhook as it was. It ends by printing
  # getWebhookInfo, which the runbook's smoke reads; that answer holds neither
  # the secret nor the token.
  class Setup
    def initialize(client: Client.new, out: $stdout)
      @client = client
      @out = out
    end

    def call
      @client.set_webhook(url: "#{Rails.configuration.x.public_origin}#{Bot::WEBHOOK_PATH}",
                          secret_token: Rails.configuration.x.telegram_webhook_secret,
                          allowed_updates: Bot::ALLOWED_UPDATES, max_connections: Bot::MAX_CONNECTIONS)
      info = @client.webhook_info
      @out.puts(JSON.pretty_generate(info))
      info
    end
  end
end
