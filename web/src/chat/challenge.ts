// Cloudflare Turnstile, the check before the server mints a visitor identity
// (design FR-18, threat model SR-39, ADR-0012). The chat draws the widget
// under the composer and hands its token to the session that may mint one
// (useConversation.ts); the server asks Cloudflare whether the token is good
// (app/models/turnstile.rb). What it does follows Cloudflare's docs as read on
// 2026-11-20 ("Embed the widget", "Widget configurations", "Client-side
// errors"):
//
// - the script is Cloudflare's own, from its own address, never a copy, with
//   explicit rendering, as a single-page app needs; the page waits for it at
//   most SCRIPT_TIMEOUT_MS, and asks for the session without a token after
//   that, which a page that brings back its cookie does not need;
// - the widget is managed and appears only when Cloudflare wants the visitor
//   to tick it (interaction-only), in the page's language and its light
//   paper; it starts its challenge when drawn, as the page loads;
// - a token is good once and for five minutes: each is given once, and the
//   next one asked for starts the challenge again; nothing retries a failure,
//   refreshes an expired token or a tick left unanswered by itself, so a page
//   left open does not run a challenge every five minutes, nor ask the
//   visitor to tick a box nobody needs;
// - a failed challenge, an unsupported browser and a script that does not
//   load answer no token, and the server's refusal then gives the page its
//   retry hint.

// The widget's options the page uses, in Cloudflare's names.
export interface RenderOptions {
  sitekey: string;
  action: string;
  appearance: "always" | "execute" | "interaction-only";
  execution: "render" | "execute";
  language: string;
  theme: "auto" | "light" | "dark";
  size: "normal" | "flexible" | "compact";
  retry: "auto" | "never";
  "refresh-expired": "auto" | "manual" | "never";
  "refresh-timeout": "auto" | "manual" | "never";
  "response-field": boolean;
  "feedback-enabled": boolean;
  callback?: (token: string) => void;
  "error-callback"?: (code: string) => void;
  "expired-callback"?: () => void;
  "unsupported-callback"?: () => void;
  "before-interactive-callback"?: () => void;
  "timeout-callback"?: () => void;
}

// What Cloudflare's script leaves on window, as far as the page uses it.
export interface TurnstileApi {
  render(
    container: HTMLElement,
    options: RenderOptions,
  ): string | null | undefined;
  reset(widgetId: string): void;
  remove(widgetId: string): void;
}

declare global {
  interface Window {
    turnstile?: TurnstileApi;
  }
}

export const SCRIPT_SRC =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
// How long the page waits for Cloudflare's script before it asks for the
// session without a token: as long as a request to the server (api.ts).
export const SCRIPT_TIMEOUT_MS = 15_000;

// The site key is public, as every page that shows the widget carries it: a
// tracked constant, never an env value or a build argument (FR-18). The
// owner's widget answers on the demo's public name; anywhere else
// (development, the tests, a rehearsal host from M3) the page takes
// Cloudflare's published test key, which always passes and whose dummy
// token only a test secret accepts (ADR-0012).
const SITE_KEYS: Readonly<Record<string, string>> = {
  "balcao.rafasouza.dev.br": "0x4AAAAAAF03lbnq8L3wEEjC",
};
export const TEST_SITE_KEY = "1x00000000000000000000AA";

export function siteKeyFor(hostname: string): string {
  return Object.hasOwn(SITE_KEYS, hostname)
    ? (SITE_KEYS[hostname] ?? TEST_SITE_KEY)
    : TEST_SITE_KEY;
}

export interface Challenge {
  // A token for one session, or null when the check gave none.
  token(): Promise<string | null>;
  // Where the widget is drawn, as React gives it to a callback ref.
  attach: (element: HTMLElement | null) => void;
}

type Waiter = (token: string | null) => void;

// The page's one widget, drawn in its element on the first ask.
export function createChallenge(language: () => string): Challenge {
  let container: HTMLElement | null = null;
  let script: HTMLScriptElement | null = null;
  let widget: string | null = null;
  // The element and the language the widget was drawn in.
  let drawnIn: HTMLElement | null = null;
  let drawnLanguage: string | null = null;
  // A token the widget gave that nobody has asked for yet.
  let held: string | null = null;
  // A challenge is running: drawn or started again, no answer yet.
  let running = false;
  let unsupported = false;
  const waiters: Waiter[] = [];

  // Cloudflare's script, once: an element that failed, or that loaded and
  // left no Turnstile (a content blocker's stub, a script that threw as it
  // ran), is dropped, so the next ask adds it again; one still loading is
  // waited on again (review finding C5 of pull request #53).
  function load(): Promise<TurnstileApi | null> {
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (!script) {
      const element = document.createElement("script");
      element.src = SCRIPT_SRC;
      element.async = true;
      const drop = () => {
        element.remove();
        if (script === element) script = null;
      };
      element.addEventListener("error", drop);
      element.addEventListener("load", () => {
        if (!window.turnstile) drop();
      });
      document.head.append(element);
      script = element;
    }
    const element = script;
    return new Promise((resolve) => {
      const done = (api: TurnstileApi | null) => {
        window.clearTimeout(timer);
        element.removeEventListener("load", loaded);
        element.removeEventListener("error", failed);
        resolve(api);
      };
      const loaded = () => {
        done(window.turnstile ?? null);
      };
      const failed = () => {
        done(null);
      };
      const timer = window.setTimeout(failed, SCRIPT_TIMEOUT_MS);
      element.addEventListener("load", loaded);
      element.addEventListener("error", failed);
    });
  }

  // The challenge's answer: to the first who waits, else held.
  function answer(token: string | null) {
    running = false;
    const waiter = waiters.shift();
    if (waiter) waiter(token);
    else if (token !== null) held = token;
  }

  // Whoever still waits once an answer was given starts the next challenge:
  // the widget is reset, or drawn again when the page's language changed
  // since it was drawn, since a reset keeps its language (review finding C6
  // of pull request #53). The script throws on what it cannot do (a widget
  // it does not know): every wait then ends with no token (C7).
  function next(api: TurnstileApi) {
    if (waiters.length === 0 || running || widget === null) return;
    running = true;
    drawnIn?.removeAttribute("data-asking");
    try {
      if (language().toLowerCase() === drawnLanguage) {
        api.reset(widget);
        return;
      }
      api.remove(widget);
      widget = null;
      const element = container ?? drawnIn;
      if (element && draw(api, element)) return;
    } catch {
      // Below: nobody is left waiting.
    }
    running = false;
    for (const waiter of waiters.splice(0)) waiter(null);
  }

  // Draws the widget, whose challenge starts at once; false when it was not.
  function draw(api: TurnstileApi, element: HTMLElement): boolean {
    let id: string | null | undefined;
    try {
      id = render(api, element);
    } catch {
      return false;
    }
    if (typeof id !== "string") return false;
    widget = id;
    drawnIn = element;
    drawnLanguage = language().toLowerCase();
    return true;
  }

  function render(api: TurnstileApi, element: HTMLElement) {
    return api.render(element, {
      sitekey: siteKeyFor(window.location.hostname),
      action: "session",
      appearance: "interaction-only",
      execution: "render",
      // Cloudflare's codes are lower case: "pt-BR" warns and falls back.
      language: language().toLowerCase(),
      theme: "light",
      size: "normal",
      retry: "never",
      "refresh-expired": "never",
      "refresh-timeout": "never",
      "response-field": false,
      "feedback-enabled": false,
      callback: (token) => {
        answer(token);
        next(api);
      },
      "error-callback": () => {
        answer(null);
        next(api);
      },
      "expired-callback": () => {
        held = null;
      },
      // A tick left unanswered past Cloudflare's time answers no token, as a
      // failure does, rather than refreshing for ever while a session waits
      // on it that may not need one (the review of pull request #53).
      "timeout-callback": () => {
        answer(null);
        next(api);
      },
      "unsupported-callback": () => {
        unsupported = true;
        running = false;
        for (const waiter of waiters.splice(0)) waiter(null);
      },
      // The widget takes no room until it asks for a tick, but its element
      // is never empty once drawn: the page spaces it by this mark, which
      // stays while the widget shows the tick's result.
      "before-interactive-callback": () => {
        element.setAttribute("data-asking", "");
      },
    });
  }

  async function token(): Promise<string | null> {
    const ready = held;
    if (ready !== null) {
      held = null;
      return ready;
    }
    if (unsupported) return null;
    const api = window.turnstile ?? (await load());
    const element = container;
    if (!api || !element) return null;
    return new Promise((resolve) => {
      waiters.push(resolve);
      if (widget !== null) {
        next(api);
        return;
      }
      if (running) return;
      running = true;
      if (draw(api, element)) return;
      running = false;
      const waiting = waiters.indexOf(resolve);
      if (waiting >= 0) waiters.splice(waiting, 1);
      resolve(null);
    });
  }

  return {
    token,
    attach(element) {
      container = element;
    },
  };
}
