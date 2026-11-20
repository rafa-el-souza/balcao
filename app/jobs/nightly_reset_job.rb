# FR-15: every day at 03:00 São Paulo (config/recurring.yml) the fictional
# data is rebuilt and what passed its seven days is deleted (threat model
# SR-31, the privacy page), in steps, each safe to run again, so a run
# retried after failing midway ends as one clean run would:
#
# 1. reservations past their pickup deadline expire; their units come back
#    with step 3;
# 2. the purge, each record by its own age: messages, turns, spans and usage
#    records older than seven days, a turn's spans and usage going with it;
#    then visitors not seen for seven days, with everything still under them
#    (the database cascades), which is little, since a visitor silent for
#    seven days wrote nothing since and its older rows went just before (the
#    finder's note on pull request #40: a batch of visitors deleted first
#    took all their rows in one statement); conversations whose last message
#    went, or that never had one, once seven days old (a trace link dies with
#    its conversation); reservations seven days past their deadline, which
#    outlive the conversation of their turn until then; the stored Telegram
#    updates, read or not (FR-19); and the digests of the Turnstile tokens
#    that minted a web visitor (threat model SR-39);
# 3. the catalogue returns to the seed, its stock less the units that open
#    reservations hold (CatalogueSeed), counted after the purge;
# 4. a message body an image before PR-18 wrote in plain text is encrypted
#    (threat model SR-41; review finding V1 of pull request #32);
# 5. on the other databases: the failed jobs older than seven days, whose
#    stored error may quote what a visitor wrote (the dead letter of
#    ProcessTurnJob; review finding C4 of pull request #30, the owner's word
#    of 2026-11-15), and the limits' counters, which live in the cache under
#    an IP address or an identity's hash (EdgeLimits.purge; design §10, note
#    of 2026-11-14, PR-17).
#
# Every step runs even when one before it failed, so one that breaks (a
# delete past the statement timeout, the cache's database down) stops
# neither the catalogue's reset nor the purge of the rest; each step that
# fails writes an error line with its error's class and backtrace, never its
# message (SR-30), the summary names it in place of its count and goes at
# WARN, and the job raises the first error at the end, for its retry (review
# findings S5 of pull request #29, V2 and M5 of #32, the triage's A-V1, and
# H3 of #40). Each delete goes in batches, so
# no one statement grows with a week of a busy demo past the statement
# timeout (SR-20).
#
# The month's spend is the budget's row, which no step touches (FR-14).
# Bookings' slots join at M2. The log line counts, and names nothing.
class NightlyResetJob < ApplicationJob
  RETENTION = 7.days
  BATCH = 1_000

  # The purge's deletes, in the order they run: the records by their own
  # age first, so the database's cascade from a visitor finds little left;
  # a conversation goes once its messages have.
  PURGE = {
    "messages" => ->(before) { Message.where(created_at: ...before) },
    "turns" => ->(before) { Turn.where(created_at: ...before) },
    "spans" => ->(before) { TraceEvent.where(created_at: ...before) },
    "usage records" => ->(before) { UsageRecord.where(created_at: ...before) },
    "visitors" => ->(_before) { Visitor.unseen_for(RETENTION) },
    "conversations" => ->(before) { Conversation.where(created_at: ...before).where.missing(:messages) },
    "reservations" => ->(before) { Reservation.where(pickup_until: ...before) },
    "stored updates" => ->(before) { WebhookEvent.where(created_at: ...before) },
    "Turnstile tokens" => ->(before) { TurnstileRedemption.where(created_at: ...before) }
  }.freeze
  # The order of the log line.
  DELETED = [ "visitors", "conversations", "messages", "turns", "spans", "usage records", "reservations",
              "stored updates", "Turnstile tokens", "failed jobs", "limit counters" ].freeze

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform
    now = Time.current
    before = now - RETENTION
    @failures = {}
    expired = step("expiring reservations") { Reservation.open.where(pickup_until: ..now).update_all(state: "expired", updated_at: now) }
    deleted = PURGE.to_h { |name, scope| [ name, step(name) { scope.call(before).in_batches(of: BATCH).delete_all } ] }
    reset = step("resetting products") { CatalogueSeed.seed! }
    encrypted = step("encrypting plain bodies") { Message.encrypt_plain_bodies }
    deleted["failed jobs"] = step("failed jobs") { failed_jobs(before) }
    deleted["limit counters"] = step("limit counters") { EdgeLimits.purge(before, batch: BATCH) }
    Rails.logger.public_send(@failures.any? ? :warn : :info, line(expired, reset, deleted, encrypted))
    raise @failures.values.first if @failures.any?
  end

  private

  # The step's count, or nil when it raised; the error is kept for the end,
  # and its line names it by its class with the backtrace's frames of the
  # app, which name only code.
  def step(name)
    yield
  rescue StandardError => e
    @failures[name] = e
    Rails.logger.error("nightly reset: #{name} failed: #{e.class}\n#{Rails.backtrace_cleaner.clean(Array(e.backtrace)).first(8).join("\n")}")
    nil
  end

  # Solid Queue keeps a job's last error as a failed execution (the dead
  # letter the console reads, FR-16), with the error's message, which may
  # quote what a visitor wrote; such a job goes with it, as Solid Queue's own
  # discard does. Any other adapter (development's, the specs') keeps none.
  def failed_jobs(before)
    return 0 unless self.class.queue_adapter.is_a?(ActiveJob::QueueAdapters::SolidQueueAdapter)

    old = SolidQueue::FailedExecution.where(created_at: ...before)
    count = old.count
    old.discard_all_in_batches(batch_size: BATCH)
    count
  end

  def line(expired, reset, deleted, encrypted)
    "nightly reset: #{told("expired %d reservations", expired, "expiring reservations")}, " \
      "#{told("reset %d products", reset, "resetting products")}; deleted " +
      DELETED.map { |name| told("%d #{name}", deleted[name], name) }.join(", ") +
      "; #{told("encrypted %d plain bodies", encrypted, "encrypting plain bodies")}"
  end

  def told(format, count, name)
    count.nil? ? "#{name} failed: #{@failures.fetch(name).class}" : Kernel.format(format, count)
  end
end
