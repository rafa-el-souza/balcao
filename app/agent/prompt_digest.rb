# What the model reads besides its route, by digest: the system prompt
# (SystemPrompt, the same digest the trace shows, threat model SR-12), the
# tools it is offered, each one's name, description, input schema and
# options as the SDK sends them, and FR-20's check of its replies. ADR-0003's
# gate names the three, since the boundary suite measured the economy model
# on them, and a gate written for another prompt, tool set or check does not
# speak for this one (Budget, Evals::EconomyGate; the hunter's F2 on pull
# request #55; #59's M4).
module PromptDigest
  module_function

  def prompt = TurnTrace.prompt_summary["balcao.system_prompt.sha256"]

  def tools(tools = Tools::ALL)
    definitions = tools.map { |tool| [ tool.name, tool.doc_string, tool.model&.to_json_schema, tool.tool_options ] }
    Digest::SHA256.hexdigest(JSON.generate(definitions))[0, 16]
  end

  # FR-20's check as the boundary suite ran it beside every reply: its system
  # prompt, what it reads around the texts (Guardrail.content, on fixed
  # words), its route, its thinking and its answer's shape. Every boundary
  # case fails on a replacement, so a stricter check fails cases a gate
  # written before it never measured (#59's M4, the owner, 2026-11-20).
  def guardrail(route = ModelPolicy.guardrail)
    reads = Guardrail.content(message: "MESSAGE", reply: "REPLY", earlier: [ "EARLIER" ])
    definition = [ Guardrail::SYSTEM, reads, route.model, route.effort, Guardrail::THINKING, Guardrail::Output.to_json_schema ]
    Digest::SHA256.hexdigest(JSON.generate(definition))[0, 16]
  end
end
