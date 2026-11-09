class CreateReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :visitor, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :product, type: :uuid, null: false, foreign_key: true
      t.string :code, null: false
      t.integer :quantity, null: false
      # The SDK tool_use id of the call that created it, injected by the runner (NFR-02, SR-16).
      t.string :idempotency_key, null: false
      t.datetime :pickup_until, null: false
      t.string :state, null: false, default: "open"
      t.timestamps
    end

    add_index :reservations, :idempotency_key, unique: true
    add_index :reservations, :code, unique: true
    add_index :reservations, %i[visitor_id state]
    add_check_constraint :reservations, "quantity > 0", name: "reservations_quantity_positive"
  end
end
