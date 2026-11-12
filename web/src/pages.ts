// The web app's pages and their routes (design §6.7). Each page is rendered
// at build time into its own shell, once per language, and Rails sends the
// shell of the route (config/routes.rb, app/controllers/spa_controller.rb;
// spec/requests/spa_spec.rb holds the two lists together). A route's
// `:param` is one path segment the page reads itself. The privacy and status
// pages join here with their pull requests.
export const PAGES = {
  landing: "/",
  chat: "/chat",
  trace: "/trace/:token",
} as const;

export type Page = keyof typeof PAGES;

export function isPage(value: unknown): value is Page {
  return typeof value === "string" && Object.hasOwn(PAGES, value);
}

const matches = (route: string, path: string) =>
  new RegExp(
    `^${route.replace(/:\w+/g, "[^/]+").replace(/[.]/g, "\\.")}$`,
  ).test(path);

// The page of a path, as the server routes it; the dev server sends the one
// shell for every path, so the browser decides there.
export function pageOf(pathname: string): Page {
  const path = pathname.replace(/\/+$/, "") || "/";
  const found = Object.entries(PAGES).find(([, route]) => matches(route, path));
  return found && isPage(found[0]) ? found[0] : "landing";
}

export const TITLES = {
  landing: "landing.title",
  chat: "chat.title",
  trace: "trace.title",
} as const satisfies Record<Page, string>;
