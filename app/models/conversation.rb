class Conversation < ApplicationRecord
  belongs_to :visitor
  # The database deletes messages and turns, and theirs, with the conversation (FR-05, FR-15).
  has_many :messages
  has_many :turns

  # 24 characters of base58, about 140 random bits (FR-12, threat model SR-11).
  has_secure_token :trace_token

  # The conversation states of FR-10; the handoff ones arrive at M2.
  enum :state, { active: "active", handoff_online: "handoff_online",
                 handoff_offline: "handoff_offline", paused: "paused" }, validate: true

  validates :language, inclusion: { in: ->(_) { I18n.available_locales.map(&:to_s) } }

  scope :current, -> { where(closed_at: nil) }

  # The visitor's open conversation, opened if there is none (FR-04). Read
  # first; concurrent first messages meet the partial unique index, and the
  # one that loses gets the conversation the other opened (NFR-02).
  def self.current_for!(visitor)
    find_by(visitor_id: visitor.id, closed_at: nil) || create_or_find_by!(visitor_id: visitor.id, closed_at: nil)
  end
end
