import type { Content, Deleted, ServerMessage, Snapshot } from "./api";

// The conversation on the page (design §6.9: a React reducer, not server
// cache). Two parts, drawn as one thread:
//
// - the server's messages of the current conversation, in the server's own
//   order, as the last snapshot gave them;
// - the page's own entries: a message on its way or accepted but not yet in a
//   snapshot (drawn after everything the server has), and what the server
//   never stored, a message that failed or met a limit and the limit's stamp
//   (drawn after the server message that was the last one when it happened).
//
// A message the page sent leaves its own part when a snapshot holds it,
// matched by the id the page generated (client_id), so it takes the server's
// place in the order (review finding C1 of pull request #14).

export type Voice = "visitor" | "attendant" | "pharmacist" | "stamp";

export interface Entry {
  key: string;
  voice: Voice;
  text: string;
  // An opener's language, when it is not the page's.
  lang?: string;
  // The page's own message: the id it generated, its state and its content.
  clientId?: string;
  status?: "sending" | "sent" | "failed" | "limited";
  content?: Content;
}

interface Own extends Entry {
  // The server message this entry follows; null before any.
  after: number | null;
  // The conversation the server accepted it into (the 202's answer).
  conversationId?: number;
}

export interface State {
  phase: "loading" | "ready" | "failed";
  conversationId: number | null;
  // FR-05's confirmation, when the visitor's data is gone.
  deleted: string | null;
  pending: boolean;
  server: ServerMessage[];
  own: Own[];
  // The languages of the openers the page sent, by client id.
  langs: Record<string, string>;
}

export type Action =
  | { type: "loaded" }
  | { type: "loadFailed" }
  | {
      type: "sending";
      clientId: string;
      content: Content;
      text: string;
      lang?: string;
    }
  | { type: "accepted"; clientId: string; conversationId: number }
  | { type: "failed"; clientId: string }
  | { type: "limited"; clientId: string | null; text: string }
  | { type: "retrying"; clientId: string }
  | { type: "snapshot"; answer: Snapshot | Deleted };

export const initialState: State = {
  phase: "loading",
  conversationId: null,
  deleted: null,
  pending: false,
  server: [],
  own: [],
  langs: {},
};

const VOICES: Record<ServerMessage["author"], Voice> = {
  visitor: "visitor",
  bot: "attendant",
  operator: "pharmacist",
  system: "stamp",
};

const lastServerId = (state: State) => state.server.at(-1)?.id ?? null;

// An entry the page still waits on: drawn after everything the server has.
const travelling = (entry: Own) =>
  entry.status === "sending" || entry.status === "sent";

function update(state: State, clientId: string, change: Partial<Own>): State {
  return {
    ...state,
    own: state.own.map((entry) =>
      entry.clientId === clientId ? { ...entry, ...change } : entry,
    ),
  };
}

export function reduce(state: State, action: Action): State {
  switch (action.type) {
    case "loaded":
      return { ...state, phase: state.phase === "failed" ? "failed" : "ready" };
    case "loadFailed":
      return { ...state, phase: "failed" };
    case "sending":
      return {
        ...state,
        own: [
          ...state.own,
          {
            key: `l${action.clientId}`,
            voice: "visitor",
            text: action.text,
            clientId: action.clientId,
            status: "sending",
            content: action.content,
            after: null,
            ...(action.lang ? { lang: action.lang } : {}),
          },
        ],
        langs: action.lang
          ? { ...state.langs, [action.clientId]: action.lang }
          : state.langs,
      };
    case "accepted":
      return update(state, action.clientId, {
        status: "sent",
        conversationId: action.conversationId,
      });
    case "failed":
      return update(state, action.clientId, {
        status: "failed",
        after: lastServerId(state),
      });
    case "retrying":
      return update(state, action.clientId, { status: "sending" });
    case "limited": {
      const after = lastServerId(state);
      const limited = action.clientId
        ? update(state, action.clientId, { status: "limited", after })
        : state;
      // The message moves to where the stamp is: both are the page's own now.
      const own = limited.own.filter(
        (entry) => entry.clientId !== action.clientId,
      );
      const message = limited.own.find(
        (entry) => action.clientId && entry.clientId === action.clientId,
      );
      return {
        ...limited,
        own: [
          ...own,
          ...(message ? [message] : []),
          {
            key: `limit${String(state.own.length)}`,
            voice: "stamp",
            text: action.text,
            after,
          },
        ],
      };
    }
    case "snapshot":
      return merge(state, action.answer);
  }
}

function merge(state: State, answer: Snapshot | Deleted): State {
  if ("deleted" in answer) {
    return {
      ...state,
      phase: "ready",
      conversationId: null,
      deleted: answer.text,
      pending: false,
      server: [],
      own: state.own.filter((entry) => entry.status === "sending"),
    };
  }

  const id = answer.conversation.id;
  const held = new Set(answer.messages.map((message) => message.client_id));
  // A conversation the page showed, replaced (a reset, FR-04's 24 hours) or
  // gone (FR-05); not the first one the page learns of.
  const changed =
    state.deleted !== null ||
    (state.conversationId !== null && state.conversationId !== id);
  const own = state.own.filter((entry) => {
    // The server has it: its copy takes the entry's place.
    if (entry.clientId !== undefined && held.has(entry.clientId)) return false;
    if (entry.status === "sent") return !changed;
    // What the page drew in another conversation goes with it, but for a
    // message still on its way.
    return !changed || entry.status === "sending";
  });

  return {
    ...state,
    phase: "ready",
    conversationId: id,
    deleted: null,
    pending: answer.pending,
    server: answer.messages,
    own,
  };
}

// The thread as drawn: the server's messages in its order, each followed by
// what the page anchored after it; then the messages still travelling.
export function entriesOf(state: State): Entry[] {
  const anchored = (after: number | null) =>
    state.own.filter((entry) => !travelling(entry) && entry.after === after);
  const fromServer = (message: ServerMessage): Entry => {
    const lang = message.client_id ? state.langs[message.client_id] : undefined;
    return {
      key: `s${String(message.id)}`,
      voice: VOICES[message.author],
      text: message.body,
      ...(lang ? { lang } : {}),
    };
  };
  const known = new Set(state.server.map((message) => message.id));

  return [
    ...(state.deleted !== null
      ? [{ key: "deleted", voice: "stamp" as const, text: state.deleted }]
      : []),
    // Anchored before any server message, or after one no longer shown.
    ...state.own.filter(
      (entry) =>
        !travelling(entry) && (entry.after === null || !known.has(entry.after)),
    ),
    ...state.server.flatMap((message) => [
      fromServer(message),
      ...anchored(message.id),
    ]),
    ...state.own.filter(travelling),
  ].map(({ key, voice, text, lang, clientId, status, content }) => ({
    key,
    voice,
    text,
    ...(lang ? { lang } : {}),
    ...(clientId ? { clientId } : {}),
    ...(status ? { status } : {}),
    ...(content ? { content } : {}),
  }));
}

// While the server holds a turn without its reply, or a message it accepted
// has not come back in a snapshot yet, the page asks again.
export function awaiting(state: State): boolean {
  return state.pending || state.own.some((entry) => entry.status === "sent");
}
