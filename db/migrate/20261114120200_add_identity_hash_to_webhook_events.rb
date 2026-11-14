# Review finding T2 of pull request #32: a person's updates are read in the
# order Telegram numbered them, so an unread update keeps its sender's hashed
# identity (threat model SR-10), the one the visitor's row holds, until its
# job has read it; then it goes with the body (FR-19).
class AddIdentityHashToWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_events, :identity_hash, :string
    add_index :webhook_events, [ :identity_hash, :update_id ], where: "identity_hash IS NOT NULL"
  end
end
