# The usage of one model call, as the API reported it, and its price (FR-14).
class UsageRecord < ApplicationRecord
  belongs_to :turn

  validates :model, presence: true
  validates :input_tokens, :cache_creation_tokens, :cached_tokens, :output_tokens,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :cost_usd, numericality: { greater_than_or_equal_to: 0 }
end
