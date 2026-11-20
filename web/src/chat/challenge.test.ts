import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DUMMY_TOKEN, fakeTurnstile } from "../test/fakeTurnstile";
import {
  createChallenge,
  SCRIPT_SRC,
  SCRIPT_TIMEOUT_MS,
  siteKeyFor,
  TEST_SITE_KEY,
} from "./challenge";

// Design FR-18, threat model SR-39, ADR-0012: the chat runs Cloudflare
// Turnstile's widget and hands its token, one challenge's worth at a time, to
// the session that mints a visitor.

afterEach(() => {
  vi.useRealTimers();
  delete window.turnstile;
  for (const script of document.head.querySelectorAll("script"))
    script.remove();
});

function container() {
  const element = document.createElement("div");
  document.body.append(element);
  return element;
}

function attached(language: () => string) {
  const challenge = createChallenge(language);
  challenge.attach(container());
  return challenge;
}

describe("SR-39 the site key, public, by the page's hostname", () => {
  // The key as the owner copied it from Cloudflare's dashboard: a typed copy
  // had one character more, which Cloudflare would refuse on the public name
  // alone, the one host the tests never are (review finding C1 of pull
  // request #53). Cloudflare's keys, its test keys too, are "0x4" or a test
  // digit and "x", then 21 characters.
  it("is the owner's widget on the public name, in the shape of Cloudflare's keys", () => {
    const key = siteKeyFor("balcao.rafasouza.dev.br");
    expect(key).toBe("0x4AAAAAAF03lbnq8L3wEEjC");
    expect(key).toMatch(/^0x4[A-Za-z0-9_-]{21}$/);
    expect(TEST_SITE_KEY).toMatch(/^[123]x[A-Za-z0-9_-]{22}$/);
  });

  it("is Cloudflare's published test key everywhere else: development, the tests, a rehearsal host", () => {
    expect(TEST_SITE_KEY).toBe("1x00000000000000000000AA");
    for (const host of [
      "127.0.0.1",
      "localhost",
      "ensaio.rafasouza.dev.br",
      "evil.example",
      "constructor",
      "__proto__",
      "",
    ])
      expect(siteKeyFor(host)).toBe(TEST_SITE_KEY);
  });
});

describe("SR-39 FR-18 the challenge", () => {
  it("renders one widget, managed and seen only when it needs the visitor, in the page's language, for the session's action", async () => {
    const fake = fakeTurnstile();
    window.turnstile = fake.api;
    const element = container();
    const challenge = createChallenge(() => "es");
    challenge.attach(element);

    await expect(challenge.token()).resolves.toBe(DUMMY_TOKEN);

    expect(fake.rendered).toHaveLength(1);
    expect(fake.rendered[0]?.container).toBe(element);
    expect(fake.rendered[0]?.options).toMatchObject({
      sitekey: TEST_SITE_KEY,
      action: "session",
      appearance: "interaction-only",
      execution: "render",
      language: "es",
      theme: "light",
      size: "normal",
      retry: "never",
      "refresh-expired": "never",
      "response-field": false,
      "feedback-enabled": false,
    });
  });

  it("gives each token once: the next session's challenge starts again", async () => {
    const fake = fakeTurnstile();
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");

    await challenge.token();
    fake.answer = "hold";
    const second = challenge.token();
    expect(fake.resets).toEqual(["widget-1"]);
    fake.solve("second-token");

    await expect(second).resolves.toBe("second-token");
    expect(fake.rendered).toHaveLength(1);
  });

  it("keeps a token that came before it was asked for, and gives it at once", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");

    const first = challenge.token();
    fake.solve("first-token");
    await expect(first).resolves.toBe("first-token");

    // A challenge the widget solved again by itself before the page asked.
    fake.solve("early-token");
    await expect(challenge.token()).resolves.toBe("early-token");
    expect(fake.resets).toEqual([]);
  });

  it("drops a token that expired before the page asked for it", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");
    const first = challenge.token();
    fake.solve("first-token");
    await first;
    fake.solve("early-token");
    fake.expire();

    const next = challenge.token();
    expect(fake.resets).toEqual(["widget-1"]);
    fake.solve("fresh-token");
    await expect(next).resolves.toBe("fresh-token");
  });

  it("answers no token when the challenge fails, and starts it again when asked again", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");

    const first = challenge.token();
    fake.fail("300030");
    await expect(first).resolves.toBeNull();

    const again = challenge.token();
    expect(fake.resets).toEqual(["widget-1"]);
    fake.solve("after-failure");
    await expect(again).resolves.toBe("after-failure");
  });

  it("answers no token, and asks Cloudflare nothing more, in a browser the widget does not support", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");

    const first = challenge.token();
    fake.unsupported();
    await expect(first).resolves.toBeNull();

    await expect(challenge.token()).resolves.toBeNull();
    expect(fake.resets).toEqual([]);
  });

  // The widget takes no room until it asks for a tick (interaction-only),
  // but its element is never empty once drawn: the page spaces it by this
  // mark (docs/prototype/chat.html draws the line 12 px under the
  // suggestions).
  it("marks its element while the widget asks the visitor to tick, until the challenge starts again", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const element = container();
    const challenge = createChallenge(() => "pt-BR");
    challenge.attach(element);

    const first = challenge.token();
    expect(element).not.toHaveAttribute("data-asking");
    fake.interactive();
    expect(element).toHaveAttribute("data-asking");
    fake.solve("ticked");
    await expect(first).resolves.toBe("ticked");
    expect(element).toHaveAttribute("data-asking");

    void challenge.token();
    expect(element).not.toHaveAttribute("data-asking");
  });

  it("gives two callers a token each, one challenge after the other", async () => {
    const fake = fakeTurnstile("hold");
    window.turnstile = fake.api;
    const challenge = attached(() => "pt-BR");

    const first = challenge.token();
    const second = challenge.token();
    expect(fake.resets).toEqual([]);
    fake.solve("one-token");
    await expect(first).resolves.toBe("one-token");

    expect(fake.resets).toEqual(["widget-1"]);
    fake.solve("two-token");
    await expect(second).resolves.toBe("two-token");
  });
});

describe("SR-39 Cloudflare's script, loaded once, from Cloudflare", () => {
  beforeEach(() => {
    delete window.turnstile;
  });

  function scripts() {
    return [...document.head.querySelectorAll("script")];
  }

  it("adds Cloudflare's script for explicit rendering, once, and renders when it has loaded", async () => {
    const challenge = attached(() => "pt-BR");
    const token = challenge.token();

    expect(scripts()).toHaveLength(1);
    expect(scripts()[0]?.src).toBe(SCRIPT_SRC);
    expect(SCRIPT_SRC).toBe(
      "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit",
    );
    expect(scripts()[0]?.async).toBe(true);

    const fake = fakeTurnstile();
    window.turnstile = fake.api;
    scripts()[0]?.dispatchEvent(new Event("load"));

    await expect(token).resolves.toBe(DUMMY_TOKEN);
    expect(scripts()).toHaveLength(1);
  });

  it("answers no token when the script fails to load, and tries it again when asked again", async () => {
    const challenge = attached(() => "pt-BR");
    const first = challenge.token();
    scripts()[0]?.dispatchEvent(new Event("error"));

    await expect(first).resolves.toBeNull();
    expect(scripts()).toHaveLength(0);

    const again = challenge.token();
    expect(scripts()).toHaveLength(1);
    window.turnstile = fakeTurnstile().api;
    scripts()[0]?.dispatchEvent(new Event("load"));
    await expect(again).resolves.toBe(DUMMY_TOKEN);
  });

  // Review finding C5 of pull request #53: a script that loads and leaves no
  // Turnstile (a content blocker's stub, a script that throws as it runs)
  // is a failure, not a script still loading.
  it("answers no token at once when the script loads and leaves no Turnstile, and adds it again when asked again", async () => {
    vi.useFakeTimers();
    const challenge = createChallenge(() => "pt-BR");
    challenge.attach(container());
    const first = challenge.token();
    scripts()[0]?.dispatchEvent(new Event("load"));

    await expect(first).resolves.toBeNull();
    expect(scripts()).toHaveLength(0);

    const again = challenge.token();
    expect(scripts()).toHaveLength(1);
    scripts()[0]?.dispatchEvent(new Event("load"));
    await expect(again).resolves.toBeNull();
  });

  it("stops waiting for a script that does not load in time, and waits on the same one when asked again", async () => {
    vi.useFakeTimers();
    const challenge = attached(() => "pt-BR");
    const first = challenge.token();

    await vi.advanceTimersByTimeAsync(SCRIPT_TIMEOUT_MS);
    await expect(first).resolves.toBeNull();

    const again = challenge.token();
    expect(scripts()).toHaveLength(1);
    window.turnstile = fakeTurnstile().api;
    scripts()[0]?.dispatchEvent(new Event("load"));
    await vi.advanceTimersByTimeAsync(0);
    await expect(again).resolves.toBe(DUMMY_TOKEN);
  });

  it("answers no token when there is nowhere to draw the widget", async () => {
    window.turnstile = fakeTurnstile().api;
    const challenge = createChallenge(() => "pt-BR");

    await expect(challenge.token()).resolves.toBeNull();
  });
});
