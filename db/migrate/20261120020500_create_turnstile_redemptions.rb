# Threat model SR-39: a Turnstile token mints one visitor. Cloudflare's own
# check of a spent token converges in seconds, so two requests close
# together may each hear its yes ("Validate the token", token reuse and
# network convergence, read on 2026-11-20): the token's SHA-256 is kept
# here once it minted, and its unique index refuses a second (review finding
# C2 of pull request #53). The key is a time-ordered uuid, as every table's
# (design §6.5). The nightly job deletes a row with the rest after seven
# days; a token lives five minutes. A new table: an image still serving
# while Kamal runs this in the new container never reads it.
class CreateTurnstileRedemptions < ActiveRecord::Migration[8.1]
  def change
    create_table :turnstile_redemptions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :digest, null: false
      t.datetime :created_at, null: false
      t.index :digest, unique: true
      t.index :created_at
    end
  end
end
