# What the model reads besides its route, by digest: the system prompt
# (SystemPrompt, the same digest the trace shows, threat model SR-12), the
# tools it is offered, each one's name, description, input schema and
# options as the SDK sends them, with the fixed texts and the shapes of their
# results, what the history gives it back of the turns before (its notices,
# the tools it replays, the time line and how it arranges them), and FR-20's
# check of its replies. ADR-0003's gate names the four, since the boundary
# suite measured the economy model on them, and a gate written for another
# prompt, tool set, history or check does not speak for this one (Budget,
# Evals::EconomyGate; the hunter's F2 on pull request #55; #59's M4; the
# close's XF-C4 and #60's C3, the owner, 2026-11-20: "Amarrar no portão").
# What the store's sheet and catalogue say is data, never digested: a price
# or a fee changes with no new run.
module PromptDigest
  # The time of the placeholder conversation the digests render: fixed, so a
  # digest is the same in every process.
  SAMPLE_AT = Time.utc(2026, 1, 5, 12, 0).freeze
  SampleMessage = Data.define(:id, :body, :created_at)
  SampleTurn = Data.define(:inbound_message, :outbound_message, :reply_kind, :model_reply, :tool_exchange)
  SampleProduct = Data.define(:id, :name, :active_ingredient, :price, :stock, :prescription_required, :match, :score)
  SampleReservation = Data.define(:code, :quantity, :product, :pickup_until)

  module_function

  def prompt = TurnTrace.prompt_summary["balcao.system_prompt.sha256"]

  # Each tool's definition and the fixed texts its results carry (its own
  # text constants: its refusals and notes, AGAIN and OPEN_LIMIT among
  # them), the failure and the tool limit every tool's caller may read, and
  # the shapes of the results the model reads, on placeholder values.
  def tools(tools = Tools::ALL)
    definitions = tools.map { |tool| [ tool.name, tool.doc_string, tool.model&.to_json_schema, tool.tool_options, texts(tool) ] }
    digest([ definitions, AgentTool::FAILED, AgentRunner::TOOL_LIMIT, results ])
  end

  def texts(tool)
    tool.constants(false).sort.filter_map do |name|
      value = tool.const_get(name)
      [ name.to_s, value ] if value.is_a?(String)
    end
  end

  def results
    product = SampleProduct.new(id: "ID", name: "NAME", active_ingredient: "INGREDIENT", price: 1, stock: 1, prescription_required: false,
                                match: "exact", score: 1.0)
    reservation = SampleReservation.new(code: "CODE", quantity: 1, product:, pickup_until: SAMPLE_AT)
    [ Tools::SearchProducts.entry(product), Tools::CreateReservation.result(reservation) ]
  end

  # What the history gives the model back (AgentRunner::History): its window,
  # the time line's format, the tools it replays, its notices, and a
  # conversation of placeholder words rendered through it, so a change of how
  # it arranges what it gives back changes the digest with no constant to
  # bump: a reply the model wrote with a lookup and a reservation, one turn
  # of each fixed text the system sent in the model's place, another reply,
  # and the turn running.
  def history
    digest([ AgentRunner::History::TURNS, AgentRunner::History::SENT, AgentRunner::History::REPLAYED, AgentRunner::History::NOTICES,
             AgentRunner::History.render(sample_turns, []) ])
  end

  def sample_turns
    kinds = [ "model", *AgentRunner::History::NOTICES.keys, "model", nil ]
    kinds.each_with_index.map do |kind, index|
      sent = SampleMessage.new(id: "IN#{index}", body: "MESSAGE #{index}", created_at: SAMPLE_AT + (index * 60))
      reply = SampleMessage.new(id: "OUT#{index}", body: "REPLY #{index}", created_at: SAMPLE_AT + (index * 60) + 30) if kind
      SampleTurn.new(inbound_message: sent, outbound_message: reply, reply_kind: kind,
                     model_reply: ("[pt] WORDS #{index} [pharmacist]" if kind == "model"), tool_exchange: (exchange if index.zero?))
    end
  end

  def exchange
    [ Tools::SearchProducts, Tools::CreateReservation ].each_with_index.flat_map do |tool, index|
      [ { "role" => "assistant", "content" => [ { "type" => "tool_use", "id" => "toolu_#{index}", "name" => tool.tool_name, "input" => { "query" => "INPUT" } } ] },
        { "role" => "user", "content" => [ { "type" => "tool_result", "tool_use_id" => "toolu_#{index}", "content" => "RESULT", "is_error" => false } ] } ]
    end
  end

  # FR-20's check as the boundary suite ran it beside every reply: its system
  # prompt, what it reads around the texts (Guardrail.content, on fixed
  # words), its route, its thinking and its answer's shape. Every boundary
  # case fails on a replacement, so a stricter check fails cases a gate
  # written before it never measured (#59's M4, the owner, 2026-11-20).
  def guardrail(route = ModelPolicy.guardrail)
    reads = Guardrail.content(message: "MESSAGE", reply: "REPLY", earlier: [ "EARLIER" ])
    digest([ Guardrail::SYSTEM, reads, route.model, route.effort, Guardrail::THINKING, Guardrail::Output.to_json_schema ])
  end

  def digest(definition) = Digest::SHA256.hexdigest(JSON.generate(definition))[0, 16]
end
