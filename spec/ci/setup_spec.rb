require "rails_helper"

# Review finding V3 on pull request #1: bin/setup enabled the secret-scan hook
# after the installs, so a commit made while they ran, or after one failed,
# escaped the scan.
RSpec.describe "SR-25 bin/setup enables the secret-scan hook before anything else" do
  it "points git at .githooks before installing gems or web packages" do
    setup = Rails.root.join("bin/setup").read
    position = ->(pattern) { setup.index(pattern) or raise "bin/setup no longer runs #{pattern.inspect}" }

    hook = position.("git config core.hooksPath .githooks")

    expect(hook).to be < position.("bundle install")
    expect(hook).to be < position.("npm ci")
  end
end
