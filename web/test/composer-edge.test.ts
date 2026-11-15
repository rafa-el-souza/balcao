// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// The composer's sheet at rest: its quiet rule stood at 1.48:1 against the
// paper, under the brief's 3:1 for a control (design brief §5, interface
// checklist item 16); it takes the strong rule, in the app and in the drawing
// (the owner, 2026-11-15; the owner's round at the MVP close, rows IR-OC2 and
// Q42). jsdom lays nothing out, so the rules are read from the sheets and the
// contrast from the tokens.
const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

function rule(source: string, selector: string): string {
  const escaped = selector.replace(/[.]/g, "\\.");
  return (
    new RegExp(`(?:^|\\n)\\s*${escaped} \\{([^}]*)\\}`).exec(source)?.[1] ?? ""
  );
}

function token(name: string): string {
  const value = new RegExp(`--${name}: (#[0-9a-f]{6});`).exec(
    read("../src/styles/tokens.css"),
  )?.[1];
  if (!value) throw new Error(`no token ${name}`);
  return value;
}

// WCAG 2's relative luminance and contrast ratio.
function luminance(hex: string): number {
  const [r = 0, g = 0, b = 0] = [1, 3, 5].map((at) => {
    const channel = parseInt(hex.slice(at, at + 2), 16) / 255;
    return channel <= 0.04045
      ? channel / 12.92
      : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return ((light ?? 0) + 0.05) / ((dark ?? 0) + 0.05);
}

describe("NFR-10 the composer's edge at rest", () => {
  it("has the strong rule, in the app and in the drawing", () => {
    expect(rule(read("../src/chat/Chat.module.css"), ".composerRow")).toMatch(
      /border: 1px solid var\(--color-rule-strong\);/,
    );
    expect(
      rule(read("../../docs/prototype/styles.css"), ".composer-row"),
    ).toMatch(/border: 1px solid var\(--color-rule-strong\);/);
  });

  it("stands at 3:1 or more against the paper outside and the sheet inside", () => {
    const edge = token("color-rule-strong");
    expect(contrast(edge, token("color-paper"))).toBeGreaterThanOrEqual(3);
    expect(contrast(edge, token("color-paper-2"))).toBeGreaterThanOrEqual(3);
  });
});
