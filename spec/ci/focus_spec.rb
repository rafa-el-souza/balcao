require "rails_helper"
require "open3"

RSpec.describe "NFR-08 a committed focus cannot shrink the suite in CI" do
  it "runs every example under CI even when one of them is focused" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "focused_spec.rb"), <<~RUBY)
        RSpec.describe("probe") do
          it("is focused", :focus) { expect(true).to be(true) }
          it("is not") { expect(true).to be(true) }
        end
      RUBY

      output, status = Open3.capture2e({ "CI" => "true" }, "bundle", "exec", "rspec", dir, chdir: Rails.root.to_s)

      expect(status).to be_success, output
      expect(output).to include("2 examples, 0 failures")
    end
  end
end
