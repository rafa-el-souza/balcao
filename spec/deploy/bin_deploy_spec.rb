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
    expect(kamal_calls.grep_v(/\Akamal server exec /)).to eq [ "kamal version", "kamal setup -d ensaio", "kamal registry remove -d ensaio" ]
  end

  # Review findings C1 and R1 of pull request #21 (threat model SR-27): Kamal
  # runs the proxy by its tag, and Docker asks the registry for a tag the host
  # lacks (a fresh host, or one whose proxy image was removed), where a tag can
  # be pushed again. Every deploy first puts the image on the host by the
  # digest written beside the tag in config/deploy.yml, under that tag.
  it "puts the pinned kamal-proxy on the host by its digest, under its tag, before kamal setup" do
    version, digest = Rails.root.join("config/deploy.yml").read
      .match(%r{^\s*version: (v\d+\.\d+\.\d+) # (basecamp/kamal-proxy@sha256:\h{64})$}).captures

    status, _err = deploy("-d", "ensaio")

    expect(status).to be_success
    put = kamal_calls.index do |call|
      call.start_with?("kamal server exec -d ensaio ") && call.include?("docker pull #{digest}") &&
        call.include?("docker tag #{digest} basecamp/kamal-proxy:#{version}")
    end
    expect(put).not_to be_nil
    expect(put).to be < kamal_calls.index("kamal setup -d ensaio")
  end

  it "stops before kamal setup when the proxy's image cannot be put on the host" do
    status, err = deploy("-d", "ensaio", env: rehearsal_env.merge("KAMAL_SHIM_FAIL_ON" => "server"))

    expect(status).not_to be_success
    expect(err).to include("kamal-proxy")
    expect(kamal_calls).not_to include("kamal setup -d ensaio")
  end

  # Review finding R2 of pull request #21: the digest is tied to the tag by
  # hand, so a bump that left the previous digest behind would put the
  # previous release under the new tag. The image's own version label, which
  # kamal-proxy's releases set to their tag from v0.10, must name the pinned
  # tag before the image takes it; a label that is no release tag passes,
  # since v0.9.2, the way back, carries only its Ubuntu base's "24.04". The
  # command bin/deploy sends to the host runs here, under sh, against a docker
  # shim.
  describe "the command that puts the proxy's image on the host" do
    let(:host) { Dir.mktmpdir("bin-deploy-host") }
    let(:docker_log) { File.join(host, "docker.log") }
    let(:version) { Rails.root.join("config/deploy.yml").read[/^\s*version: (v\d+\.\d+\.\d+) #/, 1] }

    after { FileUtils.remove_entry(host) }

    def run_on_host(label:)
      deploy("-d", "ensaio")
      command = kamal_calls.find { |call| call.start_with?("kamal server exec -d ensaio ") }.delete_prefix("kamal server exec -d ensaio ")
      docker = File.join(host, "docker")
      File.write(docker, <<~RUBY)
        #!/usr/bin/env ruby
        File.open(#{docker_log.inspect}, "a") { |file| file.puts(ARGV.join(" ")) }
        print(#{label.inspect}) if ARGV.include?("--format")
      RUBY
      File.chmod(0o755, docker)
      out, status = Open3.capture2e({ "PATH" => "#{host}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}" }, "sh", "-c", command)
      [ status, out, File.exist?(docker_log) ? File.readlines(docker_log, chomp: true) : [] ]
    end

    it "tags the image when its version label names the pinned tag" do
      status, _out, docker = run_on_host(label: version)

      expect(status).to be_success
      expect(docker.last).to match(/\Atag \S+ basecamp\/kamal-proxy:#{Regexp.escape(version)}\z/)
    end

    it "tags an image whose label is no release tag: none, or its base image's, as before v0.10" do
      [ "", "24.04" ].each do |label|
        FileUtils.rm_f(docker_log)
        status, _out, docker = run_on_host(label:)

        expect(status).to be_success, label.inspect
        expect(docker.grep(/\Atag /).size).to eq(1), label.inspect
      end
    end

    it "refuses, without tagging, an image whose label names another release, and says which" do
      status, out, docker = run_on_host(label: "v0.0.1")

      expect(status).not_to be_success
      expect(docker.grep(/\Atag /)).to be_empty
      expect(out).to include("v0.0.1", version)
    end
  end

  it "removes the local registry even when the deploy fails, and exits non-zero" do
    status, _err = deploy("-d", "ensaio", env: rehearsal_env.merge("KAMAL_SHIM_FAIL_ON" => "setup"))

    expect(status).not_to be_success
    expect(kamal_calls.last).to eq "kamal registry remove -d ensaio"
  end
end
