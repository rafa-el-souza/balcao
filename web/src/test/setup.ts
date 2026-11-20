import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach } from "vitest";

import { installTurnstile, uninstallTurnstile } from "./fakeTurnstile";

// Cloudflare's Turnstile script is never loaded here: the chat finds a fake
// that gives the test site key's dummy token (threat model SR-39), which a
// test can hold or fail instead. The tests that run in Node have no window.
beforeEach(() => {
  if (typeof window !== "undefined") installTurnstile();
});

// Testing Library cleans up by itself only when the test globals are on;
// they are off here, so every test file imports from "vitest" explicitly.
afterEach(() => {
  cleanup();
  if (typeof window !== "undefined") uninstallTurnstile();
  // The tab's icon a test put in the head (test/tabIcon.ts); the tests that
  // run in Node have no document.
  if (typeof document === "undefined") return;
  for (const icon of document.head.querySelectorAll('link[rel="icon"]'))
    icon.remove();
});
