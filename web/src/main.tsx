import { StrictMode } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";
import { I18nextProvider } from "react-i18next";

import { App } from "./App";
import { createI18n } from "./i18n";
import { chooseLocale } from "./locale";
import { isPage, pageOf } from "./pages";
import "./styles/base.css";

const root = document.getElementById("root");
if (!root) throw new Error("index.html has no #root element");

// The built shell already holds the page, rendered in the language the
// server chose (design NFR-10, vite.config.ts): hydrate it as it is. The dev
// server's shell is empty: render the path's page in the visitor's language.
const prerendered = root.hasChildNodes();
const locale = chooseLocale({
  prerendered,
  documentLang: document.documentElement.lang,
  cookie: document.cookie,
  languages: navigator.languages,
});
document.documentElement.lang = locale;
const page = isPage(root.dataset.page)
  ? root.dataset.page
  : pageOf(window.location.pathname);

const app = (
  <StrictMode>
    <I18nextProvider i18n={createI18n(locale)}>
      <App page={page} />
    </I18nextProvider>
  </StrictMode>
);

if (prerendered) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
