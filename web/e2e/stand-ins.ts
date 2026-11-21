import type { Page } from "@playwright/test";

import type { Session, Snapshot, Span, Trace } from "../src/chat/api.ts";
import { SCRIPT_SRC } from "../src/chat/challenge.ts";

// What the gate's pages meet in place of the server and Cloudflare
// (gate.e2e.ts): a conversation of two turns, with a price, a reservation's
// code and the spans of a tool call, as the API answers it (src/chat/api.ts's
// types), so the chat and the trace page are drawn full; a cable that
// confirms every subscription and sends nothing; and a Turnstile that hands
// its token at once, as Cloudflare's test key does.

// A trace link's token, as the page reads it after the "#": any 24 characters
// of base58 here, since the page only hands it to the API.
export const TRACE_TOKEN = "2".repeat(24);
const STARTED = Date.parse("2026-11-21T13:00:00Z");
const iso = (ms: number) => new Date(ms).toISOString();
const BRL = { per_usd: 5.6518, verified_on: "2026-11-13" };
const MODEL = {
  "gen_ai.request.model": "claude-opus-5-5",
  "gen_ai.response.model": "claude-opus-5-5",
  "gen_ai.request.reasoning.level": "low",
  "balcao.system_prompt.characters": 11800,
  "balcao.system_prompt.sha256": "9f2c41d0aabbccdd",
};
const TURNS = [
  {
    question: "tem dipirona?",
    answer:
      "Temos, sim: Dipirona 500 mg, 10 comprimidos, por R$ 7,90, e Dipirona gotas 500 mg/ml, 20 ml, por R$ 12,50. Quer que eu reserve?",
    codes: [] as string[],
  },
  {
    question: "reserva duas caixas da dipirona em comprimido pra mim",
    answer:
      "Pronto: reservei 2 caixas de Dipirona 500 mg, 10 comprimidos. Retire até amanhã, 20:00, com o código KP3K3K no balcão.",
    codes: ["KP3K3K"],
  },
];
const NOTICE =
  "Aviso: isto é uma demonstração, a farmácia é fictícia e as respostas são de uma IA.";

function spans(turn: string, at: number): Span[] {
  let next = 0;
  const span = (
    name: string,
    start: number,
    finish: number,
    attributes: Record<string, unknown>,
    root = false,
  ): Span => ({
    turn_id: turn,
    trace_id: "f".repeat(32),
    span_id: `${turn}${String((next += 1)).padStart(15, "0")}`.slice(-16),
    parent_span_id: root ? null : `${turn}${"1".padStart(15, "0")}`.slice(-16),
    name,
    attributes,
    started_at: iso(start),
    finished_at: iso(finish),
  });
  return [
    span(
      "balcao.turn",
      at,
      at + 4200,
      { "balcao.channel": "web", "balcao.turn.outcome": "replied" },
      true,
    ),
    span("anthropic.messages.create", at, at + 1100, {
      ...MODEL,
      "balcao.cost.usd": 0.003,
      "anthropic.message.stop_reason": "tool_use",
      "balcao.latency_ms": 1100,
      "gen_ai.usage.input_tokens": 3100,
      "gen_ai.usage.output_tokens": 42,
    }),
    span("anthropic.custom_tool_use search_products", at + 1100, at + 1140, {
      "gen_ai.tool.name": "search_products",
      "gen_ai.tool.call.arguments": '{"query":"dipirona"}',
      "anthropic.tool_result.content":
        '{"query":"dipirona","products":[{"name":"Dipirona 500 mg, 10 comprimidos"}]}',
      "balcao.tool_result.characters": 77,
      "balcao.tool_result.unit": "products",
      "balcao.tool_result.count": 2,
      "balcao.latency_ms": 40,
    }),
    span("anthropic.messages.create", at + 1200, at + 4100, {
      ...MODEL,
      "balcao.cost.usd": 0.006,
      "anthropic.message.stop_reason": "end_turn",
      "balcao.latency_ms": 2900,
      "gen_ai.usage.input_tokens": 3700,
      "gen_ai.usage.output_tokens": 98,
    }),
    span("balcao.outbound", at + 4200, at + 4200, {
      "balcao.message.author": "bot",
    }),
  ];
}

const turns = TURNS.map((turn, index) => ({
  ...turn,
  id: `0000000${String(index + 1)}`,
  at: STARTED + index * 60_000,
}));

export const session: Session = {
  conversation_id: "1",
  trace_token: TRACE_TOKEN,
  language: "pt-BR",
  mode: "normal",
  brl: BRL,
};

export const snapshot: Snapshot = {
  conversation: {
    id: "1",
    language: "pt-BR",
    state: "active",
    trace_token: TRACE_TOKEN,
  },
  messages: turns.flatMap((turn, index) => [
    {
      id: `${turn.id}a`,
      client_id: null,
      conversation_id: "1",
      turn_id: turn.id,
      author: "visitor" as const,
      body: turn.question,
      created_at: iso(turn.at),
    },
    {
      id: `${turn.id}b`,
      client_id: null,
      conversation_id: "1",
      turn_id: turn.id,
      author: "bot" as const,
      notice: index === 0 ? NOTICE : null,
      body: turn.answer,
      codes: turn.codes,
      created_at: iso(turn.at + 4200),
    },
  ]),
  spans: turns.flatMap((turn) => spans(turn.id, turn.at)),
  mode: "normal",
  brl: BRL,
};

export const trace: Trace = {
  conversation: { started_at: iso(STARTED) },
  messages: snapshot.messages.map((message) => ({
    id: message.id,
    turn_id: message.turn_id ?? "",
    author: message.author,
    notice: message.notice ?? null,
    body: message.body,
    created_at: message.created_at,
  })),
  spans: snapshot.spans,
  brl: BRL,
};

// Cloudflare's script, as its test key behaves: the widget draws nothing and
// hands its dummy token at once.
const TURNSTILE = `window.turnstile = {
  render(container, options) { setTimeout(() => options.callback && options.callback("XXXX.DUMMY.TOKEN.XXXX"), 0); return "gate"; },
  reset() {},
  remove() {},
};`;

// The routes the gate's pages call, answered from the conversation above.
export async function standIn(page: Page): Promise<void> {
  const json = (body: unknown, status = 200) => ({
    status,
    contentType: "application/json",
    body: JSON.stringify(body),
  });
  await page.route(SCRIPT_SRC, (route) =>
    route.fulfill({ contentType: "text/javascript", body: TURNSTILE }),
  );
  await page.route("**/api/session", (route) =>
    route.fulfill(json(session, 201)),
  );
  await page.route("**/api/conversations/current", (route) =>
    route.fulfill(json(snapshot)),
  );
  await page.route("**/api/trace", (route) => route.fulfill(json(trace)));
  await page.routeWebSocket("**/cable", (socket) => {
    socket.send(JSON.stringify({ type: "welcome" }));
    socket.onMessage((message) => {
      const command = JSON.parse(String(message)) as {
        command?: string;
        identifier?: string;
      };
      if (command.command === "subscribe")
        socket.send(
          JSON.stringify({
            identifier: command.identifier,
            type: "confirm_subscription",
          }),
        );
    });
  });
}
