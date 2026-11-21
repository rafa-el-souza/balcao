require "rails_helper"
require "open3"

# The finding of review F3 on pull request #1: bin/bundler-audit failed on
# every advisory, while the threat model's threshold is "above low".
RSpec.describe "SR-27 bundler-audit fails CI on advisories above low only" do
  def audit(cvss_v3, cvss_v4: nil)
    Dir.mktmpdir do |database|
      FileUtils.mkdir_p(File.join(database, "gems", "rake"))
      advisory = {
        "gem" => "rake", "cve" => "2099-0001", "url" => "https://example.invalid/advisory",
        "title" => "probe", "date" => Date.new(2026, 11, 1), "description" => "probe",
        "cvss_v3" => cvss_v3, "cvss_v4" => cvss_v4, "patched_versions" => [ ">= 99" ]
      }.compact
      File.write(File.join(database, "gems", "rake", "CVE-2099-0001.yml"), advisory.to_yaml)

      Open3.capture2e("bin/bundler-audit", "check", "--database", database, chdir: Rails.root.to_s)
    end
  end

  it "reports a low advisory and passes" do
    output, status = audit(3.1)

    expect(output).to include("CVE-2099-0001")
    expect(status).to be_success, output
    # Finding V2 (verifier, fix review): the run listed the advisory and then
    # printed "No vulnerabilities found".
    expect(output).not_to include("No vulnerabilities found")
    expect(output).to include("Low advisories only")
  end

  it "fails on a medium advisory" do
    output, status = audit(5.0)

    expect(output).to include("CVE-2099-0001")
    expect(status).not_to be_success
  end

  # Review finding R4 (fix review): bundler-audit 0.9.3 reads only CVSS v2 and
  # v3, so an advisory scored only in v4 looked unrated and failed when low.
  it "reports a low advisory scored only in CVSS v4 and passes" do
    output, status = audit(nil, cvss_v4: 2.3)

    expect(output).to include("CVE-2099-0001", "Criticality: Low")
    expect(status).to be_success, output
  end

  it "fails on a medium advisory scored only in CVSS v4" do
    _output, status = audit(nil, cvss_v4: 6.6)

    expect(status).not_to be_success
  end

  # "Above low" is read by the higher of the v3 and v4 scores (threat model
  # SR-27, the owner's word of 2026-11-15; #1's line R6): bundler-audit
  # 0.9.3 reads v3 alone when it has one.
  it "fails on an advisory low in CVSS v3 but medium in v4" do
    output, status = audit(3.1, cvss_v4: 5.3)

    expect(output).to include("CVE-2099-0001")
    expect(status).not_to be_success
    # The finder's note 4 on pull request #39: the report printed the v3
    # rating, "Low", beside a run that failed on the v4 one.
    expect(output).to include("Criticality: Medium", "the higher of its CVSS v3 and v4")
    expect(output).not_to include("Criticality: Low")
  end

  it "passes an advisory low in both CVSS v3 and v4" do
    output, status = audit(3.1, cvss_v4: 2.3)

    expect(status).to be_success, output
  end

  it "fails on an advisory with no severity score" do
    _output, status = audit(nil)

    expect(status).not_to be_success
  end
end

# #1's line, kept for M3's CI furniture (design §9.2): bin/bundler-audit run
# alone read the advisory database of its first run forever, while CI reads
# a fresh one; only bin/ci asked for the update. The script asks for it
# itself now, unless the caller names a database of its own (the probes
# above), which is read as given.
RSpec.describe "SR-27 bin/bundler-audit refreshes its advisory database itself" do
  def arguments(*argv)
    started = nil
    allow(Bundler::Audit::CLI).to receive(:start) { started = ARGV.dup }
    stub_const("ARGV", argv)
    # The script defines its modules' constants again on every load.
    silence_warnings { load Rails.root.join("bin/bundler-audit").to_s }
    started
  end

  before { require "bundler/audit/cli" }

  it "updates the database before a check, with no argument or with check" do
    expect(arguments).to include("--update", "--config", "config/bundler-audit.yml")
    expect(arguments("check")).to include("check", "--update", "--config", "config/bundler-audit.yml")
  end

  it "reads a database given by path as given" do
    expect(arguments("check", "--database", "/tmp/probe")).not_to include("--update")
  end

  it "adds no second --update" do
    expect(arguments("check", "--update").count("--update")).to eq 1
  end
end
