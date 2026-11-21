# The day's counts (design §6.5): one row per day of São Paulo, kind and key,
# whose count each writer adds to, so FR-13's figures read a row a day rather
# than every record of the day, records the seven-day purge takes (FR-15).
# The kinds are the design's: messages and referrers arrive with FR-13 and
# FR-23; the canary's passed and failed runs (FR-17) are the first written.
# Counts alone, nothing of a person, so the purge leaves them.
class DailyAggregate < ApplicationRecord
  KINDS = %w[messages referrer canary].freeze

  validates :kind, inclusion: { in: KINDS }

  # Adds one to the day's count of the kind and key, opening the row on the
  # day's first count. One statement, INSERT … ON CONFLICT DO UPDATE on the
  # unique index of the day, kind and key, so concurrent writers each add to
  # the one row and none meets RecordNotUnique (NFR-02).
  def self.add!(kind:, key:, day: Time.current.to_date)
    raise ArgumentError, "#{kind} is not among the kinds of design §6.5 (#{KINDS.join(", ")})" unless KINDS.include?(kind)

    upsert({ day:, kind:, key:, count: 1 }, unique_by: %i[day kind key],
                                            on_duplicate: Arel.sql("count = daily_aggregates.count + 1, updated_at = EXCLUDED.updated_at"))
  end
end
