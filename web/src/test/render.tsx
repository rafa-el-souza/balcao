import { render } from "@testing-library/react";
import type { ReactElement } from "react";
import { I18nextProvider } from "react-i18next";

import type { Cable } from "../cable";
import { createI18n } from "../i18n";
import { DEFAULT_LOCALE, type Locale } from "../locale";
import { createQueryClient, Providers } from "../providers";

// Renders a page as the browser does: with the page's own i18n instance, a
// query client of its own, and a cable that never connects unless the test
// gives one it drives.
export function renderPage(
  ui: ReactElement,
  locale: Locale = DEFAULT_LOCALE,
  cable?: Cable,
) {
  const i18n = createI18n(locale);
  const client = createQueryClient();
  return {
    i18n,
    client,
    ...render(
      <Providers client={client} {...(cable ? { cable } : {})}>
        <I18nextProvider i18n={i18n}>{ui}</I18nextProvider>
      </Providers>,
    ),
  };
}
