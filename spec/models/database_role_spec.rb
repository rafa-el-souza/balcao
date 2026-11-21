require "rails_helper"

# The app's own database role (M3-4; #4's review): it reads and writes its
# tables' rows and nothing else, so a query the app was made to run cannot
# read a file, run a program, change the schema or make a role, as the
# image's superuser could. Made, or brought back to its attributes and
# password, and granted every database's rows by the entrypoint's step, run
# as the owner after the migrations (db:app_role). A role is the cluster's,
# so the spec makes one of its own and drops it; it needs a user that may
# make roles, as CI's is, and is skipped where the user may not (a local
# database reached by peer authentication).
RSpec.describe "SR-24 the app's database role" do
  self.use_transactional_tests = false

  let(:name) { "balcao_app_spec_#{SecureRandom.hex(4)}" }
  let(:connection) { ActiveRecord::Base.connection }
  let(:database) { connection.current_database }

  before do
    skip "the database user may not make roles" unless connection.select_value("SELECT rolcreaterole OR rolsuper FROM pg_roles WHERE rolname = current_user")
  end

  after do
    next unless connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = $1", "spec", [ name ])

    connection.execute("DROP OWNED BY #{connection.quote_column_name(name)}")
    connection.execute("DROP ROLE #{connection.quote_column_name(name)}")
    connection.execute("DROP TABLE IF EXISTS spec_made_later")
  end

  def grant!(password = "first-password-of-the-spec") = DatabaseRole.grant!(password:, name:)

  def as_role(statement)
    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL ROLE #{connection.quote_column_name(name)}")
      connection.execute(statement)
      raise ActiveRecord::Rollback
    end
  end

  def privilege(function, *args) = connection.select_value("SELECT #{function}($1, #{args.map { |arg| connection.quote(arg) }.join(", ")})", "spec", [ name ])

  it "makes a role that may log in and holds no power of the cluster's" do
    grant!

    attributes = connection.select_one("SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolinherit " \
                                       "FROM pg_roles WHERE rolname = $1", "spec", [ name ])
    expect(attributes).to eq("rolcanlogin" => true, "rolsuper" => false, "rolcreatedb" => false, "rolcreaterole" => false,
                             "rolreplication" => false, "rolbypassrls" => false, "rolinherit" => false)
  end

  it "grants the rows of every table and their sequences, and nothing of the schema or the database" do
    grant!

    expect(privilege("has_database_privilege", database, "CONNECT")).to be true
    expect(privilege("has_database_privilege", database, "CREATE")).to be false
    expect(privilege("has_schema_privilege", "public", "USAGE")).to be true
    expect(privilege("has_schema_privilege", "public", "CREATE")).to be false
    expect(privilege("has_table_privilege", "visitors", "SELECT, INSERT, UPDATE, DELETE")).to be true
    expect(privilege("has_table_privilege", "visitors", "TRUNCATE")).to be false
    expect(privilege("has_table_privilege", "visitors", "REFERENCES")).to be false
    expect(privilege("has_table_privilege", "visitors", "TRIGGER")).to be false
  end

  it "grants the rows of a table the owner's migrations make later" do
    grant!
    connection.execute("CREATE TABLE spec_made_later (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text)")

    expect(privilege("has_table_privilege", "spec_made_later", "SELECT, INSERT, UPDATE, DELETE")).to be true
    expect(privilege("has_sequence_privilege", "spec_made_later_id_seq", "USAGE")).to be true
  end

  it "may not change the schema, read a file or run a program" do
    grant!

    expect { as_role("CREATE TABLE spec_not_allowed (id int)") }.to raise_error(ActiveRecord::StatementInvalid, /permission denied/)
    expect { as_role("DROP TABLE visitors") }.to raise_error(ActiveRecord::StatementInvalid, /must be owner/)
    expect { as_role("SELECT pg_read_file('postgresql.conf')") }.to raise_error(ActiveRecord::StatementInvalid, /permission denied/)
    expect { as_role("COPY (SELECT 1) TO PROGRAM 'true'") }.to raise_error(ActiveRecord::StatementInvalid, /pg_execute_server_program|superuser/)
  end

  it "brings an existing role back to its attributes and its password at every run" do
    grant!
    connection.execute("ALTER ROLE #{connection.quote_column_name(name)} CREATEDB NOLOGIN")

    grant!("second-password-of-the-spec")

    expect(connection.select_value("SELECT rolcreatedb OR NOT rolcanlogin FROM pg_roles WHERE rolname = $1", "spec", [ name ])).to be false
  end

  it "keeps the password out of every statement it runs, sending the database's own hash of it" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    grant!("a-password-no-statement-holds")

    expect(statements.join("\n")).not_to include("a-password-no-statement-holds")
    expect(statements.join("\n")).to include("SCRAM-SHA-256$")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
