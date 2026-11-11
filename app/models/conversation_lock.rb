# At most one turn runs per conversation (design §6.3): a PostgreSQL advisory
# lock keyed by the conversation, held on one connection while the block runs
# and released when it ends, or by the database when the connection dies
# with its process. A second job of the same conversation waits for it. The
# lock is the session's, not a transaction's, because a turn holds it for its
# model calls, up to a minute, and must not hold a transaction open as long.
#
# Every query of the block runs on the connection that holds the lock: the
# pool keeps a thread on the connection it leased for with_connection.
module ConversationLock
  module_function

  def hold(conversation_id)
    ApplicationRecord.connection_pool.with_connection do |connection|
      key = "conversation:#{conversation_id}"
      connection.execute(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_lock(hashtextextended(?, 0))", key ]))
      begin
        yield
      ensure
        release(connection, key)
      end
    end
  end

  # A connection that broke has lost the lock already; its error must not
  # hide the one that broke the turn.
  def release(connection, key)
    released = connection.select_value(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtextextended(?, 0))", key ]))
    Rails.logger.error("conversation lock was not held at release") unless released
  rescue StandardError => e
    Rails.logger.error("conversation lock not released: #{e.class}")
  end
end
