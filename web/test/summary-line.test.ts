// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The line that stands for the glass box under 52rem speaks of the last turn:
// its number, rows, cost and time. When the four do not fit, the count of
// rows leaves first, since the drawer shows the rows; cost and time stay
// whole, and the line never widens the page (the owner, 2026-11-15; the
// owner's round at the MVP close, rows IR-W1 and Q41). At 360 px a turn
// running past ten seconds with a cost pushed the page sideways, and at 320
// px every turn did. jsdom lays nothing out, so the rules are read from the
// sheet; the pull request records the browser's measure at 320, 360, 375 and
// 390 px.
const sheet = readFileSync(
  new URL("../src/chat/Chat.module.css", import.meta.url),
  "utf8",
);

function rule(selector: string): string {
  const escaped = selector.replace(/[.]/g, "\\.");
  return (
    new RegExp(`(?:^|\\n)\\s*${escaped} \\{([^}]*)\\}`).exec(sheet)?.[1] ?? ""
  );
}

describe("FR-12 NFR-10 the glass box's line under 52rem", () => {
  it("never widens the page: the line takes the room left and clips", () => {
    const line = rule(".summaryLine");
    expect(line).toMatch(/min-width: 0;/);
    expect(line).toMatch(/overflow: hidden;/);
  });

  it("lets the count of rows go first, whole, to a line nothing shows", () => {
    // The count and the figure share a box laid out from its end, the figure
    // first in its order: the count is the part that wraps.
    const rest = rule(".summaryRest");
    expect(rest).toMatch(/flex-flow: row-reverse wrap;/);
    expect(rest).toMatch(/justify-content: flex-end;/);
    expect(rest).toMatch(/height: var\(--leading-row\);/);
    expect(rest).toMatch(/overflow: hidden;/);
    expect(rule(".summaryFigure")).toMatch(/order: -1;/);
    // One line tall, as the box that clips its second line.
    expect(rule(".summaryLine")).toMatch(/line-height: var\(--leading-row\);/);
  });
});
