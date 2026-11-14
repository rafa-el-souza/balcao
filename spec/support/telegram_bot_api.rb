# The Bot API as the specs see it (FR-19, design §6.6): WebMock stubs of the
# methods a reply uses, answering ok and recording what was sent, so a spec
# reads the requests as Telegram would have received them. A spec that wants
# a failure stubs that method again after these.
module TelegramBotApi
  def bot_api_url(method) = %r{\Ahttps://api\.telegram\.org/bot[^/]+/#{method}\z}

  def bot_api_answer(result) = { status: 200, body: { ok: true, result: }.to_json, headers: { "content-type" => "application/json" } }

  def bot_api_error(code, description, retry_after: nil)
    body = { ok: false, error_code: code, description:, parameters: ({ retry_after: } if retry_after) }.compact
    { status: code, body: body.to_json, headers: { "content-type" => "application/json" } }
  end

  # Stubs sendMessage and sendChatAction; returns the list the sent messages'
  # bodies are appended to, in order.
  def stub_bot_api(sent: [], actions: [])
    stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
      sent << JSON.parse(request.body)
      bot_api_answer({ "message_id" => sent.size })
    end
    stub_request(:post, bot_api_url("sendChatAction")).to_return do |request|
      actions << JSON.parse(request.body)
      bot_api_answer(true)
    end
    sent
  end
end
