# The refusals the tools gave before pull request #19 carry no reason code,
# so the glass box and the trace page would now draw them as failures, in the
# error colour (review finding C2 of that pull request, FR-12). A refusal's
# stored text is its tool's message, cut at 500 characters, which none of
# these reaches, and a failure's text is never one of them (AgentTool::FAILED),
# so each is matched whole and given its reason; a failure keeps none. The
# messages are read from the tools as they are at that pull request, which
# did not change them. Nothing to undo: a reason given is what a refusal
# stored from then on carries.
class BackfillToolRefusalReasons < ActiveRecord::Migration[8.1]
  REFUSALS = {
    "search_products" => { Tools::SearchProducts::EMPTY => "empty_query", Tools::SearchProducts::LONG => "long_query" },
    "get_store_info" => { Tools::GetStoreInfo::UNKNOWN => "unknown_topic" }
  }.freeze

  def up
    REFUSALS.each do |tool, messages|
      messages.each do |message, reason|
        execute(ActiveRecord::Base.sanitize_sql([ <<~SQL.squish, { name: "anthropic.custom_tool_use #{tool}", message:, reason: } ]))
          UPDATE trace_events
          SET span_attributes = span_attributes || jsonb_build_object('balcao.tool_result.refusal', CAST(:reason AS text))
          WHERE name = :name
            AND span_attributes->>'error.type' = 'tool_error'
            AND span_attributes->>'anthropic.tool_result.content' = :message
            AND span_attributes->'balcao.tool_result.refusal' IS NULL
        SQL
      end
    end
  end

  def down; end
end
