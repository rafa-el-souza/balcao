// @vitest-environment node
import { readFileSync } from "node:fs";
import { build } from "vite";
import { beforeAll, describe, expect, it } from "vitest";

// NFR-10: "The public page works without JavaScript for its text content."
// The build renders each page into its own HTML shell, once per language
// (NFR-09), and the server sends the one for the route and the visitor's
// language (app/controllers/spa_controller.rb). Review finding C1 on pull
// request #4 first asked for the text in the HTML; the shells per language
// also keep a visitor of another language from seeing Portuguese first, and
// give the document its true lang.
const web = new URL("..", import.meta.url).pathname;
const LOCALES = ["pt-BR", "en", "es"] as const;
const PAGES = ["landing", "chat", "trace"] as const;

interface Text {
  landing: {
    title: string;
    headline: string;
    lede: string;
    does: { title: string; stock: string };
    business: { title: string };
    warning: { text: string };
  };
  chat: {
    title: string;
    conversation: string;
    heading: string;
    composer: { send: string };
    glass: { title: string };
  };
  trace: { title: string; pageName: string; loading: string };
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

describe("NFR-10 each page's text is in the HTML the server sends, in each language", () => {
  const shells = new Map<string, string>();
  let files: string[] = [];

  beforeAll(async () => {
    const result = await build({
      root: web,
      logLevel: "silent",
      build: { write: false },
    });
    const [bundle] = Array.isArray(result) ? result : [result];
    if (!("output" in bundle)) throw new Error("vite build returned a watcher");
    files = bundle.output.map((file) => file.fileName);
    for (const file of bundle.output) {
      if (file.type === "asset" && file.fileName.startsWith("shells/"))
        shells.set(
          file.fileName,
          typeof file.source === "string"
            ? file.source
            : Buffer.from(file.source).toString("utf8"),
        );
    }
  }, 120_000);

  it("writes one shell per page and language, and no other HTML", () => {
    expect([...shells.keys()].sort()).toEqual(
      PAGES.flatMap((page) =>
        LOCALES.map((locale) => `shells/${page}.${locale}.html`),
      ).sort(),
    );
    expect(files.filter((file) => file.endsWith(".html")).sort()).toEqual(
      [...shells.keys()].sort(),
    );
  });

  it.each(LOCALES)(
    "carries the landing's text in %s, with the document's language and title",
    (locale) => {
      const html = shells.get(`shells/landing.${locale}.html`) ?? "";
      const text = visibleWithoutJavaScript(html);
      const { landing } = textOf(locale);

      expect(html).toContain(`<html lang="${locale}">`);
      expect(html).toContain(`<title>${landing.title}</title>`);
      expect(html).toContain('data-page="landing"');
      for (const line of [
        landing.headline,
        landing.lede,
        landing.does.title,
        landing.does.stock,
        landing.business.title,
        landing.warning.text,
      ])
        // A number and its unit are joined by a no-break space, which the
        // text above folds like any other space.
        expect(text).toContain(line.replace(/\s+/g, " "));
    },
  );

  it.each(LOCALES)("carries the chat's frame in %s", (locale) => {
    const html = shells.get(`shells/chat.${locale}.html`) ?? "";
    const { chat } = textOf(locale);

    expect(html).toContain(`<html lang="${locale}">`);
    expect(html).toContain(`<title>${chat.title}</title>`);
    expect(html).toContain('data-page="chat"');
    expect(html).toContain(`aria-label="${chat.conversation}"`);
    expect(visibleWithoutJavaScript(html)).toContain(chat.heading);
    expect(visibleWithoutJavaScript(html)).toContain(chat.glass.title);
  });

  // The trace page reads its link's token in the browser: without a script it
  // is the receipt's head, in the visitor's language (FR-12).
  it.each(LOCALES)("carries the trace page's head in %s", (locale) => {
    const html = shells.get(`shells/trace.${locale}.html`) ?? "";
    const { trace } = textOf(locale);

    expect(html).toContain(`<html lang="${locale}">`);
    expect(html).toContain(`<title>${trace.title}</title>`);
    expect(html).toContain('data-page="trace"');
    expect(visibleWithoutJavaScript(html)).toContain(trace.pageName);
    expect(visibleWithoutJavaScript(html)).toContain(trace.loading);
  });

  it("names its scripts and styles by hash, from the same origin, with no inline script or style (SR-03)", () => {
    for (const html of shells.values()) {
      expect(html).toMatch(
        /<script type="module" crossorigin src="\/assets\/[^"]+\.js"><\/script>/,
      );
      expect(html).not.toMatch(/<script(?![^>]*\bsrc=)[^>]*>/);
      expect(html).not.toMatch(/\sstyle="/);
      expect(html).not.toMatch(/<style/);
    }
  });
});
