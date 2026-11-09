# The month's spend and mode (FR-14, ADR-0003). Modes beyond the pause arrive at M3.
class BudgetState < ApplicationRecord
  MODES = { normal: "normal", economy: "economy", paused: "paused" }.freeze

  enum :automatic_mode, MODES, prefix: :automatic, validate: true
  enum :forced_mode, MODES, prefix: :forced, validate: { allow_nil: true }

  validates :month, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }
  validates :spent_usd, numericality: { greater_than_or_equal_to: 0 }

  # The row of the calendar month in São Paulo, opened by the month's first
  # turn. Read first, since every turn asks; two first turns racing meet the
  # unique index, and the one that loses gets the row (NFR-02).
  def self.for_month!(time = Time.current)
    month = time.in_time_zone.strftime("%Y-%m")
    find_by(month:) || create_or_find_by!(month:)
  end
end
