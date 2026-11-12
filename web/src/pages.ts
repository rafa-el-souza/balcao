// The web app's pages and their routes (design §6.7). Each page is rendered
// at build time into its own shell, once per language, and Rails sends the
// shell of the route (config/routes.rb, app/controllers/spa_controller.rb).
// The trace, privacy and status pages join here with their pull requests.
export const PAGES = {
  landing: "/",
  chat: "/chat",
} as const;

export type Page = keyof typeof PAGES;

export function isPage(value: unknown): value is Page {
  return typeof value === "string" && Object.hasOwn(PAGES, value);
}

// The page of a path, as the server routes it; the dev server sends the one
// shell for every path, so the browser decides there.
export function pageOf(pathname: string): Page {
  const path = pathname.replace(/\/+$/, "") || "/";
  const found = Object.entries(PAGES).find(([, route]) => route === path);
  return found && isPage(found[0]) ? found[0] : "landing";
}

export const TITLES = {
  landing: "landing.title",
  chat: "chat.title",
} as const satisfies Record<Page, string>;
