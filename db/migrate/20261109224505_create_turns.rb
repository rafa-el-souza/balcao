class CreateTurns < ActiveRecord::Migration[8.1]
  def change
    create_table :turns, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # One turn per inbound message (NFR-02).
      t.references :inbound_message, type: :uuid, null: false, index: { unique: true },
                                     foreign_key: { to_table: :messages, on_delete: :cascade }
      t.string :state, null: false, default: "received"
      t.string :mode
      t.string :model
      t.integer :latency_ms
      t.timestamps
    end

    add_index :turns, %i[conversation_id created_at]
    add_foreign_key :messages, :turns, on_delete: :cascade
  end
end
