require "rails_helper"

RSpec.describe "design §6.5 primary keys" do
  it "gives every table of the primary database a time-ordered uuid (v7) as its key" do
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]

    expect(tables).not_to be_empty
    tables.each do |table|
      id = connection.columns(table).find { |column| column.name == "id" }
      expect([ table, id&.sql_type, id&.default_function ]).to eq([ table, "uuid", "uuidv7()" ])
    end
  end
end

RSpec.describe "FR-05 FR-15 deleting a visitor or a conversation takes everything under it" do
  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:product) { create(:product) }
  let!(:turn) { create(:turn, inbound_message: create(:message, conversation:)) }

  before do
    create(:outbound_message, turn:)
    create(:trace_event, turn:)
    create(:usage_record, turn:)
    create(:reservation, turn:, product:)
  end

  def counts
    [ Visitor, Conversation, Message, Turn, TraceEvent, UsageRecord, Reservation ].to_h { |model| [ model.name, model.count ] }
  end

  it "deletes the visitor's conversations, messages, turns, trace events, usage records and reservations with its row" do
    visitor.destroy!

    expect(counts.values).to all(eq(0))
    expect(product.reload).to be_persisted
  end

  it "deletes a conversation's messages, turns, trace events, usage records and the reservations its turns made" do
    conversation.destroy!

    expect(counts).to eq(
      "Visitor" => 1, "Conversation" => 0, "Message" => 0, "Turn" => 0,
      "TraceEvent" => 0, "UsageRecord" => 0, "Reservation" => 0
    )
  end

  it "keeps a product that a reservation holds" do
    expect { Product.transaction(requires_new: true) { product.destroy! } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
