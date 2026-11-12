import { vi } from "vitest";

// A stand-in for the Rails API of PR-09 (design §10, note of 2026-11-11), in
// the shapes the server answers: POST /api/session, POST /api/messages and
// GET /api/conversations/current. Each request is recorded; each answer can
// be set per test.
export interface Recorded {
  method: string;
  path: string;
  headers: Headers;
  body: unknown;
}

type Answer = { status: number; body: unknown } | "network";

export interface ServerMessage {
  id: number;
  client_id: string | null;
  conversation_id: number;
  turn_id: number | null;
  author: "visitor" | "bot" | "operator" | "system";
  body: string;
  created_at: string;
}

export function conversation(
  id: number,
  messages: ServerMessage[] = [],
  pending = false,
) {
  return {
    status: 200,
    body: {
      conversation: {
        id,
        language: "pt-BR",
        state: "active",
        trace_token: `t${String(id)}`,
      },
      messages,
      spans: [],
      pending,
    },
  };
}

let nextId = 100;
export function message(
  fields: Partial<ServerMessage> & Pick<ServerMessage, "author" | "body">,
): ServerMessage {
  nextId += 1;
  return {
    id: nextId,
    client_id: null,
    conversation_id: 1,
    turn_id: 1,
    created_at: "2026-11-12T12:03:41.000-03:00",
    ...fields,
  };
}

export function fakeServer() {
  const requests: Recorded[] = [];
  const answers = {
    session: [] as Answer[],
    current: [] as Answer[],
    messages: [] as Answer[],
  };
  const defaults: Record<keyof typeof answers, Answer> = {
    session: {
      status: 201,
      body: { conversation_id: 1, trace_token: "t1", language: "pt-BR" },
    },
    current: conversation(1),
    messages: {
      status: 202,
      body: { turn_id: 1, message_id: 1, conversation_id: 1 },
    },
  };

  const route = (method: string, path: string): keyof typeof answers => {
    if (method === "POST" && path === "/api/session") return "session";
    if (method === "POST" && path === "/api/messages") return "messages";
    if (method === "GET" && path === "/api/conversations/current")
      return "current";
    throw new Error(`no route for ${method} ${path}`);
  };

  const fetch = vi.fn((path: string, init: RequestInit = {}) => {
    const method = init.method ?? "GET";
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
  };
}
