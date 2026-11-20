import i18next from "i18next";
import { describe, expect, it } from "vitest";

import type { Span } from "../chat/api";
import chatSource from "../chat/Chat.tsx?raw";
import glassSource from "../chat/GlassBox.tsx?raw";
import threadSource from "../chat/Thread.tsx?raw";
import { createI18n } from "../i18n";
import {
  formatClock,
  formatDuration,
  formatMoney,
  formatTokens,
  placeLocal,
  turnsOf,
} from "./model";
import modelSource from "./model.ts?raw";
import rowsSource from "./Rows.tsx?raw";
import traceSource from "./TracePage.tsx?raw";

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

    // The fix review's R1 on pull request #45: a command's runs start at the
    // message's receipt, as the dead letter's run does, and the tie drew the
    // turn as a command, with a nameless row and no outcome.
    it("draws a command the job gave up on with the dead letter's outcome, every run from the receipt", () => {
      const command = (until: string) =>
        span("balcao.command", {
          span_id: `command-${until}`,
          parent_span_id: null,
          at: T("41"),
          until,
          attributes: {
            "balcao.command.name": "trace",
            "error.type": "RuntimeError",
          },
        });

      const [turn] = turnsOf([
        command(T("42")),
        command(T("45")),
        command(T("49")),
        ...gaveUp,
      ]);

      expect(turn?.rows.at(-1)).toMatchObject({
        kind: "sent",
        outcome: "dead_letter",
      });
      expect(turn?.rows).not.toContainEqual(
        expect.objectContaining({ kind: "command", name: "" }),
      );
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

  // #45's verifier, V4 (FR-12, FR-19; M4-4): the page read "mensagem
  // enviada" for every stored Telegram reply, one Telegram refused or that
  // failed after its attempts included. A Telegram reply's way to the chat
  // is a span of its own, open from its storage to Telegram's answer
  // (app/models/trace_recorder.rb, start_delivery and delivered).
  describe("a Telegram reply's way to the chat", () => {
    const delivery = (until: string | null, error?: string) =>
      span("balcao.delivery", {
        span_id: "delivery",
        at: T("44"),
        until,
        attributes: error === undefined ? {} : { "error.type": error },
      });
    const replies = (spans: Span[]) =>
      turnsOf(spans)[0]?.rows.filter(
        (row) => row.kind === "sent" || row.kind === "unsent",
      );

    it("draws the reply sent at the moment Telegram took it", () => {
      expect(replies([...answered(), delivery(T("47"))])).toEqual([
        { kind: "sent", key: "delivery", at: T("47"), outcome: null },
      ]);
    });

    it("draws the reply not sent when Telegram refused it or it failed after its attempts", () => {
      expect(
        replies([
          ...answered("t1", "fallback"),
          delivery(T("49"), "Telegram::Client::Error"),
        ]),
      ).toEqual([
        { kind: "unsent", key: "delivery", at: T("49"), outcome: "fallback" },
      ]);
    });

    // Review finding C8 of pull request #48 (the web finder's C1): the
    // unsent row dropped the turn's outcome, the only place that names a
    // fixed reply's reason (FR-12: the turn's outcome names the limit).
    it("keeps the outcome of a fixed reply that never left", () => {
      expect(
        replies([
          ...answered("t1", "tool_limit"),
          delivery(T("49"), "Telegram::Client::Error"),
        ]),
      ).toEqual([
        { kind: "unsent", key: "delivery", at: T("49"), outcome: "tool_limit" },
      ]);
    });

    // Review finding C9 of pull request #48 (the web finder's C2): until the
    // delivery span reached the page, the stored reply's row said "sent" for
    // a Telegram reply still on its way.
    it("draws no sent row while a Telegram run that stores its reply still goes", () => {
      const running = (outbound: string | null) => [
        span("balcao.turn", {
          span_id: "t1-root",
          at: T("41"),
          until: null,
          attributes: { "balcao.channel": "telegram" },
        }),
        span("anthropic.messages.create", {
          at: T("41"),
          until: T("43"),
          attributes: { "anthropic.message.stop_reason": "end_turn" },
        }),
        span("balcao.outbound", { at: T("44"), until: outbound }),
      ];

      expect(replies(running(null))).toEqual([]);
      expect(replies(running(T("44")))).toEqual([]);
    });

    // Review finding V4 of pull request #48: the run opens its reply's way
    // inside the transaction that stores the reply, so a run undone at its
    // commit leaves a way open on a live page, before the one that counts.
    it("takes the reply's way from the run that stored it, not from a run that was undone", () => {
      const undone = span("balcao.delivery", {
        span_id: "undone",
        at: T("42"),
        until: null,
      });

      expect(replies([...answered(), undone, delivery(T("47"))])).toEqual([
        { kind: "sent", key: "delivery", at: T("47"), outcome: null },
      ]);
    });

    it("takes a command's way from the run that stored its reply too", () => {
      const command = span("balcao.command", {
        span_id: "root",
        parent_span_id: null,
        at: T("10"),
        until: T("10"),
        attributes: { "balcao.command.name": "trace" },
      });
      const undone = span("balcao.delivery", {
        span_id: "undone",
        at: T("10"),
        until: null,
      });

      expect(
        turnsOf([
          command,
          undone,
          delivery(T("12"), "Telegram::Client::Error"),
        ])[0]?.rows.map((row) => row.kind),
      ).toEqual(["command", "unsent"]);
    });

    it("draws neither while the reply is on its way", () => {
      expect(replies([...answered(), delivery(null)])).toEqual([]);
    });

    it("keeps a fixed reply's outcome on the sent row", () => {
      expect(
        replies([...answered("t1", "fallback"), delivery(T("47"))]),
      ).toEqual([
        { kind: "sent", key: "delivery", at: T("47"), outcome: "fallback" },
      ]);
    });

    it("keeps the stored reply's row for a reply traced before its way had a span, as the web's", () => {
      expect(replies(answered())).toEqual([
        {
          kind: "sent",
          key: `balcao.outbound-${T("44")}`,
          at: T("44"),
          outcome: null,
        },
      ]);
    });

    it("adds to a command the row of its reply when it was not sent, and nothing when it was", () => {
      const command = span("balcao.command", {
        span_id: "root",
        parent_span_id: null,
        at: T("10"),
        until: T("10"),
        attributes: { "balcao.command.name": "trace" },
      });

      expect(
        turnsOf([command, delivery(T("12"), "Telegram::Client::Error")])[0]
          ?.rows,
      ).toEqual([
        {
          kind: "command",
          key: "root",
          at: T("10"),
          name: "trace",
          durationMs: 0,
        },
        { kind: "unsent", key: "delivery", at: T("12"), outcome: null },
      ]);
      expect(turnsOf([command, delivery(T("12"))])[0]?.rows).toHaveLength(1);
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

    expect(turn?.rows[2]).toMatchObject({ failed: true, refusal: null });
  });

  // The drawings' reason code (docs/prototype/chat-tool-refused.html): a
  // rule the tool enforces is told from its failure by the reason the
  // server gives it.
  it("gives a tool's refusal its reason code, which a failure lacks", () => {
    const spans = answered();
    const tool = spans[2];
    if (tool)
      tool.attributes = {
        ...tool.attributes,
        "error.type": "tool_error",
        "balcao.tool_result.refusal": "over_limit",
      };

    const [turn] = turnsOf(spans);

    expect(turn?.rows[2]).toMatchObject({
      failed: true,
      refusal: "over_limit",
    });
  });

  // docs/prototype/chat-reservation.html: the row names the reservation,
  // from the tool's result.
  it("reads the code of a reservation the tool made from its result", () => {
    const spans = answered();
    const tool = spans[2];
    if (tool)
      tool.attributes = {
        "gen_ai.tool.name": "create_reservation",
        "anthropic.tool_result.content":
          '{"code":"4K2QHM","quantity":2,"product":"Dipirona 500 mg","pickup_until":"2026-11-13T20:00:00-03:00"}',
      };

    const [turn] = turnsOf(spans);

    expect(turn?.rows[2]).toMatchObject({ reservation: "4K2QHM" });
  });

  it("reads no code from a refusal, another tool's result or a result that is not the reservation's", () => {
    const results: [string, string, string | undefined][] = [
      ["create_reservation", '{"code":"4K2QHM"}', "tool_error"],
      ["search_products", '{"code":"4K2QHM"}', undefined],
      [
        "create_reservation",
        '{"code":"4K2QHM","quantity":2,"product":"Dipir',
        undefined,
      ],
      ["create_reservation", '{"code":["4K2QHM"]}', undefined],
      ["create_reservation", '{"code":"<b>4K</b>"}', undefined],
      ["create_reservation", "[1]", undefined],
    ];
    for (const [name, content, error] of results) {
      const spans = answered();
      const tool = spans[2];
      if (tool)
        tool.attributes = {
          "gen_ai.tool.name": name,
          "anthropic.tool_result.content": content,
          "error.type": error,
        };

      const [turn] = turnsOf(spans);

      expect(turn?.rows[2], content).toMatchObject({ reservation: null });
    }
  });

  it("sums a turn's input, cache read and output for the trace page's total", () => {
    const [turn] = turnsOf(answered());

    expect(turn).toMatchObject({ input: 6800, cached: 5900, output: 140 });
  });

  describe("the costs (FR-12, FR-14)", () => {
    const priced = (costs: (number | undefined)[]) => {
      const spans = answered();
      spans
        .filter((item) => item.name === "anthropic.messages.create")
        .forEach((call, index) => {
          if (costs[index] !== undefined)
            call.attributes["balcao.cost.usd"] = costs[index];
        });
      return spans;
    };

    it("reads each model call's cost in US dollars, and sums the turn's", () => {
      const [turn] = turnsOf(priced([0.003, 0.006]));

      expect(
        turn?.rows.flatMap((row) => (row.kind === "model" ? [row.cost] : [])),
      ).toEqual([0.003, 0.006]);
      expect(turn?.cost).toBeCloseTo(0.009, 9);
    });

    it("has no turn cost while a call that answered has none, as a turn traced before the costs", () => {
      expect(turnsOf(priced([0.003, undefined]))[0]?.cost).toBeNull();
      expect(turnsOf(answered())[0]?.cost).toBeNull();
    });

    it("counts a call that failed as costing nothing, and a turn with no call as one that cost nothing", () => {
      const spans = priced([undefined, 0.006]);
      const first = spans.find(
        (item) => item.name === "anthropic.messages.create",
      );
      if (first)
        first.attributes = {
          "error.type": "Anthropic::Errors::OverloadedError",
        };

      expect(turnsOf(spans)[0]?.cost).toBeCloseTo(0.006, 9);
      expect(turnsOf(priced([0, 0]))[0]?.cost).toBe(0);
      expect(
        turnsOf([
          span("balcao.command", {
            at: T("50"),
            attributes: { "balcao.command.name": "trace" },
          }),
        ])[0]?.cost,
      ).toBe(0);
    });

    it("leaves a call that still runs out of the turn's sum", () => {
      const spans = priced([0.003, undefined]);
      const last = spans.filter(
        (item) => item.name === "anthropic.messages.create",
      )[1];
      if (last) {
        last.finished_at = null;
        last.attributes = { "gen_ai.request.model": "claude-opus-5-5" };
      }

      expect(turnsOf(spans)[0]?.cost).toBeCloseTo(0.003, 9);
    });
  });
});

// FR-20: the guardrail's check of the reply is a span of its own
// (app/models/turn_trace.rb, GUARDRAIL), after the model's last call and
// before the reply, with its verdict, or the error that left it without one.
describe("FR-20 FR-12 the guardrail's row", () => {
  const checked = (
    attributes: Record<string, unknown>,
    until: string | null = T("45"),
    outcome = "replied",
  ): Span[] => [
    ...answered("t1", outcome).filter(
      (item) => item.name !== "balcao.outbound",
    ),
    span("balcao.guardrail", {
      at: T("44"),
      until,
      attributes: {
        "gen_ai.request.model": "claude-haiku-5-5",
        "gen_ai.request.reasoning.level": "low",
        ...attributes,
      },
    }),
    span("balcao.outbound", { at: T("45") }),
  ];
  const passed = {
    "gen_ai.response.model": "claude-haiku-5-5",
    "anthropic.message.stop_reason": "end_turn",
    "balcao.latency_ms": 420,
    "gen_ai.usage.input_tokens": 640,
    "gen_ai.usage.output_tokens": 38,
    "balcao.cost.usd": 0.000083,
    "balcao.guardrail.clinical": false,
  };
  const guardrail = (spans: Span[]) =>
    turnsOf(spans)[0]?.rows.find((row) => row.kind === "guardrail");

  it("draws the check after the model's calls and before the reply, with its verdict, model, time and cost", () => {
    const [turn] = turnsOf(checked(passed));

    expect(turn?.rows.map((row) => row.kind)).toEqual([
      "received",
      "model",
      "tool",
      "model",
      "guardrail",
      "sent",
    ]);
    expect(guardrail(checked(passed))).toMatchObject({
      verdict: "pass",
      running: false,
      model: "claude-haiku-5-5",
      latencyMs: 420,
      input: 640,
      output: 38,
      cost: 0.000083,
      error: null,
    });
  });

  // The row says what the check found; what happened to the reply is the
  // reply's own row's (review finding W1 of pull request #54).
  it("says the check found clinical advice, and the reply's row that it was replaced", () => {
    const spans = checked(
      { ...passed, "balcao.guardrail.clinical": true },
      T("45"),
      "replaced",
    );

    expect(guardrail(spans)).toMatchObject({ verdict: "clinical" });
    expect(turnsOf(spans)[0]?.rows.at(-1)).toMatchObject({
      kind: "sent",
      outcome: "replaced",
    });
  });

  // Threat model R4: a check that gave no verdict closed its own span, with
  // its time and its error, and the reply went as the model wrote it.
  it("says the check gave no verdict, with its error, when it closed without one", () => {
    expect(
      guardrail(
        checked({
          "balcao.latency_ms": 5004,
          "error.type": "Anthropic::Errors::APITimeoutError",
        }),
      ),
    ).toMatchObject({
      verdict: "failed",
      error: "Anthropic::Errors::APITimeoutError",
      cost: null,
    });
  });

  // Review finding W1 of pull request #54: a span closed by a run that
  // broke or stopped during the check (TraceRecorder.close_interrupted,
  // TraceRecorder#abandon) has no time of the check's own; that run stored
  // no reply, so the row may not say the check failed and the reply left.
  it("tells a run that stopped during the check from a check that gave no verdict", () => {
    for (const error of ["interrupted", "ActiveRecord::StatementInvalid"])
      expect(
        guardrail(checked({ "error.type": error }, T("45"), "dead_letter")),
      ).toMatchObject({ verdict: "interrupted", error });
  });

  it("shows the check running until it answers", () => {
    expect(guardrail(checked({}, null))).toMatchObject({
      running: true,
      verdict: null,
    });
  });

  it("counts the check in the turn's tokens and cost, as the ledger charges it", () => {
    const spans = checked(passed);
    for (const call of spans.filter(
      (item) => item.name === "anthropic.messages.create",
    ))
      call.attributes["balcao.cost.usd"] = 0.004;

    const [turn] = turnsOf(spans);

    expect(turn).toMatchObject({ input: 6800 + 640, output: 140 + 38 });
    expect(turn?.cost).toBeCloseTo(0.008083, 9);
  });

  it("counts a check that failed as costing nothing", () => {
    const spans = checked({
      "error.type": "Anthropic::Errors::OverloadedError",
    });
    for (const call of spans.filter(
      (item) => item.name === "anthropic.messages.create",
    ))
      call.attributes["balcao.cost.usd"] = 0.004;

    expect(turnsOf(spans)[0]?.cost).toBeCloseTo(0.008, 9);
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
  const ptBR = createI18n("pt-BR");
  const en = createI18n("en");
  const es = createI18n("es");

  it("writes tokens in thousands past a thousand, in the page's language", () => {
    expect(formatTokens(42, ptBR)).toBe("42");
    expect(formatTokens(3100, ptBR)).toBe("3,1k");
    expect(formatTokens(22_000, ptBR)).toBe("22,0k");
    expect(formatTokens(3100, en)).toBe("3.1k");
  });

  it("writes a duration in milliseconds under a second and in seconds past it", () => {
    // A no-break space joins the figure to its unit, so a narrow row never
    // parts them (docs/prototype/landing.html's note; the owner's round at
    // the MVP close, row 35-nbsp).
    expect(formatDuration(38, ptBR)).toBe("38\u00a0ms");
    expect(formatDuration(1100, ptBR)).toBe("1,1\u00a0s");
    expect(formatDuration(10_700, es)).toBe("10,7\u00a0s");
    expect(formatDuration(3000, en)).toBe("3.0\u00a0s");
  });

  // The owner's round at the MVP close, row 29-V1w (the interface review's
  // W9; NFR-09): a unit is a word of the locale files, which a language that
  // writes it otherwise changes there, and nowhere in the code.
  it("takes the units from the locale files", () => {
    const other = i18next.createInstance();
    void other.init({
      lng: "pt-BR",
      initAsync: false,
      interpolation: { escapeValue: false },
      resources: {
        "pt-BR": {
          translation: {
            instrument: {
              units: {
                ms: "{{value}} mseg",
                s: "{{value}} seg",
                thousands: "{{value}} mil",
              },
            },
          },
        },
      },
    });

    expect(formatDuration(2800, other)).toBe("2,8 seg");
    expect(formatDuration(38, other)).toBe("38 mseg");
    expect(formatTokens(3100, other)).toBe("3,1 mil");
  });

  it("leaves units and separators to the locale files", () => {
    // Comments may quote what the page shows; the code may not write it.
    const code = (source: string) =>
      source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
    for (const source of [
      modelSource,
      rowsSource,
      traceSource,
      glassSource,
      chatSource,
      threadSource,
    ]) {
      expect(code(source)).not.toMatch(/[·…]/);
      expect(code(source)).not.toMatch(/\}(\\u00a0| )?(ms|s|k)`/);
    }
  });

  it("writes dollars to three decimals and reais to two, more where a small figure would round to zero", () => {
    expect(formatMoney(0.009, "usd", "pt-BR")).toBe("0,009");
    expect(formatMoney(0.0495, "usd", "en")).toBe("0.050");
    expect(formatMoney(0.0002, "usd", "es")).toBe("0,0002");
    expect(formatMoney(0.009 * 5.6518, "brl", "pt-BR")).toBe("0,05");
    expect(formatMoney(0.0002 * 5.6518, "brl", "pt-BR")).toBe("0,001");
    expect(formatMoney(1.234, "usd", "pt-BR")).toBe("1,234");
  });

  // Review finding C6 of pull request #29 (NFR-09): the symbols are the
  // locale files' words, which the figure fills.
  it("leaves the currency's symbol to the locale files", () => {
    expect(`${modelSource}\n${rowsSource}`).not.toMatch(/"(US|R)\$/);
  });

  it("writes the hour in São Paulo, wherever the visitor is", () => {
    expect(formatClock("2026-11-12T15:03:41.000Z", "pt-BR")).toBe("12:03:41");
    expect(formatClock("2026-11-12T15:03:41.000Z", "en")).toBe("12:03:41");
  });
});
