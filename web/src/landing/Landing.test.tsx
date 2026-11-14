import { act, fireEvent, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { DOCUMENTS, GITHUB_URL, LINKEDIN_URL, MAILTO } from "../identity";
import { LANG_COOKIE, readLocaleCookie } from "../locale";
import en from "../locales/en.json";
import ptBR from "../locales/pt-BR.json";
import openers from "../openers.json";
import { renderPage } from "../test/render";
import { Landing } from "./Landing";

afterEach(() => {
  document.cookie = `${LANG_COOKIE}=; path=/; max-age=0`;
});

describe("FR-21 the landing's openers", () => {
  it("shows one chip per opener of the server's list, in its order, each opening the chat with its key", () => {
    renderPage(<Landing />);

    const chips = within(
      screen.getByRole("list", { name: ptBR.landing.say }),
    ).getAllByRole("link");
    expect(chips.map((chip) => chip.textContent)).toEqual(
      Object.values(openers).map((opener) => opener.text),
    );
    expect(chips.map((chip) => chip.getAttribute("href"))).toEqual(
      Object.keys(openers).map((key) => `/chat?say=${key}`),
    );
  });

  it("marks each chip with the language its sentence is in, whatever the page's", () => {
    renderPage(<Landing />, "en");

    const chips = within(
      screen.getByRole("list", { name: en.landing.say }),
    ).getAllByRole("link");
    expect(chips.map((chip) => chip.getAttribute("lang"))).toEqual([
      "pt-BR",
      "es",
      "pt-BR",
    ]);
  });
});

describe("NFR-09 the landing in three languages", () => {
  it("has one first-level heading, the headline, in the page's language", () => {
    renderPage(<Landing />, "en");

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(
      screen.getByRole("heading", { level: 1, name: en.landing.headline }),
    ).toBeInTheDocument();
  });

  it("switches language from the header at once, and keeps the choice", async () => {
    renderPage(<Landing />);
    const header = screen.getByRole("banner");
    const english = within(header).getByRole("button", {
      name: /^EN English$/,
    });

    english.focus();
    fireEvent.click(english);

    expect(
      screen.getByRole("heading", { level: 1, name: en.landing.headline }),
    ).toBeInTheDocument();
    expect(readLocaleCookie(document.cookie)).toBe("en");
    expect(document.documentElement.lang).toBe("en");
    expect(
      within(header).getByRole("button", { name: /^EN English$/ }),
    ).toHaveAttribute("aria-current", "true");
    expect(
      within(header).getByRole("button", { name: /^EN English$/ }),
    ).toHaveFocus();
    await act(() => Promise.resolve());
    expect(document.title).toBe(en.landing.title);
  });
});

describe("FR-25 the landing's contact and signature", () => {
  it("offers an e-mail with the prefilled subject", () => {
    renderPage(<Landing />);

    expect(
      screen.getByRole("link", { name: ptBR.landing.business.email }),
    ).toHaveAttribute("href", MAILTO);
    expect(MAILTO).toBe(
      "mailto:rafasouza.dev@pm.me?subject=Balc%C3%A3o%3A%20contato",
    );
  });

  it("is signed with the author's name, GitHub, LinkedIn and e-mail", () => {
    renderPage(<Landing />);
    const footer = within(screen.getByRole("contentinfo"));

    expect(footer.getByText("Rafa Souza")).toBeInTheDocument();
    expect(footer.getByRole("link", { name: "GitHub" })).toHaveAttribute(
      "href",
      GITHUB_URL,
    );
    expect(footer.getByRole("link", { name: "LinkedIn" })).toHaveAttribute(
      "href",
      LINKEDIN_URL,
    );
    expect(
      footer.getByRole("link", { name: ptBR.signature.email }),
    ).toHaveAttribute("href", MAILTO);
  });

  it("links the design, the decisions, the threat model and the evals", () => {
    renderPage(<Landing />);
    const built = within(
      screen.getByRole("region", { name: ptBR.landing.built.title }),
    );

    expect(
      [
        ptBR.landing.built.design,
        ptBR.landing.built.adrs,
        ptBR.landing.built.threats,
        ptBR.landing.built.evals,
      ].map((name) => built.getByRole("link", { name }).getAttribute("href")),
    ).toEqual([
      DOCUMENTS.design,
      DOCUMENTS.adrs,
      DOCUMENTS.threats,
      DOCUMENTS.evals,
    ]);
  });
});

// The stack names the channel the project uses, Telegram's Bot API, since
// WhatsApp's business policy rules out the demo's pharmacy (ADR-0016). Moved
// forward from PR-19, so the web demo shown from day 10 agrees with its own
// privacy page (design §10, note 2026-11-14, PR-17).
describe("FR-19 the landing's stack names the bot's channel", () => {
  it("lists the Telegram Bot API, and WhatsApp nowhere, in each language", () => {
    for (const locale of ["pt-BR", "en", "es"] as const) {
      const { unmount } = renderPage(<Landing />, locale);

      expect(screen.getByText("Telegram Bot API")).toBeInTheDocument();
      expect(document.body.textContent).not.toMatch(/WhatsApp/);
      unmount();
    }
  });
});

// The privacy page is reached from the landing's warning, the stamp that says
// how long messages are kept (docs/prototype/landing.html; design §6.7).
describe("Design §6.7 the landing leads to the privacy page", () => {
  it("links the privacy page from its warning, in the page's language", () => {
    renderPage(<Landing />, "en");
    const warning = screen
      .getByText(en.landing.warning.label)
      .closest("p") as HTMLElement;

    expect(
      within(warning).getByRole("link", { name: en.privacy.link }),
    ).toHaveAttribute("href", "/privacy");
  });
});

// The drawing is the target; a line whose source arrives later is left out,
// not shown as a promise (docs/prototype/landing.html, notes).
describe("Design §10 the landing shows nothing before its source exists", () => {
  it("has no figure, no status link, no offer, no QR and no example conversations yet", () => {
    renderPage(<Landing />);

    expect(document.body.textContent).not.toMatch(/R\$|US\$|%/);
    expect(screen.queryByRole("link", { name: /status/i })).toBeNull();
    expect(screen.queryByRole("img")).toBeNull();
  });
});
