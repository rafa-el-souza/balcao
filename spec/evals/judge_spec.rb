require "rails_helper"
require Rails.root.join("lib/evals/judge").to_s

# The rubric's judge (evals/README.md, Expectation keys): the economy model
# reads the rubric and the final reply, never the tools or the trace, and
# answers in a structured output, so the verdict is parsed, never read out of
# prose.
RSpec.describe "NFR-08 SR-18 the eval runner's rubric judge" do
  include ModelResponses

  let(:responses) { [ verdict(true, "Greets and invites a task.") ] }
  let(:fake) { FakeModel.new(responses) }
  let(:judge) { Evals::Judge.new(client: fake.client) }

  def verdict(pass, reason, model: "claude-haiku-5-5", stop_reason: :end_turn)
    message(content: [ text(JSON.generate(reason:, pass:)) ], model:, stop_reason:)
  end

  def sent = fake.requests.last.body

  it "asks the economy model, with the rubric and the reply and nothing else, for a structured verdict" do
    result = judge.grade(rubric: "Greets briefly.", reply: "Olá! Posso ajudar com um produto?")

    expect(result).to have_attributes(pass: true, reason: "Greets and invites a task.", model: "claude-haiku-5-5")
    expect(sent).to include(model: "claude-haiku-5-5")
    expect(sent.dig(:output_config, :format, :type)).to eq(:json_schema)
    expect(sent.dig(:output_config, :format, :schema, :required)).to match_array(%w[reason pass])
    content = sent.fetch(:messages).sole.fetch(:content)
    expect(content).to include("Greets briefly.", "Olá! Posso ajudar com um produto?")
    expect(sent).not_to include(:tools)
  end

  it "fails a reply when the judge says so" do
    responses.replace([ verdict(false, "Does not offer the pharmacist.") ])

    expect(judge.grade(rubric: "Offers the pharmacist.", reply: "Não sei.")).to have_attributes(pass: false)
  end

  it "keeps the judge's usage, for the run's token count" do
    expect(judge.grade(rubric: "Greets.", reply: "Olá!").usage).to include(input_tokens: be_positive, output_tokens: be_positive)
  end

  # A verdict cut off or served by another model is no verdict (the eval
  # audit's served-model check): an error, never a failure of the attendant.
  it "raises an error for a verdict cut off, unreadable or from another model" do
    {
      verdict(true, "ok", stop_reason: :max_tokens) => /max_tokens/,
      message(content: [ text("pass") ], model: "claude-haiku-5-5") => /verdict/,
      verdict(true, "ok", model: "claude-opus-5-5") => /claude-opus-5-5/
    }.each do |response, error|
      judge = Evals::Judge.new(client: FakeModel.new([ response ]).client)

      expect { judge.grade(rubric: "Greets.", reply: "Olá!") }.to raise_error(Evals::Judge::Error, error)
    end
  end

  # The eval audit's known negatives: no reply, a non-answer and a confident
  # answer to another question must all fail before the judge scores a run.
  describe "the preflight" do
    it "passes when the judge fails every known-bad reply" do
      responses.replace(Evals::Judge::KNOWN_BAD.map { verdict(false, "Not a decline.") })

      expect(judge.preflight!.map(&:pass)).to all(be(false))
      expect(fake.requests.map { |request| request.body.dig(:messages, 0, :content) })
        .to all(include(Evals::Judge::PREFLIGHT_RUBRIC))
    end

    it "refuses a judge that passes one" do
      responses.replace([ verdict(false, "No."), verdict(true, "Looks fine."), verdict(false, "No.") ])

      expect { judge.preflight! }.to raise_error(Evals::Judge::Error, /known-bad/)
    end
  end
end
