# Every table of the primary database keys its rows with a time-ordered uuid
# (uuidv7(), built into PostgreSQL 18), so ids sort by creation (design §6.5).
class CreateVisitors < ActiveRecord::Migration[8.1]
  def change
    create_table :visitors, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :channel, null: false
      # sha256 of the web visitor token, or of pepper || BSUID on WhatsApp
      # (FR-19, threat model SR-10); never the raw identifier.
      t.string :identity_hash, null: false
      t.datetime :last_seen_at
      t.timestamps
    end

    # One row per person per channel, so concurrent first messages share it (NFR-02).
    add_index :visitors, %i[channel identity_hash], unique: true
  end
end
