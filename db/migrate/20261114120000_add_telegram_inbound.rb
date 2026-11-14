# PR-18, the Telegram channel's inbound side (FR-19, ADR-0016, design §6.5):
#
# - a Telegram visitor's row holds the chat id a reply needs, encrypted
#   (threat model SR-10, SR-41), and the time of the agreement that created it;
# - a stored update is keyed by Telegram's update_id (SR-07) in place of the
#   WhatsApp design's digest of the body, keeps its kind, and keeps its body,
#   encrypted, only until its job has read it (FR-19, SR-41).
#
# The WhatsApp webhook never ran, so no stored event and no WhatsApp visitor
# exists to move: a row would stop the migration at its NOT NULL.
class AddTelegramInbound < ActiveRecord::Migration[8.1]
  def change
    add_column :visitors, :telegram_chat_id, :text
    add_column :visitors, :agreed_at, :datetime

    remove_index :webhook_events, :body_sha256, unique: true
    remove_column :webhook_events, :body_sha256, :string, null: false
    remove_column :webhook_events, :payload, :jsonb, null: false
    add_column :webhook_events, :update_id, :bigint, null: false
    add_column :webhook_events, :kind, :string, null: false
    add_column :webhook_events, :payload, :text
    add_index :webhook_events, :update_id, unique: true
  end
end
