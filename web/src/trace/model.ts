import type { Span } from "../chat/api";

// The glass box and the trace page read a conversation's spans as turns of
// rows (FR-12; docs/prototype/chat.html and trace.html): one row per model
// call, in order, each opening when the call starts and completing in place.
// A turn's root span (app/models/turn_processor.rb) starts at the message's
// receipt and ends after the reply; a command is a root of its own and a turn
// of one row. Names and attributes are the server's (app/models/turn_trace.rb),
// which are the Anthropic SDK's own.

export type Row =
  | { kind: "received"; key: string; at: string }
  | {
      kind: "model";
      key: string;
      at: string;
      running: boolean;
      model: string | null;
      effort: string | null;
      stop: string | null;
      latencyMs: number | null;
      prompt: { characters: number; digest: string } | null;
      // The whole prompt: plain input, cache read and cache written.
      input: number | null;
      cacheRead: number | null;
      cacheWrite: number | null;
      output: number | null;
      error: string | null;
    }
  | {
      kind: "tool";
      key: string;
      at: string;
      running: boolean;
      name: string;
      latencyMs: number | null;
      args: string | null;
      // The result as the server keeps it, cut at 500 characters.
      result: string | null;
      // Its length before the cut, and what a list held, before the cut too.
      characters: number | null;
      count: number | null;
      unit: string | null;
      // A refusal and a failure are both the SDK's tool_error; a refusal
      // also carries the reason code of the rule that refused (design §10).
      failed: boolean;
      refusal: string | null;
      // The code of the reservation the call made (create_reservation).
      reservation: string | null;
    }
  // A fixed reply's sent row carries the turn's outcome.
  | { kind: "sent"; key: string; at: string; outcome: string | null }
  | {
      kind: "command";
      key: string;
      at: string;
      name: string;
      durationMs: number | null;
    }
  // The page's own rows (app/models/edge_limits.rb answers at the edge and
  // traces nothing; a message waits unrecorded until its turn starts).
  | { kind: "limit"; key: string; at: string }
  | { kind: "queued"; key: string; at: string; waitsFor: number };

export type LocalRow = Extract<Row, { kind: "limit" | "queued" }>;

export interface Turn {
  id: string;
  number: number;
  startedAt: string;
  // From the receipt to the reply; null while the turn runs.
  durationMs: number | null;
  running: boolean;
  rows: Row[];
  // The page's own rows that came after this turn started.
  local: LocalRow[];
  // Sums over the turn's model calls, for the trace page's foot.
  input: number;
  cached: number;
  output: number;
}

export const MAX_RESULT = 500;
const MODEL_CALL = "anthropic.messages.create";
const TOOL_CALL = "anthropic.custom_tool_use ";
const ROOTS = new Set(["balcao.turn", "balcao.command"]);
const OK_OUTCOMES = new Set(["replied"]);

const str = (attributes: Record<string, unknown>, key: string) => {
  const value = attributes[key];
  return typeof value === "string" ? value : null;
};
const num = (attributes: Record<string, unknown>, key: string) => {
  const value = attributes[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
};
const time = (iso: string) => Date.parse(iso);
const between = (from: string, until: string | null) =>
  until === null ? null : Math.max(0, time(until) - time(from));
const byStart = (a: { started_at: string }, b: { started_at: string }) =>
  time(a.started_at) - time(b.started_at);
// A span's end, one still open after every closed one.
const end = (span: Span) =>
  span.finished_at === null ? Infinity : time(span.finished_at);
const byEnd = (a: Span, b: Span) => {
  const [x, y] = [end(a), end(b)];
  return x === y ? 0 : x < y ? -1 : 1;
};

function modelRow(span: Span): Row {
  const a = span.attributes;
  const characters = num(a, "balcao.system_prompt.characters");
  const digest = str(a, "balcao.system_prompt.sha256");
  return {
    kind: "model",
    key: span.span_id,
    at: span.started_at,
    running: span.finished_at === null,
    model: str(a, "gen_ai.response.model") ?? str(a, "gen_ai.request.model"),
    effort: str(a, "gen_ai.request.reasoning.level"),
    stop: str(a, "anthropic.message.stop_reason"),
    latencyMs:
      num(a, "balcao.latency_ms") ?? between(span.started_at, span.finished_at),
    prompt:
      characters !== null && digest !== null
        ? { characters, digest: digest.slice(0, 8) }
        : null,
    input: num(a, "gen_ai.usage.input_tokens"),
    cacheRead: num(a, "gen_ai.usage.cache_read.input_tokens"),
    cacheWrite: num(a, "gen_ai.usage.cache_write.input_tokens"),
    output: num(a, "gen_ai.usage.output_tokens"),
    error: str(a, "error.type"),
  };
}

const toolName = (span: Span) =>
  str(span.attributes, "gen_ai.tool.name") ?? span.name.slice(TOOL_CALL.length);

// A reservation's code as the server draws it (app/models/reservation.rb).
const CODE = /^[0-9A-Z]+$/;

// The code of the reservation a create_reservation call made, read from its
// result (app/agent/tools/create_reservation.rb), never from the shape of a
// text (docs/prototype/chat-reservation.html): none for a refusal, a failure,
// another tool or a result the trace cut.
function reservationOf(span: Span): string | null {
  const a = span.attributes;
  const result = str(a, "anthropic.tool_result.content");
  if (
    toolName(span) !== "create_reservation" ||
    str(a, "error.type") !== null ||
    result === null
  )
    return null;
  try {
    const parsed: unknown = JSON.parse(result);
    const code =
      typeof parsed === "object" && parsed !== null && "code" in parsed
        ? parsed.code
        : null;
    return typeof code === "string" && CODE.test(code) ? code : null;
  } catch {
    return null;
  }
}

// The codes of the reservations a conversation's tool calls made, which its
// replies stamp wherever they write one (FR-07).
export function reservationCodes(spans: Span[]): string[] {
  return [
    ...new Set(
      spans
        .filter((span) => span.name.startsWith(TOOL_CALL))
        .map(reservationOf)
        .filter((code) => code !== null),
    ),
  ];
}

function toolRow(span: Span): Row {
  const a = span.attributes;
  const failed = str(a, "error.type") !== null;
  return {
    kind: "tool",
    key: span.span_id,
    at: span.started_at,
    running: span.finished_at === null,
    name: toolName(span),
    latencyMs:
      num(a, "balcao.latency_ms") ?? between(span.started_at, span.finished_at),
    args: str(a, "gen_ai.tool.call.arguments"),
    result: str(a, "anthropic.tool_result.content"),
    characters: num(a, "balcao.tool_result.characters"),
    count: num(a, "balcao.tool_result.count"),
    unit: str(a, "balcao.tool_result.unit"),
    failed,
    refusal: failed ? str(a, "balcao.tool_result.refusal") : null,
    reservation: reservationOf(span),
  };
}

function turnOf(id: string, spans: Span[]): Omit<Turn, "number"> | null {
  const sorted = [...spans].sort(byStart);
  // A turn run again (a crash, the job's next attempt or its dead letter,
  // NFR-03) has a root per run, each from the message's receipt: the first
  // gives the receipt, and the run that ended last, or still runs, the
  // outcome and the time (review finding C7 of pull request #17).
  const roots = sorted.filter((span) => ROOTS.has(span.name));
  const first = roots[0];
  const last = [...roots].sort(byEnd).at(-1);
  if (!first || !last) return null;

  const rows: Row[] = [];
  if (first.name === "balcao.command") {
    for (const root of roots)
      rows.push({
        kind: "command",
        key: root.span_id,
        at: root.started_at,
        name: str(root.attributes, "balcao.command.name") ?? "",
        durationMs: between(root.started_at, root.finished_at),
      });
  } else {
    rows.push({
      kind: "received",
      key: `${id}-received`,
      at: first.started_at,
    });
    const outcome = str(last.attributes, "balcao.turn.outcome");
    for (const span of sorted) {
      if (span.name === MODEL_CALL) rows.push(modelRow(span));
      else if (span.name.startsWith(TOOL_CALL)) rows.push(toolRow(span));
      // A run that broke while it stored its reply sent nothing.
      else if (
        span.name === "balcao.outbound" &&
        str(span.attributes, "error.type") === null
      )
        rows.push({
          kind: "sent",
          key: span.span_id,
          at: span.finished_at ?? span.started_at,
          outcome:
            outcome === null || OK_OUTCOMES.has(outcome) ? null : outcome,
        });
    }
  }

  const calls = sorted.filter((span) => span.name === MODEL_CALL);
  const sum = (key: string) =>
    calls.reduce((total, span) => total + (num(span.attributes, key) ?? 0), 0);
  return {
    id,
    startedAt: first.started_at,
    durationMs: between(first.started_at, last.finished_at),
    running: last.finished_at === null,
    rows,
    local: [],
    input: sum("gen_ai.usage.input_tokens"),
    cached: sum("gen_ai.usage.cache_read.input_tokens"),
    output: sum("gen_ai.usage.output_tokens"),
  };
}

// The turns of a conversation's spans, in the order they started, numbered
// from one. A turn whose root has not arrived yet waits for it.
export function turnsOf(spans: Span[]): Turn[] {
  const groups = new Map<string, Span[]>();
  for (const span of spans) {
    const group = groups.get(span.turn_id);
    if (group) group.push(span);
    else groups.set(span.turn_id, [span]);
  }
  return [...groups.entries()]
    .map(([id, group]) => turnOf(id, group))
    .filter((turn) => turn !== null)
    .sort((a, b) => time(a.startedAt) - time(b.startedAt))
    .map((turn, index) => ({ ...turn, number: index + 1 }));
}

// One span per id: a finished one is never replaced by its start, which a
// snapshot read before it finished may still hold.
export function withSpans(spans: Span[], incoming: Span[]): Span[] {
  const byId = new Map(spans.map((span) => [span.span_id, span]));
  for (const span of incoming) {
    const held = byId.get(span.span_id);
    if (!held || held.finished_at === null || span.finished_at !== null)
      byId.set(span.span_id, span);
  }
  return [...byId.values()];
}

// The page's own rows, each after the turn that had started before it, or
// first when none had.
export function placeLocal(
  turns: Turn[],
  rows: LocalRow[],
): { leading: LocalRow[]; turns: Turn[] } {
  const leading: LocalRow[] = [];
  const local = new Map<string, LocalRow[]>();
  for (const row of [...rows].sort((a, b) => time(a.at) - time(b.at))) {
    const before = turns.filter((turn) => time(turn.startedAt) <= time(row.at));
    const owner = before.at(-1);
    if (owner) local.set(owner.id, [...(local.get(owner.id) ?? []), row]);
    else leading.push(row);
  }
  return {
    leading,
    turns: turns.map((turn) => ({ ...turn, local: local.get(turn.id) ?? [] })),
  };
}

// --- The instrument's figures (design brief §5: tabular, the page's locale) ---

export function formatTokens(tokens: number, locale: string): string {
  if (tokens < 1000) return new Intl.NumberFormat(locale).format(tokens);
  const thousands = new Intl.NumberFormat(locale, {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1,
  }).format(tokens / 1000);
  return `${thousands}k`;
}

export function formatDuration(ms: number, locale: string): string {
  if (ms < 1000)
    return `${new Intl.NumberFormat(locale).format(Math.round(ms))} ms`;
  const seconds = new Intl.NumberFormat(locale, {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1,
  }).format(ms / 1000);
  return `${seconds} s`;
}

// The instrument's hours are São Paulo's (design §1.4), whoever reads them.
export const TIME_ZONE = "America/Sao_Paulo";

export function formatClock(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, {
    timeZone: TIME_ZONE,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(new Date(iso));
}
