import type { ServerSpan } from "./fakeServer";

// A turn's spans as the server writes them (app/models/turn_processor.rb,
// app/models/turn_trace.rb): the root from the message's receipt, the model
// calls, a tool call and the reply. Times are São Paulo's 12:03:41 onwards,
// written in UTC as the server sends them.
const at = (minute: number, second: number, ms = 0) =>
  new Date(Date.UTC(2026, 10, 12, 15, minute, second, ms)).toISOString();

let next = 0;
const id = () => {
  next += 1;
  return next.toString(16).padStart(16, "0");
};

function span(
  turn: string,
  name: string,
  started: string,
  finished: string | null,
  attributes: Record<string, unknown>,
  root = false,
): ServerSpan {
  return {
    turn_id: turn,
    trace_id: "f".repeat(32),
    span_id: id(),
    parent_span_id: root ? null : "0".repeat(15) + "1",
    name,
    attributes,
    started_at: started,
    finished_at: finished,
  };
}

export interface TurnOptions {
  minute?: number;
  outcome?: string;
  tool?: Record<string, unknown> | null;
  error?: string;
}

// An answered turn: received at minute:41, a model call that asks for a tool,
// the tool, a model call that answers and the reply, at minute:44.
export function answeredTurn(turn: string, options: TurnOptions = {}) {
  const minute = options.minute ?? 3;
  const model = {
    "gen_ai.request.model": "claude-opus-5-5",
    "gen_ai.response.model": "claude-opus-5-5",
    "gen_ai.request.reasoning.level": "medium",
    "balcao.system_prompt.characters": 11_800,
    "balcao.system_prompt.sha256": "9f2c41d0aabbccdd",
  };
  if (options.error)
    return [
      span(
        turn,
        "balcao.turn",
        at(minute, 41),
        at(minute, 45),
        {
          "balcao.turn.outcome": options.outcome ?? "model_error",
        },
        true,
      ),
      span(turn, "anthropic.messages.create", at(minute, 41), at(minute, 45), {
        ...model,
        "gen_ai.response.model": undefined,
        "balcao.latency_ms": 4200,
        "error.type": options.error,
      }),
      span(turn, "balcao.outbound", at(minute, 45), at(minute, 45), {
        "balcao.message.author": "bot",
      }),
    ];
  return [
    span(
      turn,
      "balcao.turn",
      at(minute, 41),
      at(minute, 44),
      {
        "balcao.channel": "web",
        "balcao.turn.outcome": options.outcome ?? "replied",
      },
      true,
    ),
    span(turn, "anthropic.messages.create", at(minute, 41), at(minute, 42), {
      ...model,
      "anthropic.message.stop_reason": "tool_use",
      "balcao.latency_ms": 1100,
      "gen_ai.usage.input_tokens": 3100,
      "gen_ai.usage.cache_read.input_tokens": 2800,
      "gen_ai.usage.cache_write.input_tokens": 300,
      "gen_ai.usage.output_tokens": 42,
    }),
    span(
      turn,
      "anthropic.custom_tool_use search_products",
      at(minute, 42),
      at(minute, 42, 38),
      options.tool ?? {
        "gen_ai.tool.name": "search_products",
        "gen_ai.tool.call.arguments": '{"query":"dipirona"}',
        "anthropic.tool_result.content":
          '{"query":"dipirona","products":[{"name":"Dipirona 500 mg"}]}',
        "balcao.tool_result.characters": 60,
        "balcao.tool_result.unit": "products",
        "balcao.tool_result.count": 2,
        "balcao.latency_ms": 38,
      },
    ),
    span(turn, "anthropic.messages.create", at(minute, 43), at(minute, 44), {
      ...model,
      "anthropic.message.stop_reason": "end_turn",
      "balcao.latency_ms": 1600,
      "gen_ai.usage.input_tokens": 3700,
      "gen_ai.usage.cache_read.input_tokens": 0,
      "gen_ai.usage.cache_write.input_tokens": 3700,
      "gen_ai.usage.output_tokens": 98,
    }),
    span(turn, "balcao.outbound", at(minute, 44), at(minute, 44), {
      "balcao.message.author": "bot",
    }),
  ];
}

// A turn whose model call is still running.
export function runningTurn(turn: string, minute = 5) {
  return [
    span(turn, "balcao.turn", at(minute, 10), null, {}, true),
    span(turn, "anthropic.messages.create", at(minute, 10), null, {
      "gen_ai.request.model": "claude-opus-5-5",
      "gen_ai.request.reasoning.level": "medium",
    }),
  ];
}

// A command: one root span, no model call.
export function commandTurn(turn: string, name: string, minute = 12) {
  return [
    span(
      turn,
      "balcao.command",
      at(minute, 10),
      at(minute, 10, 12),
      {
        "balcao.command.name": name,
      },
      true,
    ),
  ];
}

// A tool call's attributes, for answeredTurn's `tool`: a reservation made
// (app/agent/tools/create_reservation.rb), a refusal with its reason code and
// a failure, both the SDK's tool_error (app/models/turn_trace.rb).
export function reservationTool(code: string) {
  const result = JSON.stringify({
    code,
    quantity: 2,
    product: "Dipirona 500 mg, 10 comprimidos",
    pickup_until: "2026-11-13T20:00:00-03:00",
  });
  return {
    "gen_ai.tool.name": "create_reservation",
    "gen_ai.tool.call.arguments":
      '{"product_id":"01a1cb3a-c25c-7759-a408-78909fba8f60","quantity":2}',
    "anthropic.tool_result.content": result,
    "balcao.tool_result.characters": result.length,
    "balcao.latency_ms": 61,
  };
}

export function refusedTool(name: string, reason: string, content: string) {
  return {
    "gen_ai.tool.name": name,
    "gen_ai.tool.call.arguments":
      '{"product_id":"01a1cb3a-c25c-7759-a408-78909fba8f60","quantity":20}',
    "anthropic.tool_result.content": content,
    "balcao.tool_result.characters": content.length,
    "balcao.tool_result.refusal": reason,
    "balcao.latency_ms": 9,
    "error.type": "tool_error",
  };
}

export function failedTool(name: string) {
  const content =
    "The tool failed. Tell the visitor you could not check this right now.";
  return {
    "gen_ai.tool.name": name,
    "gen_ai.tool.call.arguments": '{"query":"dipirona"}',
    "anthropic.tool_result.content": content,
    "balcao.tool_result.characters": content.length,
    "balcao.latency_ms": 12,
    "error.type": "tool_error",
  };
}
