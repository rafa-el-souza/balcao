import type { Locale } from "../locale";

// The public API of design §6.6 as PR-09 built it (design §10, note of
// 2026-11-11). Every request names the page's language in Accept-Language,
// since the server writes a limit's text and a deletion's confirmation in it
// before it reads any conversation. The visitor cookie rides along
// (same origin); the page never reads it.

export interface ServerMessage {
  id: number;
  client_id: string | null;
  conversation_id: number;
  turn_id: number | null;
  author: "visitor" | "bot" | "operator" | "system";
  body: string;
  created_at: string;
}

export interface Session {
  conversation_id: number;
  trace_token: string;
  language: string;
}

export interface Snapshot {
  conversation: {
    id: number;
    language: string;
    state: string;
    trace_token: string;
  };
  messages: ServerMessage[];
  spans: unknown[];
  pending: boolean;
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
  // The network, a server error, or an answer the page did not expect.
  | { kind: "failed" };

export interface Api {
  session(language: Locale): Promise<Outcome<Session>>;
  current(): Promise<Outcome<Snapshot | Deleted>>;
  send(
    id: string,
    content: Content,
  ): Promise<Outcome<{ conversation_id: number }>>;
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
  ): Promise<Outcome<T>> {
    const headers: Record<string, string> = {
      Accept: "application/json",
      "Accept-Language": locale(),
    };
    if (body) headers["Content-Type"] = "application/json";
    const controller = new AbortController();
    const timer = setTimeout(() => {
      controller.abort();
    }, TIMEOUT_MS);
    let response: Response;
    let json: unknown;
    try {
      response = await fetch(path, {
        method,
        headers,
        credentials: "same-origin",
        signal: controller.signal,
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      json = await response.json().catch(() => null);
    } catch {
      return { kind: "failed" };
    } finally {
      clearTimeout(timer);
    }
    if (response.ok && json !== null) return { kind: "ok", value: json as T };
    if (response.status === 401) return { kind: "session" };
    if (response.status === 429 && isLimit(json))
      return { kind: "limit", text: json.text };
    return { kind: "failed" };
  }

  return {
    session: (language) => request("POST", "/api/session", { language }),
    current: () => request("GET", "/api/conversations/current"),
    send: (id, content) => request("POST", "/api/messages", { id, ...content }),
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
