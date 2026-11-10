class CreateReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservations, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :visitor, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      # The turn that asked for it: with the product, the idempotency key
      # (NFR-02). A reservation outlives its turn, so an open one survives the
      # purge of an old conversation still in use (review finding R3 of #7).
      t.references :turn, type: :uuid, foreign_key: { on_delete: :nullify }, index: false
      t.references :product, type: :uuid, null: false, foreign_key: true
      t.string :code, null: false
      t.integer :quantity, null: false
      t.datetime :pickup_until, null: false
      t.string :state, null: false, default: "open"
      t.timestamps
    end

    # A turn run again after a failure calls the model again, which sends a new
    # tool_use id for the same request; the turn and the product stay the same.
    add_index :reservations, %i[turn_id product_id], unique: true
    add_index :reservations, :code, unique: true
    add_index :reservations, %i[visitor_id state]
    add_check_constraint :reservations, "quantity > 0", name: "reservations_quantity_positive"
  end
end
