# At most one turn runs per conversation (design §6.3): an advisory lock keyed
# by the conversation (AdvisoryLock), held while the turn runs; a second job
# of the same conversation waits for it. The lock is the session's, not a
# transaction's, because a turn holds it for its model calls, up to a minute,
# and must not hold a transaction open as long.
module ConversationLock
  module_function

  def hold(conversation_id, &) = AdvisoryLock.hold("conversation:#{conversation_id}", &)
end
