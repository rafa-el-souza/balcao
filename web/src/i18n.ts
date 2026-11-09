import i18n from "i18next";
import { initReactI18next } from "react-i18next";

import en from "./locales/en.json";
import es from "./locales/es.json";
import ptBR from "./locales/pt-BR.json";

// Every page string lives in the three locale files (design NFR-09). The
// browser-language choice and the persistent switcher arrive with the
// landing (design §9.1, PR-10); until then the app opens in pt-BR.
export const LOCALES = ["pt-BR", "en", "es"] as const;
export type Locale = (typeof LOCALES)[number];
export const DEFAULT_LOCALE: Locale = "pt-BR";

export const resources = {
  "pt-BR": { translation: ptBR },
  en: { translation: en },
  es: { translation: es },
} as const;

void i18n.use(initReactI18next).init({
  resources,
  lng: DEFAULT_LOCALE,
  fallbackLng: DEFAULT_LOCALE,
  supportedLngs: LOCALES,
  // React escapes what it renders, and HTML from strings is banned by lint (SR-03).
  interpolation: { escapeValue: false },
});

export default i18n;
