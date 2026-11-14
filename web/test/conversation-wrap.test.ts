// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The words of a conversation carry links and long words: the /trace reply
// is the page's own link, the /help reply the privacy page's, and a visitor
// may paste anything. Wherever those words are shown they break at any point
// rather than push the page sideways on a phone (NFR-10, WCAG 2.1's reflow at
// 320 px). On the trace page they did not: the /trace reply's link ran past
// the receipt and the screen at 390 px (the owner, 2026-11-14). jsdom lays
// nothing out, so the rules are read from the sheets; the pull request
// records the browser's measure.
const sheet = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

function rule(source: string, selector: string): string {
  const escaped = selector.replace(/[.]/g, "\\.");
  return (
    new RegExp(`(?:^|\\n)\\s*${escaped} \\{([^}]*)\\}`).exec(source)?.[1] ?? ""
  );
}

describe("FR-12 NFR-10 a conversation's words wrap at any width", () => {
  it("on the trace page, the visitor's words and the reply", () => {
    const trace = sheet("../src/trace/TracePage.module.css");
    expect(rule(trace, ".said")).toMatch(/overflow-wrap: anywhere;/);
  });

  it("in the chat, the visitor's slip, the attendant's and the pharmacist's words", () => {
    const chat = sheet("../src/chat/Chat.module.css");
    expect(rule(chat, ".visitor")).toMatch(/overflow-wrap: anywhere;/);
    expect(rule(chat, ".attendant,\n.pharmacist")).toMatch(
      /overflow-wrap: anywhere;/,
    );
  });
});
