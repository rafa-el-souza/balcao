require "rails_helper"

RSpec.describe "FR-18 POST /api/messages stores the message and enqueues its turn", type: :request do
  include ActiveJob::TestHelper

  let(:id) { SecureRandom.uuid }

  def send_text(text, message_id: id) = api_post("/api/messages", { id: message_id, text: })

  it "refuses a request without the visitor cookie, storing nothing (SR-01)" do
    expect { send_text("tem dipirona?") }.not_to change(Message, :count)
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "session")
  end

  context "with a session" do
    let!(:visitor) { start_session }
    let(:conversation) { visitor.conversations.sole }

    it "stores the text as the visitor's inbound message, creates its turn and enqueues ProcessTurnJob" do
      expect { send_text("tem dipirona?") }.to have_enqueued_job(ProcessTurnJob)

      expect(response).to have_http_status(:accepted)
      message = Message.sole
      expect(message).to have_attributes(conversation:, channel: "web", direction: "inbound", author: "visitor",
                                         source: "text", body: "tem dipirona?", external_id: id)
      turn = Turn.sole
      expect(turn).to have_attributes(inbound_message: message, conversation:, state: "received")
      expect(json).to eq("turn_id" => turn.id, "message_id" => message.id, "conversation_id" => conversation.id)
      expect(ProcessTurnJob).to have_been_enqueued.with(turn.id)
    end

    it "marks the visitor seen, which keeps it out of the seven-day purge (FR-15)" do
      travel_to(2.days.from_now) do
        expect { send_text("oi") }.to change { visitor.reload.last_seen_at }
      end
    end

    describe "NFR-02 a message sent again" do
      it "is stored once, and its turn is enqueued again while it has no reply" do
        send_text("tem dipirona?")
        first = json

        expect { send_text("tem dipirona?") }.to have_enqueued_job(ProcessTurnJob).with(first["turn_id"])
        expect(response).to have_http_status(:accepted)
        expect(json).to eq first
        expect(Message.count).to eq 1
        expect(Turn.count).to eq 1
      end

      it "is not enqueued again once its turn has a reply" do
        send_text("tem dipirona?")
        Message.record_outbound!(turn: Turn.sole, body: "Temos.")

        expect { send_text("tem dipirona?") }.not_to have_enqueued_job(ProcessTurnJob)
        expect(response).to have_http_status(:accepted)
      end

      it "keeps the conversation it was stored in, even after a reset closed it" do
        send_text("tem dipirona?")
        conversation.update!(closed_at: Time.current)

        send_text("tem dipirona?")

        expect(json["conversation_id"]).to eq conversation.id
        expect(Conversation.count).to eq 1
      end
    end

    it "SR-05 refuses an id another visitor's message holds, leaving that message alone" do
      other = Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32))
      held = Message.record_inbound!(conversation: Conversation.current_for!(other), external_id: id, body: "segredo")

      expect { send_text("tem dipirona?") }.not_to change(Message, :count)
      expect(response).to have_http_status(:conflict)
      expect(json).to eq("error" => "id")
      expect(response.body).not_to include("segredo", held.conversation_id)
    end

    describe "FR-21 SR-34 openers" do
      it "sends the allow-listed text of a key as the visitor's message" do
        api_post "/api/messages", { id:, say: "stock_pt" }

        expect(response).to have_http_status(:accepted)
        expect(Message.sole).to have_attributes(body: "tem dipirona?", author: "visitor", source: "text")
      end

      [ "anything-else", "", "STOCK_PT", 1, nil, [ "stock_pt" ], { "k" => "stock_pt" } ].each do |key|
        it "sends nothing for #{key.inspect}" do
          expect { api_post "/api/messages", { id:, say: key } }.not_to change(Message, :count)
          expect(response).to have_http_status(:unprocessable_content)
          expect(enqueued_jobs).to be_empty
        end
      end
    end

    describe "SR-04 the request's shape" do
      def refused(body, status: :unprocessable_content)
        expect { api_post "/api/messages", body }.not_to change(Message, :count)
        expect(response).to have_http_status(status)
        expect(json.keys).to eq [ "error" ]
      end

      it("caps a message at 1,000 characters") { refused({ id:, text: "a" * 1_001 }) }

      it "accepts exactly 1,000 characters, counted as characters, not bytes" do
        send_text("é" * 1_000)

        expect(response).to have_http_status(:accepted)
      end

      it("refuses a missing id") { refused({ text: "oi" }) }
      it("refuses an id that is not a UUID") { refused({ id: "1", text: "oi" }) }
      it("refuses an id that is not a string") { refused({ id: 1, text: "oi" }) }
      it("refuses a text that is not a string") { refused({ id:, text: [ "oi" ] }) }
      it("refuses a blank text") { refused({ id:, text: " \n\t" }) }
      it("refuses both a text and an opener") { refused({ id:, text: "oi", say: "stock_pt" }) }
      it("refuses neither a text nor an opener") { refused({ id: }) }
      it("refuses a key outside the schema") { refused({ id:, text: "oi", conversation_id: SecureRandom.uuid }) }

      it "refuses a body over 16 KB before reading it as JSON" do
        expect { api_post "/api/messages", { id:, text: "oi", pad: "x" * 16_384 } }.not_to change(Message, :count)
        expect(response).to have_http_status(:content_too_large)
      end

      # Review finding V1 of pull request #12: a body of up to the proxy's
      # 1 MB, in any encoding, reached a controller, which parsed and logged
      # it before any check; 60 a minute rotate the container's log away.
      [ [ "application/json", ->(pad) { { text: pad }.to_json } ],
        [ "application/x-www-form-urlencoded", ->(pad) { "text=#{pad}" } ],
        [ "text/plain", ->(pad) { pad } ] ].each do |type, body|
        it "refuses a #{type} body over 16 KB before any controller runs, so nothing of it is logged" do
          started = []
          callback = ->(*, payload) { started << payload[:path] }
          ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
            post "/api/messages", params: body.call("x" * 20_000), headers: { "Content-Type" => type, "Origin" => origin }
          end

          expect(response).to have_http_status(:content_too_large)
          expect(json).to eq("error" => "size")
          expect(started).to be_empty
        end
      end

      it "refuses a body over 16 KB to any API path, sessions included" do
        api_post "/api/session", { language: "x" * 20_000 }

        expect(response).to have_http_status(:content_too_large)
      end

      it "refuses a body that is not JSON" do
        post "/api/messages", params: "id=1&text=oi", headers: { "Content-Type" => "application/x-www-form-urlencoded", "Origin" => origin }

        expect(response).to have_http_status(:unsupported_media_type)
        expect(Message.count).to eq 0
      end

      it "refuses malformed JSON" do
        post "/api/messages", params: "{\"id\":", headers: { "Content-Type" => "application/json", "Origin" => origin }

        expect(response).to have_http_status(:bad_request)
        expect(json).to eq("error" => "json")
      end

      it("refuses a JSON body that is not an object") { refused([ id, "oi" ]) }

      it "drops NUL characters, which PostgreSQL text cannot hold, and invalid UTF-8" do
        send_text("tem\u0000 dipirona?")

        expect(response).to have_http_status(:accepted)
        expect(Message.sole.body).to eq "tem dipirona?"
      end
    end

    # Review finding C3 of pull request #12: Rails' instrumentation logged the
    # parsed body, the visitor's text with it, before the action ran; the log
    # outlives the deletion (FR-05) and the seven-day purge.
    it "SR-30 keeps the visitor's message out of the log: Rails reads no JSON body before the action" do
      logged = []
      callback = ->(*, payload) { logged << payload[:params] }
      ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
        send_text("meu telefone é 11 98765-4321")
      end

      expect(response).to have_http_status(:accepted)
      expect(Message.sole.body).to eq "meu telefone é 11 98765-4321"
      expect(logged.sole.keys).not_to include("text", "id")
      expect(logged.inspect).not_to include("98765")
    end

    # Review finding V2 of pull request #12: SR-30 named `body`, and the API's
    # key is `text`; Rack still reads a form body under 16 KB as parameters.
    it "SR-30 masks a text sent as a form, which the API refuses, in the log" do
      logged = []
      callback = ->(*, payload) { logged << payload[:params] }
      ActiveSupport::Notifications.subscribed(callback, "start_processing.action_controller") do
        post "/api/messages", params: { id:, text: "meu telefone é 11 98765-4321" },
                              headers: { "Origin" => origin }
      end

      expect(response).to have_http_status(:unsupported_media_type)
      expect(logged.sole["text"]).to eq "[FILTERED]"
      expect(logged.inspect).not_to include("98765")
    end

    it "SR-30 filters the message keys of the API and of the WhatsApp webhook" do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter("text" => "a", "body" => "b", "say" => "stock_pt"))
        .to eq("text" => "[FILTERED]", "body" => "[FILTERED]", "say" => "stock_pt")
    end

    it "SR-03 refuses a message from another origin, storing nothing" do
      expect do
        post "/api/messages", params: { id:, text: "oi" }.to_json,
                              headers: { "Content-Type" => "application/json", "Origin" => "https://evil.example" }
      end.not_to change(Message, :count)
      expect(response).to have_http_status(:forbidden)
    end

    describe "FR-04 a message after 24 hours of silence starts a new conversation" do
      before do
        travel_to Time.zone.local(2026, 11, 11, 10, 0, 0)
        send_text("tem dipirona?", message_id: SecureRandom.uuid)
        conversation.update!(language: "es")
      end

      after { travel_back }

      it "closes the old conversation and opens one in its language when the last message is 24 hours old" do
        travel_to Time.zone.local(2026, 11, 12, 10, 0, 1)
        send_text("y el paracetamol?")

        expect(conversation.reload.closed_at).to be_present
        fresh = visitor.conversations.current.sole
        expect(fresh).not_to eq conversation
        expect(fresh.language).to eq "es"
        expect(json["conversation_id"]).to eq fresh.id
        expect(Message.find(json["message_id"]).conversation).to eq fresh
      end

      it "keeps the conversation when the last message is younger than 24 hours" do
        travel_to Time.zone.local(2026, 11, 12, 9, 59, 59)
        send_text("e o paracetamol?")

        expect(json["conversation_id"]).to eq conversation.id
        expect(conversation.reload.closed_at).to be_nil
      end
    end

    it "FR-05 starts over with a new visitor and conversation after the visitor deleted its data" do
      identity = visitor.identity_hash
      visitor.erase!

      expect { send_text("oi de novo") }.to change(Visitor, :count).by(1)
      expect(response).to have_http_status(:accepted)
      fresh = Visitor.sole
      expect(fresh.identity_hash).to eq identity
      expect(Message.sole.conversation.visitor).to eq fresh
    end
  end
end
