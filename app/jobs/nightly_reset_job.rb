# FR-15: every day at 03:00 São Paulo (config/recurring.yml) the fictional
# data is rebuilt and what passed its seven days is deleted (threat model
# SR-31, the privacy page), in four steps, each safe to run again, so a run
# retried after failing midway ends as one clean run would:
#
# 1. reservations past their pickup deadline expire; their units come back
#    with step 3;
# 2. the purge, each record by its own age: visitors not seen for seven days,
#    with everything under them (the database cascades); messages, turns,
#    spans and usage records older than seven days, a turn's spans and usage
#    going with it; conversations whose last message went, or that never had
#    one, once seven days old (a trace link dies with its conversation);
#    reservations seven days past their deadline, which outlive the
#    conversation of their turn until then; the stored Telegram updates,
#    read or not (FR-19); and the limits' counters, which live in the cache
#    under an IP address or an identity's hash (EdgeLimits.purge; design §10,
#    note of 2026-11-14, PR-17);
# 3. the catalogue returns to the seed, its stock less the units that open
#    reservations hold (CatalogueSeed), counted after the purge;
# 4. a message body an image before PR-18 wrote in plain text is encrypted
#    (threat model SR-41; review finding V1 of pull request #32).
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
    encrypted = Message.encrypt_plain_bodies
    Rails.logger.info("nightly reset: expired #{expired} reservations, reset #{reset} products; deleted " +
                      deleted.map { |name, count| "#{count} #{name}" }.join(", ") + "; encrypted #{encrypted} plain bodies")
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
      "reservations" => Reservation.where(pickup_until: ...before).delete_all,
      "stored updates" => WebhookEvent.where(created_at: ...before).delete_all,
      "limit counters" => EdgeLimits.purge(before)
    }.slice("visitors", "conversations", "messages", "turns", "spans", "usage records", "reservations",
            "stored updates", "limit counters")
  end
end
