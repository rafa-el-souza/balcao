class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :conversation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # The turn that produced an outbound message; its foreign key arrives with
      # the turns table. Inbound messages are keyed on that table instead.
      t.uuid :turn_id
      t.references :webhook_event, type: :uuid, foreign_key: { on_delete: :nullify }
      # The visitor's channel, copied so that the channel's id is unique per channel.
      t.string :channel, null: false
      t.string :direction, null: false
      t.string :author, null: false
      t.string :source, null: false, default: "text"
      t.text :body, null: false
      t.string :external_id
      t.string :status
      t.timestamps
    end

    add_index :messages, %i[conversation_id created_at]
    # Inbound by the channel's message id (NFR-02, SR-07); web messages carry none.
    add_index :messages, %i[channel external_id], unique: true, where: "external_id IS NOT NULL"
    # One outbound message per turn (NFR-02).
    add_index :messages, :turn_id, unique: true, where: "turn_id IS NOT NULL",
                                   name: "index_messages_one_outbound_per_turn"
    add_check_constraint :messages, "direction = 'outbound' OR turn_id IS NULL",
                         name: "messages_turn_only_on_outbound"
  end
end
