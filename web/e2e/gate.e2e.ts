import { createRequire } from "node:module";
import { gzipSync } from "node:zlib";

import { type Page, expect, test } from "@playwright/test";
import type { AxeResults } from "axe-core";

import { type Served, serve } from "./server.ts";
import { TRACE_TOKEN, standIn } from "./stand-ins.ts";

// NFR-10's gate over the four public pages that exist since M3 (landing,
// chat, trace, privacy; the calendar and the status page join at M5), in
// the three languages and at a phone's width and a desktop's:
//
// - axe-core fails the page on any violation of WCAG 2.2 A or AA, in its
//   state with content: the chat and the trace page drawn from a
//   conversation of two turns (stand-ins.ts);
// - the first visit, with nothing cached, loads at most 300 kB excluding
//   fonts, counted as the server sends it, compressed: each file the build
//   serves (the shell, its hashed files, the tab's icon) at zlib's fastest
//   gzip level, larger than what the app's Thruster sends in gzip or zstd
//   (design §10, M3-5's note). The API's answers and Cloudflare's script
//   are not the build's and are not counted.

const LIMIT_BYTES = 300_000;
const WCAG = [
  "wcag2a",
  "wcag2aa",
  "wcag21a",
  "wcag21aa",
  "wcag22a",
  "wcag22aa",
];
const AXE = createRequire(import.meta.url).resolve("axe-core/axe.min.js");
const FONT = /\.(woff2?|ttf|otf)$/;
// The API's answers and the cable are the app's, not the build's.
const NOT_BUILT = /^\/(api|cable)(\/|$)/;

const PAGES = [
  { name: "landing", path: "/", ready: "main h1" },
  { name: "chat", path: "/chat", ready: "text=KP3K3K" },
  {
    name: "trace",
    path: `/trace#${TRACE_TOKEN}`,
    ready: "text=search_products",
  },
  { name: "privacy", path: "/privacy", ready: "main h1" },
] as const;
const LOCALES = ["pt-BR", "en", "es"] as const;
const WIDTHS = [
  { name: "390 px", width: 390, height: 844 },
  { name: "desktop", width: 1280, height: 900 },
] as const;

let served: Served;
test.beforeAll(async () => {
  served = await serve();
});
test.afterAll(async () => {
  await served.close();
});

const sized = (url: string, body: Buffer) => ({
  url,
  built: body.length,
  sent: gzipSync(body, { level: 1 }).length,
});

// What the first visit loaded from the build, compressed and as built: what
// the page asked for, and the icons its shell names, which a headless
// browser does not fetch and a visitor's does.
async function visit(page: Page, path: string, ready: string) {
  const loaded: Promise<{ url: string; built: number; sent: number }>[] = [];
  page.on("response", (response) => {
    const url = new URL(response.url());
    if (
      url.origin !== served.origin ||
      FONT.test(url.pathname) ||
      NOT_BUILT.test(url.pathname)
    )
      return;
    loaded.push(response.body().then((body) => sized(response.url(), body)));
  });
  await page.goto(`${served.origin}${path}`);
  await page.locator(ready).first().waitFor();
  await page.waitForLoadState("networkidle");
  const icons = await page
    .locator('link[rel~="icon"], link[rel="apple-touch-icon"]')
    .evaluateAll((links) =>
      links.map((link) => (link as HTMLLinkElement).href),
    );
  for (const icon of icons)
    loaded.push(
      page.request
        .get(icon)
        .then(async (answer) => sized(icon, await answer.body())),
    );
  return Promise.all(loaded);
}

async function violations(page: Page) {
  await page.addScriptTag({ path: AXE });
  const results = await page.evaluate(
    (tags) =>
      (
        window as unknown as {
          axe: { run: (...args: unknown[]) => Promise<AxeResults> };
        }
      ).axe.run(document, { runOnly: { type: "tag", values: tags } }),
    WCAG,
  );
  return results.violations.map(
    (violation) =>
      `${violation.id} (${violation.impact ?? "no impact"}): ${violation.help}; ${violation.nodes
        .map((node) => node.target.join(" "))
        .join(", ")}`,
  );
}

for (const { name, path, ready } of PAGES)
  for (const locale of LOCALES)
    for (const size of WIDTHS)
      test(`NFR-10 ${name} in ${locale} at ${size.name}: no WCAG 2.2 AA violation, the first visit under 300 kB`, async ({
        page,
        context,
      }) => {
        await page.setViewportSize({ width: size.width, height: size.height });
        await context.addCookies([
          { name: "lang", value: locale, url: served.origin },
        ]);
        await standIn(page);

        const files = await visit(page, path, ready);
        const sent = files.reduce((total, file) => total + file.sent, 0);
        const built = files.reduce((total, file) => total + file.built, 0);
        test.info().annotations.push({
          type: "first visit",
          description: `${String(sent)} bytes compressed, ${String(built)} as built, ${String(files.length)} files`,
        });

        expect(await violations(page)).toEqual([]);
        expect(
          sent,
          `the first visit sends ${String(sent)} bytes: ${files.map((file) => `${file.url} ${String(file.sent)}`).join(", ")}`,
        ).toBeLessThanOrEqual(LIMIT_BYTES);
      });
