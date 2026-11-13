module Api
  # POST /api/messages (FR-18): a message ({id, text}) or an opener ({id,
  # say}), stored once per client id with its turn, which is enqueued
  # (NFR-02). Answers 202 with the turn and the message as the server stored
  # it, in the shape the stream and GET /api/conversations/current carry: the
  # page puts it in its place in the server's order, so the reply the stream
  # brings is drawn after it without a fetch (design §10, note of 2026-11-13
  # on the chat's stream). The reply arrives on the stream, or by polling.
  class MessagesController < BaseController
    MAX_TEXT = 1_000
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    KEYS = [ %w[id text], %w[id say] ].freeze

    def create
      identity_hash = require_session!
      id, text = message(json_body)
      # A visitor who deleted its data starts over with the same token (FR-05).
      visitor = Visitor.identify!(channel: "web", identity_hash:)
      turn = Intake.new(visitor).receive!(external_id: id.downcase, body: text)

      render json: { turn_id: turn.id, message_id: turn.inbound_message_id, conversation_id: turn.conversation_id,
                     message: turn.inbound_message.stream_payload(turn_id: turn.id, first_reply: false) },
             status: :accepted
    rescue ActiveRecord::RecordNotUnique
      refuse!(:conflict, "id")
    end

    private

    # SR-04's schema: exactly an id (a UUID) and either a text of 1 to 1,000
    # characters or an opener's key (FR-21, SR-34).
    def message(body)
      refuse!(:unprocessable_content, "schema") unless KEYS.include?(body.keys.sort)
      id = body["id"]
      refuse!(:unprocessable_content, "id") unless id.is_a?(String) && id.match?(UUID)

      [ id, body.key?("say") ? opener(body["say"]) : text(body["text"]) ]
    end

    def text(value)
      refuse!(:unprocessable_content, "text") unless value.is_a?(String)
      text = value.delete("\u0000").strip
      refuse!(:unprocessable_content, "text") if text.empty? || text.length > MAX_TEXT
      text
    end

    def opener(key)
      Openers.current.fetch(key)&.text or refuse!(:unprocessable_content, "say")
    end
  end
end
