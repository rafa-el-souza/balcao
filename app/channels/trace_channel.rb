# trace:<token> (design §6.6): a conversation's spans for its trace page,
# read only, for whoever holds the token (FR-12); the token is the whole
# credential (threat model SR-11), and each lookup counts against the
# source's limit.
class TraceChannel < ApplicationCable::Channel
  private

  # Private, so a page cannot call it as an action (ActionCable's action_methods).
  def subscribed
    return reject if over_limit?

    token = params[:token]
    return reject unless token.is_a?(String) && Conversation.exists?(trace_token: token)

    stream_from "trace:#{token}"
  end
end
