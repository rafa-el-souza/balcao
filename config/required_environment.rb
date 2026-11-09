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
    # Generated per destination by bin/secrets-example, or held by an outside console.
    SECRETS = %w[SECRET_KEY_BASE POSTGRES_PASSWORD].freeze
    # Clear values set in config/deploy.yml and config/deploy.ensaio.yml.
    SETTINGS = %w[APP_HOST DB_HOST].freeze
    NAMES = (SETTINGS + SECRETS).freeze

    class Missing < StandardError; end

    def self.missing(env)
      NAMES.select { |name| env[name].to_s.strip.empty? }
    end

    def self.verify!(env)
      names = missing(env)
      return if names.empty?

      raise Missing, "Refusing to boot: #{names.join(", ")} #{names.one? ? "is" : "are"} blank. " \
                     "Set #{names.one? ? "it" : "them"} in the destination's env file (threat model SR-25)."
    end
  end
end
