require "rails_helper"

# The finding of review V2 on pull request #1: bin/ci audited the gems against
# the advisory database of its first run forever, while CI downloads a fresh
# one, so a local run could pass where CI fails. Since M3's CI furniture
# bin/bundler-audit asks for the update itself (spec/ci/bundler_audit_spec.rb),
# so bin/ci runs it as CI does, with no database of its own.
RSpec.describe "SR-27 bin/ci audits gems against a fresh advisory database" do
  it "runs bin/bundler-audit as CI does, which updates its database before checking" do
    recorder = Class.new do
      attr_reader :steps

      def initialize = @steps = {}
      def run(&block) = instance_eval(&block)
      def step(title, *command) = @steps[title] = command.join(" ")
      def success? = true
      def failure(*) = nil
    end.new
    stub_const("CI", recorder)

    load Rails.root.join("config/ci.rb")

    audit = recorder.steps.values.find { |command| command.include?("bin/bundler-audit") }
    expect(audit).to eq("bin/bundler-audit")
  end
end
