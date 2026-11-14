import { act, fireEvent, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { render as prerender } from "../entry-server";
import { EMAIL, GITHUB_URL, LINKEDIN_URL, MAILTO } from "../identity";
import { LANG_COOKIE, readLocaleCookie } from "../locale";
import en from "../locales/en.json";
import es from "../locales/es.json";
import ptBR from "../locales/pt-BR.json";
import { pageOf } from "../pages";
import { renderPage } from "../test/render";
import { Privacy } from "./Privacy";

const pt = ptBR.privacy;

afterEach(() => {
  document.cookie = `${LANG_COOKIE}=; path=/; max-age=0`;
});

// The visible text of the page, as a reader gets it: spaces folded, so a
// number and its unit joined by a no-break space read as in the locale file.
const text = () => document.body.textContent.replace(/\s+/g, " ");
const plain = (line: string) =>
  line.replace(/<\/?\w+>/g, "").replace(/\s+/g, " ");

describe("Design §6.7 the privacy page, one screen in three languages", () => {
  it("has one first-level heading and its sections in the drawing's order", () => {
    renderPage(<Privacy />);

    expect(screen.getAllByRole("heading", { level: 1 })).toHaveLength(1);
    expect(
      screen.getByRole("heading", { level: 1, name: pt.heading }),
    ).toBeInTheDocument();
    expect(
      screen
        .getAllByRole("heading", { level: 2 })
        .map((heading) => heading.textContent),
    ).toEqual([
      pt.kept.title,
      pt.agreement.title,
      pt.retention.title,
      pt.deletion.title,
      pt.readers.title,
      pt.processors.title,
      pt.contact.title,
    ]);
  });

  it("switches language from the header at once, and keeps the choice", async () => {
    renderPage(<Privacy />);
    const header = screen.getByRole("banner");
    const spanish = within(header).getByRole("button", {
      name: /^ES Español$/,
    });

    spanish.focus();
    fireEvent.click(spanish);

    expect(
      screen.getByRole("heading", { level: 1, name: es.privacy.heading }),
    ).toBeInTheDocument();
    expect(readLocaleCookie(document.cookie)).toBe("es");
    await act(() => Promise.resolve());
    expect(document.title).toBe(es.privacy.title);
  });

  it("names the page in its header and leads home from the wordmark", () => {
    renderPage(<Privacy />, "en");
    const header = within(screen.getByRole("banner"));

    expect(header.getByText(en.privacy.pageName)).toBeInTheDocument();
    expect(header.getByRole("link", { name: en.app.name })).toHaveAttribute(
      "href",
      "/",
    );
  });

  it("says every sentence of the drawing that has its source today, in each language", () => {
    for (const [locale, page] of [
      ["pt-BR", ptBR.privacy],
      ["en", en.privacy],
      ["es", es.privacy],
    ] as const) {
      const { unmount } = renderPage(<Privacy />, locale);
      for (const line of [
        page.what,
        page.advice.text,
        ...Object.values(page.kept).filter(
          (value) => value !== page.kept.title,
        ),
        page.agreement.text,
        page.retention.intro,
        ...page.retention.items,
        page.retention.logs,
        page.retention.totals,
        page.deletion.text,
        page.deletion.telegram,
        page.readers.trace,
        page.readers.cases,
        ...page.processors.items,
      ])
        expect(text(), `${locale}: ${line}`).toContain(plain(line));
      unmount();
    }
  });
});

// The page is the Telegram bot's own privacy policy, set in BotFather: the
// standard one would forbid sending a message to the model (ADR-0016). It
// says what is kept, how and what for, as Telegram's terms ask.
describe("FR-19 the privacy page is the bot's own policy", () => {
  it("says it covers the site and the bot, and that the bot asks before it reads", () => {
    renderPage(<Privacy />);

    expect(screen.getByText(pt.what)).toBeInTheDocument();
    expect(pt.what).toMatch(/bot do Balcão no Telegram/);
    const agreement = screen
      .getByRole("heading", { level: 2, name: pt.agreement.title })
      .closest("section") as HTMLElement;
    expect(
      within(agreement).getByText("Concordo", { selector: "strong" }),
    ).toBeInTheDocument();
  });

  it("names Telegram among those who process the data, and no company the demo does not use yet", () => {
    renderPage(<Privacy />);
    const processors = within(
      screen
        .getByRole("heading", { level: 2, name: pt.processors.title })
        .closest("section") as HTMLElement,
    );

    expect(processors.getAllByRole("listitem")).toHaveLength(3);
    expect(processors.getByText(/^Telegram:/)).toBeInTheDocument();
    // Cloudflare joins with Turnstile (FR-18, SR-39), Meta left with the
    // channel (ADR-0016).
    expect(text()).not.toMatch(/Cloudflare|Meta|WhatsApp/);
  });

  it("keeps a Telegram conversation out of the test cases, which a web one may become", () => {
    renderPage(<Privacy />);

    expect(text()).toContain(
      "Uma conversa do Telegram nunca vira caso de teste.",
    );
  });
});

// What the delete command does and what it does not reach (FR-05, threat model
// SR-32): the chat in the visitor's app is the visitor's own copy.
describe("FR-05 the privacy page on deleting before the seven days", () => {
  it("names the delete command of the page's language", () => {
    for (const [locale, command] of [
      ["pt-BR", "/apagar"],
      ["en", "/delete"],
      ["es", "/borrar"],
    ] as const) {
      const { unmount } = renderPage(<Privacy />, locale);
      expect(screen.getByText(command, { selector: "code" })).toBeVisible();
      unmount();
    }
  });

  it("says the chat left in Telegram is the visitor's to clear", () => {
    renderPage(<Privacy />);

    expect(text()).toContain(
      "As mensagens que continuam no chat são a sua cópia",
    );
    expect(text()).toContain("a opção de limpar o histórico");
  });
});

// The drawing marks the lines whose source arrives later; the page leaves them
// out until then: the backups (M3) and Cloudflare's check (the Turnstile
// slice), and the status link (M3).
describe("Design §10 the privacy page shows nothing before its source exists", () => {
  it("has no backups, no anti-bot check and no status link yet", () => {
    renderPage(<Privacy />);

    expect(text()).not.toMatch(/cópias de segurança|backup/i);
    expect(text()).not.toMatch(/anti-bot/);
    expect(screen.queryByRole("link", { name: /status/i })).toBeNull();
  });
});

// Review of pull request #30: every sentence is a claim about what the server
// keeps, checked against the code and the configuration.
describe("Design §6.7 the privacy page says what the server really keeps", () => {
  // Review finding C1: the limits' counters sit in the cache under the IP
  // address and the identifier's hash, outlive the delete command on purpose
  // (FR-05) and have no bound by age until PR-18 gives them one.
  it("names the limits' counters, kept by the IP and the identifier, which the delete command leaves (FR-05, FR-14)", () => {
    for (const page of [ptBR.privacy, en.privacy, es.privacy]) {
      const { unmount } = renderPage(
        <Privacy />,
        page === ptBR.privacy ? "pt-BR" : page === en.privacy ? "en" : "es",
      );
      expect(text()).toContain(plain(page.retention.counters));
      unmount();
    }
    expect(pt.retention.counters).toMatch(/endereço IP e pelo identificador/);
    expect(pt.retention.counters).toMatch(/não zeram quando você apaga/);
    expect(pt.deletion.text).toMatch(/ficam só os contadores dos limites/);
    expect(pt.retention.totals).toMatch(/^Fora isso/);
  });
});

// Review finding C2: the bot sends links to the site (the trace's, the privacy
// page's), and opening one reaches the server from the visitor's own device.
describe("FR-19 the privacy page on what reaches the server from Telegram", () => {
  it("says a Telegram visitor's IP reaches the site when they open one of its links", () => {
    renderPage(<Privacy />);

    expect(text()).toContain(plain(pt.kept.ip));
    expect(pt.kept.ip).toMatch(
      /o seu IP só chega ao Balcão se você abrir um link do site/,
    );
    expect(en.privacy.kept.ip).toMatch(
      /only if you open a link to the website/,
    );
    expect(es.privacy.kept.ip).toMatch(/abres un enlace del sitio/);
  });
});

// Review finding C3: the nightly cleanup runs at 03:00 and deletes what is
// older than seven days, so a record goes between seven and eight days after
// its clock starts (FR-15), the trace link with its conversation (FR-12).
describe("FR-15 the privacy page gives the nightly cleanup's real window", () => {
  it("says seven to eight days for each record and for the trace link, in each language", () => {
    for (const [page, window] of [
      [ptBR.privacy, "entre 7 e 8 dias"],
      [en.privacy, "between 7 and 8 days"],
      [es.privacy, "entre 7 y 8 días"],
    ] as const) {
      for (const line of [...page.retention.items, page.readers.trace])
        expect(line.replace(/\s+/g, " ")).toContain(window);
    }
  });
});

// Review note N1 (the Rails finder): before the agreement the update is stored
// until its job reads it, then stripped of all but its id and kind (FR-19);
// what stays of the person is the limits' counter (threat model SR-10).
describe("FR-19 the privacy page on a message sent before the agreement", () => {
  it("says the bot drops the message once read and that no model reads it", () => {
    for (const [page, dropped] of [
      [ptBR.privacy, /descarta cada mensagem assim que ela é lida/],
      [en.privacy, /drops each message as soon as it is read/],
      [es.privacy, /descarta cada mensaje en cuanto lo lee/],
    ] as const) {
      expect(page.agreement.text).toMatch(dropped);
      expect(page.agreement.text).not.toMatch(
        /não guarda nada seu além|keeps nothing of yours but|no guarda nada tuyo salvo/,
      );
    }
  });
});

describe("FR-25 the privacy page's contact and signature", () => {
  it("names the person responsible and the e-mail for any request", () => {
    renderPage(<Privacy />);
    const contact = within(
      screen
        .getByRole("heading", { level: 2, name: pt.contact.title })
        .closest("section") as HTMLElement,
    );

    expect(contact.getByText(/Rafa Souza/)).toBeInTheDocument();
    expect(contact.getByRole("link", { name: EMAIL })).toHaveAttribute(
      "href",
      MAILTO,
    );
  });

  it("is signed as the landing is", () => {
    renderPage(<Privacy />);
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
});

describe("NFR-10 the privacy page before any script runs", () => {
  it("is the whole text, in the page's language", () => {
    const { html, title } = prerender("privacy", "es");

    expect(title).toBe(es.privacy.title);
    expect(html).toContain(es.privacy.heading);
    expect(html.replace(/\s+/g, " ")).toContain(
      plain(es.privacy.readers.cases).replace(/"/g, "&quot;"),
    );
  });
});

describe("Design §6.7 the privacy page's route", () => {
  it("is the page of the /privacy address", () => {
    expect(pageOf("/privacy")).toBe("privacy");
    expect(pageOf("/privacy/")).toBe("privacy");
  });
});
