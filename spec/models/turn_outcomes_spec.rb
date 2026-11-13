require "rails_helper"

# A fixed reply's sent row in the glass box says why the reply is fixed, read
# from the turn's outcome on its root span (design §10, note of 2026-11-12):
# a slice that adds or renames an outcome gives the panel its words in the
# same change, and this spec keeps the two lists one.
RSpec.describe "FR-12 turn outcomes: every one the server writes has the glass box's words (NFR-03, NFR-09)" do
  def words(locale) = JSON.parse(Rails.root.join("web/src/locales/#{locale}.json").read).dig("instrument", "outcomes")

  it "lists AgentRunner's outcomes and the two TurnProcessor adds" do
    expect(TurnProcessor::OUTCOMES).to eq(%w[replied refused incomplete tool_limit deadline model_error reservations dead_letter])
  end

  it "gives the panel a word, in each of the three languages, for every outcome but a reply of the model's own" do
    %w[pt-BR en es].each do |locale|
      expect(words(locale).keys - %w[other]).to match_array(TurnProcessor::OUTCOMES - %w[replied]), locale
    end
  end

  it "refuses an outcome AgentRunner does not list, so none reaches the panel unworded" do
    expect { AgentRunner::Result.new(outcome: :overloaded, text: nil, language: nil, model_calls: [], tool_calls: [], error: nil) }
      .to raise_error(ArgumentError, /overloaded/)
  end
end
