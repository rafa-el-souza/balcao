# NFR-02, SR-07: every inbound message is keyed by its channel's message id
# (Message.record_inbound! refuses one without), and the database holds the
# rule too (review finding RN5 of pull request #7; design §10's standing
# trigger for the next migration, pulled by M4-4).
#
# An inbound message stored before PR-07 made the id required has none: it
# takes its own row's id as its channel's, which no channel's id is (a web
# client's, a Telegram visitor's and message's). The demo held none such
# when this was written (87 inbound messages of 87, 2026-11-15), and every
# image since PR-07 writes the id, so an image still serving while Kamal
# runs this in the new container writes nothing it refuses.
class CheckInboundMessagesHaveTheirId < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE messages SET external_id = id::text WHERE direction = 'inbound' AND external_id IS NULL"
    add_check_constraint :messages, "direction::text = 'outbound'::text OR external_id IS NOT NULL",
                         name: "messages_inbound_has_id"
  end

  def down
    remove_check_constraint :messages, name: "messages_inbound_has_id"
  end
end
