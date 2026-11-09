/// <reference types="vitest/config" />
import { createHash } from "node:crypto";
import { basename, relative } from "node:path";
import { fileURLToPath } from "node:url";

import react from "@vitejs/plugin-react";
import { type CSSOptions, type Plugin, createServer, defineConfig } from "vite";

// The SPA (ADR-0001). `vite build` writes web/dist: the image serves
// index.html through Rails with no-cache and the hashed files under assets/
// as static files (Dockerfile, design §6.7). In development, bin/dev runs
// this server beside Rails and it forwards the API, the cable and /up.
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

// Puts the app's HTML, rendered from the locale files, into the built shell,
// so the public page has its text without JavaScript (design NFR-10, review
// finding C1 on pull request #4); the browser hydrates it (src/main.tsx).
function prerenderShell(): Plugin {
  return {
    name: "balcao:prerender-shell",
    apply: "build",
    transformIndexHtml: {
      order: "post",
      async handler(html) {
        if (html.split(SHELL_ROOT).length !== 2)
          throw new Error(`index.html must contain ${SHELL_ROOT} exactly once`);
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
          const entry = (await server.ssrLoadModule(
            "/src/entry-server.tsx",
          )) as {
            render: () => string;
          };
          return html.replace(
            SHELL_ROOT,
            `<div id="root">${entry.render()}</div>`,
          );
        } finally {
          await server.close();
        }
      },
    },
  };
}

export default defineConfig({
  plugins: [react(), prerenderShell()],
  css,
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": RAILS,
      "/up": RAILS,
      "/cable": { target: RAILS, ws: true },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
