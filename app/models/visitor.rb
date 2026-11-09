# A person on one channel, known only by the hash of an identifier (FR-19,
# threat model SR-10).
class Visitor < ApplicationRecord
  CHANNELS = { web: "web", whatsapp: "whatsapp" }.freeze

  enum :channel, CHANNELS, validate: true

  # The database deletes conversations and reservations with the visitor (FR-05).
  has_many :conversations
  has_many :reservations

  validates :identity_hash, presence: true

  # The visitor with this identity on this channel, created on first contact.
  # Read first, since nearly every message comes from someone already known;
  # when two first messages race, the unique index lets one row in and the
  # other caller gets that row (NFR-02).
  def self.identify!(channel:, identity_hash:)
    find_by(channel:, identity_hash:) || create_or_find_by!(channel:, identity_hash:)
  end
end
