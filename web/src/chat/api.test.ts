import { afterEach, describe, expect, it, vi } from "vitest";

import { createApi, serverClock, setServerClock } from "./api";

// A Date has whole seconds, so an answer only places the server's clock
// between its second and the next one plus the round trip (review findings
// C3 and R2 of pull request #17).
describe("FR-12 the server's clock, from the answers' Date", () => {
  const date = "Thu, 12 Nov 2026 15:05:10 GMT";
  const second = Date.parse("2026-11-12T15:05:10Z");

  afterEach(() => {
    serverClock.offset = 0;
  });

  it("leaves a clock the answer allows as it is", () => {
    setServerClock(date, second + 650, second + 700);
    expect(serverClock.offset).toBe(0);

    setServerClock(date, second + 900, second + 1_040);
    expect(serverClock.offset).toBe(0);
  });

  it("moves a clock behind or ahead to the middle of what the answer allows", () => {
    setServerClock(date, second - 120_050, second - 120_000);
    expect(serverClock.offset).toBe(120_000 + 525);

    serverClock.offset = 0;
    setServerClock(date, second + 4_950, second + 5_000);
    expect(serverClock.offset).toBe(525 - 5_000);
  });

  it("keeps the clock it has while the next answer allows it", () => {
    setServerClock(date, second - 120_050, second - 120_000);
    const offset = serverClock.offset;

    setServerClock(
      "Thu, 12 Nov 2026 15:05:12 GMT",
      second + 2_100 - offset,
      second + 2_150 - offset,
    );
    expect(serverClock.offset).toBe(offset);
  });

  it("does nothing with an answer that has no Date", () => {
    setServerClock(null, second, second + 50);
    setServerClock("yesterday", second, second + 50);
    expect(serverClock.offset).toBe(0);
  });
});

// The owner's round at the MVP close, rows 14-V2V3 and IR-V2: an answer the
// server would give again to the same request is a refusal, which the page
// does not offer to send again; the network, a server error and a refusal at
// the edge that is not its limit may pass.
describe("FR-18 NFR-02 what an answer says of sending again", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const answering = (status: number, body: unknown = {}) => {
    vi.stubGlobal("fetch", () =>
      Promise.resolve(
        new Response(JSON.stringify(body), {
          status,
          headers: { "Content-Type": "application/json" },
        }),
      ),
    );
    return createApi(() => "pt-BR").send("id", { text: "tem dipirona?" });
  };

  it.each([400, 403, 409, 413, 422])("refuses after %i", async (status) => {
    expect(await answering(status)).toEqual({ kind: "refused" });
  });

  it.each([500, 502, 503])("fails after %i", async (status) => {
    expect(await answering(status)).toEqual({ kind: "failed" });
  });

  it("reads 401 as the cookie's, 404 as the missing, and 429 as the edge's", async () => {
    expect(await answering(401)).toEqual({ kind: "session" });
    expect(await answering(404)).toEqual({ kind: "missing" });
    expect(await answering(429, { error: "limit", text: "Limite." })).toEqual({
      kind: "limit",
      text: "Limite.",
    });
    expect(await answering(429)).toEqual({ kind: "failed" });
  });
});

// Threat model SR-39: a session that mints a visitor carries the widget's
// token, and the server's refusal of the check is the page's retry hint.
describe("SR-39 FR-18 the session and Turnstile's token", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function recording(status: number, body: unknown) {
    const bodies: unknown[] = [];
    vi.stubGlobal("fetch", (_path: string, init: RequestInit) => {
      bodies.push(JSON.parse(init.body as string));
      return Promise.resolve(
        new Response(JSON.stringify(body), {
          status,
          headers: { "Content-Type": "application/json" },
        }),
      );
    });
    return bodies;
  }

  it("sends the token beside the language when it has one, and no token field when it has none", async () => {
    const bodies = recording(201, { conversation_id: "c" });
    const api = createApi(() => "pt-BR");

    await api.session("es", "XXXX.DUMMY.TOKEN.XXXX");
    await api.session("en", null);

    expect(bodies).toEqual([
      { language: "es", turnstile_token: "XXXX.DUMMY.TOKEN.XXXX" },
      { language: "en" },
    ]);
  });

  it("reads the server's refusal of the check apart from the Origin's", async () => {
    recording(403, { error: "challenge" });
    expect(await createApi(() => "pt-BR").session("pt-BR", null)).toEqual({
      kind: "challenge",
    });

    recording(403, { error: "origin" });
    expect(await createApi(() => "pt-BR").session("pt-BR", null)).toEqual({
      kind: "refused",
    });
  });
});
