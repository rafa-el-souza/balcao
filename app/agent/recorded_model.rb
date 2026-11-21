# MODEL_ADAPTER=fake, the model of a rehearsal host (design §8, ADR-0011;
# M3-6b): the API with no key and no network. It answers a visitor's message
# with the answers the real model gave the same message when the evals
# recorded it (evals/recordings/, bin/evals --record), its tool calls and
# FR-20's check among them, in their order, so the host runs every path a
# turn runs, the tools against its own catalogue included, on replies the
# model wrote. FR-17's canary asks a question the evals record
# (store-address-pt-01), so it passes there; so does the smoke's opener. It
# sits where FakeModel does, innermost in the SDK's middleware chain, so every
# middleware above it runs as in production.
#
# A recording answers when its case is one message on the default catalogue
# and its answers name no product by its id (the host's catalogue draws its
# own ids), and with the answers that came 200 alone. The visitor's message
# is matched with its case's whatever the letter case, the spaces or
# Unicode's composition. Each request finds its answer by what it carries, so
# turns in many threads share one instance: the attendant's n-th answer for a
# request whose visitor's newest message is followed by n of the model's
# messages, and the check's for a check whose tag holds that message.
#
# A message no recording answers gets what the API sends for a request it
# cannot serve, a 404, which the SDK does not retry: the turn ends as a model
# error, with the fixed apology, and FR-17's canary counts it among the
# visitors' turns as one. The log says so with no word of the message
# (threat model SR-30).
class RecordedModel
  include Anthropic::Middleware

  DIR = Rails.root.join("evals/recordings")
  CASES = Rails.root.join("evals/cases.yaml")
  # FR-20's check gives the visitor's message in this tag (Guardrail.content).
  CHECKED = %r{<visitor_message>\n(.*?)\n</visitor_message>}m
  NOT_RECORDED = "No recorded reply for this message: a rehearsal host's model answers only the messages the evals " \
                 "recorded (design §8).".freeze

  Exchange = Data.define(:attendant, :check)

  # The recordings that answer a message, by the message's key.
  def self.load(cases: CASES, dir: DIR)
    exchanges = YAML.safe_load_file(cases).each_with_object({}) do |kase, table|
      turns = Array(kase["turns"])
      next unless turns.one? && turns.first.keys == [ "user" ] && kase.fetch("seed", "default") == "default"

      path = Pathname(dir).join("#{kase["id"]}.json")
      next unless path.exist?

      data = JSON.parse(path.read)
      responses = data.fetch("responses")
      next if data["products"].present? || !responses.all? { |response| response["request"].is_a?(Hash) }

      answers = responses.select { |response| response["status"] == 200 && response["body"].is_a?(Hash) }
      attendant, check = answers.partition { |response| response["request"].key?("tools") }.map { |list| list.map { |response| response["body"] }.freeze }
      table[key(turns.first["user"])] ||= Exchange.new(attendant:, check:)
    end
    new(exchanges)
  end

  # A message as both sides read it: the check gives its angle brackets as
  # single guillemets (Guardrail.data).
  def self.key(text) = text.to_s.tr("‹›", "<>").unicode_normalize(:nfc).downcase.squish

  def initialize(exchanges)
    @exchanges = exchanges.freeze
  end

  # An SDK client whose every request this model answers, with production's
  # retries: an answer it serves is a 200 or a 404, neither retried.
  def client = FakeModel::Client.new(self, api_key: "recorded-model", max_retries: AgentRunner::MAX_RETRIES)

  def call(request, _next)
    body = JSON.parse(JSON.generate(request.body))
    attendant = body.key?("tools")
    answer = attendant ? attendant_answer(body.fetch("messages", [])) : check_answer(body.fetch("messages", []))
    return response(request, 200, answer) if answer

    Rails.logger.info("recorded model: no recording answers #{attendant ? "the attendant's request" : "FR-20's check"} " \
                      "(#{@exchanges.size} messages recorded)")
    response(request, 404, { type: "error", error: { type: "not_found_error", message: NOT_RECORDED } })
  end

  private

  # The visitor's newest message: the last user message of text, not of tool
  # results (the history joins messages in a row into one, the newest last).
  def attendant_answer(messages)
    index = messages.rindex { |message| message["role"] == "user" && visitor?(message) } or return
    exchange = @exchanges[self.class.key(texts(messages[index]).last)] or return
    exchange.attendant[messages.drop(index + 1).count { |message| message["role"] == "assistant" }]
  end

  def check_answer(messages)
    message = texts(messages.first).join[CHECKED, 1] or return
    @exchanges[self.class.key(message)]&.check&.first
  end

  def visitor?(message) = texts(message).any? && blocks(message).none? { |block| block["type"] == "tool_result" }

  def texts(message)
    blocks(message).filter_map { |block| block.is_a?(String) ? block : (block["text"] if block["type"] == "text") }
  end

  def blocks(message) = Array(message.to_h["content"])

  def response(request, status, body)
    headers = { "content-type" => "application/json" }
    headers["x-should-retry"] = "false" unless status == 200
    Anthropic::APIResponse.new(status:, headers:, body: JSON.generate(body), request:)
  end
end
