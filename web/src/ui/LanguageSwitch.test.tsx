import { act, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Chat } from "../chat/Chat";
import { Landing } from "../landing/Landing";
import { LANG_COOKIE } from "../locale";
import en from "../locales/en.json";
import { fakeServer } from "../test/fakeServer";
import { renderPage } from "../test/render";

// The owner's round at the MVP close, row 14-FN-bfcache (the interface
// review's W4): each page is its own document, and a page the browser
// restores from its back-forward cache kept the language it had when the
// visitor left it, after they chose another on a later page. The choice is
// in the cookie, which the restored page now reads again (NFR-09).
const restore = (persisted: boolean) => {
  act(() => {
    window.dispatchEvent(new PageTransitionEvent("pageshow", { persisted }));
  });
};

beforeEach(() => {
  document.documentElement.lang = "pt-BR";
});

afterEach(() => {
  vi.unstubAllGlobals();
  document.cookie = `${LANG_COOKIE}=; path=/; max-age=0`;
});

describe("NFR-09 a page restored from the back-forward cache", () => {
  it("takes the language the visitor chose on a later page", () => {
    renderPage(<Landing />);
    document.cookie = `${LANG_COOKIE}=en; path=/`;

    restore(true);

    expect(document.documentElement.lang).toBe("en");
    expect(
      screen.getByRole("heading", { level: 1, name: en.landing.headline }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /^EN English$/ }),
    ).toHaveAttribute("aria-current", "true");
  });

  it("changes nothing on a page the browser loads anew, or when the choice is the page's", () => {
    renderPage(<Landing />);
    document.cookie = `${LANG_COOKIE}=en; path=/`;
    restore(false);
    expect(document.documentElement.lang).toBe("pt-BR");

    document.cookie = `${LANG_COOKIE}=pt-BR; path=/`;
    restore(true);
    expect(document.documentElement.lang).toBe("pt-BR");
  });

  it("tells the chat's conversation, as a press of the switch does (FR-02)", async () => {
    const server = fakeServer();
    vi.stubGlobal("fetch", server.fetch);
    renderPage(<Chat />);
    await waitFor(() => {
      expect(server.polls()).toHaveLength(1);
    });
    document.cookie = `${LANG_COOKIE}=en; path=/`;

    restore(true);

    await waitFor(() => {
      expect(
        server.requests.filter((request) => request.path === "/api/session"),
      ).toHaveLength(2);
    });
    const sessions = server.requests.filter(
      (request) => request.path === "/api/session",
    );
    expect(sessions[1]?.body).toEqual({ language: "en" });
    expect(document.documentElement.lang).toBe("en");
  });
});
