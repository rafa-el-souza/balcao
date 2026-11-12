import {
  act,
  fireEvent,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { LANG_COOKIE } from "../locale";
import en from "../locales/en.json";
import es from "../locales/es.json";
import ptBR from "../locales/pt-BR.json";
import openers from "../openers.json";
import { conversation, fakeServer, message } from "../test/fakeServer";
import { renderPage } from "../test/render";
import { Chat } from "./Chat";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const pt = ptBR.chat;

let server: ReturnType<typeof fakeServer>;

beforeEach(() => {
  server = fakeServer();
  vi.stubGlobal("fetch", server.fetch);
  window.history.replaceState(null, "", "/chat");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  document.cookie = `${LANG_COOKIE}=; path=/; max-age=0`;
});

const idOf = (body: unknown) => (body as { id: string }).id;
const thread = () => screen.getByRole("list", { name: pt.conversation });
const field = () => screen.getByRole("textbox", { name: pt.composer.label });
const ready = () =>
  waitFor(() => {
    expect(server.polls()).toHaveLength(1);
  });

function type(text: string) {
  fireEvent.change(field(), { target: { value: text } });
}

describe("FR-21 the chat's openers (threat model SR-34)", () => {
  it("sends exactly one message, the allow-listed key, when the page opens with ?say=", async () => {
    window.history.replaceState(null, "", "/chat?say=stock_pt");
    renderPage(<Chat />);

    await ready();
    const [sent, ...more] = server.sent();
    expect(more).toEqual([]);
    expect(Object.keys(sent?.body as object).sort()).toEqual(["id", "say"]);
    expect(sent?.body).toMatchObject({ say: "stock_pt" });
    expect(idOf(sent?.body)).toMatch(UUID);
    expect(
      within(thread()).getByText(openers.stock_pt.text),
    ).toBeInTheDocument();
    // A reload, or the back button, must not send it again.
    expect(window.location.search).toBe("");
  });

  it("sends nothing for a key outside the list, and opens empty with the openers", async () => {
    window.history.replaceState(null, "", "/chat?say=anything-else");
    renderPage(<Chat />);

    await ready();
    expect(server.sent()).toEqual([]);
    expect(within(thread()).getByText(pt.greeting)).toBeInTheDocument();
    expect(window.location.search).toBe("");
  });

  it("greets a first visit and offers the openers, each sending its key", async () => {
    renderPage(<Chat />);
    await ready();

    const buttons = within(thread()).getAllByRole("button");
    expect(buttons.map((button) => button.textContent)).toEqual(
      Object.values(openers).map((opener) => opener.text),
    );
    expect(buttons[1]).toHaveAttribute("lang", "es");

    fireEvent.click(
      within(thread()).getByRole("button", { name: openers.delivery_es.text }),
    );

    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    expect(server.sent()[0]?.body).toMatchObject({ say: "delivery_es" });
    expect(Object.keys(server.sent()[0]?.body as object).sort()).toEqual([
      "id",
      "say",
    ]);
    expect(within(thread()).queryByText(pt.greeting)).toBeNull();
  });
});

describe("NFR-09 the chat speaks the page's language to the server", () => {
  it("names the page's language in the session and in every request, and follows the switch", async () => {
    renderPage(<Chat />, "es");
    await ready();

    expect(server.requests[0]?.path).toBe("/api/session");
    expect(server.requests[0]?.body).toEqual({ language: "es" });
    expect(
      server.requests.map((request) => request.headers.get("Accept-Language")),
    ).toEqual(server.requests.map(() => "es"));

    const switches = screen.getAllByRole("button", { name: /^EN English$/ });
    fireEvent.click(switches[0] as HTMLElement);

    await waitFor(() => {
      expect(server.requests).toHaveLength(3);
    });
    expect(server.requests[2]?.body).toEqual({ language: "en" });
    expect(server.requests[2]?.headers.get("Accept-Language")).toBe("en");
    expect(
      screen.getByRole("textbox", { name: en.chat.composer.label }),
    ).toBeInTheDocument();
  });
});

describe("FR-18 the composer", () => {
  it("sends the text with Enter, keeps a new line with Shift+Enter, and empties", async () => {
    renderPage(<Chat />);
    await ready();

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter", shiftKey: true });
    expect(server.sent()).toEqual([]);

    fireEvent.keyDown(field(), { key: "Enter" });

    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    expect(server.sent()[0]?.body).toMatchObject({ text: "tem dipirona?" });
    expect(idOf(server.sent()[0]?.body)).toMatch(UUID);
    expect(field()).toHaveValue("");
    expect(within(thread()).getByText("tem dipirona?")).toBeInTheDocument();
  });

  it("sends nothing when the field holds only spaces", async () => {
    renderPage(<Chat />);
    await ready();

    type("   ");
    fireEvent.click(screen.getByRole("button", { name: pt.composer.send }));

    expect(server.sent()).toEqual([]);
  });

  it("takes at most 1,000 characters and counts only past 800", async () => {
    renderPage(<Chat />);
    await ready();

    expect(field()).toHaveAttribute("maxLength", "1000");
    type("a".repeat(800));
    expect(screen.queryByText(/de 1\.000/)).toBeNull();

    type("a".repeat(801));
    expect(field()).toHaveAccessibleDescription("801 de 1.000");
    expect(screen.getByRole("status")).toHaveTextContent("801 de 1.000");

    // Announced when it appears and at the limit, not at every key.
    type("a".repeat(802));
    expect(field()).toHaveAccessibleDescription("802 de 1.000");
    expect(screen.getByRole("status")).toHaveTextContent("801 de 1.000");
    type("a".repeat(1000));
    expect(screen.getByRole("status")).toHaveTextContent("1.000 de 1.000");
  });

  it("puts a suggestion in the field for the visitor to finish, and sends nothing", async () => {
    renderPage(<Chat />);
    await ready();

    fireEvent.click(screen.getByRole("button", { name: pt.composer.reserve }));

    expect(field()).toHaveValue(pt.composer.reserveText);
    expect(field()).toHaveFocus();
    expect(server.sent()).toEqual([]);
  });
});

describe("FR-18 the reply arrives by polling", () => {
  it("asks every 3 s while a turn waits, shows the reply, then stops asking", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    renderPage(<Chat />);
    await ready();

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    const id = idOf(server.sent()[0]?.body);
    const visitor = message({
      author: "visitor",
      body: "tem dipirona?",
      client_id: id,
    });
    server.answers.current.push(
      conversation(1, [visitor], true),
      conversation(1, [
        visitor,
        message({ author: "bot", body: "Temos duas." }),
      ]),
    );

    await act(() => vi.advanceTimersByTimeAsync(3000));
    expect(server.polls()).toHaveLength(2);
    expect(within(thread()).queryByText("Temos duas.")).toBeNull();

    await act(() => vi.advanceTimersByTimeAsync(3000));
    expect(within(thread()).getByText("Temos duas.")).toBeInTheDocument();
    expect(within(thread()).getAllByText("tem dipirona?")).toHaveLength(1);

    await act(() => vi.advanceTimersByTimeAsync(9000));
    expect(server.polls()).toHaveLength(3);
  });

  it("shows the conversation a returning visitor already has, without the greeting", async () => {
    server.answers.current.push(
      conversation(1, [
        message({ author: "visitor", body: "tem dipirona?" }),
        message({ author: "bot", body: "Temos duas." }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    expect(
      await within(thread()).findByText("Temos duas."),
    ).toBeInTheDocument();
    expect(within(thread()).queryByText(pt.greeting)).toBeNull();
  });
});

describe("FR-14 the demo's limit", () => {
  it("keeps the message as sent and stamps the server's text under it", async () => {
    const text =
      "Você chegou ao limite da demo por agora. Tente de novo daqui a pouco.";
    server.answers.messages.push({
      status: 429,
      body: { error: "limit", text },
    });
    renderPage(<Chat />);
    await ready();

    type("e xarope pra tosse?");
    fireEvent.keyDown(field(), { key: "Enter" });

    const stamp = await within(thread()).findByText(text);
    const items = within(thread()).getAllByRole("listitem");
    expect(items.map((item) => item.textContent)).toEqual([
      "e xarope pra tosse?",
      text,
    ]);
    expect(stamp.closest("li")).toHaveAttribute("data-voice", "stamp");
    expect(within(thread()).queryByText(pt.failed)).toBeNull();
  });
});

describe("FR-05 the visitor's data deleted", () => {
  it("sends the language's command from the button and then shows only the confirmation", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push(
      conversation(1, [message({ author: "visitor", body: "tem dipirona?" })]),
    );
    renderPage(<Chat />, "es");
    await ready();

    fireEvent.click(screen.getByRole("button", { name: es.chat.glass.delete }));
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    expect(server.sent()[0]?.body).toMatchObject({ text: "/borrar" });

    const text = "Tus datos fueron borrados.";
    server.answers.current.push({ status: 200, body: { deleted: true, text } });
    await act(() => vi.advanceTimersByTimeAsync(3000));

    const items = within(
      screen.getByRole("list", { name: es.chat.conversation }),
    ).getAllByRole("listitem");
    expect(items.map((item) => item.textContent)).toEqual([text]);
  });
});

describe("FR-04 starting over", () => {
  it("sends the reset command and then shows the new conversation alone", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push(
      conversation(1, [
        message({ author: "visitor", body: "tem dipirona?" }),
        message({ author: "bot", body: "Temos duas." }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    fireEvent.click(screen.getByRole("button", { name: pt.glass.reset }));
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    expect(server.sent()[0]?.body).toMatchObject({ text: "/reiniciar" });

    server.answers.current.push(
      conversation(2, [
        message({
          author: "bot",
          body: "Pronto, começamos de novo.",
          conversation_id: 2,
        }),
      ]),
    );
    await act(() => vi.advanceTimersByTimeAsync(3000));

    expect(
      within(thread())
        .getAllByRole("listitem")
        .map((item) => item.textContent),
    ).toEqual(["Pronto, começamos de novo."]);
  });
});

describe("NFR-02 a message that could not be sent", () => {
  it("says so beside it and sends it again with the same id", async () => {
    server.answers.messages.push("network");
    renderPage(<Chat />);
    await ready();

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });

    fireEvent.click(await screen.findByRole("button", { name: pt.retry }));

    await waitFor(() => {
      expect(server.sent()).toHaveLength(2);
    });
    const [first, second] = server.sent();
    expect(idOf(second?.body)).toBe(idOf(first?.body));
    await waitFor(() => {
      expect(screen.queryByText(pt.failed)).toBeNull();
    });
  });

  it("asks for a new session once when the cookie is gone, then sends", async () => {
    server.answers.messages.push({ status: 401, body: { error: "session" } });
    renderPage(<Chat />);
    await ready();

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });

    await waitFor(() => {
      expect(server.sent()).toHaveLength(2);
    });
    expect(
      server.requests.filter((request) => request.path === "/api/session"),
    ).toHaveLength(2);
    expect(screen.queryByText(pt.failed)).toBeNull();
  });
});

describe("FR-18 the chat that cannot open", () => {
  it("says so when the session cannot be had", async () => {
    server.answers.session.push({ status: 500, body: {} });
    renderPage(<Chat />);

    expect(await screen.findByText(pt.loadFailed)).toBeInTheDocument();
    expect(server.polls()).toEqual([]);
  });
});

describe("Threat model SR-03 the attendant's words are text", () => {
  it("renders paragraphs and line breaks, and never markup", async () => {
    server.answers.current.push(
      conversation(1, [
        message({
          author: "bot",
          body: "<b>Temos</b> duas.\n\nDipirona 500 mg\nDipirona gotas",
        }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    const reply = (
      await within(thread()).findByText("<b>Temos</b> duas.")
    ).closest("li");
    expect(reply?.querySelector("b")).toBeNull();
    expect(reply?.querySelectorAll("p")).toHaveLength(2);
    expect(reply?.querySelectorAll("br")).toHaveLength(1);
    expect(reply).toHaveAttribute("data-voice", "attendant");
  });
});

describe("NFR-10 the chat for assistive technology", () => {
  it("has one first-level heading that names the conversation's section", async () => {
    renderPage(<Chat />);
    await ready();

    const [heading, ...others] = screen.getAllByRole("heading", { level: 1 });
    expect(others).toEqual([]);
    expect(heading).toHaveTextContent(pt.heading);
    expect(screen.getByRole("region", { name: pt.heading })).toContainElement(
      thread(),
    );
  });
});

// Review finding C1 of pull request #14: the thread followed where the page
// first drew a message, so a returning visitor's opener sat above the
// conversation it joined.
describe("FR-21 the thread in the server's order", () => {
  it("puts a returning visitor's opener after the conversation it already has", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const earlier = [
      message({ author: "visitor", body: "tem dipirona?" }),
      message({ author: "bot", body: "Temos duas." }),
    ];
    server.answers.current.push(conversation(1, earlier));
    window.history.replaceState(null, "", "/chat?say=delivery_es");
    renderPage(<Chat />);
    await ready();
    await within(thread()).findByText("Temos duas.");
    const items = () =>
      within(thread())
        .getAllByRole("listitem")
        .map((item) => item.textContent);
    expect(items()).toEqual([
      "tem dipirona?",
      "Temos duas.",
      openers.delivery_es.text,
    ]);

    const id = idOf(server.sent()[0]?.body);
    server.answers.current.push(
      conversation(1, [
        ...earlier,
        message({
          author: "visitor",
          body: openers.delivery_es.text,
          client_id: id,
        }),
        message({ author: "bot", body: "Sí, entregamos." }),
      ]),
    );
    await act(() => vi.advanceTimersByTimeAsync(3000));

    expect(items()).toEqual([
      "tem dipirona?",
      "Temos duas.",
      openers.delivery_es.text,
      "Sí, entregamos.",
    ]);
    expect(
      within(thread()).getByText(openers.delivery_es.text).closest("li"),
    ).toHaveAttribute("lang", "es");
  });

  it("puts a message retried after later ones where the server stored it", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.messages.push("network");
    renderPage(<Chat />);
    await ready();

    type("primeira");
    fireEvent.keyDown(field(), { key: "Enter" });
    await screen.findByRole("button", { name: pt.retry });
    type("segunda");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(2);
    });
    const [first, second] = server.sent().map((request) => idOf(request.body));
    fireEvent.click(screen.getByRole("button", { name: pt.retry }));
    await waitFor(() => {
      expect(server.sent()).toHaveLength(3);
    });

    server.answers.current.push(
      conversation(1, [
        message({
          author: "visitor",
          body: "segunda",
          client_id: second ?? null,
        }),
        message({ author: "bot", body: "resposta da segunda" }),
        message({
          author: "visitor",
          body: "primeira",
          client_id: first ?? null,
        }),
        message({ author: "bot", body: "resposta da primeira" }),
      ]),
    );
    await act(() => vi.advanceTimersByTimeAsync(3000));

    expect(
      within(thread())
        .getAllByRole("listitem")
        .map((item) => item.textContent),
    ).toEqual([
      "segunda",
      "resposta da segunda",
      "primeira",
      "resposta da primeira",
    ]);
  });
});
