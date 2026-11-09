class CreateWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      # Meta's message id: a redelivered event is a no-op (FR-19, SR-07, NFR-02).
      t.string :external_id, null: false
      t.jsonb :payload, null: false
      t.string :status, null: false, default: "received"
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :webhook_events, :external_id, unique: true
  end
end
