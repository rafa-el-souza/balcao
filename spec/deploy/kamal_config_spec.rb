require "rails_helper"
require "erb"
require "yaml"

# The base configuration is production, deployed only by the owner; the
# destination ensaio is the rehearsal, deployed by bin/deploy (ADR-0011).
# Kamal deep-merges the destination file over the base, so the destination
# must replace every production-specific value rather than inherit it.
module KamalConfigHelpers
  REHEARSAL_ENV = {
    "ENSAIO_HOST" => "203.0.113.10",
    "ENSAIO_SSH_KEY" => "/rehearsal/key",
    "ENSAIO_SSH_CONFIG" => "/rehearsal/ssh_config"
  }.freeze

  # Kamal renders each file with ERB against the deploying shell's environment.
  def load_kamal(file, env = {})
    saved = env.keys.to_h { |name| [ name, ENV[name] ] }
    env.each { |name, value| ENV[name] = value }
    YAML.safe_load(ERB.new(Rails.root.join(file).read, trim_mode: "-").result, aliases: true)
  ensure
    saved&.each { |name, value| ENV[name] = value }
  end

  def base = load_kamal("config/deploy.yml")
  def rehearsal_file = load_kamal("config/deploy.ensaio.yml", REHEARSAL_ENV)
  def rehearsal = base.deep_merge(rehearsal_file)
  def roles(config) = config.fetch("servers")
end

RSpec.describe "SR-38 the rehearsal destination inherits nothing production-specific" do
  include KamalConfigHelpers

  it "names production's host only as the operator's SSH alias, in the base file" do
    expect(roles(base).values.map { |role| role.fetch("hosts") }).to all(eq [ "balcao-prod" ])
  end

  it "puts every role of the rehearsal on the rehearsal host and nowhere else" do
    expect(roles(rehearsal).values.map { |role| role.fetch("hosts") }).to all(eq [ KamalConfigHelpers::REHEARSAL_ENV.fetch("ENSAIO_HOST") ])
    expect(rehearsal.to_s).not_to include("balcao-prod")
  end

  it "attaches the database accessory by role, never by a literal host" do
    db = base.dig("accessories", "db")

    expect(db.keys & %w[host hosts tag tags]).to be_empty
    expect(db["role"] || db["roles"]).to be_present
  end

  it "reads the rehearsal host, key and ssh config from the deploying shell, never from the file" do
    raw = Rails.root.join("config/deploy.ensaio.yml").read

    KamalConfigHelpers::REHEARSAL_ENV.each_key { |name| expect(raw).to include(%(ENV.fetch("#{name}"))) }
    expect(rehearsal.dig("ssh", "keys")).to eq [ "/rehearsal/key" ]
    expect(rehearsal.dig("ssh", "config")).to eq [ "/rehearsal/ssh_config" ]
    expect(rehearsal.dig("ssh", "keys_only")).to be true
  end

  it "sets the rehearsal's public name explicitly, the same for the proxy and APP_HOST" do
    [ base, rehearsal ].each do |config|
      expect(config.dig("env", "clear", "APP_HOST")).to eq config.dig("proxy", "host")
    end
    expect(rehearsal_file.dig("proxy", "host")).to be_present
    expect(rehearsal_file.dig("env", "clear", "APP_HOST")).to be_present
  end

  it "keeps the two accounts' local registries on different loopback ports" do
    expect(base.dig("registry", "server")).to eq "localhost:5556"
    expect(rehearsal.dig("registry", "server")).to eq "localhost:5555"
  end

  it "runs no repository hook: no hooks directory and no hooks path" do
    expect(Rails.root.join(".kamal/hooks")).not_to exist
    [ base, rehearsal ].each { |config| expect(config).not_to have_key("hooks_path") }
  end
end

RSpec.describe "SR-24 the containers Kamal runs" do
  include KamalConfigHelpers

  it "connects as the non-root deploy user without forwarding the workstation's SSH agent" do
    [ base, rehearsal ].each do |config|
      expect(config.dig("ssh", "user")).to eq "deploy"
      expect(config.dig("ssh", "forward_agent")).to be false
    end
  end

  it "runs every application role on a read-only root filesystem with writable tmpfs mounts" do
    roles(rehearsal).each_value do |role|
      expect(role.dig("options", "read-only")).to be true
      expect(Array(role.dig("options", "tmpfs"))).to include("/tmp")
    end
  end

  # Docker mounts a tmpfs owned by root with mode 755, except at /tmp, so the
  # image's non-root user could not write Rails' tmp directory (found by the
  # local smoke run of the image on 2026-11-09).
  it "gives the image's user (uid 1000) its own Rails tmp directory" do
    roles(rehearsal).each_value do |role|
      rails_tmp = Array(role.dig("options", "tmpfs")).find { |mount| mount.start_with?("/rails/tmp") }

      expect(rails_tmp).to match(/\A\/rails\/tmp:(?=.*\buid=1000\b)(?=.*\bgid=1000\b)/)
    end
  end

  it "keeps the database on the Docker network, publishing no port" do
    expect(base.dig("accessories", "db")).not_to have_key("port")
  end

  it "keeps Postgres at the major version CI tests against, on its version-18 data path" do
    db = base.dig("accessories", "db")
    ci_image = YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
      .dig("jobs", "ruby_test", "services", "postgres", "image")

    expect(db.fetch("image")).to match(/\Apostgres:18\.\d+@sha256:[0-9a-f]{64}\z/)
    expect(ci_image).to start_with("postgres:18")
    expect(db.fetch("directories")).to eq [ "data:/var/lib/postgresql" ]
  end

  it "runs Solid Queue in its own job container, not inside Puma" do
    expect(roles(base).dig("job", "cmd")).to eq "bin/jobs"
    expect(base.dig("env", "clear")).not_to have_key("SOLID_QUEUE_IN_PUMA")
  end
end
