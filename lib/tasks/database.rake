namespace :db do
  # The app's own database role on every database of the environment
  # (DatabaseRole; M3-4): made, or brought back to its attributes and
  # password, and granted what the migrations made. The web container's
  # entrypoint runs it after db:prepare, as the database's owner
  # (DATABASE_OWNER=1, bin/docker-entrypoint); production alone connects as
  # the role (config/database.yml).
  desc "Make or update the app's database role and grant it every database's rows (run as the owner)"
  task app_role: :environment do
    abort "db:app_role runs as the database's owner (DATABASE_OWNER=1, bin/docker-entrypoint)" unless ENV["DATABASE_OWNER"] == "1"

    DatabaseRole.grant!(password: ENV.fetch("APP_DATABASE_PASSWORD", ""))
    puts "db:app_role: #{DatabaseRole::NAME} granted on #{ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).size} databases"
  end
end
