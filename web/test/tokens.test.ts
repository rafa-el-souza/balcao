// @vitest-environment node
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// The drawings of docs/prototype/ were reviewed with the owner, and the app
// follows them (design §10, note of 2026-11-12): the token block at the top of
// the prototype's stylesheet is the app's tokens.css, unchanged (ADR-0008).
// A token changes in both places or in neither.
const read = (path: string) =>
  readFileSync(new URL(path, import.meta.url), "utf8");

const rootBlock = (css: string) => {
  const block = /^:root \{\n[\s\S]*?\n\}$/m.exec(css)?.[0];
  if (!block) throw new Error("no :root block");
  return block;
};

describe("ADR-0008 the app's tokens are the prototype's", () => {
  it("has the prototype's :root block, character for character", () => {
    const prototype = rootBlock(read("../../docs/prototype/styles.css"));
    const app = rootBlock(read("../src/styles/tokens.css"));

    expect(app).toBe(prototype);
  });

  it("defines no colour outside tokens.css (interface checklist item 5)", () => {
    const src = new URL("../src/", import.meta.url);
    const files = readdirSync(src, { recursive: true, encoding: "utf8" })
      .filter((file) => file.endsWith(".css"))
      .filter((file) => file !== join("styles", "tokens.css"));
    const literals = files.flatMap((file) =>
      [
        ...readFileSync(new URL(file, src), "utf8").matchAll(
          /#[0-9a-f]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab|lab|lch|hwb)\(|(?<![-\w])(?:white|black)(?![-\w])/gi,
        ),
      ].map((match) => `${file}: ${match[0]}`),
    );

    expect(files.length).toBeGreaterThan(1);
    expect(literals).toEqual([]);
  });
});
