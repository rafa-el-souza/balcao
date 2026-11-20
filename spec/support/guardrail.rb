# FR-20: every reply the model writes passes the guardrail's check (Guardrail)
# before it is sent. In the suite the check answers "not clinical" unless an
# example scripts its own verdicts, so an example about something else gets
# the reply it scripted, with the check's span and its charge beside it, as
# in production. Each check asks a fake of its own: an example's turns are
# checked one by one.
module GuardrailVerdicts
  REASON = "Answers the visitor with no clinical advice.".freeze

  module_function

  def usage = ModelResponses.usage(input: 640, output: 38, cache_read: 0)

  def verdict(clinical, reason = REASON, stop_reason: :end_turn)
    ModelResponses.message(content: [ ModelResponses.text(JSON.generate(reason:, clinical:)) ], model: "claude-haiku-5-5",
                           stop_reason:, usage:)
  end
end

RSpec.configure do |config|
  config.before do
    allow(Guardrail).to receive(:default_client) { FakeModel.new([ GuardrailVerdicts.verdict(false) ]).client }
  end
end
