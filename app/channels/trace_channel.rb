# trace:<token> (design §6.6): a conversation's spans for its trace page,
# read only, for whoever holds the token (FR-12); the token is the whole
# credential (threat model SR-11), and each lookup counts against the
# source's limit.
class TraceChannel < ApplicationCable::Channel
  private

  # Private, so a page cannot call it as an action (ActionCable's action_methods).
  def subscribed
    return reject if over_limit?

    conversation = Conversation.find_by_trace_token(params[:token])
    return reject if conversation.nil?

    stream_from "trace:#{conversation.trace_token}"
  end
end
