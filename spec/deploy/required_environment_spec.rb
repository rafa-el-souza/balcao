require "rails_helper"
require "open3"
require_relative "../../config/required_environment"

# Kamal reads .kamal/secrets with dotenv, which renders a reference to an
# unset variable as an empty string, so a forgotten secret reaches the
# container blank rather than missing. The production process refuses to boot
# on a blank required variable instead of running half-configured.
RSpec.describe "SR-25 production refuses to boot when a required variable is blank" do
  let(:complete) { ProductionEnv.complete }

  describe Balcao::RequiredEnvironment do
    it "requires the generated secrets the app reads and the settings production cannot guess" do
      expect(described_class::SECRETS).to include("SECRET_KEY_BASE", "APP_DATABASE_PASSWORD")
      expect(described_class::SETTINGS).to include("APP_HOST", "DB_HOST")
    end

    # The app connects as its own role, with its rows' privileges alone; the
    # database owner's password is the entrypoint's, for the migrations and
    # the role's grants before the server starts (M3-4; #4's review).
    it "requires the database owner's password only of the entrypoint's step that runs as the owner" do
      expect(described_class::SECRETS).not_to include("POSTGRES_PASSWORD")
      expect { described_class.verify!(complete.except("POSTGRES_PASSWORD")) }.not_to raise_error
      expect { described_class.verify!(complete.except("POSTGRES_PASSWORD").merge("DATABASE_OWNER" => "1")) }
        .to raise_error(described_class::Missing, /POSTGRES_PASSWORD/)
      expect { described_class.verify!(complete.merge("POSTGRES_PASSWORD" => "value", "DATABASE_OWNER" => "1")) }.not_to raise_error
    end

    # The first deploy that runs turns (design §6.4, §8): the MVP host calls
    # the real model with the spend-limited dev/eval key.
    it "requires the model key, held by the model provider's console, and the model adapter" do
      expect(described_class::SECRETS).to include("ANTHROPIC_API_KEY")
      expect(described_class::HELD).to include("ANTHROPIC_API_KEY")
      expect(described_class::SETTINGS).to include("MODEL_ADAPTER")
    end

    # PR-18: what visitors send is encrypted at rest (SR-41) and a Telegram
    # identity is hashed with the pepper (SR-10); the bot's token comes from
    # BotFather and the webhook's secret is generated (FR-19, SR-06).
    it "requires the encryption keys, the pepper, the bot's token held by BotFather and the webhook's secret" do
      expect(described_class::SECRETS).to include(
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "IDENTITY_PEPPER", "TELEGRAM_BOT_TOKEN", "TELEGRAM_WEBHOOK_SECRET"
      )
      expect(described_class::HELD).to include("ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN")
    end

    # M2's first slice (SR-39, ADR-0012): the Turnstile widget's secret is held
    # by Cloudflare's dashboard, never generated.
    it "requires Turnstile's secret, held by Cloudflare's dashboard" do
      expect(described_class::SECRETS).to include("TURNSTILE_SECRET_KEY")
      expect(described_class::HELD).to contain_exactly("ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN", "TURNSTILE_SECRET_KEY")
    end

    # Cloudflare's published test secrets accept the test site keys' dummy
    # token, which anyone can send: on the demo's public name one would let a
    # script mint identities past the check while refusing every visitor's
    # real token. The rehearsal hosts, on another name from M3, hold them.
    it "refuses a published test secret on the public name, never naming the value" do
      public_name = ProductionEnv.public_name
      %w[1x0000000000000000000000000000000AA 2x0000000000000000000000000000000AA 3x0000000000000000000000000000000AA].each do |value|
        expect { described_class.verify!(public_name.merge("TURNSTILE_SECRET_KEY" => value)) }
          .to raise_error(described_class::Missing, /TURNSTILE_SECRET_KEY.*SR-39/) { |error| expect(error.message).not_to include(value) }
        expect { described_class.verify!(complete.merge("APP_HOST" => "ensaio.rafasouza.dev.br", "TURNSTILE_SECRET_KEY" => value)) }
          .not_to raise_error
      end
      expect { described_class.verify!(public_name.merge("TURNSTILE_SECRET_KEY" => "0x4AAAAAAAvalue-of-a-real-secret")) }.not_to raise_error
      expect(Turnstile::TEST_SECRETS).to all(match(described_class::TURNSTILE_TEST_SECRET))
    end

    # Telegram takes a secret token of 1 to 256 characters among A-Z, a-z,
    # 0-9, _ and - (setWebhook), and BotFather's tokens are a number, a colon
    # and the key: a pasted value with a space or a quote stops the boot
    # rather than the webhook's registration.
    it "refuses a webhook secret Telegram would refuse and a bot token not of BotFather's shape, never naming a value" do
      [ "with space", "quote\"d", "a:b", "x" * 257 ].each do |value|
        expect { described_class.verify!(complete.merge("TELEGRAM_WEBHOOK_SECRET" => value)) }
          .to raise_error(described_class::Missing, /TELEGRAM_WEBHOOK_SECRET.*SR-06/) { |error| expect(error.message).not_to include(value) }
      end
      [ "AAkey-without-number", "123456789", "123456789: AAkey", "'123456789:AAkey'" ].each do |value|
        expect { described_class.verify!(complete.merge("TELEGRAM_BOT_TOKEN" => value)) }
          .to raise_error(described_class::Missing, /TELEGRAM_BOT_TOKEN.*SR-25/) { |error| expect(error.message).not_to include(value) }
      end
      expect { described_class.verify!(complete.merge("TELEGRAM_WEBHOOK_SECRET" => "A-z_09" * 42)) }.not_to raise_error
    end

    # Review findings C3 and L5 of pull request #32: the JSON log writes a
    # token of five digits or more and a key of thirty characters or more as
    # [FILTERED] (SR-30), so the boot check takes no other: a token that
    # boots is one no log line can carry.
    it "takes only a bot token of the shape the log masks" do
      require_relative "../../lib/logging/json_log_formatter"

      [ "123456789:AAshort-key_29-characters-x", "1234:AA#{"k" * 33}" ].each do |value|
        expect { described_class.verify!(complete.merge("TELEGRAM_BOT_TOKEN" => value)) }
          .to raise_error(described_class::Missing, /TELEGRAM_BOT_TOKEN/)
      end
      shortest = "12345:AA#{"k" * 28}"
      expect { described_class.verify!(complete.merge("TELEGRAM_BOT_TOKEN" => shortest)) }.not_to raise_error
      expect("bot#{shortest}/sendMessage".gsub(Balcao::JsonLogFormatter::BOT_TOKEN, "[FILTERED]")).to eq("bot[FILTERED]/sendMessage")
    end

    it "refuses a model adapter other than the real one, naming the variable and never its value" do
      expect { described_class.verify!(complete.merge("MODEL_ADAPTER" => "fake")) }
        .to raise_error(described_class::Missing) { |error|
          expect(error.message).to include("MODEL_ADAPTER", "real", "SR-25")
          expect(error.message).not_to include("value-of")
        }
    end

    # FR-14, ADR-0003: each destination states its month's cap, which a typo
    # must not turn into no cap at all.
    it "requires the month's budget cap as a positive decimal, naming the variable and never its value" do
      expect(described_class::SETTINGS).to include("BUDGET_CAP_USD")

      [ "abc", "0", "-5", "10,5", "1e3" ].each do |value|
        expect { described_class.verify!(complete.merge("BUDGET_CAP_USD" => value)) }
          .to raise_error(described_class::Missing, /BUDGET_CAP_USD.*FR-14/) { |error| expect(error.message).not_to include(value) }
      end
      expect { described_class.verify!(complete.merge("BUDGET_CAP_USD" => "10.50")) }.not_to raise_error
    end

    # FR-17, NFR-04 (M3-2; the owner, 2026-11-21, "Dois heartbeats"): the
    # canary and the Telegram delivery watch each tell a heartbeat of the
    # external monitor. On the public name both are required, or a failure
    # would reach no one; a rehearsal host has none (design §8). Each URL
    # carries the monitor's token, so it is a secret, never named.
    it "requires the two monitor URLs on the public name, as https URLs, never naming a value" do
      expect(described_class::MONITORS).to eq(%w[MONITOR_URL TELEGRAM_MONITOR_URL])
      public_name = ProductionEnv.public_name
      described_class::MONITORS.each do |name|
        [ "", "  ", "http://monitor.example/api/v1/heartbeat/secret-token", "monitor.example/secret-token",
          "https://monitor.example/api/v1/heartbeat/secret token", "https://monitor.example/hb/secret-token?src=x",
          "https://monitor.example/hb/secret-token#f", "https://monitor.example/", "https://monitor.example" ].each do |value|
          expect { described_class.verify!(public_name.merge(name => value)) }
            .to raise_error(described_class::Missing, /#{name}.*FR-17/) { |error| expect(error.message).not_to include("secret-token") }
        end
      end
      expect { described_class.verify!(public_name) }.not_to raise_error
    end

    # H5 of #64's review: a rehearsal host that told the demo's heartbeats
    # would close the incidents of the demo's failures, and hide its
    # silence, so off the public name the URLs stay blank.
    it "lets a rehearsal host go only without monitor URLs, never naming a value" do
      rehearsal = complete.merge("APP_HOST" => "ensaio.rafasouza.dev.br")

      expect { described_class.verify!(rehearsal.merge("MONITOR_URL" => "", "TELEGRAM_MONITOR_URL" => " ")) }.not_to raise_error
      described_class::MONITORS.each do |name|
        expect { described_class.verify!(rehearsal.merge("MONITOR_URL" => "", "TELEGRAM_MONITOR_URL" => "", name => "https://monitor.example/hb/secret-token")) }
          .to raise_error(described_class::Missing, /#{name}.*off the public name.*FR-17/) { |error| expect(error.message).not_to include("secret-token") }
      end
    end

    # C3 of #64's review: one heartbeat for both, and the canary's next pass
    # closes the watch's incident, which two were chosen to prevent.
    it "refuses the same URL for both heartbeats on the public name, never naming it" do
      url = "https://monitor.example/api/v1/heartbeat/secret-token"
      public_name = ProductionEnv.public_name

      expect { described_class.verify!(public_name.merge("MONITOR_URL" => url, "TELEGRAM_MONITOR_URL" => " #{url}/ ")) }
        .to raise_error(described_class::Missing, /MONITOR_URL and TELEGRAM_MONITOR_URL.*FR-17/) { |error| expect(error.message).not_to include("secret-token") }
    end

    it "accepts an environment where every required variable has a value" do
      expect { described_class.verify!(complete) }.not_to raise_error
    end

    it "names every unset, empty or whitespace-only variable, never a value" do
      env = complete.merge("SECRET_KEY_BASE" => "", "APP_DATABASE_PASSWORD" => "  \n").except("APP_HOST")

      expect { described_class.verify!(env) }.to raise_error(described_class::Missing) { |error|
        expect(error.message).to include("SECRET_KEY_BASE", "APP_DATABASE_PASSWORD", "APP_HOST", "SR-25")
        expect(error.message).not_to include("DB_HOST", "value-of")
      }
    end
  end

  describe "the production boot" do
    def boot(env)
      # No DATABASE_URL from the test job: the boot must not depend on it.
      Open3.capture3(env.merge("RAILS_ENV" => "production", "DATABASE_URL" => nil),
                     "bin/rails", "runner", "puts :booted", chdir: Rails.root.to_s)
    end

    it "stops with the variable's name when a secret renders blank" do
      out, err, status = boot(complete.merge("SECRET_KEY_BASE" => ""))

      expect(status).not_to be_success
      expect(out).not_to include("booted")
      expect(err).to include("SECRET_KEY_BASE", "SR-25")
    end

    it "boots when every required variable has a value" do
      out, err, status = boot(complete)

      expect(status).to be_success, err
      expect(out).to include("booted")
    end

    # The review of pull request #53 (its Rails verifier's V4): the boot
    # check reads a secret without the spaces around it, so the app must too,
    # or a pasted line break boots and every new visitor is refused.
    it "reads Turnstile's secret as the boot check does, without the spaces or line break a paste left around it" do
      env = complete.merge("RAILS_ENV" => "production", "DATABASE_URL" => nil,
                           "TURNSTILE_SECRET_KEY" => " 0x4AAAAAAAvalue-of-a-real-secret\n")
      out, err, status = Open3.capture3(env, "bin/rails", "runner", "p Rails.configuration.x.turnstile_secret_key",
                                        chdir: Rails.root.to_s)

      expect(status).to be_success, err
      expect(out.lines.last).to eq "\"0x4AAAAAAAvalue-of-a-real-secret\"\n"
    end

    # The fix review of pull request #53, given to M3-6 by the owner on
    # 2026-11-20: the host, the three encryption keys and the pepper were read
    # with the spaces or line break a paste left, which the boot check reads
    # past. A host with a line break boots and answers no request; a key or
    # the pepper with one boots, and the day the paste is mended every stored
    # row stops decrypting and every Telegram identity changes. The secret
    # key base, which signs the web visitor's cookie, breaks every web
    # identity the same way (M3-6).
    it "reads the host, the encryption keys, the pepper and the secret key base without a paste's spaces or line break" do
      names = %w[APP_HOST ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
                 ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT IDENTITY_PEPPER SECRET_KEY_BASE]
      clean = names.to_h { |name| [ name, name == "APP_HOST" ? "demo.example" : "value-of-#{name.downcase}" ] }
      env = complete.merge(clean.transform_values { |value| " #{value}\n" })
                    .merge("RAILS_ENV" => "production", "DATABASE_URL" => nil)
      read = <<~RUBY
        encryption = Rails.application.config.active_record.encryption
        puts "READ " + JSON.generate(
          "APP_HOST" => Rails.application.config.hosts.first,
          "origin" => Rails.configuration.x.public_origin,
          "mailer" => Rails.application.config.action_mailer.default_url_options[:host],
          "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => Array(encryption.primary_key).first,
          "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => Array(encryption.deterministic_key).first,
          "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => encryption.key_derivation_salt,
          "IDENTITY_PEPPER" => Rails.configuration.x.identity_pepper,
          "SECRET_KEY_BASE" => Rails.application.secret_key_base)
      RUBY
      out, err, status = Open3.capture3(env, "bin/rails", "runner", read, chdir: Rails.root.to_s)

      expect(status).to be_success, err
      expect(JSON.parse(out.lines.grep(/\AREAD /).last.delete_prefix("READ ")))
        .to eq(clean.merge("origin" => "https://demo.example", "mailer" => "demo.example"))
    end
  end
end
