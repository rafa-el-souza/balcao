class CreateDailyAggregates < ActiveRecord::Migration[8.1]
  def change
    # The day's counts (design §6.5): one row per day of São Paulo, kind and
    # key, whose count each writer adds to (NFR-02). FR-17's canary is the
    # first kind written, its passed and failed runs, which FR-13's pipeline
    # uptime reads (M3-3). Counts alone: nothing of a person.
    create_table :daily_aggregates, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.date :day, null: false
      t.string :kind, null: false
      t.string :key, null: false
      t.integer :count, null: false, default: 0
      t.timestamps
    end
    add_index :daily_aggregates, %i[day kind key], unique: true
  end
end
