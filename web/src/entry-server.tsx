import { renderToString } from "react-dom/server";
import { I18nextProvider } from "react-i18next";

import { App } from "./App";
import { createI18n } from "./i18n";
import type { Locale } from "./locale";
import { type Page, TITLES } from "./pages";

export { LOCALES } from "./locale";
export { PAGES } from "./pages";

// Renders a page in a language at build time, so the shell the server sends
// carries the page's text before any script runs (design NFR-10). The
// browser then hydrates the same markup (main.tsx). Only the build calls it
// (web/vite.config.ts).
export function render(
  page: Page,
  locale: Locale,
): { html: string; title: string } {
  const i18n = createI18n(locale);
  const html = renderToString(
    <I18nextProvider i18n={i18n}>
      <App page={page} />
    </I18nextProvider>,
  );
  return { html, title: i18n.t(TITLES[page]) };
}
