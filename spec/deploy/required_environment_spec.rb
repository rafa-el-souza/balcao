require "rails_helper"
require "open3"
require_relative "../../config/required_environment"

# Kamal reads .kamal/secrets with dotenv, which renders a reference to an
# unset variable as an empty string, so a forgotten secret reaches the
# container blank rather than missing. The production process refuses to boot
# on a blank required variable instead of running half-configured.
RSpec.describe "SR-25 production refuses to boot when a required variable is blank" do
  let(:complete) do
    Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "value-of-#{name.downcase}" ] }
  end

  describe Balcao::RequiredEnvironment do
    it "requires the generated secrets the app reads and the settings production cannot guess" do
      expect(described_class::SECRETS).to include("SECRET_KEY_BASE", "POSTGRES_PASSWORD")
      expect(described_class::SETTINGS).to include("APP_HOST", "DB_HOST")
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
