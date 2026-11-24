require "erb"
require "yaml"

# The base configuration is production, deployed only by the owner; the
# destination ensaio is the rehearsal, deployed by bin/deploy (ADR-0011).
# Kamal renders each file with ERB, trim mode "-", against the deploying
# shell's environment, and deep-merges the destination's over the base, a
# list in the destination replacing the base's (Kamal::Configuration, 2.12).
module KamalConfigHelpers
  REHEARSAL_ENV = {
    "ENSAIO_HOST" => "203.0.113.10",
    "ENSAIO_SSH_KEY" => "/rehearsal/key",
    "ENSAIO_SSH_CONFIG" => "/rehearsal/ssh_config"
  }.freeze

  # The rehearsal's two modes (design §8, M3-6b): the fake model unless the
  # rehearsal env file holds ENSAIO_MODEL_ADAPTER=real for the host's life. nil
  # renders the file with the variable unset, whatever the shell running the
  # specs has; a blank value, as .env.example lists it, is the fake model too.
  REHEARSAL_MODELS = [ nil, "", "real" ].freeze

  def load_kamal(file, env = {})
    saved = env.keys.to_h { |name| [ name, ENV[name] ] }
    env.each { |name, value| ENV[name] = value }
    YAML.safe_load(ERB.new(Rails.root.join(file).read, trim_mode: "-").result, aliases: true)
  ensure
    saved&.each { |name, value| ENV[name] = value }
  end

  def base = load_kamal("config/deploy.yml")
  def rehearsal_file(model: nil) = load_kamal("config/deploy.ensaio.yml", REHEARSAL_ENV.merge("ENSAIO_MODEL_ADAPTER" => model))
  def rehearsal(model: nil) = base.deep_merge(rehearsal_file(model:))
  def roles(config) = config.fetch("servers")
end
