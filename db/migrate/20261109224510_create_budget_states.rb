class CreateBudgetStates < ActiveRecord::Migration[8.1]
  def change
    create_table :budget_states, id: :uuid, default: -> { "uuidv7()" } do |t|
      # The calendar month in São Paulo, "2026-11" (FR-14, design §1.4).
      t.string :month, null: false
      t.decimal :spent_usd, precision: 16, scale: 8, null: false, default: 0
      t.string :automatic_mode, null: false, default: "normal"
      t.string :forced_mode
      t.timestamps
    end

    add_index :budget_states, :month, unique: true
  end
end
