class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products, id: :uuid, default: -> { "uuidv7()" } do |t|
      # The seed's key, so the nightly reset finds each product again (FR-15).
      t.string :sku, null: false
      t.string :name, null: false
      t.string :active_ingredient
      t.decimal :price, precision: 10, scale: 2, null: false
      t.integer :stock, null: false, default: 0
      t.boolean :prescription_required, null: false, default: false
      t.timestamps
    end

    add_index :products, :sku, unique: true
    add_check_constraint :products, "stock >= 0", name: "products_stock_not_negative"
    add_check_constraint :products, "price >= 0", name: "products_price_not_negative"
  end
end
