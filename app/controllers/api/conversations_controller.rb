module Api
  # GET /api/conversations/current (FR-18): the polling fallback, every 3 s
  # while the socket is unavailable. It answers what the streams carry, for
  # the visitor's open conversation only (SR-05): its messages, the spans of
  # its turns and whether a turn still waits for its reply. The chat reads
  # the wait from the messages since the note of 2026-11-13 on the chat's
  # stream (design §10); the flag stays for a page loaded before it.
  class ConversationsController < BaseController
    def current
      visitor = cookie_visitor
      return render(json: deleted) if visitor.nil?

      conversation = Conversation.current_for!(visitor)
      turns = conversation.turns.pluck(:inbound_message_id, :id).to_h
      messages = conversation.messages.order(:created_at, :id).to_a
      first_reply = messages.find(&:outbound?)
      codes = Reservation.where(visitor_id: visitor.id).pluck(:code)
      render json: {
        conversation: conversation.slice(:id, :language, :state, :trace_token),
        messages: messages.map do |message|
          message.stream_payload(turn_id: turns.fetch(message.id, message.turn_id), first_reply: message == first_reply,
                                 reservation_codes: codes)
        end,
        spans: TraceEvent.where(turn_id: turns.values).order(:started_at, :id).map(&:stream_payload),
        pending: conversation.turns.where.missing(:outbound_message).exists?
      }
    end

    private

    # The cookie names no visitor: it deleted its data, and the confirmation
    # went to a stream the page may not have had (FR-05); or the nightly job
    # purged it (FR-15), which the same words describe.
    def deleted
      { deleted: true, text: FixedReply.command(:delete, RequestLanguage.of(request.headers["Accept-Language"])) }
    end
  end
end
