require "rails_helper"

# The operator's own chat with the bot, where the alerts go (threat model
# SR-35, ADR-0020, ADR-0022): linked once, by a deep link the runbook's command
# mints in the application's container, so only someone who can run a command
# there can link a chat. The link carries a token of 256 random bits, good for
# fifteen minutes and once, and the row keeps its digest alone; the chat id is
# encrypted at rest, as a visitor's is (SR-41).
RSpec.describe "SR-35 the operator's chat, linked once by the runbook's command" do
  let(:chat_id) { 734_120_042 }

  def token_of(url) = url[/\?start=(.+)\z/, 1]

  def link(token, at: Time.current) = OperatorChat.link!(token, chat_id:, language: "pt-BR", at:)

  it "mints a deep link to the bot whose token is 43 characters of the URL-safe alphabet, its digest alone kept" do
    url = OperatorChat.link_url!

    expect(url).to match(%r{\Ahttps://t\.me/BalcaoDemoBot\?start=[A-Za-z0-9_-]{43}\z})
    row = OperatorChat.sole
    expect(row.link_digest).to eq(Digest::SHA256.hexdigest(token_of(url)))
    expect(row.attributes.values.map(&:to_s)).not_to include(token_of(url))
  end

  it "links the chat that sends the token, keeps its id encrypted, and spends the token" do
    token = token_of(OperatorChat.link_url!)

    expect(link(token)).to be(true)

    expect(OperatorChat.chat_id).to eq(chat_id)
    expect(OperatorChat.language).to eq("pt-BR")
    row = OperatorChat.sole
    expect(row).to have_attributes(link_digest: nil, link_expires_at: nil, linked_at: be_present)
    expect(OperatorChat.connection.select_value("SELECT chat_id FROM operator_chats")).not_to include(chat_id.to_s)
    expect(OperatorChat.link!(token, chat_id: 734_120_999, language: "en")).to be(false)
    expect(OperatorChat.chat_id).to eq(chat_id)
  end

  it "refuses a token past its fifteen minutes, one never minted, and anything that is not a token" do
    minted = Time.zone.local(2026, 11, 21, 10, 0)
    token = travel_to(minted) { token_of(OperatorChat.link_url!) }

    expect(link(token, at: minted + 15.minutes)).to be(false)
    expect(link(SecureRandom.urlsafe_base64(32))).to be(false)
    [ nil, "", "short", "#{token}x", token.tr("A-Za-z", "*") ].each { |other| expect(link(other)).to be(false) }
    expect(OperatorChat.chat_id).to be_nil
  end

  it "keeps the linked chat while a new link is pending, and moves to the chat that uses it" do
    link(token_of(OperatorChat.link_url!))
    token = token_of(OperatorChat.link_url!)

    expect(OperatorChat.chat_id).to eq(chat_id)
    OperatorChat.link!(token, chat_id: 734_120_043, language: "es")

    expect(OperatorChat.chat_id).to eq(734_120_043)
    expect(OperatorChat.language).to eq("es")
  end

  it "keeps only the last link minted: an earlier token no longer links" do
    first = token_of(OperatorChat.link_url!)
    OperatorChat.link_url!

    expect(link(first)).to be(false)
  end

  it "unlinks, after which the alerts have nowhere to go" do
    link(token_of(OperatorChat.link_url!))

    OperatorChat.unlink!

    expect(OperatorChat.chat_id).to be_nil
    expect(OperatorChat.sole.linked_at).to be_nil
  end

  it "answers no chat, with a line, when the linked one does not decrypt" do
    link(token_of(OperatorChat.link_url!))
    OperatorChat.connection.execute("UPDATE operator_chats SET chat_id = 'not a ciphertext'")
    allow(Rails.logger).to receive(:error)

    expect(OperatorChat.chat_id).to be_nil
    expect(Rails.logger).to have_received(:error).with(/\Aoperator chat: the chat does not decrypt, ActiveRecord::Encryption::Errors::\w+\z/)
  end

  it "speaks the default language until a chat is linked" do
    expect(OperatorChat.language).to eq("pt-BR")
  end
end
