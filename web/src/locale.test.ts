import { afterEach, describe, expect, it } from "vitest";

import {
  DEFAULT_LOCALE,
  LANG_COOKIE,
  chooseLocale,
  localeFromLanguages,
  persistLocale,
  readLocaleCookie,
} from "./locale";

// NFR-09: the language comes from the browser, with a visible switcher whose
// choice persists. The server reads the same cookie to send the page already
// in that language (app/controllers/spa_controller.rb).
describe("NFR-09 the page's language", () => {
  afterEach(() => {
    document.cookie = `${LANG_COOKIE}=; path=/; max-age=0`;
    document.documentElement.lang = DEFAULT_LOCALE;
  });

  it("takes the first of the browser's languages it has, by its primary tag", () => {
    expect(localeFromLanguages(["de-DE", "es-UY", "en"])).toBe("es");
    expect(localeFromLanguages(["en-GB"])).toBe("en");
    expect(localeFromLanguages(["pt-PT"])).toBe("pt-BR");
    expect(localeFromLanguages(["fr", "de"])).toBe("pt-BR");
    expect(localeFromLanguages([])).toBe("pt-BR");
  });

  it("reads only one of the three locales from the cookie", () => {
    expect(readLocaleCookie("a=1; lang=en; b=2")).toBe("en");
    expect(readLocaleCookie("lang=es")).toBe("es");
    expect(readLocaleCookie("lang=fr")).toBeNull();
    expect(readLocaleCookie("lang=en%22%3E")).toBeNull();
    expect(readLocaleCookie("xlang=en")).toBeNull();
    expect(readLocaleCookie("")).toBeNull();
  });

  it("keeps the language the server rendered the page in, so hydration matches", () => {
    expect(
      chooseLocale({
        prerendered: true,
        documentLang: "es",
        cookie: "lang=en",
        languages: ["en"],
      }),
    ).toBe("es");
  });

  it("prefers the visitor's choice to the browser's when the page was not rendered", () => {
    expect(
      chooseLocale({
        prerendered: false,
        documentLang: "pt-BR",
        cookie: "lang=en",
        languages: ["es"],
      }),
    ).toBe("en");
    expect(
      chooseLocale({
        prerendered: false,
        documentLang: "pt-BR",
        cookie: "",
        languages: ["es-AR"],
      }),
    ).toBe("es");
  });

  it("persists a choice in a cookie for a year and marks the document's language", () => {
    persistLocale("en");

    expect(readLocaleCookie(document.cookie)).toBe("en");
    expect(document.documentElement.lang).toBe("en");
  });
});
