# A WhatsApp event as Meta sent it, stored before any processing (FR-19, SR-09).
class WebhookEvent < ApplicationRecord
  has_many :messages

  enum :status, { received: "received", processed: "processed", ignored: "ignored", failed: "failed" },
       validate: true

  validates :external_id, :received_at, presence: true
  validates :payload, exclusion: { in: [ nil ] }

  # Stores the event keyed by Meta's message id. A redelivery meets the unique
  # index and returns the event already stored, which the caller recognises by
  # previously_new_record? being false (SR-07, NFR-02).
  def self.record!(external_id:, payload:, received_at: Time.current)
    create_or_find_by!(external_id:) do |event|
      event.payload = payload
      event.received_at = received_at
    end
  end
end
