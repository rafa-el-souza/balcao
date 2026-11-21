require "rails_helper"

# Design §8, ADR-0011 (M3-6b): a rehearsal host runs MODEL_ADAPTER=fake, the
# recorded model: the API with no key and no network, answering a visitor's
# message with the answers the real model gave the same message when the
# evals recorded it (evals/recordings/), its tool calls and FR-20's check
# among them. Here its reading of requests, on recordings this spec writes;
# spec/agent/recorded_model_turn_spec.rb runs turns and FR-17's canary on the
# committed ones.
RSpec.describe "Design §8 ADR-0011 the recorded model of a rehearsal host" do
  include ModelResponses

  let(:dir) { Pathname(Dir.mktmpdir("recorded-model")) }
  let(:attendant_request) { { "model" => "a", "messages" => "b", "system" => "c", "tools" => "d" } }
  let(:check_request) { { "model" => "a", "messages" => "e", "system" => "f", "output_config" => "g" } }
  let(:search) { tool_use("search_products", { query: "dipirona" }, id: "toolu_recorded_search") }
  let(:price) { "[pt] Temos Dipirona 500 mg por R$ 7,00." }
  let(:street) { "[pt] Ficamos na Rua dos Boticários, 120." }
  let(:cases) do
    [
      { "id" => "stock", "turns" => [ { "user" => "tem dipirona?" } ] },
      { "id" => "address", "seed" => "default", "turns" => [ { "user" => "Qual é o endereço da farmácia?" } ] },
      { "id" => "follow-up", "turns" => [ { "user" => "oi" }, { "assistant" => "(any)" }, { "user" => "e o preço?" } ] },
      { "id" => "other-seed", "seed" => "out-of-stock", "turns" => [ { "user" => "tem soro?" } ] },
      { "id" => "named-product", "turns" => [ { "user" => "reserva uma dipirona" } ] },
      { "id" => "unrecorded", "turns" => [ { "user" => "tem vitamina C?" } ] }
    ]
  end

  after { FileUtils.remove_entry(dir) }

  def recorded(id, *answers, products: nil)
    data = { "case" => id, "responses" => answers.map { |request, response| { "request" => request }.merge(response.deep_stringify_keys) } }
    data["products"] = products if products
    dir.join("#{id}.json").write(JSON.generate(data))
  end

  def model
    dir.join("cases.yaml").write(cases.to_yaml)
    recorded("stock", [ attendant_request, tool_turn(search) ], [ attendant_request, reply(price) ],
             [ check_request, GuardrailVerdicts.verdict(false) ])
    recorded("address", [ attendant_request, error(:overloaded) ], [ attendant_request, reply(street) ],
             [ check_request, GuardrailVerdicts.verdict(false) ])
    recorded("follow-up", [ attendant_request, reply("[pt] Oi!") ], [ attendant_request, reply("[pt] R$ 7,00") ])
    recorded("other-seed", [ attendant_request, reply("[pt] Acabou.") ])
    recorded("named-product", [ attendant_request, reply("[pt] Reservei.") ], products: { "a-product-id" => "SKU-1" })
    RecordedModel.load(cases: dir.join("cases.yaml"), dir:)
  end

  def visitor(text, sent: "Sent Saturday, 2026-11-21 15:00 (São Paulo time)")
    { role: "user", content: [ { type: "text", text: sent }, { type: "text", text: } ] }
  end

  # The attendant's request, as AgentRunner sends it: the history, the tools.
  def ask(client, messages, model: "claude-haiku-5-5")
    client.beta.messages.create(model:, max_tokens: 1024, messages:, system_: [ { type: "text", text: "prompt" } ],
                                tools: [ { name: "search_products", description: "search", input_schema: { type: "object" } } ])
  end

  # FR-20's check, as Guardrail sends it: one user message of the tags.
  def check(client, message, reply)
    client.messages.create(model: "claude-haiku-5-5", max_tokens: 256, system_: "check",
                           messages: [ { role: "user", content: Guardrail.content(message:, reply:) } ])
  end

  def texts(message) = message.content.select { |block| block.type == :text }.map(&:text)

  it "answers a turn's first request with the recording's first answer, on whatever route the turn asks" do
    client = model.client

    expect(ask(client, [ visitor("tem dipirona?") ]).content.map(&:type)).to include(:tool_use)
    expect(texts(ask(client, [ visitor("Qual é o endereço da farmácia?") ], model: "claude-opus-5-5"))).to eq [ street ]
  end

  it "answers the request after a tool call with the recording's next answer, counting the model's messages after the visitor's" do
    client = model.client
    first = ask(client, [ visitor("tem dipirona?") ])
    after_tool = [ visitor("tem dipirona?"), { role: "assistant", content: first.content },
                   { role: "user", content: [ { type: "tool_result", tool_use_id: "toolu_recorded_search", content: "[]" } ] } ]

    expect(texts(ask(client, after_tool))).to eq [ price ]
  end

  it "answers FR-20's check with the recording's, read by the visitor's message in the check's tag" do
    verdict = check(model.client, "tem dipirona?", price)

    expect(JSON.parse(texts(verdict).join)).to include("clinical" => false)
  end

  it "takes the visitor's message whatever its letter case, spaces or Unicode composition, in a later turn too" do
    client = model.client
    decomposed = "  Qual  É o endereço da farmácia?".unicode_normalize(:nfd)
    later = [ visitor("oi"), { role: "assistant", content: [ { type: "text", text: "[pt] Oi!" } ] }, visitor(decomposed) ]

    expect(texts(ask(client, later))).to eq [ street ]
    expect(JSON.parse(texts(check(client, decomposed, street)).join)).to include("clinical" => false)
  end

  it "takes the newest of two messages the history joined, and reads past a system notice after it" do
    joined = { role: "user", content: [ *visitor("oi")[:content], *visitor("tem dipirona?")[:content] ] }
    notice = { role: "system", content: "No reply of yours reached the visitor for their message sent Saturday." }

    expect(ask(model.client, [ joined, notice ]).content.map(&:type)).to include(:tool_use)
  end

  # A message no recording answers ends its turn as a model error, with the
  # fixed apology: a 404 the SDK does not retry, and a log line that names
  # no word of the visitor's (threat model SR-30).
  it "refuses a message no recording answers with the API's not found, never retried, logging no word of it" do
    model = self.model
    allow(model).to receive(:call).and_call_original
    allow(Rails.logger).to receive(:info).and_call_original

    expect { ask(model.client, [ visitor("tem vitamina C?") ]) }.to raise_error(Anthropic::Errors::NotFoundError)
    expect { check(model.client, "tem vitamina C?", "[pt] Não temos.") }.to raise_error(Anthropic::Errors::NotFoundError)
    expect(model).to have_received(:call).twice
    expect(Rails.logger).to have_received(:info).with(/recorded model: no recording answers the attendant's request/).once
    expect(Rails.logger).to have_received(:info).with(/recorded model: no recording answers FR-20's check/).once
    expect(Rails.logger).not_to have_received(:info).with(/vitamina/)
  end

  it "refuses the request past a recording's last answer" do
    client = model.client
    past = [ visitor("Qual é o endereço da farmácia?"), { role: "assistant", content: [ { type: "text", text: street } ] },
             { role: "user", content: [ { type: "tool_result", tool_use_id: "toolu_x", content: "[]" } ] } ]

    expect { ask(client, past) }.to raise_error(Anthropic::Errors::NotFoundError)
  end

  # The host's catalogue draws its own product ids, and a recording's later
  # messages answer an earlier reply the host never gave: such recordings
  # would replay something other than what the model read.
  it "leaves out a case of several messages, one of another catalogue, and one whose answers name a product by its id" do
    client = model.client

    [ "e o preço?", "oi", "tem soro?", "reserva uma dipirona" ].each do |text|
      expect { ask(client, [ visitor(text) ]) }.to raise_error(Anthropic::Errors::NotFoundError), text
    end
  end

  it "serves the answers that came 200 alone, so a recorded overload never reaches the host" do
    expect(texts(ask(model.client, [ visitor("Qual é o endereço da farmácia?") ]))).to eq [ street ]
  end

  it "keeps nothing between requests: turns in two threads at once each get their own answers" do
    client = model.client
    answers = Array.new(8) do |index|
      Thread.new { index.even? ? texts(ask(client, [ visitor("Qual é o endereço da farmácia?") ])) : ask(client, [ visitor("tem dipirona?") ]).content.map(&:type) }
    end.map(&:value)

    expect(answers.each_slice(2).to_a).to all(eq [ [ street ], [ :thinking, :tool_use ] ])
  end

  it "is AgentRunner's and FR-20's check's client when MODEL_ADAPTER is fake, reading no key" do
    saved = Rails.configuration.x.fake_model
    AgentRunner.instance_variable_set(:@default_client, nil)
    Rails.configuration.x.fake_model = true
    allow(ENV).to receive(:[]).and_call_original
    allow(RecordedModel).to receive(:load).and_return(model)

    client = AgentRunner.default_client

    expect(client).to be_a(FakeModel::Client)
    expect(texts(ask(client, [ visitor("Qual é o endereço da farmácia?") ]))).to eq [ street ]
    expect(ENV).not_to have_received(:[]).with("ANTHROPIC_API_KEY")
  ensure
    Rails.configuration.x.fake_model = saved
    AgentRunner.instance_variable_set(:@default_client, nil)
  end

  it "reads the committed recordings and cases from the paths the image keeps" do
    expect(RecordedModel::CASES).to eq Rails.root.join("evals/cases.yaml")
    expect(RecordedModel::DIR).to eq Rails.root.join("evals/recordings")
    expect(Rails.root.join(".dockerignore").read.lines.map(&:strip)).not_to include("/evals", "evals", "/evals/*")
  end
end
