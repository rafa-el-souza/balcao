class AddTheDayAndTheOperatorAlert < ActiveRecord::Migration[8.1]
  def change
    # FR-14's daily slice: the spend of the day in São Paulo, kept on the
    # month's row, since a day never straddles two months there; the charge
    # starts it over when the day changes.
    change_table :budget_states, bulk: true do |t|
      t.date :day
      t.decimal :day_spent_usd, precision: 16, scale: 8, null: false, default: 0
    end

    # The operator's own chat with the bot (threat model SR-35), linked by a
    # deep link the runbook's command mints: the chat id encrypted, and the
    # pending link's token as its digest alone, until it is used or expires.
    create_table :operator_chats, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :role, null: false, default: "operator"
      t.text :chat_id
      t.string :language
      t.datetime :linked_at
      t.string :link_digest
      t.datetime :link_expires_at
      t.timestamps
    end
    add_index :operator_chats, :role, unique: true
    add_index :operator_chats, :link_digest, unique: true

    # The alerts the bot sends to that chat (FR-14's at the cap; FR-10's
    # handoff from M2-9): each kept until it leaves, keyed by its kind and
    # what it is about, so it is sent once (NFR-02).
    create_table :operator_alerts, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :kind, null: false
      t.string :key, null: false
      t.text :text, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :sent_at
      t.string :error
      t.timestamps
    end
    add_index :operator_alerts, %i[kind key], unique: true
    add_index :operator_alerts, :status
  end
end
