require "rails_helper"
require "open3"
require_relative "../../config/required_environment"

# Kamal reads .kamal/secrets with dotenv, which renders a reference to an
# unset variable as an empty string, so a forgotten secret reaches the
# container blank rather than missing. The production process refuses to boot
# on a blank required variable instead of running half-configured.
RSpec.describe "SR-25 production refuses to boot when a required variable is blank" do
  let(:complete) do
    Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "value-of-#{name.downcase}" ] }.merge("MODEL_ADAPTER" => "real")
  end

  describe Balcao::RequiredEnvironment do
    it "requires the generated secrets the app reads and the settings production cannot guess" do
      expect(described_class::SECRETS).to include("SECRET_KEY_BASE", "POSTGRES_PASSWORD")
      expect(described_class::SETTINGS).to include("APP_HOST", "DB_HOST")
    end

    # The first deploy that runs turns (design §6.4, §8): the MVP host calls
    # the real model with the spend-limited dev/eval key.
    it "requires the model key, held by the model provider's console, and the model adapter" do
      expect(described_class::SECRETS).to include("ANTHROPIC_API_KEY")
      expect(described_class::HELD).to eq [ "ANTHROPIC_API_KEY" ]
      expect(described_class::SETTINGS).to include("MODEL_ADAPTER")
    end

    it "refuses a model adapter other than the real one, naming the variable and never its value" do
      expect { described_class.verify!(complete.merge("MODEL_ADAPTER" => "fake")) }
        .to raise_error(described_class::Missing) { |error|
          expect(error.message).to include("MODEL_ADAPTER", "real", "SR-25")
          expect(error.message).not_to include("value-of")
        }
    end

    it "accepts an environment where every required variable has a value" do
      expect { described_class.verify!(complete) }.not_to raise_error
    end

    it "names every unset, empty or whitespace-only variable, never a value" do
      env = complete.merge("SECRET_KEY_BASE" => "", "POSTGRES_PASSWORD" => "  \n").except("APP_HOST")

      expect { described_class.verify!(env) }.to raise_error(described_class::Missing) { |error|
        expect(error.message).to include("SECRET_KEY_BASE", "POSTGRES_PASSWORD", "APP_HOST", "SR-25")
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
  end
end
