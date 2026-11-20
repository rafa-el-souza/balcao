# What the model reads besides its route, by digest: the system prompt
# (SystemPrompt, the same digest the trace shows, threat model SR-12) and the
# tools it is offered, each one's name, description, input schema and
# options as the SDK sends them. ADR-0003's gate names both, since the
# boundary suite measured the economy model on them, and a gate written for
# another prompt or tool set does not speak for this one (Budget,
# Evals::EconomyGate; the hunter's F2 on pull request #55).
module PromptDigest
  module_function

  def prompt = TurnTrace.prompt_summary["balcao.system_prompt.sha256"]

  def tools(tools = Tools::ALL)
    definitions = tools.map { |tool| [ tool.name, tool.doc_string, tool.model&.to_json_schema, tool.tool_options ] }
    Digest::SHA256.hexdigest(JSON.generate(definitions))[0, 16]
  end
end
