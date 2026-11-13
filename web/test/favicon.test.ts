// @vitest-environment node
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(new URL(path, import.meta.url));
const text = (path: string) => read(path).toString("utf8");

// Design §6.7 and its note of 2026-11-13 in §10: every shell is built from
// web/index.html, so its head names the tab's icon for every page. Vite gives
// the SVG and the PNG hashed names under assets/; the .ico is a file of the
// server's public/ at the site's root, which Vite leaves alone.
describe("Design §6.7 the tab's icon in every page", () => {
  it("names the .ico at the site's root, the SVG cross and the phone's icon", () => {
    const html = text("../index.html");
    // The .ico keeps its name at the site's root, where public/'s year of
    // cache holds it, so the page asks for it by its content: a changed mark
    // is fetched anew (review finding C1 of pull request #22).
    const version = createHash("sha256")
      .update(read("../../public/favicon.ico"))
      .digest("hex")
      .slice(0, 8);

    expect(html).toContain(
      `<link rel="icon" href="/favicon.ico?v=${version}" sizes="32x32" vite-ignore />`,
    );
    expect(html).toContain(
      '<link rel="icon" href="/src/favicon/icon.svg" type="image/svg+xml" />',
    );
    expect(html).toContain(
      '<link rel="apple-touch-icon" href="/src/favicon/apple-touch-icon.png" />',
    );
  });

  // An icon is a document of its own and cannot read the page's custom
  // properties, so it writes their values; they change with the tokens.
  it("draws in the page's tokens: the rule's border, the paper and the lit green", () => {
    const tokens = text("../src/styles/tokens.css");
    const token = (name: string) =>
      new RegExp(`--color-${name}: (#[0-9a-f]{6});`).exec(tokens)?.[1];

    expect(text("../src/favicon/icon.svg")).toBe(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" shape-rendering="crispEdges">' +
        `<path fill="${String(token("rule"))}" d="M0 0h16v16H0z"/>` +
        `<path fill="${String(token("paper"))}" d="M1 1h14v14H1z"/>` +
        `<path fill="${String(token("accent"))}" d="M6 2h4v4h4v4h-4v4H6v-4H2V6h4z"/>` +
        "</svg>\n",
    );
  });

  it("dims nothing but the cross: the dim icon is the lit one with its cross at 30%", () => {
    const lit = text("../src/favicon/icon.svg");

    expect(text("../src/favicon/icon-dim.svg")).toBe(
      lit.replace(
        '<path fill="#086f49" d="',
        '<path fill="#086f49" opacity="0.3" d="',
      ),
    );
  });

  it("gives the phone an opaque square of 180 px, which the system rounds itself", () => {
    const png = read("../src/favicon/apple-touch-icon.png");

    expect(png.subarray(12, 16).toString("latin1")).toBe("IHDR");
    expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([180, 180]);
    // Colour type 2: red, green and blue, and no alpha to show the black that
    // a phone puts behind a transparent icon.
    expect(png[25]).toBe(2);
  });
});
