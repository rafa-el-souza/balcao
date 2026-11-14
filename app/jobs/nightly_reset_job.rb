# FR-15: every day at 03:00 São Paulo (config/recurring.yml) the fictional
# data is rebuilt and what passed its seven days is deleted (threat model
# SR-31, the privacy page), in three steps, each safe to run again, so a run
# retried after failing midway ends as one clean run would:
#
# 1. reservations past their pickup deadline expire; their units come back
#    with step 3;
# 2. the purge, each record by its own age: visitors not seen for seven days,
#    with everything under them (the database cascades); messages, turns,
#    spans and usage records older than seven days, a turn's spans and usage
#    going with it; conversations whose last message went, or that never had
#    one, once seven days old (a trace link dies with its conversation); and
#    reservations seven days past their deadline, which outlive the
#    conversation of their turn until then;
# 3. the catalogue returns to the seed, its stock less the units that open
#    reservations hold (CatalogueSeed), counted after the purge.
#
# The month's spend is the budget's row, which no step touches (FR-14).
# Bookings' slots join at M2. The log line counts, and names nothing.
class NightlyResetJob < ApplicationJob
  RETENTION = 7.days

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform
    now = Time.current
    expired = Reservation.open.where(pickup_until: ..now).update_all(state: "expired", updated_at: now)
    deleted = purge(now - RETENTION)
    reset = CatalogueSeed.seed!
    Rails.logger.info("nightly reset: expired #{expired} reservations, reset #{reset} products; deleted " +
                      deleted.map { |name, count| "#{count} #{name}" }.join(", "))
  end

  private

  def purge(before)
    {
      "visitors" => Visitor.unseen_for(RETENTION).delete_all,
      "messages" => Message.where(created_at: ...before).delete_all,
      "turns" => Turn.where(created_at: ...before).delete_all,
      "spans" => TraceEvent.where(created_at: ...before).delete_all,
      "usage records" => UsageRecord.where(created_at: ...before).delete_all,
      "conversations" => Conversation.where(created_at: ...before).where.missing(:messages).delete_all,
      "reservations" => Reservation.where(pickup_until: ...before).delete_all
    }.slice("visitors", "conversations", "messages", "turns", "spans", "usage records", "reservations")
  end
end
