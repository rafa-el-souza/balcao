require "rails_helper"

# FR-18: when the socket is unavailable, the page polls the current
# conversation every 3 s; the answer carries what the streams would have.
RSpec.describe "FR-18 SR-05 GET /api/conversations/current, the polling fallback", type: :request do
  it "refuses a request without the visitor cookie" do
    get "/api/conversations/current"

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "session")
  end

  context "with a session" do
    let!(:visitor) { start_session(language: "es") }
    let(:conversation) { visitor.conversations.sole }
    let(:inbound) { Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "¿tienen dipirona?") }
    let(:turn) { Turn.for_inbound!(inbound) }

    it "answers the open conversation, its messages in order, its spans and whether a turn waits for its reply" do
      turn
      span = create(:trace_event, turn:, name: "balcao.turn", span_attributes: { "balcao.channel" => "web" })

      get "/api/conversations/current"

      expect(response).to have_http_status(:ok)
      expect(json["conversation"]).to eq("id" => conversation.id, "language" => "es", "state" => "active",
                                         "trace_token" => conversation.trace_token)
      expect(json["messages"]).to eq [ {
        "id" => inbound.id, "client_id" => inbound.external_id, "conversation_id" => conversation.id,
        "turn_id" => turn.id, "author" => "visitor", "notice" => nil, "body" => "¿tienen dipirona?",
        "created_at" => inbound.created_at.iso8601(3)
      } ]
      expect(json["spans"]).to eq [ TraceRecorder.payload(
        span.attributes.symbolize_keys.merge(attributes: span.span_attributes)
      )[:span].deep_stringify_keys ]
      expect(json["pending"]).to be true
    end

    it "carries the reply in the shape the stream sends it, and no turn waits once it has one" do
      reply = Message.record_outbound!(turn:, body: "Sí, tenemos.")

      get "/api/conversations/current"

      expect(json["messages"].last).to eq(
        "id" => reply.id, "client_id" => nil, "conversation_id" => conversation.id, "turn_id" => turn.id,
        "author" => "bot", "notice" => nil, "body" => "Sí, tenemos.", "created_at" => reply.created_at.iso8601(3)
      )
      expect(json["pending"]).to be false
    end

    # Review finding N1 of pull request #17: the notice was told apart by
    # today's text, so a reply stored under an earlier wording kept it in its
    # body; the first reply of a conversation is the one that carries it.
    it "parts the notice of a conversation's first reply whatever its wording, and nothing from a later one" do
      Message.record_outbound!(turn:, body: "Aviso de antes: outro texto.\n\n¡Hola!")
      later = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "¿y?"))
      Message.record_outbound!(turn: later, body: "Sí.\n\nY también en gotas.")

      get "/api/conversations/current"

      replies = json["messages"].select { |message| message["author"] == "bot" }
      expect(replies.map { |message| message.slice("notice", "body") }).to eq [
        { "notice" => "Aviso de antes: outro texto.", "body" => "¡Hola!" },
        { "notice" => nil, "body" => "Sí.\n\nY también en gotas." }
      ]
    end

    it "carries a first reply's notice apart from its body (FR-01, design §10, note of 2026-11-12)" do
      Message.record_outbound!(turn:, body: FixedReply.with_notice("¡Hola!", "es"))

      get "/api/conversations/current"

      expect(json["messages"].last).to include("notice" => FixedReply.notice("es"), "body" => "¡Hola!")
    end

    it "follows a reset to the conversation it opened (FR-04)" do
      conversation.update!(closed_at: Time.current)
      opened = Conversation.current_for!(visitor)

      get "/api/conversations/current"

      expect(json.dig("conversation", "id")).to eq opened.id
    end

    it "never shows another visitor's conversation" do
      other = Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32))
      theirs = Conversation.current_for!(other)
      Message.record_inbound!(conversation: theirs, external_id: SecureRandom.uuid, body: "segredo")

      get "/api/conversations/current"

      expect(response.body).not_to include("segredo", theirs.id, theirs.trace_token)
    end

    it "FR-05 answers the deletion's confirmation once the visitor is gone, in the page's language, creating nothing" do
      visitor.erase!

      expect { get "/api/conversations/current", headers: { "Accept-Language" => "es-ES,es;q=0.9,pt;q=0.5" } }
        .not_to change(Visitor, :count)
      expect(response).to have_http_status(:ok)
      expect(json).to eq("deleted" => true, "text" => I18n.t("commands.delete", locale: :es))
    end
  end
end
