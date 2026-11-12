import { describe, expect, it } from "vitest";

import { conversation, message } from "../test/fakeServer";
import { type Action, entriesOf, initialState, reduce } from "./conversation";

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
