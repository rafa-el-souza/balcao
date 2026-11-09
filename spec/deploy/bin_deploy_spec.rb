require "rails_helper"
require "open3"
require "tmpdir"

# bin/deploy knows one destination, the rehearsal (ADR-0011). Production is
# deployed by a human from the operator account with the pinned global kamal
# invoked directly, so any other invocation must stop before kamal runs. A
# PATH shim records every call to kamal and to git.
RSpec.describe "SR-38 bin/deploy deploys only the rehearsal destination" do
  let(:shims) { Dir.mktmpdir("bin-deploy-shims") }
  let(:log) { File.join(shims, "calls.log") }
  let(:rehearsal_env) do
    {
      "ENSAIO_HOST" => "203.0.113.10",
      "ENSAIO_SSH_KEY" => "/nonexistent/key",
      "ENSAIO_SSH_CONFIG" => "/nonexistent/ssh_config"
    }
  end

  before do
    write_shim("kamal", exit_status: "ENV.fetch('KAMAL_SHIM_FAIL_ON', '').split(',').include?(ARGV.first) ? 1 : 0")
    write_shim("git", output: "ENV.fetch('GIT_SHIM_STATUS', '')")
  end

  after { FileUtils.remove_entry(shims) }

  def write_shim(name, exit_status: "0", output: "''")
    path = File.join(shims, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.open(#{log.inspect}, "a") { |file| file.puts(["#{name}", *ARGV].join(" ")) }
      print(#{output})
      exit(#{exit_status})
    RUBY
    File.chmod(0o755, path)
  end

  def deploy(*args, env: rehearsal_env)
    blank = { "ENSAIO_HOST" => nil, "ENSAIO_SSH_KEY" => nil, "ENSAIO_SSH_CONFIG" => nil }
    path = { "PATH" => "#{shims}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}" }
    _out, err, status = Open3.capture3(blank.merge(env).merge(path), Rails.root.join("bin/deploy").to_s, *args)
    [ status, err ]
  end

  def calls = File.exist?(log) ? File.readlines(log, chomp: true) : []
  def kamal_calls = calls.grep(/\Akamal /)

  it "refuses every invocation other than -d ensaio and never invokes kamal" do
    [
      [],
      %w[-d production],
      %w[-d balcao],
      %w[--destination ensaio],
      %w[-densaio],
      %w[-d],
      %w[-d ensaio -P],
      %w[-d ensaio --skip-push],
      %w[deploy -d ensaio]
    ].each do |args|
      status, err = deploy(*args)

      expect(status).not_to be_success, "bin/deploy #{args.join(" ")} exited zero"
      expect(err).to include("bin/deploy -d ensaio")
    end
    expect(kamal_calls).to be_empty
  end

  it "refuses -d ensaio when ENSAIO_HOST or another rehearsal variable is unset or blank, and never invokes kamal" do
    rehearsal_env.each_key do |name|
      [ nil, "", "  " ].each do |value|
        status, err = deploy("-d", "ensaio", env: rehearsal_env.merge(name => value))

        expect(status).not_to be_success, "#{name}=#{value.inspect} let bin/deploy through"
        expect(err).to include(name)
      end
    end
    expect(kamal_calls).to be_empty
  end

  it "refuses a working tree with uncommitted changes, because kamal builds the committed HEAD" do
    status, err = deploy("-d", "ensaio", env: rehearsal_env.merge("GIT_SHIM_STATUS" => " M Dockerfile\n"))

    expect(status).not_to be_success
    expect(err).to include("uncommitted")
    expect(kamal_calls).to be_empty
  end

  it "prints the kamal version, runs setup on the rehearsal destination and removes the local registry" do
    status, _err = deploy("-d", "ensaio")

    expect(status).to be_success
    expect(kamal_calls).to eq [ "kamal version", "kamal setup -d ensaio", "kamal registry remove -d ensaio" ]
  end

  it "removes the local registry even when the deploy fails, and exits non-zero" do
    status, _err = deploy("-d", "ensaio", env: rehearsal_env.merge("KAMAL_SHIM_FAIL_ON" => "setup"))

    expect(status).not_to be_success
    expect(kamal_calls.last).to eq "kamal registry remove -d ensaio"
  end
end
