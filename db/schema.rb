# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_11_181000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "fuzzystrmatch"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "unaccent"

  create_table "budget_states", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "month", null: false
    t.decimal "spent_usd", precision: 16, scale: 8, default: "0.0", null: false
    t.string "automatic_mode", default: "normal", null: false
    t.string "forced_mode"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["month"], name: "index_budget_states_on_month", unique: true
  end

  create_table "conversations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "visitor_id", null: false
    t.string "state", default: "active", null: false
    t.string "language", default: "pt-BR", null: false
    t.string "trace_token", null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["trace_token"], name: "index_conversations_on_trace_token", unique: true
    t.index ["visitor_id"], name: "index_conversations_on_visitor_id"
    t.index ["visitor_id"], name: "index_conversations_one_open_per_visitor", unique: true, where: "(closed_at IS NULL)"
  end

  create_table "messages", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.uuid "turn_id"
    t.uuid "webhook_event_id"
    t.string "channel", null: false
    t.string "direction", null: false
    t.string "author", null: false
    t.string "source", default: "text", null: false
    t.text "body", null: false
    t.string "external_id"
    t.string "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel", "external_id"], name: "index_messages_on_channel_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["turn_id"], name: "index_messages_one_outbound_per_turn", unique: true, where: "(turn_id IS NOT NULL)"
    t.index ["webhook_event_id"], name: "index_messages_on_webhook_event_id"
    t.check_constraint "direction::text = 'outbound'::text OR turn_id IS NULL", name: "messages_turn_only_on_outbound"
  end

  create_table "products", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "sku", null: false
    t.string "name", null: false
    t.string "active_ingredient"
    t.decimal "price", precision: 10, scale: 2, null: false
    t.integer "stock", default: 0, null: false
    t.boolean "prescription_required", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "listed", default: true, null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
    t.check_constraint "price >= 0::numeric", name: "products_price_not_negative"
    t.check_constraint "stock >= 0", name: "products_stock_not_negative"
  end

  create_table "reservations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "visitor_id", null: false
    t.uuid "turn_id"
    t.uuid "product_id", null: false
    t.string "code", null: false
    t.integer "quantity", null: false
    t.datetime "pickup_until", null: false
    t.string "state", default: "open", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_reservations_on_code", unique: true
    t.index ["product_id"], name: "index_reservations_on_product_id"
    t.index ["turn_id", "product_id"], name: "index_reservations_on_turn_id_and_product_id", unique: true
    t.index ["visitor_id", "state"], name: "index_reservations_on_visitor_id_and_state"
    t.check_constraint "quantity > 0", name: "reservations_quantity_positive"
  end

  create_table "trace_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "turn_id", null: false
    t.string "trace_id", null: false
    t.string "span_id", null: false
    t.string "parent_span_id"
    t.string "name", null: false
    t.jsonb "span_attributes", default: {}, null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["trace_id", "span_id"], name: "index_trace_events_on_trace_id_and_span_id", unique: true
    t.index ["turn_id"], name: "index_trace_events_on_turn_id"
  end

  create_table "turns", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.uuid "inbound_message_id", null: false
    t.string "state", default: "received", null: false
    t.string "mode"
    t.string "model"
    t.integer "latency_ms"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_turns_on_conversation_id_and_created_at"
    t.index ["inbound_message_id"], name: "index_turns_on_inbound_message_id", unique: true
  end

  create_table "usage_records", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "turn_id", null: false
    t.string "model", null: false
    t.integer "input_tokens", default: 0, null: false
    t.integer "cache_creation_tokens", default: 0, null: false
    t.integer "cached_tokens", default: 0, null: false
    t.integer "output_tokens", default: 0, null: false
    t.decimal "cost_usd", precision: 16, scale: 8, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["turn_id"], name: "index_usage_records_on_turn_id"
  end

  create_table "visitors", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "channel", null: false
    t.string "identity_hash", null: false
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel", "identity_hash"], name: "index_visitors_on_channel_and_identity_hash", unique: true
  end

  create_table "webhook_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "body_sha256", null: false
    t.jsonb "payload", null: false
    t.string "status", default: "received", null: false
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["body_sha256"], name: "index_webhook_events_on_body_sha256", unique: true
  end

  add_foreign_key "conversations", "visitors", on_delete: :cascade
  add_foreign_key "messages", "conversations", on_delete: :cascade
  add_foreign_key "messages", "turns", on_delete: :cascade
  add_foreign_key "messages", "webhook_events", on_delete: :nullify
  add_foreign_key "reservations", "products"
  add_foreign_key "reservations", "turns", on_delete: :nullify
  add_foreign_key "reservations", "visitors", on_delete: :cascade
  add_foreign_key "trace_events", "turns", on_delete: :cascade
  add_foreign_key "turns", "conversations", on_delete: :cascade
  add_foreign_key "turns", "messages", column: "inbound_message_id", on_delete: :cascade
  add_foreign_key "usage_records", "turns", on_delete: :cascade
end
