require "rails_helper"

RSpec.describe "NFR-02 FR-04 conversation, one open conversation per visitor" do
  let(:visitor) { create(:visitor) }

  it "opens a conversation in pt-BR, active, when the visitor has none" do
    conversation = Conversation.current_for!(visitor)

    expect(conversation).to be_previously_new_record
    expect(conversation).to have_attributes(visitor:, state: "active", language: "pt-BR", closed_at: nil)
  end

  it "returns the open conversation, by the read alone" do
    open = create(:conversation, visitor:)

    result, raised = with_raised_exceptions { Conversation.current_for!(visitor) }

    expect(result).to eq(open)
    expect(raised).not_to include(ActiveRecord::RecordNotUnique)
  end

  it "opens a new conversation once the previous one is closed" do
    closed = create(:conversation, visitor:, closed_at: 1.hour.ago)

    current = Conversation.current_for!(visitor)

    expect(current).not_to eq(closed)
    expect(visitor.conversations.count).to eq(2)
  end

  it_behaves_like "an idempotency key", index: "index_conversations_one_open_per_visitor" do
    let(:existing) { create(:conversation, visitor:) }
    let(:duplicate) { build(:conversation, visitor:) }
    let(:call_again) do
      lambda do
        # The read ran before a concurrent first message committed the conversation.
        allow(Conversation).to receive(:find_by).and_return(nil)
        Conversation.current_for!(visitor)
      end
    end
  end
end

RSpec.describe "SR-11 FR-12 conversation trace token" do
  it "is random, at least 128 bits, and different for every conversation" do
    first, second = create_list(:conversation, 2)

    # 24 characters of base58 carry about 140 bits.
    expect(first.trace_token).to match(/\A[1-9A-HJ-NP-Za-km-z]{24}\z/)
    expect(second.trace_token).not_to eq(first.trace_token)
  end

  it "is unique in the database" do
    existing = create(:conversation)
    copy = build(:conversation)
    copy.trace_token = existing.trace_token

    expect { Conversation.transaction(requires_new: true) { copy.save!(validate: false) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /"index_conversations_on_trace_token"/)
  end
end
