require "rails_helper"

# The catalogue search took 1.4 to 2.0 s a call on the demo host, with twenty
# products. The planner estimates it at about three million cost units, from
# its set-returning functions, past the 100,000 at which PostgreSQL compiles a
# plan before running it and the 500,000 at which it also inlines and
# optimizes the code; the compiling was the time. The development database is
# built without the JIT library, so nothing here showed it. With the compiler
# off the same search took 9 to 14 ms there, and no result changes (design §10,
# the note of 2026-11-15, the plan after the MVP; slice M4-1).
RSpec.describe "NFR-01 FR-06 database connections run without the JIT compiler" do
  it "turns jit off on the application's connection" do
    expect(ApplicationRecord.connection.select_value("SHOW jit")).to eq "off"
  end

  it "turns it off on every database of the production configuration" do
    configs = ActiveRecord::Base.configurations.configs_for(env_name: "production", include_hidden: true)

    expect(configs.map(&:name)).to contain_exactly("primary", "cache", "queue", "cable")
    configs.each do |config|
      expect(config.configuration_hash[:variables]).to include("jit" => "off")
    end
  end
end
