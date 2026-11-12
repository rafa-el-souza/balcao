import type { Content, Deleted, ServerMessage, Snapshot } from "./api";

// The conversation on the page (design §6.9: a React reducer, not server
// cache). The server's messages, merged by id, and the page's own entries:
// a message on its way, accepted but not yet seen in a snapshot, failed, or
// met by a limit, and the limit's stamp. A message the page sent is matched
// to the server's copy by the id the page generated (client_id), and takes
// its place where the page first showed it.

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

export interface State {
  phase: "loading" | "ready" | "failed";
  conversationId: number | null;
  deleted: boolean;
  pending: boolean;
  entries: Entry[];
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
  | { type: "accepted"; clientId: string }
  | { type: "failed"; clientId: string }
  | { type: "limited"; clientId: string | null; text: string }
  | { type: "retrying"; clientId: string }
  | { type: "snapshot"; answer: Snapshot | Deleted };

export const initialState: State = {
  phase: "loading",
  conversationId: null,
  deleted: false,
  pending: false,
  entries: [],
};

const VOICES: Record<ServerMessage["author"], Voice> = {
  visitor: "visitor",
  bot: "attendant",
  operator: "pharmacist",
  system: "stamp",
};

const fromServer = (message: ServerMessage): Entry => ({
  key: `s${String(message.id)}`,
  voice: VOICES[message.author],
  text: message.body,
});

const withStatus = (
  entries: Entry[],
  clientId: string,
  status: NonNullable<Entry["status"]>,
) =>
  entries.map((entry) =>
    entry.clientId === clientId && entry.key.startsWith("l")
      ? { ...entry, status }
      : entry,
  );

// The page's own entries that are still on their way, and so survive a
// change of conversation (a reset, the 24 hours of FR-04, a deletion).
const inFlight = (entry: Entry) =>
  entry.status === "sending" || entry.status === "failed";

export function reduce(state: State, action: Action): State {
  switch (action.type) {
    case "loaded":
      return { ...state, phase: state.phase === "failed" ? "failed" : "ready" };
    case "loadFailed":
      return { ...state, phase: "failed" };
    case "sending":
      return {
        ...state,
        entries: [
          ...state.entries,
          {
            key: `l${action.clientId}`,
            voice: "visitor",
            text: action.text,
            clientId: action.clientId,
            status: "sending",
            content: action.content,
            ...(action.lang ? { lang: action.lang } : {}),
          },
        ],
      };
    case "accepted":
      return {
        ...state,
        entries: withStatus(state.entries, action.clientId, "sent"),
      };
    case "failed":
      return {
        ...state,
        entries: withStatus(state.entries, action.clientId, "failed"),
      };
    case "retrying":
      return {
        ...state,
        entries: withStatus(state.entries, action.clientId, "sending"),
      };
    case "limited": {
      const entries = action.clientId
        ? withStatus(state.entries, action.clientId, "limited")
        : state.entries;
      return {
        ...state,
        entries: [
          ...entries,
          {
            key: `limit${String(entries.length)}`,
            voice: "stamp",
            text: action.text,
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
      conversationId: null,
      deleted: true,
      pending: false,
      entries: [
        { key: "deleted", voice: "stamp", text: answer.text },
        ...state.entries.filter(inFlight),
      ],
    };
  }

  const id = answer.conversation.id;
  const clientIds = new Set(
    answer.messages.map((message) => message.client_id),
  );
  const changed =
    state.deleted ||
    (state.conversationId !== null && state.conversationId !== id);
  const entries = changed
    ? state.entries.filter(
        (entry) =>
          inFlight(entry) ||
          (entry.clientId !== undefined && clientIds.has(entry.clientId)),
      )
    : [...state.entries];

  for (const message of answer.messages) {
    const entry = fromServer(message);
    if (entries.some((existing) => existing.key === entry.key)) continue;
    const mine = entries.findIndex(
      (existing) =>
        message.client_id !== null &&
        existing.key.startsWith("l") &&
        existing.clientId === message.client_id,
    );
    if (mine === -1) {
      entries.push(entry);
    } else {
      const lang = entries[mine]?.lang;
      entries[mine] = { ...entry, ...(lang ? { lang } : {}) };
    }
  }

  return {
    ...state,
    conversationId: id,
    deleted: false,
    pending: answer.pending,
    entries,
  };
}

// While the server holds a turn without its reply, or a message it accepted
// has not come back in a snapshot yet, the page asks again.
export function awaiting(state: State): boolean {
  return (
    state.pending ||
    state.entries.some(
      (entry) => entry.key.startsWith("l") && entry.status === "sent",
    )
  );
}
