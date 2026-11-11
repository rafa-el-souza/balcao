require "rails_helper"

RSpec.describe "NFR-03 FakeModel, the test seam (design §6.4, threat model SR-29)" do
  include ModelResponses

  let(:client) { FakeModel.new([ reply("[pt] Oi!") ]).client }

  def ask(client) = client.beta.messages.create(model: "claude-opus-5-5", max_tokens: 10, messages: [ { role: "user", content: "oi" } ])

  it "answers through the SDK's own client, which parses the reply into its types" do
    message = ask(client)

    expect(message).to be_a(Anthropic::Models::Beta::BetaMessage)
    expect(message.content.last.text).to eq("[pt] Oi!")
  end

  it "never reaches the network" do
    ask(client)

    expect(WebMock).not_to have_requested(:any, /anthropic/)
  end

  it "keeps every request it was sent, as the SDK sent it" do
    fake = FakeModel.new([ reply("[pt] Oi!") ])
    ask(fake.client)

    expect(fake.requests.first.body).to include(model: "claude-opus-5-5", messages: [ { role: "user", content: "oi" } ])
  end

  it "fails loudly when asked more than it was given" do
    ask(client)

    expect { ask(client) }.to raise_error(FakeModel::Unscripted)
  end

  it "replays a recording file, the format of evals/recordings/" do
    path = Rails.root.join("tmp/fake_model_spec_recording.json")
    File.write(path, JSON.generate("responses" => [ reply("[pt] Gravado.") ]))

    expect(ask(FakeModel.load(path).client).content.last.text).to eq("[pt] Gravado.")
  ensure
    FileUtils.rm_f(path)
  end
end
