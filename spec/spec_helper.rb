# Line coverage of the whole run, against the threshold in .simplecov (design
# NFR-08): CI's RSpec step sets COVERAGE=1. SimpleCov starts before the app
# loads, so every file the run requires is counted.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start "rails"
end

# Configuration shared by every spec; Rails-specific setup is in rails_helper.rb.
# Every example group names the requirement it covers in its description
# string, e.g. RSpec.describe "FR-07 reservation" (design NFR-08).
RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  # Focus is a local convenience; in CI every example runs, so a focus
  # committed by mistake cannot shrink the suite to one green example (NFR-08).
  config.filter_run_when_matching :focus unless ENV["CI"]
  # A run whose filters select nothing fails: CI's step for SR-25 and SR-38
  # names its examples by filter, and a description reworded would leave it
  # green and empty (the review of #66, C3).
  config.fail_if_no_examples = true
  config.example_status_persistence_file_path = "tmp/rspec_examples.txt"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
