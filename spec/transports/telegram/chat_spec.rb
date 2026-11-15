require "rails_helper"
require "pp"

# Threat model SR-10: a Telegram user's id is personal data, never logged and
# never in a trace. A reply needs it as the chat to send to, so the chat is
# held in memory where the reply is made (FR-19), and nothing that prints or
# serialises the object writes it: inspect, to_s and so a string's
# interpolation, pp, to_h and so as_json and to_json (review finding C5 of
# pull request #33: Data's to_s is its own inspect, not the one a class
# defines, and pp and to_h list the members).
RSpec.describe "SR-10 FR-19 Telegram::Chat, the chat a reply goes to" do
  let(:id) { 7_341_200_001 }
  let(:identity) { "c" * 64 }
  let(:chat) { Telegram::Chat.new(identity:, id:) }

  it "writes neither the chat's id nor the person's identity wherever it is printed or serialised" do
    shown = { inspect: chat.inspect, to_s: chat.to_s, interpolated: "sent to #{chat}", pp: chat.pretty_inspect,
              to_h: chat.to_h.to_s, as_json: chat.as_json.to_s, to_json: chat.to_json, in_a_hash: { chat: }.to_json }

    shown.each do |how, text|
      expect(text).not_to include(id.to_s), "#{how} wrote the chat's id: #{text}"
      expect(text).not_to include(identity), "#{how} wrote the identity: #{text}"
    end
    expect(chat.to_s).to eq("#<Telegram::Chat>")
  end

  it "keeps both for the code that sends, and a chat equal to another of the same person" do
    expect([ chat.id, chat.identity ]).to eq([ id, identity ])
    expect(chat).to eq(Telegram::Chat.new(identity:, id:))
    expect(chat.with(id: 5).id).to eq(5)
  end
end
