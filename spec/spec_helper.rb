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
  config.example_status_persistence_file_path = "tmp/rspec_examples.txt"
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
