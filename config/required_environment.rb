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
    # and the webhook's secret are the Telegram channel's (FR-19, SR-06); the
    # Turnstile widget's secret checks a new web visitor's token (SR-39).
    SECRETS = %w[
      SECRET_KEY_BASE POSTGRES_PASSWORD ANTHROPIC_API_KEY
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT IDENTITY_PEPPER TELEGRAM_BOT_TOKEN TELEGRAM_WEBHOOK_SECRET
      TURNSTILE_SECRET_KEY
    ].freeze
    # The secrets an outside console holds, which bin/secrets-example never
    # generates: the model key comes from the provider's console, the bot's
    # token from BotFather and Turnstile's secret from Cloudflare's dashboard
    # (design §8).
    HELD = %w[ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN TURNSTILE_SECRET_KEY].freeze
    # The external monitor's heartbeat URLs (FR-17, NFR-04; the owner,
    # 2026-11-21, "Dois heartbeats"): the canary's and the Telegram delivery
    # watch's, held by the monitor's console. Each carries the monitor's
    # token, so each is a secret. On the public name both are required, or
    # a failure would reach no one, each an https URL with a path and no
    # query or fragment (review finding H4 of pull request #64), and not the
    # same one (C3). Off it they stay blank: a rehearsal host has no monitor
    # (design §8), and one that told the demo's heartbeats would close the
    # demo's incidents and hide its silence (H5).
    MONITORS = %w[MONITOR_URL TELEGRAM_MONITOR_URL].freeze
    # Every secret Kamal injects: the two secrets files and env.secret in
    # config/deploy.yml name these.
    INJECTED = (SECRETS + MONITORS).freeze
    # An https URL with a host and a path, and no space, query or fragment.
    MONITOR_URL = %r{\Ahttps://[^\s/?#]+/[^\s?#]+\z}
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
    # The demo's public name, and Cloudflare's published Turnstile test
    # secrets (Turnstile::TEST_SECRETS), which accept the test site keys'
    # dummy token that anyone can send: on the public name one would let a
    # script mint visitor identities past the check (SR-39). The rehearsal
    # hosts hold one, on their own name from M3 (ADR-0012).
    PUBLIC_HOST = "balcao.rafasouza.dev.br".freeze
    TURNSTILE_TEST_SECRET = /\A[123]x0{31}AA\z/

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
      if env["APP_HOST"].strip.casecmp?(PUBLIC_HOST) && env["TURNSTILE_SECRET_KEY"].strip.match?(TURNSTILE_TEST_SECRET)
        raise Missing, "Refusing to boot: TURNSTILE_SECRET_KEY is one of Cloudflare's test secrets on the public name " \
                       "(threat model SR-39, ADR-0012)."
      end
      unless env["TELEGRAM_BOT_TOKEN"].match?(BOT_TOKEN)
        raise Missing, "Refusing to boot: TELEGRAM_BOT_TOKEN must be BotFather's token, a number, a colon and the key " \
                       "(FR-19, threat model SR-25)."
      end
      verify_monitors!(env)
    end

    def self.verify_monitors!(env)
      public_name = env["APP_HOST"].strip.casecmp?(PUBLIC_HOST)
      values = MONITORS.to_h { |name| [ name, env[name].to_s.strip ] }
      values.each do |name, value|
        if !public_name
          next if value.empty?

          raise Missing, "Refusing to boot: #{name} is set off the public name, where a rehearsal host would tell the demo's " \
                         "heartbeats (FR-17, design §8, threat model SR-25)."
        elsif value.empty?
          raise Missing, "Refusing to boot: #{name} is blank on the public name, where the canary's and the Telegram watch's " \
                         "failures go to the external monitor (FR-17, NFR-04, threat model SR-25)."
        elsif !value.match?(MONITOR_URL)
          raise Missing, "Refusing to boot: #{name} must be the monitor's https URL, with a path and no query or fragment " \
                         "(FR-17, threat model SR-25)."
        end
      end
      return unless public_name && values.values.map { |value| value.chomp("/") }.uniq.one?

      raise Missing, "Refusing to boot: MONITOR_URL and TELEGRAM_MONITOR_URL are the same heartbeat; the canary and the " \
                     "Telegram watch need one each (FR-17, threat model SR-25)."
    end
  end
end
