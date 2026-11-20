import type { RenderOptions, TurnstileApi } from "../chat/challenge";

// A stand-in for Cloudflare's Turnstile script (window.turnstile), so no test
// loads anything from Cloudflare. It records what the page asks of it and
// answers as the widget does: by default the test site key's dummy token,
// a moment after a challenge starts; a test can hold the answers and give
// them itself (solve, fail, expire, unsupported).
export const DUMMY_TOKEN = "XXXX.DUMMY.TOKEN.XXXX";

export interface FakeTurnstile {
  api: TurnstileApi;
  rendered: { container: HTMLElement; options: RenderOptions }[];
  resets: string[];
  removed: string[];
  // How a challenge ends by itself: the dummy token, or nothing until the
  // test says.
  answer: "token" | "hold";
  solve(token?: string): void;
  fail(code?: string): void;
  expire(): void;
  unsupported(): void;
  // The challenge turns interactive: the widget asks for a tick.
  interactive(): void;
}

export function fakeTurnstile(answer: FakeTurnstile["answer"] = "token") {
  let widgets = 0;
  const fake: FakeTurnstile = {
    rendered: [],
    resets: [],
    removed: [],
    answer,
    api: {
      render(container, options) {
        fake.rendered.push({ container, options });
        widgets += 1;
        start();
        return `widget-${String(widgets)}`;
      },
      reset(id) {
        fake.resets.push(id);
        start();
      },
      remove(id) {
        fake.removed.push(id);
      },
    },
    solve(token = DUMMY_TOKEN) {
      options().callback?.(token);
    },
    fail(code = "300030") {
      options()["error-callback"]?.(code);
    },
    expire() {
      options()["expired-callback"]?.();
    },
    unsupported() {
      options()["unsupported-callback"]?.();
    },
    interactive() {
      options()["before-interactive-callback"]?.();
    },
  };
  function options(): RenderOptions {
    const last = fake.rendered.at(-1);
    if (!last) throw new Error("no widget rendered");
    return last.options;
  }
  function start() {
    if (fake.answer === "token")
      setTimeout(() => {
        fake.solve();
      }, 0);
  }
  return fake;
}

// The fake as the page finds it, on window, as Cloudflare's script leaves it.
// Every test starts with one (setup.ts), so no page waits on a script jsdom
// never loads; turnstile() is the one the page sees.
let installed: FakeTurnstile | null = null;

export function installTurnstile(answer: FakeTurnstile["answer"] = "token") {
  installed = fakeTurnstile(answer);
  window.turnstile = installed.api;
  return installed;
}

export function turnstile(): FakeTurnstile {
  if (!installed) throw new Error("no fake Turnstile installed");
  return installed;
}

export function uninstallTurnstile() {
  installed = null;
  delete window.turnstile;
}
