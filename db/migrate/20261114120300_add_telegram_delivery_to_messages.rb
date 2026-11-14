# FR-19: how a Telegram reply is on its way (Telegram::Outbound). A reply
# longer than Telegram's 4,096 characters goes as consecutive messages, marked
# sent part by part, so a new attempt starts at the first part not sent
# (parts_sent); a send Telegram asked to wait for, or that failed on the way,
# is tried again by a job scheduled for its time, three attempts in all
# (send_attempts, next_attempt_at; review finding C3 of pull request #33).
# Additive, with defaults: an image before it, still serving while Kamal runs
# this in the new container, writes its rows as before, and only a Telegram
# reply reads these columns.
class AddTelegramDeliveryToMessages < ActiveRecord::Migration[8.1]
  def change
    change_table :messages, bulk: true do |t|
      t.integer :parts_sent, default: 0, null: false
      t.integer :send_attempts, default: 0, null: false
      t.datetime :next_attempt_at
    end
  end
end
