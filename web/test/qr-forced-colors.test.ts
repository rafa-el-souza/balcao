// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// Review finding W1 of pull request #33 (FR-19, NFR-10): in forced colours
// (a high-contrast theme) the receipt takes the system's canvas, black in a
// dark theme, while the QR's dark modules kept their fill, so the QR could not
// be seen or scanned. The QR keeps its own colours and a light ground of its
// own. jsdom draws no forced colours, so the rule is read from the sheet; the
// pull request records the browser's picture.
const css = readFileSync(
  new URL("../src/landing/Landing.module.css", import.meta.url),
  "utf8",
);

describe("FR-19 the landing's QR in forced colours", () => {
  const qr = /\n\.qr \{([^}]*)\}/.exec(css)?.[1] ?? "";

  it("keeps its own colours, dark modules on a light ground of its own", () => {
    expect(qr).toMatch(/forced-color-adjust: none;/);
    expect(qr).toMatch(/background-color: var\(--color-paper-2\);/);
    expect(qr).toMatch(/fill: var\(--color-instrument-ink\);/);
  });
});
