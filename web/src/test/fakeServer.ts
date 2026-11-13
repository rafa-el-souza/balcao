import { vi } from "vitest";

import { serverClock } from "../chat/api";
import openers from "../openers.json";

// A stand-in for the Rails API of PR-09 and PR-11 (design §10, notes of
// 2026-11-11 and 2026-11-12), in the shapes the server answers: POST
// /api/session, POST /api/messages, GET /api/conversations/current and GET
// /api/trace, the token in X-Trace-Token. Each request is recorded; each answer can be set per
// test, or made from the request's body as POST /api/messages answers with
// the message it stored (stored, the default). The server's ids are UUIDs,
// strings on the wire; the helpers take a number for short and send its
// string.
export interface Recorded {
  method: string;
  path: string;
  headers: Headers;
  body: unknown;
}

type Answer = { status: number; body: unknown } | "network";
// An answer made from the request's body, as the server echoes a message.
type Reply = Answer | ((body: unknown) => Answer);

export interface ServerMessage {
  id: string;
  client_id: string | null;
  conversation_id: string;
  turn_id: string | null;
  author: "visitor" | "bot" | "operator" | "system";
  notice?: string | null;
  body: string;
  // The codes of the visitor's own reservations the message writes.
  codes?: string[];
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

// A reply to a message the server stored: its turn, a second after it.
export function replyTo(
  question: ServerMessage,
  body: string,
  fields: Partial<ServerMessage> = {},
): ServerMessage {
  return message({
    author: "bot",
    body,
    conversation_id: question.conversation_id,
    turn_id: question.turn_id,
    created_at: new Date(Date.parse(question.created_at) + 1000).toISOString(),
    ...fields,
  });
}

// POST /api/messages' answer (app/controllers/api/messages_controller.rb):
// the turn, and the message as the server stored it, with the id the page
// generated, its own turn and the server's time.
export function stored(
  request: unknown,
  fields: Partial<Omit<ServerMessage, "id" | "conversation_id" | "turn_id">> & {
    id?: Id;
    conversation_id?: Id;
    turn_id?: Id;
  } = {},
) {
  const { id, text, say } = request as {
    id: string;
    text?: string;
    say?: keyof typeof openers;
  };
  const copy = message({
    author: "visitor",
    body: text ?? (say ? openers[say].text : ""),
    client_id: id,
    turn_id: `t${String(nextId + 1)}`,
    created_at: new Date().toISOString(),
    ...fields,
  });
  return {
    status: 202,
    body: {
      turn_id: copy.turn_id,
      message_id: copy.id,
      conversation_id: copy.conversation_id,
      message: copy,
    },
  };
}

export function fakeServer() {
  // Each test starts with the browser's clock as the server's.
  serverClock.offset = 0;
  const requests: Recorded[] = [];
  const copies: ServerMessage[] = [];
  const answers = {
    session: [] as Reply[],
    current: [] as Reply[],
    messages: [] as Reply[],
    trace: [] as Reply[],
  };
  const defaults: Record<keyof typeof answers, Reply> = {
    session: {
      status: 201,
      body: { conversation_id: "1", trace_token: "t1", language: "pt-BR" },
    },
    current: conversation(1),
    messages: (body) => stored(body),
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
    const reply = answers[name].shift() ?? defaults[name];
    const answer = typeof reply === "function" ? reply(body) : reply;
    if (answer !== "network" && name === "messages") {
      const { message: copy } = answer.body as { message?: ServerMessage };
      if (copy) copies.push(copy);
    }
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
    // The messages the 202s answered with, as the server stored them.
    copies: () => copies,
    // The one the n-th 202 answered with; a test that asks for one the
    // server did not store is wrong.
    copy: (index = 0) => {
      const stored = copies[index];
      if (!stored) throw new Error(`no stored message ${String(index)}`);
      return stored;
    },
    sent: () => requests.filter((request) => request.path === "/api/messages"),
    polls: () =>
      requests.filter(
        (request) => request.path === "/api/conversations/current",
      ),
    traces: () => requests.filter((request) => request.path === "/api/trace"),
  };
}
