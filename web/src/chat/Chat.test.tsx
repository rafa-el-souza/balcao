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

// React applies the updates made inside one act() when it ends, so a timer
// the page re-arms after an answer needs time to pass in steps.
async function elapse(ms: number) {
  for (let passed = 0; passed < ms; passed += 500) {
    await act(() => vi.advanceTimersByTimeAsync(500));
  }
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

    await elapse(9000);
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

// Review finding C3 of pull request #14: a message accepted into a
// conversation the page no longer shows kept the page asking every 3 s.
describe("FR-18 the page stops asking for what the server will not bring", () => {
  it("stops once a reset's conversation arrives after a failed first load", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push("network");
    renderPage(<Chat />);
    await screen.findByText(pt.loadFailed);

    fireEvent.click(screen.getByRole("button", { name: pt.glass.reset }));
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    server.defaults.current = conversation(2, [
      message({
        author: "bot",
        body: "Pronto, começamos de novo.",
        conversation_id: 2,
      }),
    ]);
    await elapse(18_000);

    expect(server.polls()).toHaveLength(2);
    expect(within(thread()).queryByText("/reiniciar")).toBeNull();
    expect(
      within(thread()).getByText("Pronto, começamos de novo."),
    ).toBeInTheDocument();
  });

  it("drops a failed message with the conversation a reset closed, so no retry lands there", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push(
      conversation(1, [message({ author: "visitor", body: "oi" })]),
    );
    renderPage(<Chat />);
    await ready();

    server.answers.messages.push("network");
    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await screen.findByRole("button", { name: pt.retry });
    fireEvent.click(screen.getByRole("button", { name: pt.glass.reset }));
    await waitFor(() => {
      expect(server.sent()).toHaveLength(2);
    });
    server.defaults.current = conversation(2, [
      message({
        author: "bot",
        body: "Pronto, começamos de novo.",
        conversation_id: 2,
      }),
    ]);
    await elapse(9000);

    expect(screen.queryByRole("button", { name: pt.retry })).toBeNull();
    expect(server.polls()).toHaveLength(2);
  });
});

// Review finding C7 of pull request #14: the "could not open" stamp stayed
// above a conversation that a later snapshot opened.
describe("FR-18 the chat that could not open, and then could", () => {
  it("takes the stamp away once a snapshot opens the conversation", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push("network");
    renderPage(<Chat />);
    await screen.findByText(pt.loadFailed);

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    const id = idOf(server.sent()[0]?.body);
    server.answers.current.push(
      conversation(1, [
        message({ author: "visitor", body: "tem dipirona?", client_id: id }),
        message({ author: "bot", body: "Temos duas." }),
      ]),
    );
    await act(() => vi.advanceTimersByTimeAsync(3000));

    expect(within(thread()).getByText("Temos duas.")).toBeInTheDocument();
    expect(screen.queryByText(pt.loadFailed)).toBeNull();
  });
});

// Review finding C2 of pull request #14: a request that never answered left
// the message drawn as sent, or the page loading, with nothing said.
describe("FR-18 a request that never answers", () => {
  const hanging =
    (hung: string) =>
    (path: string, init: RequestInit = {}) =>
      path === hung
        ? new Promise<Response>((_, reject) => {
            init.signal?.addEventListener("abort", () => {
              reject(new DOMException("timed out", "AbortError"));
            });
          })
        : server.fetch(path, init);

  it("says a message was not sent when its request hangs", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.stubGlobal("fetch", hanging("/api/messages"));
    renderPage(<Chat />);
    await ready();

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await elapse(60_000);

    expect(
      within(thread()).getByText(pt.failed, { exact: false }),
    ).toBeInTheDocument();
  });

  it("says the chat could not open when the session request hangs", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.stubGlobal("fetch", hanging("/api/session"));
    renderPage(<Chat />);

    await elapse(60_000);

    expect(screen.getByText(pt.loadFailed)).toBeInTheDocument();
  });
});

// Review finding C4 of pull request #14: on a first visit, a second session
// request sent while the first was in flight minted a second visitor.
describe("FR-21 one session at a time", () => {
  const sessions = () =>
    server.requests.filter((request) => request.path === "/api/session");

  function holdFirstSession() {
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    vi.stubGlobal("fetch", (path: string, init?: RequestInit) => {
      const first = path === "/api/session" && sessions().length === 0;
      const answer = server.fetch(path, init);
      return first ? held.then(() => answer) : answer;
    });
    return () => {
      release();
    };
  }

  it("asks for the switcher's language only after the first session answers", async () => {
    const release = holdFirstSession();
    renderPage(<Chat />);
    await waitFor(() => {
      expect(sessions()).toHaveLength(1);
    });

    fireEvent.click(
      screen.getAllByRole("button", { name: /^EN English$/ })[0] as HTMLElement,
    );
    await act(() => Promise.resolve());
    expect(sessions()).toHaveLength(1);

    release();
    await waitFor(() => {
      expect(sessions()).toHaveLength(2);
    });
    expect(sessions()[1]?.body).toEqual({ language: "en" });
  });

  it("sends a message typed before the first session answers only after it, once", async () => {
    const release = holdFirstSession();
    renderPage(<Chat />);
    await waitFor(() => {
      expect(sessions()).toHaveLength(1);
    });

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await act(() => Promise.resolve());
    expect(server.sent()).toEqual([]);

    release();
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    expect(sessions()).toHaveLength(1);
  });
});

// Review finding C6 of pull request #14: when the new session a message
// needed was refused at the edge, the limit's text was dropped.
describe("FR-14 the limit met by the session a message needs", () => {
  it("stamps the limit's text instead of offering a retry", async () => {
    const text =
      "Você chegou ao limite da demo por agora. Tente de novo daqui a pouco.";
    server.answers.messages.push({ status: 401, body: { error: "session" } });
    renderPage(<Chat />);
    await ready();
    server.answers.session.push({
      status: 429,
      body: { error: "limit", text },
    });

    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });

    expect(await within(thread()).findByText(text)).toBeInTheDocument();
    expect(
      within(thread()).queryByText(pt.failed, { exact: false }),
    ).toBeNull();
  });
});

// Review finding C5 of pull request #14: the page asked every 3 s whatever
// the answer, refused polls included, which the edge counts too.
describe("FR-14 the polling that is refused", () => {
  it("asks less and less often while the polls fail, and at 3 s again once one answers", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    renderPage(<Chat />);
    await ready();
    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    const refused = {
      status: 429,
      body: {
        error: "limit",
        text: "Você chegou ao limite da demo por agora.",
      },
    };
    server.defaults.current = refused;

    await elapse(60_000);
    const afterAMinute = server.polls().length;
    expect(afterAMinute).toBeLessThan(10);

    server.defaults.current = conversation(1, [], true);
    await elapse(30_000);
    const recovered = server.polls().length;
    await elapse(9_000);
    expect(server.polls().length - recovered).toBe(3);
  });
});

// Review finding V1 of pull request #14 (found by the verifier): a page
// whose polls kept failing showed the message as sent and said nothing; the
// drawing's note asks it to say so when asking the server fails too.
describe("FR-18 the connection lost", () => {
  it("says so while the polls fail, and stops saying it once one answers", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    renderPage(<Chat />);
    await ready();
    type("tem dipirona?");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });

    server.defaults.current = "network";
    await elapse(3000);
    expect(screen.queryByText(pt.offline)).toBeNull();
    await elapse(30_000);
    expect(within(thread()).getByText(pt.offline)).toBeInTheDocument();

    server.defaults.current = conversation(1, [], true);
    await elapse(30_000);
    expect(screen.queryByText(pt.offline)).toBeNull();
  });
});

// Review finding C8 of pull request #14: each click sent the command again
// with a new id, so a double click reset or deleted twice.
describe("FR-04 and FR-05 the glass box's commands, pressed twice", () => {
  it("sends one command for a double click, and the command again once it was sent", async () => {
    renderPage(<Chat />);
    await ready();
    const reset = screen.getByRole("button", { name: pt.glass.reset });

    fireEvent.click(reset);
    fireEvent.click(reset);
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    await act(() => Promise.resolve());
    expect(server.sent()).toHaveLength(1);

    fireEvent.click(reset);
    await waitFor(() => {
      expect(server.sent()).toHaveLength(2);
    });
  });
});

// The fix review of pull request #14 (R1 to R6), over the fixes above.
describe("FR-18 and FR-21 the fixes' own edges (fix review of pull request #14)", () => {
  // Holds the load's own GET until the test lets it go.
  function holdFirstPoll() {
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    vi.stubGlobal("fetch", (path: string, init?: RequestInit) => {
      const first =
        path === "/api/conversations/current" && server.polls().length === 0;
      const answer = server.fetch(path, init);
      return first ? held.then(() => answer) : answer;
    });
    return () => {
      release();
    };
  }
  const items = () =>
    within(thread())
      .getAllByRole("listitem")
      .map((item) => item.textContent);
  const earlier = () => [
    message({ author: "visitor", body: "tem dipirona?" }),
    message({ author: "bot", body: "Temos duas." }),
  ];

  // R1: the 24 hours of FR-04 closed the conversation the load read.
  it("keeps an opener the server accepted into a newer conversation, and shows its reply", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push(conversation(1, earlier()));
    server.answers.messages.push({
      status: 202,
      body: { turn_id: 9, message_id: 9, conversation_id: 2 },
    });
    const release = holdFirstPoll();
    window.history.replaceState(null, "", "/chat?say=delivery_es");
    renderPage(<Chat />);
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    await act(() => vi.advanceTimersByTimeAsync(50));
    const id = idOf(server.sent()[0]?.body);
    server.defaults.current = conversation(2, [
      message({
        author: "visitor",
        body: openers.delivery_es.text,
        client_id: id,
        conversation_id: 2,
      }),
      message({ author: "bot", body: "Sí, entregamos.", conversation_id: 2 }),
    ]);
    release();
    await elapse(9000);

    expect(within(thread()).getByText("Sí, entregamos.")).toBeInTheDocument();
  });

  // R2: a message that failed after one still travelling.
  it("draws a failed message after the earlier one still on its way", async () => {
    renderPage(<Chat />);
    await ready();
    type("primeira");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    server.answers.messages.push("network");
    type("segunda");
    fireEvent.keyDown(field(), { key: "Enter" });
    await screen.findByRole("button", { name: pt.retry });

    expect(items()[0]).toBe("primeira");
    expect(items()[1]).toContain("segunda");
  });

  // R3: an opener refused before the conversation loaded.
  it("draws a refused opener and its stamp after the history the first snapshot brings", async () => {
    const text = "Você chegou ao limite da demo por hoje. Volte amanhã.";
    server.answers.current.push(conversation(1, earlier()));
    server.answers.messages.push({
      status: 429,
      body: { error: "limit", text },
    });
    const release = holdFirstPoll();
    window.history.replaceState(null, "", "/chat?say=delivery_es");
    renderPage(<Chat />);
    await within(thread()).findByText(text);
    release();
    await within(thread()).findByText("Temos duas.");

    expect(items()).toEqual([
      "tem dipirona?",
      "Temos duas.",
      openers.delivery_es.text,
      text,
    ]);
  });

  // R4: the load's GET timed out after a poll opened the conversation.
  it("does not say the chat could not open once a poll opened it", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    // The load's own GET hangs until its timeout; later polls answer.
    vi.stubGlobal("fetch", (path: string, init: RequestInit = {}) => {
      const answer = server.fetch(path, init);
      if (path !== "/api/conversations/current" || server.polls().length > 1)
        return answer;
      return new Promise<Response>((_, reject) => {
        init.signal?.addEventListener("abort", () => {
          reject(new DOMException("timed out", "AbortError"));
        });
      });
    });
    window.history.replaceState(null, "", "/chat?say=stock_pt");
    renderPage(<Chat />);
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    const id = idOf(server.sent()[0]?.body);
    server.defaults.current = conversation(1, [
      message({
        author: "visitor",
        body: openers.stock_pt.text,
        client_id: id,
      }),
      message({ author: "bot", body: "Temos duas." }),
    ]);
    await elapse(20_000);

    expect(within(thread()).getByText("Temos duas.")).toBeInTheDocument();
    expect(screen.queryByText(pt.loadFailed)).toBeNull();
  });

  // R2, as the verifier wrote it: a message that met the limit.
  it("draws a message that met the limit, and its stamp, after the earlier one still on its way", async () => {
    const text =
      "Você chegou ao limite da demo por agora. Tente de novo daqui a pouco.";
    renderPage(<Chat />);
    await ready();
    type("primeira");
    fireEvent.keyDown(field(), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });
    server.answers.messages.push({
      status: 429,
      body: { error: "limit", text },
    });
    type("segunda");
    fireEvent.keyDown(field(), { key: "Enter" });
    await within(thread()).findByText(text);

    expect(items()).toEqual(["primeira", "segunda", text]);
  });
});
