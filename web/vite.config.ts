/// <reference types="vitest/config" />
import { createHash } from "node:crypto";
import { basename, relative } from "node:path";
import { fileURLToPath } from "node:url";

import react from "@vitejs/plugin-react";
import { type CSSOptions, type Plugin, createServer, defineConfig } from "vite";

// The SPA (ADR-0001). `vite build` writes web/dist: the image serves the
// page shells under shells/ through Rails with no-cache and the hashed files
// under assets/ as static files (Dockerfile, design §6.7). In development, bin/dev runs
// this server beside Rails and it forwards the API, the cable, /up and the
// tab's .ico.
const RAILS = "http://127.0.0.1:3000";
const ROOT = fileURLToPath(new URL(".", import.meta.url));
const SHELL_ROOT = '<div id="root"></div>';

// CSS Module class names depend only on the file and the class, so the
// markup rendered at build time and the bundle the browser runs agree.
const css: CSSOptions = {
  modules: {
    generateScopedName(name, filename) {
      const file = relative(ROOT, filename.split("?")[0] ?? filename);
      const hash = createHash("sha256")
        .update(`${file}:${name}`)
        .digest("base64url")
        .slice(0, 6);
      return `${basename(file, ".module.css")}_${name}_${hash}`;
    },
  },
};

// Renders each page into its own copy of the built shell, once per language,
// so the public page has its text without JavaScript (design NFR-10, review
// finding C1 on pull request #4) and in the visitor's language (NFR-09):
// web/dist/shells/<page>.<locale>.html, with the document's lang and title.
// Rails sends the one for the route and the language
// (app/controllers/spa_controller.rb); the browser hydrates it (src/main.tsx).
const SHELL_HTML = '<html lang="pt-BR">';
const SHELL_TITLE = "<title>Balcão</title>";

const escapeHtml = (text: string) =>
  text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

function prerenderShells(): Plugin {
  return {
    name: "balcao:prerender-shells",
    apply: "build",
    enforce: "post",
    async generateBundle(_options, bundle) {
      const shell = bundle["index.html"];
      if (shell?.type !== "asset")
        throw new Error("the build has no index.html");
      const template =
        typeof shell.source === "string"
          ? shell.source
          : Buffer.from(shell.source).toString("utf8");
      for (const marker of [SHELL_ROOT, SHELL_HTML, SHELL_TITLE])
        if (template.split(marker).length !== 2)
          throw new Error(`index.html must contain ${marker} exactly once`);

      const server = await createServer({
        configFile: false,
        root: ROOT,
        plugins: [react()],
        css,
        logLevel: "error",
        appType: "custom",
        server: { middlewareMode: true, hmr: false, ws: false },
      });
      try {
        const entry = (await server.ssrLoadModule("/src/entry-server.tsx")) as {
          render: (
            page: string,
            locale: string,
          ) => { html: string; title: string };
          PAGES: Record<string, string>;
          LOCALES: readonly string[];
        };
        for (const page of Object.keys(entry.PAGES)) {
          for (const locale of entry.LOCALES) {
            const { html, title } = entry.render(page, locale);
            this.emitFile({
              type: "asset",
              fileName: `shells/${page}.${locale}.html`,
              source: template
                .replace(SHELL_HTML, `<html lang="${locale}">`)
                .replace(SHELL_TITLE, `<title>${escapeHtml(title)}</title>`)
                .replace(
                  SHELL_ROOT,
                  `<div id="root" data-page="${page}">${html}</div>`,
                ),
            });
          }
        }
      } finally {
        await server.close();
      }
      // Only the shells are served; the template would be a page in no language.
      delete bundle["index.html"];
    },
  };
}

export default defineConfig({
  plugins: [react(), prerenderShells()],
  css,
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": RAILS,
      "/up": RAILS,
      "/cable": { target: RAILS, ws: true },
      // The tab's .ico is a file of Rails' public/ (index.html, design §10).
      "/favicon.ico": RAILS,
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
