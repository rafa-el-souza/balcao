# A person on one channel, known only by the hash of an identifier (FR-19,
# threat model SR-10).
class Visitor < ApplicationRecord
  CHANNELS = { web: "web", whatsapp: "whatsapp" }.freeze

  enum :channel, CHANNELS, validate: true

  # The database deletes conversations and reservations with the visitor (FR-05).
  has_many :conversations
  has_many :reservations

  validates :identity_hash, presence: true

  # Visitors not seen for the retention period, or created and never seen
  # since, which the nightly job deletes with everything under them (FR-15,
  # SR-31; review finding N9 of pull request #7).
  scope :unseen_for, ->(period) { where("COALESCE(last_seen_at, created_at) < ?", period.ago) }

  # The visitor with this identity on this channel, created on first contact.
  # Read first, since nearly every message comes from someone already known;
  # when two first messages race, the unique index lets one row in and the
  # other caller gets that row (NFR-02).
  def self.identify!(channel:, identity_hash:)
    find_by(channel:, identity_hash:) || create_or_find_by!(channel:, identity_hash:)
  end
end
