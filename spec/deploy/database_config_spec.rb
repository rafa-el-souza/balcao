require "rails_helper"
require "rake"

# The app connects to its four production databases as its own role, which
# holds its rows' privileges alone, not as the image's superuser (M3-4; #4's
# review): the database's owner, the superuser the Postgres image makes from
# POSTGRES_USER, is the entrypoint's alone, for the migrations and the role's
# grants (DATABASE_OWNER=1, bin/docker-entrypoint).
RSpec.describe "SR-24 SR-25 the app's database role in production" do
  def production(env)
    saved = env.keys.to_h { |name| [ name, ENV[name] ] }
    env.each { |name, value| ENV[name] = value }
    ActiveRecord::DatabaseConfigurations.new(Rails.application.config.database_configuration)
                                        .configs_for(env_name: "production").to_h { |config| [ config.name, config.configuration_hash ] }
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  let(:passwords) { { "POSTGRES_PASSWORD" => "the-owner's", "APP_DATABASE_PASSWORD" => "the-app's" } }

  it "connects every database as the app's role, with its own password" do
    configs = production(passwords.merge("DATABASE_OWNER" => nil))

    expect(configs.keys).to contain_exactly("primary", "cache", "queue", "cable")
    configs.each_value { |config| expect(config).to include(username: DatabaseRole::NAME, password: "the-app's") }
  end

  it "connects as the owner, with the owner's password, only for the entrypoint's step" do
    production(passwords.merge("DATABASE_OWNER" => "1")).each_value do |config|
      expect(config).to include(username: DatabaseRole::OWNER, password: "the-owner's")
    end
  end

  describe "the entrypoint's task, db:app_role" do
    before do
      Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "db:app_role" }
      allow(DatabaseRole).to receive(:grant!)
    end

    around do |example|
      saved = ENV.values_at("DATABASE_OWNER", "APP_DATABASE_PASSWORD")
      example.run
    ensure
      ENV["DATABASE_OWNER"], ENV["APP_DATABASE_PASSWORD"] = saved
    end

    it "grants the role with the app's password when run as the owner" do
      ENV["DATABASE_OWNER"] = "1"
      ENV["APP_DATABASE_PASSWORD"] = "the-app's"

      expect { Rake::Task["db:app_role"].execute }.to output(/balcao_app granted/).to_stdout
      expect(DatabaseRole).to have_received(:grant!).with(password: "the-app's")
    end

    it "refuses to run as anyone but the owner" do
      ENV["DATABASE_OWNER"] = nil

      expect { Rake::Task["db:app_role"].execute }.to raise_error(SystemExit).and output(/DATABASE_OWNER=1/).to_stderr
      expect(DatabaseRole).not_to have_received(:grant!)
    end
  end
end
