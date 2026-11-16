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
  # The key travels as a parameter, never in the statement's text: on
  # Telegram it names a person by their identity's hash, and the database's
  # own log keeps a statement's text when it ends in an error, as a wait ends
  # in a reboot's fast shutdown (threat model SR-30; review finding V1 of
  # pull request #40). The lock's own result is void, which Rails does not
  # know and warned about on each connection, outside the JSON log, so the
  # statement answers 1 instead (review finding R2 of the same pull request).
  LOCK = "SELECT 1 FROM (SELECT pg_advisory_lock(hashtextextended($1, 0))) AS locked".freeze
  UNLOCK = "SELECT pg_advisory_unlock(hashtextextended($1, 0))".freeze
  # Takes the lock and gives it back at once, answering whether it was free.
  # A CASE, since PostgreSQL promises the order of a CASE's branches and not
  # of an AND's operands: the unlock runs only after a try that took the lock,
  # and an unlock run first would leave the try's lock held (the Rails
  # finder's note on pull request #48).
  TRY = "SELECT CASE WHEN pg_try_advisory_lock(hashtextextended($1, 0)) " \
        "THEN pg_advisory_unlock(hashtextextended($1, 0)) ELSE false END".freeze

  module_function

  # Whether no session holds the lock now (NFR-03's sweep asks it before it
  # takes up what may still be at work): tried without waiting, and given
  # back in the same statement, so the caller keeps no lock. A session that
  # holds the lock itself is told it is free, as PostgreSQL's advisory locks
  # are its own to take again.
  def free?(key) = ApplicationRecord.connection.select_value(TRY, "AdvisoryLock", [ key ]) == true

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
      connection.select_value(LOCK, "AdvisoryLock", [ key ])
      raise ActiveRecord::Rollback
    end
  end

  # A connection that broke has lost the lock already; its error must not
  # hide the one that broke the block.
  def release(connection, key)
    released = connection.select_value(UNLOCK, "AdvisoryLock", [ key ])
    Rails.logger.error("#{key.split(":").first} lock was not held at release") unless released
  rescue StandardError => e
    Rails.logger.error("#{key.split(":").first} lock not released: #{e.class}")
  end
end
