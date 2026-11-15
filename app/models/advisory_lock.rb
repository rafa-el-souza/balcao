# A PostgreSQL advisory lock keyed by a name, held on one connection while the
# block runs and released when it ends, or by the database when the
# connection dies with its process; a second holder of the same name waits.
# The lock is the session's, not a transaction's, so the block may run for a
# minute without holding a transaction open, and its own transactions commit
# as they go: a job it enqueues sees them (ConversationLock, TelegramUpdateJob).
#
# Every query of the block runs on the connection that holds the lock: the
# pool keeps a thread on the connection it leased for with_connection.
module AdvisoryLock
  module_function

  def hold(key)
    ApplicationRecord.connection_pool.with_connection do |connection|
      acquire(connection, key)
      begin
        yield
      ensure
        release(connection, key)
      end
    end
  end

  # Waiting for the holder ahead is not a stuck statement (config/database.yml):
  # a job may wait the earlier turn's sixty seconds and more. The wait runs in a
  # short transaction of its own with neither timeout, which SET LOCAL lifts
  # until that transaction ends; the lock is the session's, so it outlives the
  # transaction and the timeouts are back for the block.
  #
  # The transaction is rolled back, not committed: it writes nothing, and
  # inside an open transaction (an eval attempt's, lib/evals/pipeline.rb) it
  # is a savepoint, whose release would keep the SET LOCAL until the outer
  # transaction ended, while a rollback to it undoes the SET LOCAL there and
  # then (#39's line for the owner). A session's lock survives a rollback.
  def acquire(connection, key)
    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = 0")
      connection.execute("SET LOCAL lock_timeout = 0")
      connection.execute(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_lock(hashtextextended(?, 0))", key ]))
      raise ActiveRecord::Rollback
    end
  end

  # A connection that broke has lost the lock already; its error must not
  # hide the one that broke the block.
  def release(connection, key)
    released = connection.select_value(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtextextended(?, 0))", key ]))
    Rails.logger.error("#{key.split(":").first} lock was not held at release") unless released
  rescue StandardError => e
    Rails.logger.error("#{key.split(":").first} lock not released: #{e.class}")
  end
end
