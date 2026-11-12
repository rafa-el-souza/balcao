module Api
  # GET /api/traces/:token (FR-12, design §6.6): a conversation's trace page,
  # for whoever holds its link, cookie or not (a WhatsApp visitor has none).
  # The token is the whole credential (threat model SR-11): 128 random bits
  # and more, counted at the edge like every API request, 404 on a miss, and
  # no listing. The answer is that conversation alone (SR-05): each of its
  # turns' messages, with the turn (a reset's reply among them, though it opens
  # the conversation the reset started, FR-04), and its spans, in the shape the
  # trace stream sends them, so the page follows it live.
  class TracesController < BaseController
    # A token of bytes that are not UTF-8 reaches the action, binary, and is a
    # miss like any other, not the router's 400 (review finding S5 of pull
    # request #17).
    skip_parameter_encoding :show

    def show
      conversation = Conversation.find_by_trace_token(params[:token])
      return render(json: { error: "not_found" }, status: :not_found) if conversation.nil?

      turns = conversation.turns.includes(:inbound_message, :outbound_message).order(:created_at, :id).to_a
      render json: {
        conversation: { started_at: conversation.created_at.iso8601(3) },
        messages: messages_of(turns),
        spans: TraceEvent.where(turn_id: turns.map(&:id)).order(:started_at, :id).map(&:stream_payload)
      }
    end

    private

    def messages_of(turns)
      pairs = turns.flat_map { |turn| [ turn.inbound_message, turn.outbound_message ].compact.map { |message| [ message, turn ] } }
      first_replies = Message.first_reply_ids(pairs.filter_map { |message, _| message.conversation_id if message.outbound? })
      pairs.sort_by { |message, _| [ message.created_at, message.id ] }
           .map { |message, turn| message.trace_payload(turn_id: turn.id, first_reply: first_replies.include?(message.id)) }
    end
  end
end
