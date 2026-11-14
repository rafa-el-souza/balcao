# The production process refuses to boot when a required variable is blank
# (threat model SR-25). Kamal reads .kamal/secrets with dotenv, which renders
# a reference to an unset variable as an empty string, so a forgotten secret
# reaches the container blank rather than missing. Required by
# config/environments/production.rb before anything reads the environment.
#
# A slice that starts reading a new secret adds it to SECRETS, to both
# .kamal/secrets files, to env.secret in config/deploy.yml and to
# .env.example; spec/deploy/secrets_spec.rb keeps the five in step.
module Balcao
  module RequiredEnvironment
    # Generated per destination by bin/secrets-example, or held by an outside
    # console. The encryption keys guard what visitors send (threat model
    # SR-41) and the pepper hashes a Telegram user id (SR-10); the bot's token
    # and the webhook's secret are the Telegram channel's (FR-19, SR-06).
    SECRETS = %w[
      SECRET_KEY_BASE POSTGRES_PASSWORD ANTHROPIC_API_KEY
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT IDENTITY_PEPPER TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET
    ].freeze
    # The secrets an outside console holds, which bin/secrets-example never
    # generates: the model key comes from the provider's console and the bot's
    # token from BotFather (design §8).
    HELD = %w[ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN].freeze
    # Clear values set in config/deploy.yml and config/deploy.ensaio.yml.
    SETTINGS = %w[APP_HOST DB_HOST MODEL_ADAPTER BUDGET_CAP_USD].freeze
    NAMES = (SETTINGS + SECRETS).freeze
    # The model adapters production can run. The fake one, for rehearsal hosts
    # with recorded replies, arrives at M3 (design §8, §10).
    MODEL_ADAPTERS = %w[real].freeze
    # The month's budget cap in US dollars (FR-14): a positive decimal.
    CAP = /\A\d+(?:\.\d+)?\z/
    # What setWebhook takes as a secret token: 1 to 256 of A-Z, a-z, 0-9, _
    # and -. A value Telegram would refuse stops the boot, not the webhook's
    # registration.
    WEBHOOK_SECRET = /\A[A-Za-z0-9_-]{1,256}\z/
    # BotFather's token: the bot's number, a colon and the key, in the shape
    # the JSON log writes as [FILTERED] (Balcao::JsonLogFormatter::BOT_TOKEN,
    # threat model SR-30): five digits or more and a key of thirty characters
    # or more, so a token that boots is one no log line can carry (review
    # findings C3 and L5 of pull request #32).
    BOT_TOKEN = /\A\d{5,}:[A-Za-z0-9_-]{30,}\z/

    class Missing < StandardError; end

    def self.missing(env)
      NAMES.select { |name| env[name].to_s.strip.empty? }
    end

    def self.verify!(env)
      names = missing(env)
      unless names.empty?
        raise Missing, "Refusing to boot: #{names.join(", ")} #{names.one? ? "is" : "are"} blank. " \
                       "Set #{names.one? ? "it" : "them"} in the destination's env file (threat model SR-25)."
      end
      unless MODEL_ADAPTERS.include?(env["MODEL_ADAPTER"])
        raise Missing, "Refusing to boot: MODEL_ADAPTER must be #{MODEL_ADAPTERS.join(" or ")} " \
                       "(design §8, threat model SR-25)."
      end
      unless env["BUDGET_CAP_USD"].match?(CAP) && BigDecimal(env["BUDGET_CAP_USD"]).positive?
        raise Missing, "Refusing to boot: BUDGET_CAP_USD must be a positive number of US dollars " \
                       "(FR-14, threat model SR-25)."
      end
      unless env["TELEGRAM_WEBHOOK_SECRET"].match?(WEBHOOK_SECRET)
        raise Missing, "Refusing to boot: TELEGRAM_WEBHOOK_SECRET must be 1 to 256 of A-Z, a-z, 0-9, _ and - " \
                       "(FR-19, threat model SR-06)."
      end
      return if env["TELEGRAM_BOT_TOKEN"].match?(BOT_TOKEN)

      raise Missing, "Refusing to boot: TELEGRAM_BOT_TOKEN must be BotFather's token, a number, a colon and the key " \
                     "(FR-19, threat model SR-25)."
    end
  end
end
