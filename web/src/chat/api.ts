import type { Locale } from "../locale";

// The public API of design §6.6 as PR-09 built it (design §10, note of
// 2026-11-11). Every request names the page's language in Accept-Language,
// since the server writes a limit's text and a deletion's confirmation in it
// before it reads any conversation. The visitor cookie rides along
// (same origin); the page never reads it.

// The server's ids are UUIDs; the page compares them and never reads them.
export interface ServerMessage {
  id: string;
  client_id: string | null;
  conversation_id: string;
  turn_id: string | null;
  author: "visitor" | "bot" | "operator" | "system";
  // A conversation's first reply carries the demo notice apart from its body
  // (FR-01; design §10, note of 2026-11-12).
  notice?: string | null;
  body: string;
  created_at: string;
}

// One span of a turn's trace, in the shape of OpenTelemetry (ADR-0010), as the
// streams and the endpoints carry it.
export interface Span {
  turn_id: string;
  trace_id: string;
  span_id: string;
  parent_span_id: string | null;
  name: string;
  attributes: Record<string, unknown>;
  started_at: string;
  finished_at: string | null;
}

export interface Session {
  conversation_id: string;
  trace_token: string;
  language: string;
}

export interface Snapshot {
  conversation: {
    id: string;
    language: string;
    state: string;
    trace_token: string;
  };
  messages: ServerMessage[];
  spans: Span[];
  pending: boolean;
}

// A message as a trace page shows it: its words and its turn (FR-12).
export interface TraceMessage {
  id: string;
  turn_id: string;
  author: ServerMessage["author"];
  notice: string | null;
  body: string;
  created_at: string;
}

export interface Trace {
  conversation: { started_at: string };
  messages: TraceMessage[];
  spans: Span[];
}

export interface Deleted {
  deleted: true;
  text: string;
}

export type Content = { text: string } | { say: string };

export type Outcome<T> =
  | { kind: "ok"; value: T }
  // FR-14: past a limit, with the fixed text in the page's language.
  | { kind: "limit"; text: string }
  // The visitor cookie is missing or unreadable.
  | { kind: "session" }
  // What was asked for does not exist (a trace link that expired).
  | { kind: "missing" }
  // The network, a server error, or an answer the page did not expect.
  | { kind: "failed" };

export interface Accepted {
  turn_id: string;
  conversation_id: string;
}

export interface Api {
  session(language: Locale): Promise<Outcome<Session>>;
  // A request given up by its caller (signal) answers failed.
  current(signal?: AbortSignal): Promise<Outcome<Snapshot | Deleted>>;
  send(id: string, content: Content): Promise<Outcome<Accepted>>;
  trace(token: string, signal?: AbortSignal): Promise<Outcome<Trace>>;
}

// The server's clock, as the Date of its answers gives it: the page's own
// rows are dated by it, and a running turn's time is counted against it,
// since the server's spans carry the server's hours (review finding C3 of
// pull request #17). A Date has whole seconds and its answer takes time to
// arrive, so it only places the server's clock between that second and the
// next one plus the request's round trip: the page's clock stands while it
// falls there, and a clock outside is moved to the middle (review finding R2
// of pull request #17), so a right clock is never pulled a second back.
export const serverClock = { offset: 0 };

export function serverNow(): number {
  return Date.now() + serverClock.offset;
}

export function setServerClock(
  date: string | null,
  sent: number,
  received: number,
): void {
  const earliest = Date.parse(date ?? "");
  if (Number.isNaN(earliest)) return;
  const latest = earliest + 1000 + Math.max(0, received - sent);
  const now = received + serverClock.offset;
  if (now >= earliest && now <= latest) return;
  serverClock.offset = (earliest + latest) / 2 - received;
}

// A request the server has not answered in this time is given up and counts
// as failed: the page says so beside the message, which is sent again with the
// same id (review finding C2 of pull request #14). The server's own hang is
// cut at 30 s by the proxy; the visitor's network can stall for minutes.
export const TIMEOUT_MS = 15_000;

export function createApi(locale: () => Locale): Api {
  async function request<T>(
    method: "GET" | "POST",
    path: string,
    body?: object,
    signal?: AbortSignal,
    extra: Record<string, string> = {},
  ): Promise<Outcome<T>> {
    const headers: Record<string, string> = {
      Accept: "application/json",
      "Accept-Language": locale(),
      ...extra,
    };
    if (body) headers["Content-Type"] = "application/json";
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
    }, TIMEOUT_MS);
    signal?.addEventListener("abort", () => {
      controller.abort();
    });
    let response: Response;
    let json: unknown;
    try {
      const sent = Date.now();
      response = await fetch(path, {
        method,
        headers,
        credentials: "same-origin",
        signal: controller.signal,
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      setServerClock(response.headers.get("Date"), sent, Date.now());
      json = await response.json().catch(() => null);
    } catch {
      return { kind: "failed" };
    } finally {
      clearTimeout(timer);
    }
    if (response.ok && json !== null) return { kind: "ok", value: json as T };
    if (response.status === 401) return { kind: "session" };
    if (response.status === 404) return { kind: "missing" };
    if (response.status === 429 && isLimit(json))
      return { kind: "limit", text: json.text };
    return { kind: "failed" };
  }

  return {
    session: (language) => request("POST", "/api/session", { language }),
    current: (signal) =>
      request("GET", "/api/conversations/current", undefined, signal),
    send: (id, content) => request("POST", "/api/messages", { id, ...content }),
    // The token travels in a header, never in the path or the query, which
    // kamal-proxy writes to the host's log (review finding V3 of pull request
    // #17).
    trace: (token, signal) =>
      request("GET", "/api/trace", undefined, signal, {
        "X-Trace-Token": token,
      }),
  };
}

function isLimit(json: unknown): json is { error: "limit"; text: string } {
  return (
    typeof json === "object" &&
    json !== null &&
    (json as { error?: unknown }).error === "limit" &&
    typeof (json as { text?: unknown }).text === "string"
  );
}
