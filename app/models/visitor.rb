# A person on one channel, known only by the hash of an identifier (FR-18,
# FR-19, threat model SR-10).
#
# On Telegram the row is created by the visitor's agreement (FR-19, the
# owner's decision of 2026-11-14) and holds the one thing a reply needs that
# the hash cannot give back, the chat to send to, encrypted (SR-41); it goes
# with the row (FR-05, FR-15).
#
# One row is no person: FR-17's canary asks its question as the system
# visitor, on the system channel, which no transport sends to and no stream
# follows (Conversation#streamed?), and which the seven-day purge, the sweep
# and every public count leave (NightlyResetJob, StrandedSweepJob; #7's RS1).
class Visitor < ApplicationRecord
  CHANNELS = { web: "web", telegram: "telegram", system: "system" }.freeze
  # The system visitor's identity: the SHA-256 of a fixed name, in the shape
  # every identity has (IDENTITY_HASH), so no person's can be it.
  CANARY = Digest::SHA256.hexdigest("balcao:canary").freeze

  enum :channel, CHANNELS, validate: true

  encrypts :telegram_chat_id

  # The database deletes conversations and reservations with the visitor (FR-05).
  has_many :conversations
  has_many :reservations

  # SR-10: the SHA-256 of an identifier, as both channels compute it
  # (WebSession, Telegram::Inbound); anything else would be an identifier
  # stored as it came (review finding C7 of pull request #7).
  IDENTITY_HASH = /\A[0-9a-f]{64}\z/

  validates :identity_hash, format: { with: IDENTITY_HASH }

  # Visitors not seen for the retention period, or created and never seen
  # since, which the nightly job deletes with everything under them (FR-15,
  # SR-31; review finding N9 of pull request #7).
  scope :unseen_for, ->(period) { where("COALESCE(last_seen_at, created_at) < ?", period.ago) }

  # The visitor with this identity on this channel, created on first contact
  # and marked seen now, which keeps it out of the seven-day purge while it
  # keeps writing (FR-15; review finding R1 of pull request #7). Read first,
  # since nearly every message comes from someone already known; when two
  # first messages race, the unique index lets one row in and the other
  # caller gets that row (NFR-02).
  def self.identify!(channel:, identity_hash:)
    visitor = find_by(channel:, identity_hash:) || create_or_find_by!(channel:, identity_hash:)
    visitor.update_column(:last_seen_at, Time.current)
    visitor
  end

  # FR-17: the system visitor the canary asks as, created on the canary's
  # first run and found again on the next; when two first runs race, the
  # unique index lets one row in and the other gets it (NFR-02).
  def self.canary! = find_by(channel: "system", identity_hash: CANARY) || create_or_find_by!(channel: "system", identity_hash: CANARY)

  # The Telegram visitor its agreement creates (FR-19): the time of the
  # agreement and the chat a reply goes to, which in a private chat is the
  # sender's own id (threat model SR-42). When two agreements race, the
  # unique index lets one row in and the other caller gets it as it was.
  def self.agree!(identity_hash:, chat_id:)
    visitor = find_by(channel: "telegram", identity_hash:) ||
              create_or_find_by!(channel: "telegram", identity_hash:) do |agreed|
                agreed.telegram_chat_id = chat_id.to_s
                agreed.agreed_at = Time.current
              end
    visitor.update_column(:last_seen_at, Time.current)
    visitor
  end

  # Deletes the visitor's data on request (FR-05): releases the stock of its
  # open reservations, then deletes the visitor, and the database deletes its
  # conversations, messages, turns, trace events, usage records and
  # reservations with it (design §6.5). One transaction, and the open
  # reservations are locked first, so a second deletion, or the nightly job
  # expiring one, cannot release the same stock twice. Bookings join at M2.
  def erase!
    self.class.transaction do
      Reservation.where(visitor_id: id, state: "open").order(:id).lock.each do |reservation|
        Product.update_counters(reservation.product_id, stock: reservation.quantity)
      end
      self.class.where(id:).delete_all
    end
  end
end
