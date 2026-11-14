require "rails_helper"
require Rails.root.join("db/migrate/20261114120100_encrypt_message_bodies")

# Threat model SR-41 from PR-18: the messages stored before it were written in
# plain text, and a model that encrypts the column cannot read them. The
# migration encrypts each one where it is.
RSpec.describe "SR-41 the messages stored in plain text before PR-18 are encrypted in place" do
  def insert_plain(conversation, body)
    id = SecureRandom.uuid
    Message.connection.execute(Message.sanitize_sql([ <<~SQL.squish, id, conversation.id, body ]))
      INSERT INTO messages (id, conversation_id, channel, direction, author, source, body, created_at, updated_at)
      VALUES (?, ?, 'web', 'inbound', 'visitor', 'text', ?, now(), now())
    SQL
    id
  end

  def stored(id) = Message.connection.select_value(Message.sanitize_sql([ "SELECT body FROM messages WHERE id = ?", id ]))

  def migrate = ActiveRecord::Migration.suppress_messages { EncryptMessageBodies.new.up }

  let(:conversation) { create(:conversation) }

  it "encrypts every body stored in plain text, which the app then reads as written" do
    plain = insert_plain(conversation, "tem dipirona? meu telefone é 31 98765-4321")
    expect { Message.find(plain).body }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

    migrate

    expect(stored(plain)).not_to include("dipirona")
    expect(Message.find(plain).body).to eq("tem dipirona? meu telefone é 31 98765-4321")
  end

  it "leaves a body already encrypted as it was, and can run again" do
    encrypted = create(:message, conversation:, body: "Temos, sim.")
    before = stored(encrypted.id)

    migrate
    migrate

    expect(stored(encrypted.id)).to eq(before)
    expect(encrypted.reload.body).to eq("Temos, sim.")
  end
end
