class CreateConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :conversations, id: :uuid, default: -> { "uuidv7()" } do |t|
      # Deleting a visitor deletes everything under it (FR-05).
      t.references :visitor, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :state, null: false, default: "active"
      t.string :language, null: false, default: "pt-BR"
      t.string :trace_token, null: false
      t.datetime :closed_at
      t.timestamps
    end

    add_index :conversations, :trace_token, unique: true
    # At most one open conversation per visitor (FR-04, NFR-02).
    add_index :conversations, :visitor_id, unique: true, where: "closed_at IS NULL",
                                           name: "index_conversations_one_open_per_visitor"
  end
end
