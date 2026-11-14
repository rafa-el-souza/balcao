import { withSpans } from "../trace/model";
import {
  type Content,
  type Deleted,
  type Mode,
  modeOf,
  rateOf,
  type ServerMessage,
  type Snapshot,
  type Span,
} from "./api";

// The conversation on the page (design §6.9: a React reducer, not server
// cache). Two parts, drawn as one thread:
//
// - the server's messages of the current conversation, in the server's own
//   order (each message's time, then its id): those the snapshots gave, the
//   page's own as the 202 answered it, and the replies the stream brought;
// - the page's own entries: a message on its way or accepted but not yet
//   held as the server stored it (drawn after everything the server has), and
//   what the server never stored, a message that failed or met a limit and
//   the limit's stamp (drawn after the entry that was the last one drawn when
//   it happened, the server's or the page's).
//
// A message the page sent leaves its own part when the server's copy is
// held, matched by the id the page generated (client_id), so it takes the
// server's place in the order (review finding C1 of pull request #14), still
// drawn under the key it had, so its element stays.
//
// A reply the stream brings is drawn at once when the page holds the message
// it answers; otherwise the page asks for the conversation (unplaced). A
// snapshot of the conversation the page shows adds to what it holds, by id,
// so one taken before a reply the stream brought never takes the reply away;
// another conversation's replaces it (design §10, note of 2026-11-13 on the
// chat's stream).
//
// Beside the thread, the conversation's spans, which the glass box draws
// (FR-12): the snapshot's and those the cable brings, one per span id; and
// the budget's mode and the rate of the real, from the session and each
// snapshot, the mode also from a turn the stream closes (FR-12, FR-14).

export type Voice = "visitor" | "attendant" | "pharmacist" | "stamp";

export interface Entry {
  key: string;
  voice: Voice;
  text: string;
  // FR-01's notice, stamped apart from the reply it came with.
  notice?: boolean;
  // The reservation codes a reply stamps where it writes them (FR-07).
  marks?: string[];
  // An opener's language, when it is not the page's.
  lang?: string;
  // The page's own message: the id it generated, its state and its content.
  clientId?: string;
  status?: "sending" | "sent" | "failed" | "limited";
  content?: Content;
  // The turn the server opened for it (the 202's answer), and when the
  // server accepted it or the edge refused it, for the glass box's own rows.
  turnId?: string;
  at?: string;
}

interface Own extends Entry {
  // The key of the entry this one follows, the server's ("s…") or the page's
  // ("l…", which becomes the server's copy once a snapshot holds it); null
  // before any.
  after: string | null;
  // The conversation the server accepted it into (the 202's answer).
  conversationId?: string;
}

export interface State {
  phase: "loading" | "ready" | "failed";
  conversationId: string | null;
  // The link to the conversation's trace page (FR-12), from the snapshot.
  traceToken: string | null;
  // FR-05's confirmation, when the visitor's data is gone.
  deleted: string | null;
  server: ServerMessage[];
  // Counts the replies the stream brought that the page could not place: each
  // makes the page ask for the conversation.
  unplaced: number;
  own: Own[];
  spans: Span[];
  // The languages of the openers the page sent, by client id.
  langs: Record<string, string>;
  // A snapshot has been merged: the page knows the conversation's history.
  seen: boolean;
  // The conversations the page has learned of, from the session or a
  // snapshot: one accepted into another is either one of these, left behind,
  // or a newer one the page has not seen yet (review finding R1).
  known: string[];
  // Numbers the stamps the page writes.
  stamps: number;
  // The budget's mode (FR-14), none until the server names one it knows.
  mode: Mode | null;
  // Reais per dollar (FR-12), none until the server gives the rate.
  brl: number | null;
}

export type Action =
  | { type: "session"; conversationId: string; mode?: unknown; brl?: unknown }
  | { type: "loaded" }
  | { type: "loadFailed" }
  | {
      type: "sending";
      clientId: string;
      content: Content;
      text: string;
      lang?: string;
    }
  | {
      type: "accepted";
      clientId: string;
      conversationId: string;
      turnId?: string;
      at?: string;
      // The message as the server stored it (the 202's answer).
      message?: ServerMessage;
    }
  | { type: "failed"; clientId: string }
  | { type: "limited"; clientId: string | null; text: string; at?: string }
  | { type: "retrying"; clientId: string }
  | { type: "snapshot"; answer: Snapshot | Deleted }
  // A message the stream brought: a reply (FR-18).
  | { type: "message"; message: ServerMessage }
  // A span the cable brought, started or finished (FR-12).
  | { type: "span"; span: Span };

export const initialState: State = {
  phase: "loading",
  conversationId: null,
  traceToken: null,
  deleted: null,
  server: [],
  unplaced: 0,
  own: [],
  spans: [],
  langs: {},
  seen: false,
  known: [],
  stamps: 0,
  mode: null,
  brl: null,
};

// The mode and the rate an answer names, over what the page held.
function budgetOf(
  state: State,
  answer: { mode?: unknown; brl?: unknown },
): Pick<State, "mode" | "brl"> {
  return {
    mode: modeOf(answer.mode) ?? state.mode,
    brl: rateOf(answer.brl) ?? state.brl,
  };
}

// A turn's root closes with the month's mode after the turn's own charge
// (app/models/turn_processor.rb), newer than any answer the page had while
// the turn ran. The mode the turn ran in, read when it started, is not the
// month's now (review finding C3 of pull request #29).
function modeClosedBy(span: Span): Mode | null {
  return span.name === "balcao.turn" && span.finished_at !== null
    ? modeOf(span.attributes["balcao.budget.mode"])
    : null;
}

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

// The server's order (app/controllers/api/conversations_controller.rb): a
// message's time, then its id. The time comes to the millisecond and the
// server orders by the microsecond, so two messages of one millisecond are
// ordered here by their ids, which the server does only when their times
// are equal to the microsecond.
function serverOrder(a: ServerMessage, b: ServerMessage): number {
  return (
    Date.parse(a.created_at) - Date.parse(b.created_at) ||
    (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
  );
}

// The messages held and those that came, one per id, the copy that came
// last kept, in the server's order.
function withMessages(
  held: ServerMessage[],
  incoming: ServerMessage[],
): ServerMessage[] {
  const byId = new Map(held.map((message) => [message.id, message]));
  for (const message of incoming) byId.set(message.id, message);
  return [...byId.values()].sort(serverOrder);
}

// The key a server's message is drawn under: the page's own message keeps the
// one it had on its way, so its element stays when the server's copy takes
// its place.
const keyOf = (message: ServerMessage) =>
  message.client_id ? `l${message.client_id}` : `s${message.id}`;

// The server's copies join the thread, and take the place of the page's own
// messages they hold.
function place(state: State, messages: ServerMessage[]): State {
  const held = new Set(messages.map((message) => message.client_id));
  return {
    ...state,
    server: withMessages(state.server, messages),
    own: state.own.filter(
      (entry) => entry.clientId === undefined || !held.has(entry.clientId),
    ),
  };
}

// A reply the page draws as the stream brings it: in the conversation the
// page shows, answering a message the page holds. Any other message is left
// to a fetch of the conversation: a reset's reply, which opens the next
// conversation (FR-04), or the reply to a message another tab sent.
function answersHeld(state: State, message: ServerMessage): boolean {
  return (
    message.conversation_id === state.conversationId &&
    message.author !== "visitor" &&
    message.turn_id !== null &&
    state.server.some(
      (held) => held.author === "visitor" && held.turn_id === message.turn_id,
    )
  );
}

export function reduce(state: State, action: Action): State {
  switch (action.type) {
    case "session": {
      const known = state.known.includes(action.conversationId)
        ? state.known
        : [...state.known, action.conversationId];
      return { ...state, known, ...budgetOf(state, action) };
    }
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
    case "accepted": {
      const accepted = update(state, action.clientId, {
        status: "sent",
        conversationId: action.conversationId,
        ...(action.turnId ? { turnId: action.turnId } : {}),
        ...(action.at ? { at: action.at } : {}),
      });
      // Into the conversation the page shows, the server's copy takes the
      // message's place at once; into another, the fetch that follows it
      // moves the page there.
      const copy = action.message;
      return copy?.client_id === action.clientId &&
        copy.conversation_id === state.conversationId
        ? place(accepted, [copy])
        : accepted;
    }
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
        ? update(state, action.clientId, {
            status: "limited",
            after,
            ...(action.at ? { at: action.at } : {}),
          })
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
    case "message":
      return answersHeld(state, action.message)
        ? place(state, [action.message])
        : { ...state, unplaced: state.unplaced + 1 };
    case "span":
      return {
        ...state,
        spans: withSpans(state.spans, [action.span]),
        mode: modeClosedBy(action.span) ?? state.mode,
      };
  }
}

function merge(state: State, answer: Snapshot | Deleted): State {
  if ("deleted" in answer) return mergeDeleted(state, answer);
  return { ...mergeConversation(state, answer), ...budgetOf(state, answer) };
}

function mergeDeleted(state: State, answer: Deleted): State {
  return {
    ...state,
    phase: "ready",
    conversationId: null,
    traceToken: null,
    deleted: answer.text,
    server: [],
    spans: [],
    own: state.own.filter((entry) => entry.status === "sending"),
    seen: true,
  };
}

function mergeConversation(state: State, answer: Snapshot): State {
  const id = answer.conversation.id;
  // A conversation the page showed, replaced (a reset, FR-04's 24 hours) or
  // gone (FR-05); not the first one the page learns of.
  const changed =
    state.deleted !== null ||
    (state.conversationId !== null && state.conversationId !== id);
  // The same conversation's snapshot adds to what the page holds: one taken
  // before a reply the stream brought must not take the reply away. A
  // message never leaves a conversation the page still shows: a reset moves
  // the messages after it out of the one it closes, and its reply moves the
  // page to the next (FR-04).
  const server = withMessages(changed ? [] : state.server, answer.messages);
  const held = new Set(server.map((message) => message.client_id));
  // What the page drew before it knew the history follows the history
  // (review finding R3).
  const last = server.at(-1);
  const start = last ? keyOf(last) : null;
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
    traceToken: answer.conversation.trace_token,
    deleted: null,
    server,
    own,
    // A conversation the page did not show starts its glass box empty: after a
    // reset the new one has its own trace (FR-04, FR-12).
    spans: changed ? answer.spans : withSpans(state.spans, answer.spans),
    seen: true,
    known: state.known.includes(id) ? state.known : [...state.known, id],
  };
}

// A reservation's code as the server draws it (app/models/reservation.rb).
const CODE = /^[0-9A-Z]+$/;

// The codes a reply stamps: those the server lists, the visitor's own
// reservations the reply writes, whatever conversation made them, never a
// word of that shape (docs/prototype/chat-reservation.html; review finding
// C1 of pull request #19). Each is letters and digits, as a pattern needs.
function codesOf(message: ServerMessage): string[] {
  const codes: unknown = message.codes;
  return Array.isArray(codes)
    ? codes.filter(
        (code): code is string => typeof code === "string" && CODE.test(code),
      )
    : [];
}

// The thread as drawn: the server's messages in its order and then the
// messages still travelling, each followed by what the page anchored after it.
export function entriesOf(state: State): Entry[] {
  const fromServer = (message: ServerMessage): Entry[] => {
    const lang = message.client_id ? state.langs[message.client_id] : undefined;
    const marks = message.author === "visitor" ? [] : codesOf(message);
    return [
      // FR-01's notice, which the server sends apart from the reply.
      ...(message.notice
        ? [
            {
              key: `n${message.id}`,
              voice: "stamp" as const,
              text: message.notice,
              notice: true,
            },
          ]
        : []),
      {
        key: keyOf(message),
        voice: VOICES[message.author],
        text: message.body,
        ...(lang ? { lang } : {}),
        ...(marks.length > 0 ? { marks } : {}),
      },
    ];
  };
  // A page message the server holds is drawn as the server's copy, under the
  // same key, so what the page anchored after it follows the copy.
  const copies = new Set(state.server.map(keyOf));
  const own = state.own.filter((entry) => !copies.has(entry.key));
  const terminal = own.filter((entry) => !travelling(entry));
  const placed = new Set<string>();
  const follow = (key: string | null): Entry[] =>
    terminal
      .filter((entry) => entry.after === key)
      .flatMap((entry) => {
        placed.add(entry.key);
        return [entry, ...follow(entry.key)];
      });

  const head = follow(null);
  const body = [
    ...state.server.flatMap((message) => [
      ...fromServer(message),
      ...follow(keyOf(message)),
    ]),
    ...own.filter(travelling).flatMap((entry) => [entry, ...follow(entry.key)]),
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
  ].map(
    ({
      key,
      voice,
      text,
      notice,
      marks,
      lang,
      clientId,
      status,
      content,
      turnId,
      at,
    }) => ({
      key,
      voice,
      text,
      ...(notice ? { notice } : {}),
      ...(marks ? { marks } : {}),
      ...(lang ? { lang } : {}),
      ...(clientId ? { clientId } : {}),
      ...(status ? { status } : {}),
      ...(content ? { content } : {}),
      ...(turnId ? { turnId } : {}),
      ...(at ? { at } : {}),
    }),
  );
}

// The visitor's messages the thread holds without their reply: a reply
// carries its turn's id. The thread tells it, not the snapshot's flag, which
// a reply the stream brought after the snapshot would leave behind.
function unanswered(state: State): ServerMessage[] {
  const answered = new Set(
    state.server
      .filter((message) => message.author !== "visitor")
      .map((message) => message.turn_id),
  );
  return state.server.filter(
    (message) =>
      message.author === "visitor" &&
      message.turn_id !== null &&
      !answered.has(message.turn_id),
  );
}

// While a message of the visitor's waits for its reply, or one the server
// accepted is not yet held as the server stored it, the page asks again.
export function awaiting(state: State): boolean {
  return (
    unanswered(state).length > 0 ||
    state.own.some((entry) => entry.status === "sent")
  );
}

// NFR-03: since when the visitor waits for an answer, by the server's clock:
// the receipt of the oldest of their messages still without its reply, or
// the moment the server accepted one the page does not hold as stored yet,
// whichever is older. Null when nothing waits, or when no time is known.
export function waitingSince(state: State): string | null {
  if (!awaiting(state)) return null;
  const times = [
    ...unanswered(state).map((message) => message.created_at),
    ...state.own.flatMap((entry) =>
      entry.status === "sent" && entry.at ? [entry.at] : [],
    ),
  ].filter((time) => !Number.isNaN(Date.parse(time)));
  return times.reduce<string | null>(
    (oldest, time) =>
      oldest === null || Date.parse(time) < Date.parse(oldest) ? time : oldest,
    null,
  );
}
