require "rails_helper"

# A tool's refusal carries its reason code, which the glass box words (the
# drawings' reason code, design §10; docs/prototype/chat-tool-refused.html):
# a tool that adds or renames a reason gives the panel its words in the same
# change, and this spec keeps the two lists one, as turn_outcomes_spec does
# for the turn's outcomes.
RSpec.describe "FR-12 tool refusals: every reason a tool gives has the glass box's words (FR-07, NFR-09)" do
  def words(locale) = JSON.parse(Rails.root.join("web/src/locales/#{locale}.json").read).dig("instrument", "tool", "reasons")

  def reasons = Tools::ALL.flat_map { |tool| tool::REASONS }

  it "lists the reasons of the attendant's tools, each once" do
    expect(reasons).to match_array(%w[unknown_topic empty_query long_query unknown_product prescription invalid_quantity
                                      over_limit open_limit low_stock out_of_stock])
  end

  it "gives the panel a word, in each of the three languages, for every reason" do
    %w[pt-BR en es].each do |locale|
      expect(words(locale).keys).to match_array(reasons), locale
    end
  end

  it "takes a reason its tool does not list for a bug, so none reaches the panel unworded" do
    allow(Rails.logger).to receive(:error)
    unlisted = Class.new(SpecTools::Refuse) { def perform(_input) = refuse("no such topic", "brand_new") }
    allow(unlisted).to receive(:name).and_return("SpecTools::Refuse")
    calls = []

    expect { unlisted.new(turn: create(:turn), on_call: ->(call) { calls << call }).call(SpecTools::EchoInput.new(text: "x")) }
      .to raise_error(AgentTool::Error, AgentTool::FAILED)
    expect(calls.sole).to have_attributes(refusal: nil)
    expect(Rails.logger).to have_received(:error).with(/refuse.*ArgumentError.*brand_new/)
  end
end
