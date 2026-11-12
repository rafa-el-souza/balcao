import { vi } from "vitest";

import { serverClock } from "../chat/api";

// A stand-in for the Rails API of PR-09 and PR-11 (design §10, notes of
// 2026-11-11 and 2026-11-12), in the shapes the server answers: POST
// /api/session, POST /api/messages, GET /api/conversations/current and GET
// /api/trace, the token in X-Trace-Token. Each request is recorded; each answer can be set per
// test. The server's ids are UUIDs, strings on the wire; the helpers take a
// number for short and send its string.
export interface Recorded {
  method: string;
  path: string;
  headers: Headers;
  body: unknown;
}

type Answer = { status: number; body: unknown } | "network";

export interface ServerMessage {
  id: string;
  client_id: string | null;
  conversation_id: string;
  turn_id: string | null;
  author: "visitor" | "bot" | "operator" | "system";
  notice?: string | null;
  body: string;
  created_at: string;
}

export interface ServerSpan {
  turn_id: string;
  trace_id: string;
  span_id: string;
  parent_span_id: string | null;
  name: string;
  attributes: Record<string, unknown>;
  started_at: string;
  finished_at: string | null;
}

type Id = number | string;

export function conversation(
  id: Id,
  messages: ServerMessage[] = [],
  pending = false,
  spans: ServerSpan[] = [],
) {
  return {
    status: 200,
    body: {
      conversation: {
        id: String(id),
        language: "pt-BR",
        state: "active",
        trace_token: `t${String(id)}`,
      },
      messages,
      spans,
      pending,
    },
  };
}

let nextId = 100;
export function message(
  fields: Partial<Omit<ServerMessage, "id" | "conversation_id" | "turn_id">> & {
    id?: Id;
    conversation_id?: Id;
    turn_id?: Id | null;
  } & Pick<ServerMessage, "author" | "body">,
): ServerMessage {
  nextId += 1;
  const { id, conversation_id, turn_id, ...rest } = fields;
  return {
    client_id: null,
    created_at: "2026-11-12T12:03:41.000-03:00",
    ...rest,
    id: String(id ?? nextId),
    conversation_id: String(conversation_id ?? 1),
    turn_id: turn_id === null ? null : String(turn_id ?? 1),
  };
}

export function fakeServer() {
  // Each test starts with the browser's clock as the server's.
  serverClock.offset = 0;
  const requests: Recorded[] = [];
  const answers = {
    session: [] as Answer[],
    current: [] as Answer[],
    messages: [] as Answer[],
    trace: [] as Answer[],
  };
  const defaults: Record<keyof typeof answers, Answer> = {
    session: {
      status: 201,
      body: { conversation_id: "1", trace_token: "t1", language: "pt-BR" },
    },
    current: conversation(1),
    messages: {
      status: 202,
      body: { turn_id: "1", message_id: "1", conversation_id: "1" },
    },
    trace: { status: 404, body: { error: "not_found" } },
  };

  const route = (method: string, path: string): keyof typeof answers => {
    if (method === "POST" && path === "/api/session") return "session";
    if (method === "POST" && path === "/api/messages") return "messages";
    if (method === "GET" && path === "/api/conversations/current")
      return "current";
    if (method === "GET" && path === "/api/trace") return "trace";
    throw new Error(`no route for ${method} ${path}`);
  };

  const fetch = vi.fn((path: string, init: RequestInit = {}) => {
    const method = init.method ?? "GET";
    if (init.signal?.aborted)
      return Promise.reject(new DOMException("aborted", "AbortError"));
    const headers = new Headers(init.headers);
    const body: unknown =
      typeof init.body === "string" ? JSON.parse(init.body) : undefined;
    requests.push({ method, path, headers, body });
    const name = route(method, path);
    const answer = answers[name].shift() ?? defaults[name];
    if (answer === "network")
      return Promise.reject(new TypeError("Failed to fetch"));
    return Promise.resolve(
      new Response(JSON.stringify(answer.body), {
        status: answer.status,
        headers: { "Content-Type": "application/json" },
      }),
    );
  });

  return {
    fetch,
    requests,
    answers,
    defaults,
    sent: () => requests.filter((request) => request.path === "/api/messages"),
    polls: () =>
      requests.filter(
        (request) => request.path === "/api/conversations/current",
      ),
    traces: () => requests.filter((request) => request.path === "/api/trace"),
  };
}
