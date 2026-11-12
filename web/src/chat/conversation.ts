import type { Content, Deleted, ServerMessage, Snapshot } from "./api";

// The conversation on the page (design §6.9: a React reducer, not server
// cache). Two parts, drawn as one thread:
//
// - the server's messages of the current conversation, in the server's own
//   order, as the last snapshot gave them;
// - the page's own entries: a message on its way or accepted but not yet in a
//   snapshot (drawn after everything the server has), and what the server
//   never stored, a message that failed or met a limit and the limit's stamp
//   (drawn after the entry that was the last one drawn when it happened, the
//   server's or the page's).
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
  // The key of the entry this one follows, the server's ("s…") or the page's
  // ("l…", which becomes the server's copy once a snapshot holds it); null
  // before any.
  after: string | null;
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
  // A snapshot has been merged: the page knows the conversation's history.
  seen: boolean;
  // The conversations the page has learned of, from the session or a
  // snapshot: one accepted into another is either one of these, left behind,
  // or a newer one the page has not seen yet (review finding R1).
  known: number[];
  // Numbers the stamps the page writes.
  stamps: number;
}

export type Action =
  | { type: "session"; conversationId: number }
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
  seen: false,
  known: [],
  stamps: 0,
};

const VOICES: Record<ServerMessage["author"], Voice> = {
  visitor: "visitor",
  bot: "attendant",
  operator: "pharmacist",
  system: "stamp",
};

// An entry the page still waits on: drawn after everything the server has.
const travelling = (entry: Own) =>
  entry.status === "sending" || entry.status === "sent";

// The key of the last entry drawn, leaving out the page's own message that is
// about to become terminal: where a failure or a limit is drawn (review
// findings R2 and R3).
function lastDrawn(state: State, leaving: string | null): string | null {
  const others = {
    ...state,
    own: state.own.filter((entry) => entry.clientId !== leaving),
  };
  return entriesOf(others).at(-1)?.key ?? null;
}

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
    case "session":
      return state.known.includes(action.conversationId)
        ? state
        : { ...state, known: [...state.known, action.conversationId] };
    case "loaded":
      return { ...state, phase: state.phase === "failed" ? "failed" : "ready" };
    // A load that fails after a snapshot opened the conversation says nothing
    // (review finding R4).
    case "loadFailed":
      return state.seen ? state : { ...state, phase: "failed" };
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
        after: lastDrawn(state, action.clientId),
      });
    case "retrying":
      return update(state, action.clientId, { status: "sending" });
    case "limited": {
      const after = lastDrawn(state, action.clientId);
      const limited = action.clientId
        ? update(state, action.clientId, { status: "limited", after })
        : state;
      return {
        ...limited,
        stamps: state.stamps + 1,
        own: [
          ...limited.own,
          {
            key: `limit${String(state.stamps)}`,
            voice: "stamp",
            text: action.text,
            after: action.clientId ? `l${action.clientId}` : after,
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
      seen: true,
    };
  }

  const id = answer.conversation.id;
  const held = new Set(answer.messages.map((message) => message.client_id));
  // A conversation the page showed, replaced (a reset, FR-04's 24 hours) or
  // gone (FR-05); not the first one the page learns of.
  const changed =
    state.deleted !== null ||
    (state.conversationId !== null && state.conversationId !== id);
  // What the page drew before it knew the history follows the history
  // (review finding R3).
  const last = answer.messages.at(-1);
  const start = last ? `s${String(last.id)}` : null;
  const own = state.own
    .filter((entry) => {
      // The server has it: its copy takes the entry's place.
      if (entry.clientId !== undefined && held.has(entry.clientId))
        return false;
      // Accepted into a conversation the page has left behind, and not moved
      // here: it belongs to a conversation the page no longer shows. One the
      // page has not learned of yet is newer, and the next snapshots bring it
      // (review findings C3 and R1).
      if (entry.status === "sent")
        return (
          entry.conversationId === id ||
          !state.known.includes(entry.conversationId ?? id)
        );
      // What the page drew in another conversation goes with it, but for a
      // message still on its way.
      return !changed || entry.status === "sending";
    })
    .map((entry) =>
      !state.seen && entry.after === null ? { ...entry, after: start } : entry,
    );

  return {
    ...state,
    phase: "ready",
    conversationId: id,
    deleted: null,
    pending: answer.pending,
    server: answer.messages,
    own,
    seen: true,
    known: state.known.includes(id) ? state.known : [...state.known, id],
  };
}

// The thread as drawn: the server's messages in its order and then the
// messages still travelling, each followed by what the page anchored after it.
export function entriesOf(state: State): Entry[] {
  const fromServer = (message: ServerMessage): Entry => {
    const lang = message.client_id ? state.langs[message.client_id] : undefined;
    return {
      key: `s${String(message.id)}`,
      voice: VOICES[message.author],
      text: message.body,
      ...(lang ? { lang } : {}),
    };
  };
  // A page message the server holds is drawn as the server's copy.
  const copies = new Map<string, string>(
    state.server.flatMap((message): [string, string][] =>
      message.client_id
        ? [[`l${message.client_id}`, `s${String(message.id)}`]]
        : [],
    ),
  );
  const resolve = (key: string | null) =>
    key === null ? null : (copies.get(key) ?? key);
  const terminal = state.own.filter((entry) => !travelling(entry));
  const placed = new Set<string>();
  const follow = (key: string | null): Entry[] =>
    terminal
      .filter((entry) => resolve(entry.after) === key)
      .flatMap((entry) => {
        placed.add(entry.key);
        return [entry, ...follow(entry.key)];
      });

  const head = follow(null);
  const body = [
    ...state.server.flatMap((message) => [
      fromServer(message),
      ...follow(`s${String(message.id)}`),
    ]),
    ...state.own
      .filter(travelling)
      .flatMap((entry) => [entry, ...follow(entry.key)]),
  ];
  // Anchored after an entry no longer drawn: first, in the page's order.
  const stray = terminal.filter((entry) => !placed.has(entry.key));

  return [
    ...(state.deleted !== null
      ? [{ key: "deleted", voice: "stamp" as const, text: state.deleted }]
      : []),
    ...head,
    ...stray,
    ...body,
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
