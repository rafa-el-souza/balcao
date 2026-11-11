require "rails_helper"
require "open3"
require "yaml"
require_relative "../../config/required_environment"

# Every runtime secret is an environment variable that Kamal injects from the
# deploying account's env file. The tracked secrets files carry references
# only, so the deploy-path review sees them (SR-38) and no value can land in
# the repository; the boot check, the Kamal configuration, the secrets files
# and .env.example name the same variables.
RSpec.describe "SR-25 secrets are references in the repository and values in the env file" do
  secrets_files = %w[.kamal/secrets .kamal/secrets.ensaio].freeze
  reference = /\A(?<name>[A-Z][A-Z0-9_]*)=\$(?:\k<name>|\{\k<name>\})\z/

  def lines_of(path)
    Rails.root.join(path).read.lines(chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }
  end

  def deploy_config = YAML.safe_load(Rails.root.join("config/deploy.yml").read, aliases: true)

  secrets_files.each do |path|
    it "#{path} holds only NAME=$NAME references, one per required secret" do
      lines = lines_of(path)

      expect(lines).to all(match(reference))
      expect(lines.map { |line| line[reference, :name] }).to match_array(Balcao::RequiredEnvironment::SECRETS)
    end
  end

  it "has no secrets file Kamal would read that is not tracked as references" do
    expect(Rails.root.glob(".kamal/secrets*").map { |path| path.relative_path_from(Rails.root).to_s })
      .to match_array(secrets_files)
  end

  it "injects exactly the required secrets into the app and the database password into the accessory" do
    expect(deploy_config.dig("env", "secret")).to match_array(Balcao::RequiredEnvironment::SECRETS)
    expect(deploy_config.dig("accessories", "db", "env", "secret")).to eq [ "POSTGRES_PASSWORD" ]
  end

  it "lists every required variable in .env.example without a value" do
    entries = lines_of(".env.example").to_h { |line| line.split("=", 2) }

    expect(entries.keys).to include(*Balcao::RequiredEnvironment::NAMES)
    expect(entries.values).to all(be_empty)
  end

  describe "bin/secrets-example" do
    def run(env = {})
      cleared = (Balcao::RequiredEnvironment::NAMES + generated_names).to_h { |name| [ name, nil ] }
      out, err, status = Open3.capture3(cleared.merge(env), Rails.root.join("bin/secrets-example").to_s)
      expect(status).to be_success, err
      out.lines(chomp: true).reject { |line| line.start_with?("#") }.to_h { |line| line.split("=", 2) }
    end

    let(:generated_names) do
      %w[SECRET_KEY_BASE POSTGRES_PASSWORD
         ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
         ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT IDENTITY_PEPPER]
    end

    it "prints a fresh value for every generated secret, safe to source from a shell and to read with dotenv" do
      first = run
      second = run

      expect(first.keys).to match_array(generated_names)
      expect(first.values).to all(match(/\A[A-Za-z0-9]{32,}\z/))
      first.each_key { |name| expect(second[name]).not_to eq(first[name]) }
    end

    it "generates every required secret that is not held by an outside console" do
      expect(generated_names).to include(*(Balcao::RequiredEnvironment::SECRETS - Balcao::RequiredEnvironment::HELD))
      expect(generated_names).not_to include(*Balcao::RequiredEnvironment::HELD)
    end

    it "skips a secret already set, so appending its output never rotates a key in use" do
      printed = run("SECRET_KEY_BASE" => "already-set", "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "already-set")

      expect(printed.keys).to match_array(generated_names - %w[SECRET_KEY_BASE ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY])
    end

    it "lists its names in .env.example" do
      expect(lines_of(".env.example").map { |line| line.split("=", 2).first }).to include(*generated_names)
    end
  end
end
