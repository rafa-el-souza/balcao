require "rails_helper"
require "open3"

# actionlint over the workflows, with shellcheck inside for their run steps
# (design NFR-08): in CI from M3's CI furniture, in bin/ci, and installed by
# bin/setup, all through bin/actionlint and the release it pins (#1's line,
# design §9.2).
RSpec.describe "NFR-08 actionlint lints the workflows in CI, in bin/ci and from bin/setup" do
  let(:script) { Rails.root.join("bin/actionlint").read }
  let(:workflow) { YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml")) }

  it "pins a release with a SHA-256 for each platform it installs, CI's runner among them" do
    expect(script[/^VERSION = "(\d+\.\d+\.\d+)"/, 1]).to be_present
    checksums = script.scan(/"(linux|darwin)_(amd64|arm64)" => "(\h+)"/)

    expect(checksums.map { |os, cpu, _| "#{os}_#{cpu}" }).to include("linux_amd64")
    expect(checksums.map(&:last)).to all(match(/\A\h{64}\z/))
  end

  it "runs in CI, in bin/ci and from bin/setup, never as a bare actionlint from the PATH" do
    steps = workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps") }.filter_map { |step| step["run"] }

    expect(steps).to include("bin/actionlint")
    expect(Rails.root.join("config/ci.rb").read).to include('"bin/actionlint"')
    expect(Rails.root.join("config/ci.rb").read).not_to include('"actionlint"')
    expect(Rails.root.join("bin/setup").read).to include('"bin/actionlint", "-version"')
  end

  it "refuses to run without shellcheck, which lints the workflows' run steps" do
    ruby = RbConfig.ruby
    Dir.mktmpdir do |dir|
      File.symlink(ruby, File.join(dir, "ruby"))
      _out, err, status = Open3.capture3({ "PATH" => dir }, File.join(dir, "ruby"), Rails.root.join("bin/actionlint").to_s, "-version")

      expect(status).not_to be_success
      expect(err).to include("shellcheck is not on the PATH")
    end
  end
end
