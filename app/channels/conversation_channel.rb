# conversation:<id> (design §6.6): the replies, the commands' confirmations
# and the spans of one conversation, for the holder of the visitor cookie
# whose conversation it is (FR-18, threat model SR-05). A page keeps
# following a conversation a reset closed until the reset's reply names the
# next one (FR-04).
class ConversationChannel < ApplicationCable::Channel
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  private

  # Private, so a page cannot call it as an action (ActionCable's action_methods).
  def subscribed
    return reject if over_limit? || connection.identity_hash.nil?

    id = params[:conversation_id]
    return reject unless id.is_a?(String) && id.match?(UUID)

    conversation = Conversation.joins(:visitor)
                               .find_by(id:, visitors: { channel: "web", identity_hash: connection.identity_hash })
    return reject if conversation.nil?

    stream_from "conversation:#{conversation.id}"
  end
end
