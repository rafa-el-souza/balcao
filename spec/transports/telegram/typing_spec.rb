require "rails_helper"

# FR-19, NFR-03: while a turn's model works, the visitor's chat shows
# Telegram's typing status, renewed before Telegram clears it (five seconds),
# and a status that fails to send never fails the turn.
RSpec.describe "FR-19 NFR-03 Telegram::Typing, the typing status while the model works" do
  include TelegramBotApi

  let(:chat) { Telegram::Chat.new(identity: "b" * 64, id: 7_341_200_002) }
  let(:actions) { [] }

  before { stub_bot_api(actions:) }

  it "sends the typing status at once and renews it while the block runs, and stops when it ends" do
    typing = Telegram::Typing.new(chat, interval: 0.05)

    result = typing.during do
      sleep 0.18
      :answered
    end
    count = actions.size
    sleep 0.15

    expect(result).to eq :answered
    expect(count).to be_between(3, 5)
    expect(actions.size).to eq count
    expect(actions).to all(eq("chat_id" => chat.id, "action" => "typing"))
  end

  it "renews it sooner than Telegram clears it" do
    expect(Telegram::Typing::INTERVAL).to be < 5
  end

  it "never fails the turn when the status cannot be sent, and logs it once by its class" do
    stub_request(:post, bot_api_url("sendChatAction")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
    allow(Rails.logger).to receive(:warn)

    result = Telegram::Typing.new(chat, interval: 0.02).during do
      sleep 0.1
      :answered
    end

    expect(result).to eq :answered
    expect(Rails.logger).to have_received(:warn).once.with("telegram typing: not sent, Telegram::Client::Error (403)")
  end

  it "lets the block's own error through" do
    expect { Telegram::Typing.new(chat, interval: 0.02).during { raise ArgumentError, "broke" } }.to raise_error(ArgumentError, "broke")
  end

  it "does nothing for a visitor of another channel" do
    expect(Telegram::Typing.for(create(:visitor)).during { :answered }).to eq :answered

    expect(actions).to be_empty
  end
end
