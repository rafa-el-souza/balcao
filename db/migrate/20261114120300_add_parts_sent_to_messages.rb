# FR-19: a reply longer than Telegram's 4,096 characters goes as consecutive
# messages, and it is marked sent part by part, so a new attempt starts at the
# first part not sent (Telegram::Outbound). Additive, with a default: an image
# before it, still serving while Kamal runs this in the new container, writes
# its rows as before (the column reads 0 there, and only a Telegram reply
# reads it).
class AddPartsSentToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :parts_sent, :integer, default: 0, null: false
  end
end
