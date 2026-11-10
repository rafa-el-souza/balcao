# One row per model call, from the response's usage fields (FR-14).
class CreateUsageRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_records, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :turn, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :model, null: false
      t.integer :input_tokens, null: false, default: 0
      # Cache writes cost more than plain input, cache reads less; both are
      # priced apart (FR-14), and the trace shows the reads (FR-12).
      t.integer :cache_creation_tokens, null: false, default: 0
      t.integer :cached_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.decimal :cost_usd, precision: 16, scale: 8, null: false, default: 0
      t.timestamps
    end
  end
end
