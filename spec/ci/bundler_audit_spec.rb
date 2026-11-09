require "rails_helper"
require "open3"

# The finding of review F3 on pull request #1: bin/bundler-audit failed on
# every advisory, while the threat model's threshold is "above low".
RSpec.describe "SR-27 bundler-audit fails CI on advisories above low only" do
  def audit(cvss_v3)
    Dir.mktmpdir do |database|
      FileUtils.mkdir_p(File.join(database, "gems", "rake"))
      advisory = {
        "gem" => "rake", "cve" => "2099-0001", "url" => "https://example.invalid/advisory",
        "title" => "probe", "date" => Date.new(2026, 11, 1), "description" => "probe",
        "cvss_v3" => cvss_v3, "patched_versions" => [ ">= 99" ]
      }.compact
      File.write(File.join(database, "gems", "rake", "CVE-2099-0001.yml"), advisory.to_yaml)

      Open3.capture2e("bin/bundler-audit", "check", "--database", database, chdir: Rails.root.to_s)
    end
  end

  it "reports a low advisory and passes" do
    output, status = audit(3.1)

    expect(output).to include("CVE-2099-0001")
    expect(status).to be_success, output
  end

  it "fails on a medium advisory" do
    output, status = audit(5.0)

    expect(output).to include("CVE-2099-0001")
    expect(status).not_to be_success
  end

  it "fails on an advisory with no severity score" do
    _output, status = audit(nil)

    expect(status).not_to be_success
  end
end
