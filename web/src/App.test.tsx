import { act, render, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { App } from "./App";
import i18n, { DEFAULT_LOCALE, LOCALES, resources } from "./i18n";
import { REPOSITORY_URL } from "./placeholder/Placeholder";

// The placeholder landing that the domain shows until the real landing ships
// (design §9.1, PR-02 to PR-10): the same short text in the three languages
// at once, each section marked with its language, so it needs no switcher.
describe("NFR-09 trilingual placeholder landing", () => {
  afterEach(async () => {
    await act(() => i18n.changeLanguage(DEFAULT_LOCALE));
  });

  const textOf = (locale: (typeof LOCALES)[number]) =>
    resources[locale].translation.placeholder;

  it("names the product once, as the page's only first-level heading", () => {
    render(<App />);

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(
      screen.getByRole("heading", { level: 1, name: "Balcão" }),
    ).toBeInTheDocument();
    expect(screen.getByText("Farmácia Vida Longa")).toBeInTheDocument();
  });

  it("says it in pt-BR first, then en and es, each section marked with its language", () => {
    render(<App />);

    const sections = LOCALES.map((locale) =>
      screen.getByRole("region", { name: textOf(locale).tagline }),
    );
    expect(sections.map((section) => section.getAttribute("lang"))).toEqual([
      "pt-BR",
      "en",
      "es",
    ]);
    expect(screen.getAllByRole("region")).toEqual(sections);
    expect(textOf("pt-BR").tagline).toBe(
      "Um atendente de IA para uma farmácia de bairro fictícia.",
    );

    LOCALES.forEach((locale, index) => {
      const section = within(sections[index] as HTMLElement);
      const text = textOf(locale);
      expect(section.getByText(text.status)).toBeInTheDocument();
      expect(section.getByText(text.soon)).toBeInTheDocument();
      expect(
        section.getByRole("link", { name: text.repository }),
      ).toHaveAttribute("href", REPOSITORY_URL);
    });
  });

  it("keeps the three languages whatever the current one", async () => {
    render(<App />);

    await act(() => i18n.changeLanguage("es"));

    const portuguese = screen.getByRole("region", {
      name: textOf("pt-BR").tagline,
    });
    expect(portuguese).toHaveAttribute("lang", "pt-BR");
    expect(
      within(portuguese).getByText(textOf("pt-BR").status),
    ).toBeInTheDocument();
  });

  it("links to the public repository over HTTPS", () => {
    expect(REPOSITORY_URL).toBe("https://github.com/rafa-el-souza/balcao");
  });
});
