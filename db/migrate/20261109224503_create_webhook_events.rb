class CreateWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      # The SHA-256 of the raw body: a redelivered POST is a no-op, and each
      # status notification of one message is its own event (FR-19, SR-07,
      # NFR-02). The messages it yields are keyed by Meta's message id.
      t.string :body_sha256, null: false
      t.jsonb :payload, null: false
      t.string :status, null: false, default: "received"
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :webhook_events, :body_sha256, unique: true
  end
end
