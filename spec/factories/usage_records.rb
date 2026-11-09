FactoryBot.define do
  factory :usage_record do
    turn
    model { "claude-opus-5-5" }
    input_tokens { 1200 }
    cache_creation_tokens { 0 }
    cached_tokens { 3000 }
    output_tokens { 150 }
    cost_usd { BigDecimal("0.0123") }
  end
end
