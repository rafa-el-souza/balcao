import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { I18nextProvider } from "react-i18next";

import { createI18n } from "../i18n";
import { DEFAULT_LOCALE, type Locale } from "../locale";

// Renders a page as the browser does: with the page's own i18n instance.
export function renderPage(ui: ReactElement, locale: Locale = DEFAULT_LOCALE) {
  const i18n = createI18n(locale);
  return {
    i18n,
    ...render(<I18nextProvider i18n={i18n}>{ui}</I18nextProvider>),
  };
}
