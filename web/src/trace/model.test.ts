import { describe, expect, it } from "vitest";

import type { Span } from "../chat/api";
import {
  formatClock,
  formatDuration,
  formatTokens,
  placeLocal,
  turnsOf,
} from "./model";

// Spans as the server sends them (app/models/trace_recorder.rb,
// app/models/turn_trace.rb), for one answered turn: the root from the
// message's receipt, two model calls around a tool call, and the reply.
function span(
  name: string,
  fields: Partial<Span> & { at: string; until?: string | null },
): Span {
  const { at, until, ...rest } = fields;
  return {
    turn_id: "t1",
    trace_id: "a".repeat(32),
    span_id: `${name}-${at}`,
    parent_span_id: name === "balcao.turn" ? null : "root",
    name,
    attributes: {},
    started_at: at,
    finished_at: until === undefined ? at : until,
    ...rest,
  };
}

const T = (s: string) => `2026-11-12T15:03:${s}.000Z`;

const answered = (turn = "t1", outcome = "replied"): Span[] => [
  span("balcao.turn", {
    turn_id: turn,
    span_id: `${turn}-root`,
    at: T("41"),
    until: T("44"),
    attributes: {
      "balcao.channel": "web",
      "balcao.turn.outcome": outcome,
    },
  }),
  span("anthropic.messages.create", {
    turn_id: turn,
    at: T("41"),
    until: T("42"),
    attributes: {
      "gen_ai.request.model": "claude-opus-5-5",
      "gen_ai.response.model": "claude-opus-5-5",
      "gen_ai.request.reasoning.level": "medium",
      "anthropic.message.stop_reason": "tool_use",
      "balcao.latency_ms": 1100,
      "balcao.system_prompt.characters": 11_800,
      "balcao.system_prompt.sha256": "9f2c41d0aabbccdd",
      "gen_ai.usage.input_tokens": 3100,
      "gen_ai.usage.cache_read.input_tokens": 2800,
      "gen_ai.usage.cache_write.input_tokens": 300,
      "gen_ai.usage.output_tokens": 42,
    },
  }),
  span("anthropic.custom_tool_use search_products", {
    turn_id: turn,
    at: T("42"),
    attributes: {
      "gen_ai.tool.name": "search_products",
      "gen_ai.tool.call.arguments": '{"query":"dipirona"}',
      "anthropic.tool_result.content": '{"products":[]}',
      "balcao.tool_result.characters": 640,
      "balcao.tool_result.unit": "products",
      "balcao.tool_result.count": 2,
      "balcao.latency_ms": 38,
    },
  }),
  span("anthropic.messages.create", {
    turn_id: turn,
    at: T("43"),
    until: T("44"),
    attributes: {
      "gen_ai.request.model": "claude-opus-5-5",
      "anthropic.message.stop_reason": "end_turn",
      "balcao.latency_ms": 1600,
      "gen_ai.usage.input_tokens": 3700,
      "gen_ai.usage.cache_read.input_tokens": 3100,
      "gen_ai.usage.cache_write.input_tokens": 600,
      "gen_ai.usage.output_tokens": 98,
    },
  }),
  span("balcao.outbound", { turn_id: turn, at: T("44") }),
];

describe("FR-12 the glass box's rows, one per model call, from the spans", () => {
  it("draws a turn as its receipt, each model call, each tool call and its reply, in order", () => {
    const [turn, ...more] = turnsOf(answered());

    expect(more).toEqual([]);
    expect(turn?.number).toBe(1);
    expect(turn?.durationMs).toBe(3000);
    expect(turn?.running).toBe(false);
    expect(turn?.rows.map((row) => row.kind)).toEqual([
      "received",
      "model",
      "tool",
      "model",
      "sent",
    ]);
    expect(turn?.rows[1]).toMatchObject({
      model: "claude-opus-5-5",
      effort: "medium",
      stop: "tool_use",
      latencyMs: 1100,
      prompt: { characters: 11_800, digest: "9f2c41d0" },
      input: 3100,
      cacheRead: 2800,
      cacheWrite: 300,
      output: 42,
      error: null,
      running: false,
    });
    expect(turn?.rows[2]).toMatchObject({
      name: "search_products",
      args: '{"query":"dipirona"}',
      result: '{"products":[]}',
      characters: 640,
      count: 2,
      unit: "products",
      failed: false,
      latencyMs: 38,
    });
    expect(turn?.rows[4]).toMatchObject({ kind: "sent", outcome: null });
  });

  it("numbers the turns in the order they started, whatever order the spans came in", () => {
    const turns = turnsOf([
      ...answered("t2").map((each) => ({
        ...each,
        started_at: each.started_at.replace("15:03", "15:05"),
        finished_at: each.finished_at?.replace("15:03", "15:05") ?? null,
      })),
      ...answered("t1"),
    ]);

    expect(turns.map((turn) => [turn.id, turn.number])).toEqual([
      ["t1", 1],
      ["t2", 2],
    ]);
  });

  it("shows a model call that runs with what is known at its start, and a turn that runs without its time", () => {
    const [turn] = turnsOf([
      span("balcao.turn", { at: T("41"), until: null, span_id: "root" }),
      span("anthropic.messages.create", {
        at: T("41"),
        until: null,
        attributes: {
          "gen_ai.request.model": "claude-opus-5-5",
          "gen_ai.request.reasoning.level": "medium",
        },
      }),
    ]);

    expect(turn?.running).toBe(true);
    expect(turn?.durationMs).toBeNull();
    expect(turn?.rows[1]).toMatchObject({
      kind: "model",
      running: true,
      model: "claude-opus-5-5",
      effort: "medium",
      stop: null,
      input: null,
    });
  });

  it("gives a fixed reply's sent row the turn's outcome, and a failed call its error", () => {
    const spans = answered("t1", "model_error");
    const [first] = spans.filter(
      (each) => each.name === "anthropic.messages.create",
    );
    if (first)
      first.attributes["error.type"] = "Anthropic::Errors::InternalServerError";

    const [turn] = turnsOf(spans);

    expect(turn?.rows.at(-1)).toMatchObject({
      kind: "sent",
      outcome: "model_error",
    });
    expect(turn?.rows[1]).toMatchObject({
      error: "Anthropic::Errors::InternalServerError",
    });
  });

  // NFR-03: a turn the job tried again has a root per run, every one from the
  // message's receipt (review finding C7 of pull request #17).
  describe("a turn run more than once", () => {
    const broken = (until: string) => [
      span("balcao.turn", {
        span_id: `broken-${until}`,
        at: T("41"),
        until,
        attributes: { "error.type": "ActiveRecord::ConnectionFailed" },
      }),
      span("anthropic.messages.create", {
        span_id: `call-${until}`,
        at: T("41"),
        until,
        attributes: { "error.type": "ActiveRecord::ConnectionFailed" },
      }),
    ];
    const gaveUp = [
      span("balcao.turn", {
        span_id: "dead",
        at: T("41"),
        until: T("50"),
        attributes: {
          "balcao.turn.outcome": "dead_letter",
          "error.type": "ActiveRecord::ConnectionFailed",
        },
      }),
      span("balcao.outbound", { span_id: "fallback", at: T("50") }),
    ];

    it("takes the outcome and the time from the run that ended last, whatever order the roots came in", () => {
      for (const spans of [
        [...broken(T("42")), ...broken(T("46")), ...gaveUp],
        [...gaveUp, ...broken(T("46")), ...broken(T("42"))],
      ]) {
        const [turn] = turnsOf(spans);

        expect(turn?.durationMs).toBe(9000);
        expect(turn?.running).toBe(false);
        expect(turn?.rows.at(-1)).toMatchObject({
          kind: "sent",
          outcome: "dead_letter",
        });
      }
    });

    it("counts a run still going as the last, so the turn runs", () => {
      const [turn] = turnsOf([
        span("balcao.turn", { span_id: "again", at: T("41"), until: null }),
        ...broken(T("42")),
      ]);

      expect(turn?.running).toBe(true);
      expect(turn?.durationMs).toBeNull();
    });

    it("draws no sent row for a reply a broken run never stored", () => {
      const [turn] = turnsOf([
        ...broken(T("42")),
        span("balcao.outbound", {
          span_id: "lost",
          at: T("42"),
          attributes: { "error.type": "ActiveRecord::ConnectionFailed" },
        }),
        ...gaveUp,
      ]);

      expect(
        turn?.rows.filter((row) => row.kind === "sent").map((row) => row.key),
      ).toEqual(["fallback"]);
    });
  });

  it("draws a command as a turn of one row, with no receipt and no reply", () => {
    const [turn] = turnsOf([
      span("balcao.command", {
        span_id: "root",
        parent_span_id: null,
        at: "2026-11-12T15:12:10.000Z",
        until: "2026-11-12T15:12:10.012Z",
        attributes: { "balcao.command.name": "trace" },
      }),
    ]);

    expect(turn?.rows).toEqual([
      {
        kind: "command",
        key: "root",
        at: "2026-11-12T15:12:10.000Z",
        name: "trace",
        durationMs: 12,
      },
    ]);
    expect(turn?.durationMs).toBe(12);
  });

  it("marks a tool call that refused or failed", () => {
    const spans = answered();
    const tool = spans[2];
    if (tool)
      tool.attributes = {
        ...tool.attributes,
        "error.type": "tool_error",
        "balcao.tool_result.count": undefined,
      };

    const [turn] = turnsOf(spans);

    expect(turn?.rows[2]).toMatchObject({ failed: true });
  });

  it("sums a turn's input, cache read and output for the trace page's total", () => {
    const [turn] = turnsOf(answered());

    expect(turn).toMatchObject({ input: 6800, cached: 5900, output: 140 });
  });
});

describe("FR-12 the glass box's own rows, for what the server did not trace", () => {
  it("puts each after the turn that had started before it, or first when none had", () => {
    const turns = turnsOf(answered());
    const placed = placeLocal(turns, [
      { kind: "limit", key: "l1", at: "2026-11-12T15:03:30.000Z" },
      { kind: "limit", key: "l2", at: "2026-11-12T15:04:02.000Z" },
    ]);

    expect(placed.leading.map((row) => row.key)).toEqual(["l1"]);
    expect(placed.turns[0]?.local.map((row) => row.key)).toEqual(["l2"]);
  });
});

describe("FR-12 the instrument's figures", () => {
  it("writes tokens in thousands past a thousand, in the page's language", () => {
    expect(formatTokens(42, "pt-BR")).toBe("42");
    expect(formatTokens(3100, "pt-BR")).toBe("3,1k");
    expect(formatTokens(22_000, "pt-BR")).toBe("22,0k");
    expect(formatTokens(3100, "en")).toBe("3.1k");
  });

  it("writes a duration in milliseconds under a second and in seconds past it", () => {
    expect(formatDuration(38, "pt-BR")).toBe("38 ms");
    expect(formatDuration(1100, "pt-BR")).toBe("1,1 s");
    expect(formatDuration(10_700, "es")).toBe("10,7 s");
    expect(formatDuration(3000, "en")).toBe("3.0 s");
  });

  it("writes the hour in São Paulo, wherever the visitor is", () => {
    expect(formatClock("2026-11-12T15:03:41.000Z", "pt-BR")).toBe("12:03:41");
    expect(formatClock("2026-11-12T15:03:41.000Z", "en")).toBe("12:03:41");
  });
});
