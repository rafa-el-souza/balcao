require "rails_helper"
require "open3"
require "tmpdir"

# The container entrypoint is the generator's shell script rewritten in Ruby,
# because no shell script lives in the repository (design NFR-08, §6.9). It
# prepares the databases before the web server starts, and only then.
RSpec.describe "NFR-08 the container entrypoint, in Ruby" do
  let(:app) { Dir.mktmpdir("entrypoint") }
  let(:log) { File.join(app, "calls.log") }

  before do
    FileUtils.mkdir_p(File.join(app, "bin"))
    %w[rails thrust jobs].each do |name|
      path = File.join(app, "bin", name)
      File.write(path, <<~RUBY)
        #!/usr/bin/env ruby
        File.open(#{log.inspect}, "a") { |file| file.puts(["#{name}", *ARGV].join(" ")) }
        exit(ENV.key?("FAIL_ON") && ENV["FAIL_ON"] == ARGV.first ? 1 : 0)
      RUBY
      File.chmod(0o755, path)
    end
  end

  after { FileUtils.remove_entry(app) }

  def entrypoint(*command, env: {})
    _out, _err, status = Open3.capture3(env, Rails.root.join("bin/docker-entrypoint").to_s, *command, chdir: app)
    [ status, File.exist?(log) ? File.readlines(log, chomp: true) : [] ]
  end

  it "prepares the databases, then starts the web server behind Thruster" do
    status, calls = entrypoint("./bin/thrust", "./bin/rails", "server")

    expect(status).to be_success
    expect(calls).to eq [ "rails db:prepare", "thrust ./bin/rails server" ]
  end

  it "runs any other command as given, without touching the databases" do
    status, calls = entrypoint("./bin/jobs")

    expect(status).to be_success
    expect(calls).to eq [ "jobs" ]
  end

  it "does not start the server when the databases cannot be prepared" do
    status, calls = entrypoint("./bin/rails", "server", env: { "FAIL_ON" => "db:prepare" })

    expect(status).not_to be_success
    expect(calls).to eq [ "rails db:prepare" ]
  end
end
