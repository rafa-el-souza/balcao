require "rails_helper"

# FR-12: the trace page of a conversation, for whoever holds its link (a
# WhatsApp visitor has no cookie); the token is the whole credential (threat
# model SR-11) and the page shows only that conversation (SR-05, SR-12). The
# page sends the token in a header, so no request line carries it (review
# finding V3 of pull request #17).
RSpec.describe "FR-12 SR-11 SR-12 GET /api/trace, a conversation's trace page", type: :request do
  let(:conversation) { create(:conversation, language: "es") }

  def look_up(token, env: {}) = get("/api/trace", headers: { "X-Trace-Token" => token }, env:)

  def turn_in(conversation, text, reply: nil, at: Time.current)
    travel_to(at) do
      inbound = Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text)
      turn = Turn.for_inbound!(inbound)
      Message.record_outbound!(turn:, body: reply) if reply
      turn
    end
  end

  def span_of(turn, name = "balcao.turn") = create(:trace_event, turn:, name:, span_attributes: { "balcao.channel" => "web" })

  it "answers the conversation's start, its turns' messages and its spans, each with its turn, without the visitor cookie" do
    started = Time.zone.local(2026, 11, 12, 12, 3, 41)
    conversation.update!(created_at: started)
    first = turn_in(conversation, "¿tienen dipirona?", reply: FixedReply.with_notice("Sí, tenemos.", "es"), at: started)
    second = turn_in(conversation, "¿y en gotas?", at: started + 1.minute)
    spans = [ span_of(first), span_of(second) ]

    look_up(conversation.trace_token)

    expect(response).to have_http_status(:ok)
    expect(json["conversation"]).to eq("started_at" => started.iso8601(3))
    expect(json["messages"]).to eq [
      { "id" => first.inbound_message_id, "turn_id" => first.id, "author" => "visitor", "notice" => nil,
        "body" => "¿tienen dipirona?", "created_at" => first.inbound_message.created_at.iso8601(3) },
      { "id" => first.outbound_message.id, "turn_id" => first.id, "author" => "bot", "notice" => FixedReply.notice("es"),
        "body" => "Sí, tenemos.", "created_at" => first.outbound_message.created_at.iso8601(3) },
      { "id" => second.inbound_message_id, "turn_id" => second.id, "author" => "visitor", "notice" => nil,
        "body" => "¿y en gotas?", "created_at" => second.inbound_message.created_at.iso8601(3) }
    ]
    expect(json["spans"]).to eq(spans.map { |span| span.stream_payload.deep_stringify_keys })
    expect(json["spans"].map { |span| span["turn_id"] }).to eq([ first.id, second.id ])
  end

  it "parts the notice of a conversation's first reply whatever its wording (review finding N1 of pull request #17)" do
    turn_in(conversation, "hola", reply: "Aviso de antes: outro texto.\n\n¡Hola!")

    look_up(conversation.trace_token)

    expect(json["messages"].last).to include("notice" => "Aviso de antes: outro texto.", "body" => "¡Hola!")
  end

  # Review finding N3 of pull request #17: a browser may keep an answer it is
  # allowed to cache, and these carry the conversation's words, which a
  # deletion is to erase (FR-05).
  it "tells the browser to keep no copy of the conversation's words, here and in the polling answer" do
    look_up(conversation.trace_token)
    expect(response.headers["Cache-Control"]).to include("no-store")

    start_session
    get "/api/conversations/current"
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  # Review findings C2 and S5 of pull request #17: a NUL, which the database
  # driver refuses, and bytes that are not UTF-8 are misses like any other.
  it "answers 404 and nothing else for a token that names no conversation, whatever its shape (SR-11)" do
    [ SecureRandom.base58(24), "", "x", "a" * 200, conversation.trace_token.downcase, "#{conversation.trace_token}x",
      "a\u0000b", "\xFF".b * 24, "ç#{"a" * 22}" ].each do |token|
      look_up(token)

      expect(response).to have_http_status(:not_found), token
      expect(json).to eq("error" => "not_found")
    end

    get "/api/trace"
    expect(response).to have_http_status(:not_found)
  end

  it "has one path: no format extension reaches it" do
    get "/api/trace.json", headers: { "X-Trace-Token" => conversation.trace_token }

    expect(response).to have_http_status(:not_found)
  end

  # Review finding V3 of pull request #17: kamal-proxy writes the path and the
  # query of every request to the host's log, whatever Rails masks in its own,
  # so the token travels in neither.
  it "reads the token from no path and no query" do
    token = conversation.trace_token

    [ "/api/traces/#{token}", "/api/trace?token=#{token}", "/api/trace/#{token}" ].each do |path|
      get path

      expect(response).to have_http_status(:not_found), path
    end
  end

  it "stops answering once the conversation is gone, deleted or purged (FR-05, FR-15)" do
    token = conversation.trace_token
    conversation.visitor.erase!

    look_up(token)

    expect(response).to have_http_status(:not_found)
  end

  it "shows nothing of the visitor's other conversations, nor of anyone else's (FR-12, SR-05)" do
    turn = turn_in(conversation, "¿tienen dipirona?", reply: "Sí.")
    span = span_of(turn)
    conversation.update!(closed_at: Time.current)
    later = Conversation.current_for!(conversation.visitor)
    other = create(:conversation)
    [ later, other ].each { |each| span_of(turn_in(each, "otra cosa", reply: "Otra respuesta.")) }

    look_up(conversation.trace_token)

    expect(json["messages"].map { |message| message["body"] }).to eq([ "¿tienen dipirona?", "Sí." ])
    expect(json["spans"].map { |each| each["span_id"] }).to eq([ span.span_id ])
  end

  it "keeps a reset's reply with its turn, though the reply opens the conversation the reset started (FR-04)" do
    reset = turn_in(conversation, "/reiniciar")
    conversation.update!(closed_at: Time.current)
    opened = Conversation.current_for!(conversation.visitor)
    reply = Message.record_outbound!(turn: reset, body: FixedReply.with_notice("Conversa nova.", "pt-BR"), conversation: opened)

    look_up(conversation.trace_token)
    expect(json["messages"].map { |message| message["id"] }).to eq([ reset.inbound_message_id, reply.id ])

    look_up(opened.trace_token)
    expect(json["messages"]).to eq([])
  end

  it "carries nothing of the visitor's identity and no id a page could reuse (SR-12)" do
    turn_in(conversation, "¿tienen dipirona?", reply: "Sí.")

    look_up(conversation.trace_token)

    written = response.body
    visitor = conversation.visitor
    expect([ visitor.id, visitor.identity_hash, conversation.id ]).to all(be_present)
    expect([ visitor.id, visitor.identity_hash, conversation.id ].select { |value| written.include?(value) }).to be_empty
    expect(json["messages"].flat_map(&:keys).uniq).to match_array(%w[id turn_id author notice body created_at])
  end

  # Review findings C3, G1 and V3 of pull request #17: the token, the whole
  # credential of the trace, travelled in the path, and the request's own log
  # line wrote it whole; parameter filtering never reaches a path (SR-30). It
  # travels in a header now, and a link given before then is masked.
  it "writes no trace token to the log, for the page, its lookup or a link given before", :spa_shells do
    io = StringIO.new
    sink = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(sink)
    begin
      get "/trace"
      look_up(conversation.trace_token)
      get "/trace/#{conversation.trace_token}"
      get "//trace/#{conversation.trace_token}/"
    ensure
      Rails.logger.stop_broadcasting_to(sink)
    end

    expect(io.string).to include('Started GET "/trace"', 'Started GET "/api/trace"', 'Started GET "/trace/[FILTERED]"')
    expect(io.string).not_to include(conversation.trace_token)
  end

  describe "at the edge (FR-14, SR-01, SR-11)" do
    around do |example|
      store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rack::Attack.cache.store = store
    end

    it "counts each lookup without the cookie against the source's minute, and refuses the 61st" do
      60.times { look_up(SecureRandom.base58(24), env: { "REMOTE_ADDR" => "203.0.113.9" }) }
      expect(response).to have_http_status(:not_found)

      look_up(conversation.trace_token, env: { "REMOTE_ADDR" => "203.0.113.9" })

      expect(response).to have_http_status(:too_many_requests)
      expect(json["error"]).to eq("limit")
    end
  end
end
