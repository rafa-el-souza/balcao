import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

// Testing Library cleans up by itself only when the test globals are on;
// they are off here, so every test file imports from "vitest" explicitly.
afterEach(() => {
  cleanup();
  // The tab's icon a test put in the head (test/tabIcon.ts); the tests that
  // run in Node have no document.
  if (typeof document === "undefined") return;
  for (const icon of document.head.querySelectorAll('link[rel="icon"]'))
    icon.remove();
});
