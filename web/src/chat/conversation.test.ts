import { describe, expect, it } from "vitest";

import { conversation, message } from "../test/fakeServer";
import { answeredTurn } from "../test/spans";
import {
  type Action,
  awaiting,
  entriesOf,
  initialState,
  reduce,
  waitingSince,
} from "./conversation";

const run = (actions: Action[]) => actions.reduce(reduce, initialState);
// São Paulo's 12:03 and these seconds, as the server writes a message's time.
const at = (second: number) =>
  `2026-11-12T12:03:${String(second).padStart(2, "0")}.000-03:00`;
const visitor = (clientId: string, turn: string, second: number) =>
  message({
    author: "visitor",
    body: `pergunta ${clientId}`,
    client_id: clientId,
    turn_id: turn,
    created_at: at(second),
  });
const reply = (turn: string, second: number, conversationId = 1) =>
  message({
    author: "bot",
    body: `resposta ${turn}`,
    turn_id: turn,
    conversation_id: conversationId,
    created_at: at(second),
  });
const opened = (
  messages: ReturnType<typeof message>[] = [],
  pending = false,
): Action[] => [
  { type: "session", conversationId: "1" },
  { type: "snapshot", answer: conversation(1, messages, pending).body },
];
const sending = (clientId: string): Action => ({
  type: "sending",
  clientId,
  content: { text: `pergunta ${clientId}` },
  text: `pergunta ${clientId}`,
});
const accepted = (
  clientId: string,
  copy: ReturnType<typeof message>,
): Action => ({
  type: "accepted",
  clientId,
  conversationId: copy.conversation_id,
  turnId: copy.turn_id ?? "",
  at: copy.created_at,
  message: copy,
});
const keys = (actions: Action[]) =>
  entriesOf(run(actions)).map((entry) => entry.key);

// The cable carries the reply, and the page draws it from the stream: no
// fetch for each reply, the thread in the server's order by the time and id
// each message carries, and the visitor's message under the key it was
// first drawn with, so its element stays (design §10, note of 2026-11-13).
describe("FR-18 the reply drawn from the conversation's stream", () => {
  it("puts the page's message in the server's order from the 202, still drawn under its own key", () => {
    const copy = visitor("a", "t1", 41);
    const state = run([...opened(), sending("a"), accepted("a", copy)]);

    expect(state.server).toEqual([copy]);
    expect(state.own).toEqual([]);
    expect(entriesOf(state).map((entry) => entry.key)).toEqual(["la"]);
    expect(awaiting(state)).toBe(true);
    expect(waitingSince(state)).toBe(at(41));
  });

  it("draws the reply the stream brings after the message it answers, and stops waiting", () => {
    const answer = reply("t1", 45);
    const state = run([
      ...opened(),
      sending("a"),
      accepted("a", visitor("a", "t1", 41)),
      { type: "message", message: answer },
    ]);

    expect(entriesOf(state).map((entry) => entry.text)).toEqual([
      "pergunta a",
      "resposta t1",
    ]);
    expect(awaiting(state)).toBe(false);
    expect(state.unplaced).toBe(0);
  });

  it("draws a reply once, however often the stream or a snapshot brings it", () => {
    const answer = reply("t1", 45);
    const question = visitor("a", "t1", 41);
    const state = run([
      ...opened(),
      sending("a"),
      accepted("a", question),
      { type: "message", message: answer },
      { type: "message", message: answer },
      { type: "snapshot", answer: conversation(1, [question, answer]).body },
    ]);

    expect(state.server).toEqual([question, answer]);
  });

  it("keeps the server's order when the 202 arrives after the reply to an earlier turn", () => {
    const state = run([
      ...opened(),
      sending("a"),
      accepted("a", visitor("a", "t1", 41)),
      sending("b"),
      { type: "message", message: reply("t1", 45) },
      accepted("b", visitor("b", "t2", 43)),
    ]);

    expect(entriesOf(state).map((entry) => entry.text)).toEqual([
      "pergunta a",
      "pergunta b",
      "resposta t1",
    ]);
    expect(awaiting(state)).toBe(true);
    expect(waitingSince(state)).toBe(at(43));
  });

  it("orders two messages of one millisecond by their ids, as the server does", () => {
    const later = { ...reply("t1", 45), id: "0002" };
    const earlier = { ...visitor("b", "t2", 45), id: "0001" };
    const state = run([
      ...opened([visitor("a", "t1", 41)]),
      { type: "message", message: later },
      sending("b"),
      accepted("b", earlier),
    ]);

    expect(state.server.map((each) => each.id).slice(1)).toEqual([
      "0001",
      "0002",
    ]);
  });

  it("asks for the conversation when the stream brings a reply to a message the page does not hold", () => {
    const state = run([
      ...opened(),
      { type: "message", message: reply("t9", 45) },
    ]);

    expect(state.server).toEqual([]);
    expect(state.unplaced).toBe(1);
  });

  it("asks for the conversation when the reply is another conversation's, a reset's (FR-04)", () => {
    const state = run([
      ...opened(),
      sending("a"),
      accepted("a", visitor("a", "t1", 41)),
      { type: "message", message: reply("t1", 45, 2) },
    ]);

    expect(state.server.map((each) => each.author)).toEqual(["visitor"]);
    expect(state.unplaced).toBe(1);
  });

  it("leaves a message accepted into another conversation to the fetch that follows it", () => {
    const copy = { ...visitor("a", "t1", 41), conversation_id: "2" };
    const state = run([...opened(), sending("a"), accepted("a", copy)]);

    expect(state.server).toEqual([]);
    expect(state.own.map((entry) => entry.status)).toEqual(["sent"]);
  });

  it("keeps a reply the stream brought when a snapshot taken before it arrives", () => {
    const question = visitor("a", "t1", 41);
    const state = run([
      ...opened(),
      sending("a"),
      accepted("a", question),
      { type: "message", message: reply("t1", 45) },
      { type: "snapshot", answer: conversation(1, [question], true).body },
    ]);

    expect(entriesOf(state).map((entry) => entry.text)).toEqual([
      "pergunta a",
      "resposta t1",
    ]);
    expect(awaiting(state)).toBe(false);
  });

  it("replaces the thread when a snapshot brings another conversation (FR-04)", () => {
    const next = reply("t2", 50, 2);
    const state = run([
      ...opened([visitor("a", "t1", 41), reply("t1", 45)]),
      { type: "snapshot", answer: conversation(2, [next]).body },
    ]);

    expect(state.server).toEqual([next]);
  });

  it("waits while a visitor's message has no reply in the thread, whatever the snapshot's flag says", () => {
    const question = visitor("a", "t1", 41);

    expect(awaiting(run(opened([question], false)))).toBe(true);
    expect(awaiting(run(opened([question, reply("t1", 45)], true)))).toBe(
      false,
    );
  });

  it("draws a failed message after the page's message whose server copy the 202 brought", () => {
    expect(
      keys([
        ...opened(),
        sending("a"),
        accepted("a", visitor("a", "t1", 41)),
        sending("b"),
        { type: "failed", clientId: "b" },
      ]),
    ).toEqual(["la", "lb"]);
  });
});

// Review finding V4 of pull request #14 (found by the verifier): a limit's
// stamp was keyed by the number of the page's own entries, which shrinks
// when a snapshot takes the page's messages, so two stamps could share a key.
describe("FR-14 every stamp of the demo's limit has a key of its own", () => {
  it("keys two limits apart after a snapshot took the messages before them", () => {
    const snapshot = conversation(1, [
      message({ author: "visitor", body: "a", client_id: "a" }),
      message({ author: "visitor", body: "b", client_id: "b" }),
    ]).body;
    const actions: Action[] = [
      { type: "session", conversationId: "1" },
      { type: "sending", clientId: "a", content: { text: "a" }, text: "a" },
      { type: "sending", clientId: "b", content: { text: "b" }, text: "b" },
      { type: "sending", clientId: "c", content: { text: "c" }, text: "c" },
      { type: "accepted", clientId: "a", conversationId: "1" },
      { type: "accepted", clientId: "b", conversationId: "1" },
      { type: "limited", clientId: "c", text: "limite" },
      { type: "snapshot", answer: snapshot },
      { type: "sending", clientId: "d", content: { text: "d" }, text: "d" },
      { type: "limited", clientId: "d", text: "limite" },
    ];
    const keys = entriesOf(actions.reduce(reduce, initialState)).map(
      (entry) => entry.key,
    );

    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toHaveLength(6);
  });
});

// Review finding C3 of pull request #29: a turn's root carries the mode the
// turn ran in, read when it started, and the month's mode when it closed,
// after its own charge; the head follows the second alone, so a turn that
// started before a pause the page already knows never takes it back.
describe("FR-14 the glass box head's mode", () => {
  const closed = (fields: { turnMode?: string; budgetMode?: string }) => {
    const [root] = answeredTurn("t1", {
      ...(fields.turnMode ? { mode: fields.turnMode } : {}),
      ...(fields.budgetMode ? { budgetMode: fields.budgetMode } : {}),
    });
    if (!root) throw new Error("no root");
    return { type: "span", span: root } as const;
  };

  it("keeps a pause the server answered when a turn that started before it closes", () => {
    const state = run([
      { type: "session", conversationId: "1", mode: "normal" },
      {
        type: "snapshot",
        answer: conversation(1, [], true, [], { mode: "paused" }).body,
      },
      closed({ turnMode: "normal", budgetMode: "paused" }),
    ]);

    expect(state.mode).toBe("paused");
  });

  it("takes the month's mode a turn closed with, not the mode it ran in", () => {
    const state = run([
      { type: "session", conversationId: "1", mode: "normal" },
      closed({ turnMode: "normal", budgetMode: "paused" }),
    ]);

    expect(state.mode).toBe("paused");
  });

  it("leaves the mode alone for a root that names no month's mode", () => {
    const state = run([
      { type: "session", conversationId: "1", mode: "paused" },
      closed({ turnMode: "normal" }),
    ]);

    expect(state.mode).toBe("paused");
  });
});
