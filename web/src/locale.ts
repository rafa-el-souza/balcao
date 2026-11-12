// The page's language (design NFR-09): one of the three, chosen from the
// browser's languages, or from the visitor's own choice on the switcher,
// which persists in a cookie. The server reads that cookie (and
// Accept-Language) to send the page already rendered in the language
// (app/controllers/spa_controller.rb), so a visitor without JavaScript reads
// it too.
export const LOCALES = ["pt-BR", "en", "es"] as const;
export type Locale = (typeof LOCALES)[number];
export const DEFAULT_LOCALE: Locale = "pt-BR";
export const LANG_COOKIE = "lang";

const ONE_YEAR = 60 * 60 * 24 * 365;
const BY_PRIMARY_TAG: Record<string, Locale> = {
  pt: "pt-BR",
  en: "en",
  es: "es",
};

export function isLocale(value: unknown): value is Locale {
  return LOCALES.includes(value as Locale);
}

// The first of the browser's languages the page has, by its primary tag.
export function localeFromLanguages(languages: readonly string[]): Locale {
  for (const language of languages) {
    const locale = BY_PRIMARY_TAG[language.toLowerCase().split("-")[0] ?? ""];
    if (locale) return locale;
  }
  return DEFAULT_LOCALE;
}

export function readLocaleCookie(cookie: string): Locale | null {
  for (const pair of cookie.split(";")) {
    const [name, value] = pair.trim().split("=");
    if (name === LANG_COOKIE && isLocale(value)) return value;
  }
  return null;
}

interface Context {
  // The shell came with the page rendered in it (the built app, not the dev server).
  prerendered: boolean;
  documentLang: string;
  cookie: string;
  languages: readonly string[];
}

export function chooseLocale(context: Context): Locale {
  if (context.prerendered && isLocale(context.documentLang))
    return context.documentLang;
  return (
    readLocaleCookie(context.cookie) ?? localeFromLanguages(context.languages)
  );
}

export function persistLocale(locale: Locale): void {
  const secure = window.location.protocol === "https:" ? "; secure" : "";
  document.cookie = `${LANG_COOKIE}=${locale}; path=/; max-age=${String(ONE_YEAR)}; samesite=lax${secure}`;
  document.documentElement.lang = locale;
}
