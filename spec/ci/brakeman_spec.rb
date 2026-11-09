require "rails_helper"
require "open3"

# The finding of review F2 and V1 on pull request #1: Brakeman refused to scan
# whenever rubygems.org listed a newer Brakeman, which turned the required
# check red on release day and pushed a same-day bump past Dependabot's
# cooldown (SR-27).
RSpec.describe "SR-28 Brakeman scans whatever rubygems.org lists" do
  it "scans and passes when a newer Brakeman was published today" do
    Dir.mktmpdir do |dir|
      shim = File.join(dir, "newer_brakeman.rb")
      File.write(shim, <<~RUBY)
        module Gem
          def self.latest_spec_for(_name)
            Gem::Specification.new { |spec| spec.name = "brakeman"; spec.version = "99.0.0"; spec.date = Time.now }
          end
        end
      RUBY
      env = { "RUBYOPT" => [ ENV["RUBYOPT"], "-r#{shim}" ].compact.join(" ") }

      output, status = Open3.capture2e(env, "bin/brakeman", "--no-pager", "--quiet", "-w2", "--exit-on-warn", "--exit-on-error", chdir: Rails.root.to_s)

      expect(status.exitstatus).to eq(0), output
    end
  end
end
