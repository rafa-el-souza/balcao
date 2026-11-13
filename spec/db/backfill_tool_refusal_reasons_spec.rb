require "rails_helper"
require Rails.root.join("db/migrate/20261113170000_backfill_tool_refusal_reasons")

# The refusals stored before the reason code carry none, and the glass box
# would draw them as failures, in the error colour (review finding C2 of pull
# request #19). A refusal's text was its tool's message, which a failure's
# never is, so the stored text says which reason it was.
RSpec.describe "FR-12 the refusals stored before the reason code get theirs, and a failure none" do
  let(:turn) { create(:turn) }

  def tool_span(tool, content, **attributes)
    create(:trace_event, turn:, name: "anthropic.custom_tool_use #{tool}", finished_at: Time.current,
                         span_attributes: { "gen_ai.tool.name" => tool, "anthropic.tool_result.content" => content,
                                            "error.type" => "tool_error" }.merge(attributes))
  end

  def backfill = ActiveRecord::Migration.suppress_messages { BackfillToolRefusalReasons.new.up }

  def reason(span) = span.reload.span_attributes["balcao.tool_result.refusal"]

  it "gives each stored refusal the reason of its tool's message" do
    empty = tool_span("search_products", Tools::SearchProducts::EMPTY)
    long = tool_span("search_products", Tools::SearchProducts::LONG)
    unknown = tool_span("get_store_info", Tools::GetStoreInfo::UNKNOWN)

    backfill

    expect([ reason(empty), reason(long), reason(unknown) ]).to eq(%w[empty_query long_query unknown_topic])
    expect(empty.span_attributes).to include("error.type" => "tool_error",
                                             "anthropic.tool_result.content" => Tools::SearchProducts::EMPTY)
  end

  it "gives a failure, another tool's span with the same text, or one that answered, no reason" do
    failure = tool_span("search_products", AgentTool::FAILED)
    other = tool_span("get_store_info", Tools::SearchProducts::EMPTY)
    answered = tool_span("search_products", Tools::SearchProducts::EMPTY, "error.type" => nil)

    backfill

    expect([ reason(failure), reason(other), reason(answered) ]).to all(be_nil)
  end

  it "leaves a reason already given as it is" do
    given = tool_span("search_products", Tools::SearchProducts::EMPTY, "balcao.tool_result.refusal" => "long_query")

    backfill

    expect(reason(given)).to eq("long_query")
  end
end
