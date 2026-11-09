// @vitest-environment node
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { build } from "vite";
import { describe, expect, it } from "vitest";

// Review finding C1 on pull request #4: the placeholder was drawn only by
// client-side React into an empty #root, so a visitor without JavaScript, or
// a link preview, got a blank page. NFR-10: "The public page works without
// JavaScript for its text content." The text must come from the locale files
// (NFR-09), so the build renders the app into the shell.
const web = fileURLToPath(new URL("..", import.meta.url));
const LOCALES = ["pt-BR", "en", "es"] as const;
const REPOSITORY_URL = "https://github.com/rafa-el-souza/balcao";

interface Text {
  app: { name: string; pharmacy: string };
  placeholder: Record<
    "status" | "tagline" | "soon" | "meanwhile" | "repository",
    string
  >;
}
const textOf = (locale: string) =>
  JSON.parse(
    readFileSync(
      new URL(`../src/locales/${locale}.json`, import.meta.url),
      "utf8",
    ),
  ) as Text;

// What a browser shows with scripts off: the body, minus scripts and styles,
// tags removed.
const visibleWithoutJavaScript = (html: string) =>
  html
    .replace(/<head>[\s\S]*?<\/head>/i, "")
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");

describe("NFR-10 the placeholder's text is in the HTML the server sends", () => {
  it("carries the three languages and the repository link before any script runs", async () => {
    const result = await build({
      root: web,
      logLevel: "silent",
      build: { write: false },
    });
    const [bundle] = Array.isArray(result) ? result : [result];
    if (!("output" in bundle)) throw new Error("vite build returned a watcher");
    const shell = bundle.output.find((file) => file.fileName === "index.html");
    if (shell?.type !== "asset") throw new Error("the build has no index.html");
    const html =
      typeof shell.source === "string"
        ? shell.source
        : Buffer.from(shell.source).toString("utf8");
    const text = visibleWithoutJavaScript(html);

    expect(text).toContain(textOf("pt-BR").app.name);
    expect(text).toContain(textOf("pt-BR").app.pharmacy);
    for (const locale of LOCALES) {
      const { placeholder } = textOf(locale);
      for (const line of [
        placeholder.status,
        placeholder.tagline,
        placeholder.soon,
        placeholder.meanwhile,
        placeholder.repository,
      ]) {
        expect(text).toContain(line);
      }
      expect(html).toContain(`lang="${locale}"`);
    }
    expect(html).toContain(`href="${REPOSITORY_URL}"`);
  }, 60_000);
});
