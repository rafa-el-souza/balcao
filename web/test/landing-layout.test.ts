// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The landing's layout at its widths (design §6.8; the §10 note of 2026-11-14
// on the landing's layout, asked by the owner). jsdom lays nothing out, so the
// rules are read from the sheet, as the QR's forced-colours spec does; the
// pull request records the browser's pictures and the measured positions.
const css = readFileSync(
  new URL("../src/landing/Landing.module.css", import.meta.url),
  "utf8",
);
const landing = readFileSync(
  new URL("../src/landing/Landing.tsx", import.meta.url),
  "utf8",
);

// The body of the block that opens with `header {`, up to its matching brace.
function block(source: string, header: string): string {
  const start = source.indexOf(`${header} {`);
  if (start < 0) return "";
  let depth = 0;
  for (let i = start + header.length + 1; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start + header.length + 2, i);
    }
  }
  return "";
}

// The declarations of the first rule for exactly `selector` in `source`.
function rule(source: string, selector: string): string {
  const escaped = selector.replace(/\./g, "\\.");
  return (
    new RegExp(`(?:^|\\n)\\s*${escaped} \\{([^}]*)\\}`).exec(source)?.[1] ?? ""
  );
}

const BAND = "@media (40rem <= width < 60rem)";
const DESK = "@media (width >= 60rem)";
const SHORT_DESK = "@media (width >= 60rem) and (height < 48rem)";

describe("FR-19 the landing's QR on whole pixels", () => {
  // The symbol is 25 modules and a quiet zone of 2 on each side (the viewBox);
  // at a whole number of pixels per module a screen draws every module the same
  // width, with no grey edges, at a density of 1 and at 1.25, 1.5 and 2.
  const box = /viewBox="-2 -2 (\d+) (\d+)"/.exec(landing);
  const qr = rule(css, ".qr");
  const width = /\n\s*width: ([\d.]+)rem;/.exec(qr)?.[1] ?? "";
  const height = /\n\s*height: ([\d.]+)rem;/.exec(qr)?.[1] ?? "";

  it("is a whole number of pixels per module at the root size", () => {
    expect(box?.[1]).toBe("29");
    expect(Number.isInteger((Number(width) * 16) / 29)).toBe(true);
    expect(height).toBe(width);
  });

  it("keeps its edges on the pixel grid", () => {
    expect(qr).toMatch(/shape-rendering: crispEdges;/);
  });
});

describe("FR-19 FR-21 between 40 and 60rem the bot's receipt stands beside the chips", () => {
  const band = block(css, BAND);

  it("makes the hero two rows of the page's two columns, the pitch across both", () => {
    const hero = rule(band, ".hero");
    expect(hero).toMatch(/grid-row: 1 \/ span 2;/);
    expect(hero).toMatch(/grid-template-columns: subgrid;/);
    expect(hero).toMatch(/grid-template-rows: subgrid;/);
    expect(rule(band, ".pitch")).toMatch(/grid-column: 1 \/ -1;/);
  });

  it("puts the chips in the first column and the receipt in the second, on one row", () => {
    const say = rule(band, ".say");
    const bot = rule(band, ".bot");
    expect(say).toMatch(/grid-column: 1;/);
    expect(say).toMatch(/grid-row: 2;/);
    expect(bot).toMatch(/grid-column: 2;/);
    expect(bot).toMatch(/grid-row: 2;/);
  });
});

describe('FR-19 on a desk "Como é feito" follows the bot\'s receipt in the third column', () => {
  const desk = block(css, DESK);

  it("lets the third column flow on its own beside the hero and the two sections", () => {
    expect(rule(desk, ".hero")).toMatch(/grid-row: 1 \/ span 2;/);
    expect(rule(desk, ".bot")).toMatch(/grid-row: 1;/);
    expect(rule(desk, ".built")).toMatch(/grid-row: 2 \/ span 2;/);
    // Spanning two rows, the receipt keeps its own height instead of stretching to theirs.
    expect(rule(css, ".built")).toMatch(/align-self: start;/);
    expect(rule(desk, ".does,\n  .business")).toMatch(/grid-row: 3;/);
  });
});

describe("FR-21 on a short desk the chips stay in the first screen", () => {
  const short = block(css, SHORT_DESK);

  it("takes air from above the headline and the chips, not from the type", () => {
    expect(rule(short, ".hero")).toMatch(/padding-top: var\(--space-8\);/);
    expect(rule(short, ".say")).toMatch(/margin-top: var\(--space-8\);/);
    expect(short).not.toMatch(/font-size/);
  });
});
