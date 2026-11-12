import i18next, { type i18n } from "i18next";
import { initReactI18next } from "react-i18next";

import { DEFAULT_LOCALE, LOCALES, type Locale } from "./locale";
import en from "./locales/en.json";
import es from "./locales/es.json";
import ptBR from "./locales/pt-BR.json";

// Every page string lives in the three locale files (design NFR-09).
export const resources = {
  "pt-BR": { translation: ptBR },
  en: { translation: en },
  es: { translation: es },
} as const;

// One instance per page load in the browser, one per render at build time:
// the resources are in the bundle, so it is ready when this returns.
export function createI18n(locale: Locale): i18n {
  const instance = i18next.createInstance();
  void instance.use(initReactI18next).init({
    resources,
    lng: locale,
    fallbackLng: DEFAULT_LOCALE,
    supportedLngs: LOCALES,
    initAsync: false,
    // React escapes what it renders, and HTML from strings is banned by lint (SR-03).
    interpolation: { escapeValue: false },
  });
  return instance;
}
