require "rails_helper"

# Review finding V1 of pull request #53 (M2's first close; M3-4): Solid Cache
# counts a key under its row's lock, and a key with no row yet has none to
# lock, so two first counts of a window each read no row and each wrote 1,
# and a source's requests at once each counted as its window's first. Two
# real threads, each on its own connection, outside the example's
# transaction.
RSpec.describe "FR-14 SR-01 a limit's first count in a window, two at once" do
  self.use_transactional_tests = false

  let(:store) { SolidCache::Store.new(namespace: "concurrency", expiry_method: :job) }
  let(:limit) { EdgeLimits::LIMITS.fetch("ip/sessions") }

  before do
    @versions = ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations")
    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/cache_schema.rb") }
    SolidCache::Entry.reset_column_information
    allow(Rack::Attack.cache).to receive(:store).and_return(store)
  end

  # The cache's table lives in its own database in production; here it is
  # made in the suite's, outside a transaction, so it goes with the example,
  # as the primary database's tables are all the app's own (spec/db/schema_spec.rb).
  # The cache schema's define writes its version into the suite's
  # schema_migrations, outside a transaction too (V4 of pull request #65).
  after do
    ActiveRecord::Base.connection.drop_table(:solid_cache_entries, if_exists: true)
    SolidCache::Entry.reset_column_information
    left = ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations") - @versions
    ActiveRecord::Base.connection.exec_delete("DELETE FROM schema_migrations WHERE version = ANY($1::varchar[])", "spec", [ "{#{left.join(",")}}" ]) if left.any?
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  it "counts both, the second after the first's row is written" do
    read = Queue.new
    # Each count stops right after reading its row, as two at once do, until
    # both have read or a second has passed.
    allow(SolidCache::Entry).to receive(:lock_and_write).and_wrap_original do |original, key, &block|
      original.call(key) do |value|
        read << true
        until_at = monotonic + 1
        sleep(0.01) until read.size >= 2 || monotonic > until_at
        block.call(value)
      end
    end

    counts = Array.new(2) do
      Thread.new { Rails.application.executor.wrap { EdgeLimits.count(limit, "203.0.113.7") } }
    end.map(&:value)

    expect(counts.sort).to eq([ 1, 2 ])
    expect(store.read("limits:ip/sessions:203.0.113.7", raw: true).to_i).to eq(2)
  end
end
