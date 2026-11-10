# One row per span, closed on finish (ADR-0010).
class CreateTraceEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :trace_events, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.references :turn, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :trace_id, null: false
      t.string :span_id, null: false
      t.string :parent_span_id
      t.string :name, null: false
      # "attributes" is a name Active Record keeps for itself.
      t.jsonb :span_attributes, null: false, default: {}
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end

    add_index :trace_events, %i[trace_id span_id], unique: true
  end
end
