# The app's own database role (threat model SR-24; design §8, M3-4; #4's
# review). The app connected as the superuser the Postgres image makes from
# POSTGRES_USER, so a query it was made to run could read the server's files,
# run a program as the database's user (COPY ... TO PROGRAM), drop a table or
# make a role. This role logs in and holds no power of the cluster's: on each
# of the environment's databases it may connect, use the public schema and
# read and write its tables' rows and use their sequences, now and for the
# tables the owner's migrations make later; it may not make or change an
# object, empty a table at once (TRUNCATE) or read a file.
#
# The web container's entrypoint runs grant! as the owner after the
# migrations, at every boot (bin/rails db:app_role, bin/docker-entrypoint):
# it makes the role, or brings it back to these attributes and to
# APP_DATABASE_PASSWORD, so a rotation is a new line in the env file and a
# deploy (the runbook says how to watch it), and grants again what a
# migration added. An existing role's password changes last, after every
# database's grants, since the containers still running hold the old one: a
# grant that fails leaves it as it was (review finding F1 of pull request
# #65). The password never reaches a statement: the database's own SCRAM
# hash of it does, computed here by libpq, as psql's \password computes it.
module DatabaseRole
  NAME = "balcao_app".freeze
  # The image's superuser, which owns the databases and runs the migrations
  # (config/deploy.yml's accessory, POSTGRES_USER).
  OWNER = "balcao".freeze
  ATTRIBUTES = "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS".freeze
  ROWS = "SELECT, INSERT, UPDATE, DELETE".freeze
  SEQUENCES = "USAGE, SELECT, UPDATE".freeze

  module_function

  # name is the role's, the specs' own in the suite; configs are the
  # environment's databases, each connected as the owner.
  def grant!(password:, name: NAME, configs: ActiveRecord::Base.configurations.configs_for(env_name: Rails.env))
    raise ArgumentError, "the app's database role needs a password (APP_DATABASE_PASSWORD)" if password.to_s.strip.empty?

    existed = false
    configs.each_with_index do |config, index|
      with_connection(config) do |connection|
        existed = make(connection, name, password) if index.zero?
        grant(connection, name)
      end
    end
    with_connection(configs.first) { |connection| connection.execute("ALTER ROLE #{role(connection, name)} PASSWORD #{hash(connection, name, password)}") } if existed
  end

  # A role is the cluster's: made with its password, or brought back to its
  # attributes, once, on the first database. Answers whether it existed.
  def make(connection, name, password)
    existed = connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = $1", "DatabaseRole", [ name ]) ? true : false
    if existed
      connection.execute("ALTER ROLE #{role(connection, name)} #{ATTRIBUTES}")
    else
      connection.execute("CREATE ROLE #{role(connection, name)} #{ATTRIBUTES} PASSWORD #{hash(connection, name, password)}")
    end
    existed
  end

  def role(connection, name) = connection.quote_column_name(name)

  def hash(connection, name, password) = connection.quote(connection.raw_connection.encrypt_password(password, name, "scram-sha-256"))

  def grant(connection, name)
    grantee = role(connection, name)
    database = connection.quote_column_name(connection.current_database)
    connection.execute("GRANT CONNECT ON DATABASE #{database} TO #{grantee}")
    connection.execute("GRANT USAGE ON SCHEMA public TO #{grantee}")
    connection.execute("GRANT #{ROWS} ON ALL TABLES IN SCHEMA public TO #{grantee}")
    connection.execute("GRANT #{SEQUENCES} ON ALL SEQUENCES IN SCHEMA public TO #{grantee}")
    connection.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT #{ROWS} ON TABLES TO #{grantee}")
    connection.execute("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT #{SEQUENCES} ON SEQUENCES TO #{grantee}")
  end

  # A database the app holds a connection to already (the suite's own) is
  # granted on it; any other is connected for the grant alone, as Rails' own
  # database tasks connect each database in turn.
  def with_connection(config, &)
    current = ActiveRecord::Base.connection_db_config
    if config.env_name == current.env_name && config.name == current.name
      return ActiveRecord::Base.connection_pool.with_connection(&)
    end

    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config, &)
  end
end
