import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

// The build as the app serves it, for NFR-10's gate (gate.e2e.ts): each
// public page's shell from web/dist/shells in the page's language, as
// SpaController sends it (the lang cookie, else Portuguese), the hashed
// files under /assets/ and the tab's icon. Nothing else answers here: the
// API, the cable and Cloudflare's script are the gate's own stand-ins.

const DIST = fileURLToPath(new URL("../dist/", import.meta.url));
const PUBLIC = fileURLToPath(new URL("../../public/", import.meta.url));
const LOCALES = ["pt-BR", "en", "es"] as const;
const PAGES: Readonly<Record<string, string>> = {
  "/": "landing",
  "/chat": "chat",
  "/trace": "trace",
  "/privacy": "privacy",
};
const TYPES: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

function locale(cookie: string | undefined): string {
  const chosen = /(?:^|;\s*)lang=([^;]+)/.exec(cookie ?? "")?.[1];
  return LOCALES.find((known) => known === chosen) ?? "pt-BR";
}

// The file a path names, or null: a page's shell, a file under /assets/
// (never above it), the icon.
function fileFor(pathname: string, cookie: string | undefined): string | null {
  const page = PAGES[pathname];
  if (page) return join(DIST, "shells", `${page}.${locale(cookie)}.html`);
  const path = normalize(pathname);
  if (path.startsWith("/assets/")) return join(DIST, path);
  if (path === "/favicon.ico") return join(PUBLIC, "favicon.ico");
  return null;
}

export interface Served {
  origin: string;
  close(): Promise<void>;
}

export async function serve(): Promise<Served> {
  const server = createServer((request, response) => {
    const { pathname } = new URL(request.url ?? "/", "http://localhost");
    const file = fileFor(pathname, request.headers.cookie);
    const answer = file
      ? readFile(file).then((body) => {
          response.writeHead(200, {
            "content-type": TYPES[extname(file)] ?? "application/octet-stream",
          });
          response.end(body);
        })
      : Promise.reject(new Error(pathname));
    answer.catch(() => {
      response.writeHead(404).end();
    });
  });
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });
  const { port } = server.address() as AddressInfo;
  return {
    origin: `http://127.0.0.1:${String(port)}`,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      }),
  };
}
