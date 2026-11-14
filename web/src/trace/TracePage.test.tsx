import { act, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { render as prerender } from "../entry-server";
import en from "../locales/en.json";
import ptBR from "../locales/pt-BR.json";
import { pageOf } from "../pages";
import { fakeCable } from "../test/fakeCable";
import { BRL, fakeServer } from "../test/fakeServer";
import { renderPage } from "../test/render";
import { answeredTurn, commandTurn, runningTurn } from "../test/spans";
import { LIT_ICON, tabIcon } from "../test/tabIcon";
import { TracePage } from "./TracePage";

// A link of the shape the server draws (24 characters of base58).
const LINK = "Xy7GqR2mN8pLw4Kd9sTzVb3H";
const pt = ptBR.trace;
let server: ReturnType<typeof fakeServer>;

beforeEach(() => {
  server = fakeServer();
  vi.stubGlobal("fetch", server.fetch);
  window.history.replaceState(null, "", `/trace#${LINK}`);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

const said = (id: string, turn: string, body: string) => ({
  id,
  turn_id: turn,
  author: "visitor",
  notice: null,
  body,
  created_at: "2026-11-12T15:03:41.000Z",
});
const reply = (
  id: string,
  turn: string,
  body: string,
  notice: string | null = null,
) => ({
  ...said(id, turn, body),
  author: "bot",
  notice,
});

function trace(
  spans = [...answeredTurn("t1"), ...commandTurn("t2", "trace")],
  brl: typeof BRL | null = BRL,
) {
  return {
    status: 200,
    body: {
      ...(brl ? { brl } : {}),
      conversation: { started_at: "2026-11-12T15:03:41.000Z" },
      messages: [
        said("m1", "t1", "tem dipirona?"),
        reply("m2", "t1", "Temos duas.", "Aviso: esta é uma demonstração."),
        said("m3", "t2", "como você funciona?"),
        reply("m4", "t2", "Veja, passo a passo, como eu funciono."),
      ],
      spans,
    },
  };
}

const roll = () => screen.getByRole("region", { name: pt.roll });
const turn = (number: number) =>
  within(roll())
    .getByRole("heading", {
      level: 2,
      name: new RegExp(`^turno ${String(number)}`),
    })
    .closest("section") as HTMLElement;

describe("FR-12 the trace page, the glass box at full length", () => {
  it("asks for the trace its address names, with no cookie of its own", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);

    await waitFor(() => {
      expect(server.traces()).toHaveLength(1);
    });
    expect(server.traces()[0]?.headers.get("X-Trace-Token")).toBe(LINK);
    expect(server.traces()[0]?.headers.get("Accept-Language")).toBe("pt-BR");
  });

  // Review finding V3 of pull request #17: kamal-proxy writes the path and
  // the query of every request to the host's log, so the token travels after
  // the address's "#", which no browser sends, and in a header.
  it("reads the token after the #, and puts it in no request's path or query", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);

    await screen.findByText("tem dipirona?");
    expect(server.traces()[0]?.path).toBe("/api/trace");
    expect(
      server.requests.filter((request) => request.path.includes(LINK)),
    ).toEqual([]);
  });

  it("follows a link to another trace opened in the same tab, and keeps nothing of the first", async () => {
    const other = "Ab3dEf5gHj7kLm9nPq2rSt4u";
    server.answers.trace.push(trace(answeredTurn("t1")), {
      status: 200,
      body: {
        conversation: { started_at: "2026-11-12T15:03:41.000Z" },
        messages: [said("m9", "t9", "outra conversa")],
        spans: answeredTurn("t9"),
      },
    });
    const cable = fakeCable();
    renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByText("tem dipirona?");
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });
    cable.send({ type: "span", span: runningTurn("t3", 9)[0] });
    expect(
      await within(roll()).findByRole("heading", {
        level: 2,
        name: /^turno 2/,
      }),
    ).toBeInTheDocument();

    act(() => {
      window.history.replaceState(null, "", `/trace#${other}`);
      window.dispatchEvent(new HashChangeEvent("hashchange"));
    });

    expect(await screen.findByText("outra conversa")).toBeInTheDocument();
    expect(server.traces().at(-1)?.headers.get("X-Trace-Token")).toBe(other);
    expect(cable.active().map((each) => each.params)).toEqual([
      { channel: "TraceChannel", token: other },
    ]);
    expect(
      within(roll()).queryByRole("heading", { level: 2, name: /^turno 2/ }),
    ).toBeNull();
  });

  it("says the link is gone for an address with no token after the #", async () => {
    window.history.replaceState(null, "", "/trace");
    renderPage(<TracePage />);

    expect(
      await screen.findByRole("heading", { level: 1, name: pt.goneHeading }),
    ).toBeInTheDocument();
    expect(server.traces()).toEqual([]);
  });

  it("titles the page with the link's head, the day and the hour it started in São Paulo, and its turns", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);

    expect(
      await screen.findByRole("heading", {
        level: 1,
        name: "Conversa Xy7G…, iniciada em 12/11 às 12:03, com 2 turnos",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText(pt.share)).toBeInTheDocument();
  });

  it("draws each turn with the visitor's words, its rows closed, its time and the reply under them", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);
    await screen.findByRole("region", { name: pt.roll });

    const first = within(turn(1));
    expect(first.getByText("tem dipirona?")).toBeInTheDocument();
    expect(first.getByText("3,0 s")).toBeInTheDocument();
    expect(first.getByText("Temos duas.")).toBeInTheDocument();
    // The demo notice is the chat's; the receipt shows the reply's own words.
    expect(turn(1)).not.toHaveTextContent("Aviso");
    const calls = first
      .getAllByText("modelo", { selector: "summary span" })
      .map((name) => name.closest("details"));
    expect(calls).toHaveLength(2);
    for (const call of calls) expect(call).not.toHaveAttribute("open");

    const second = within(turn(2));
    expect(second.getByText("como você funciona?")).toBeInTheDocument();
    expect(second.getByText("comando")).toBeInTheDocument();
    expect(second.getByText("trace")).toBeInTheDocument();
  });

  // FR-12, FR-14: the turn's cost closes it, and the receipt's total is the
  // cost, with the turns' time a line of its own (docs/prototype/trace.html).
  it("closes each turn with its cost in dollars and reais, and totals the cost above the tokens and the time", async () => {
    server.answers.trace.push(
      trace([
        ...answeredTurn("t1", { costs: [0.003, 0.006] }),
        ...commandTurn("t2", "trace"),
      ]),
    );
    renderPage(<TracePage />);
    await screen.findByRole("region", { name: pt.roll });

    const line = within(turn(1))
      .getByText("custo do turno")
      .closest("p") as HTMLElement;
    expect(line.textContent).toBe("custo do turno US$ 0,009 · R$ 0,05");
    expect(within(turn(2)).queryByText("custo do turno")).toBeNull();
    const total = within(roll())
      .getByText("total · 2 turnos")
      .closest("div") as HTMLElement;
    expect(total.textContent).toBe("total · 2 turnosUS$ 0,009 · R$ 0,05");
    const time = within(roll())
      .getByText("tempo dos turnos")
      .closest("div") as HTMLElement;
    expect(time.textContent).toBe("tempo dos turnos3,0 s");
  });

  it("writes the dollars alone when the trace's answer has no rate", async () => {
    server.answers.trace.push(
      trace(answeredTurn("t1", { costs: [0.003, 0.006] }), null),
    );
    renderPage(<TracePage />);
    await screen.findByRole("region", { name: pt.roll });

    expect(
      within(roll()).getByText("custo do turno").closest("p")?.textContent,
    ).toBe("custo do turno US$ 0,009");
    expect(roll().textContent).not.toMatch(/R\$/);
  });

  it("totals the turns, the input with what the cache read, the output and the turns' time", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);
    await screen.findByRole("region", { name: pt.roll });

    const total = within(roll())
      .getByText("total · 2 turnos")
      .closest("dl") as HTMLElement;
    expect(
      within(total).getByText("6,8k (2,8k lidos do cache)"),
    ).toBeInTheDocument();
    expect(within(total).getByText("140")).toBeInTheDocument();
    expect(within(total).getByText("3,0 s")).toBeInTheDocument();
    expect(roll().textContent).not.toMatch(/US\$|R\$/);
  });

  it("says the conversation is no longer here when the link names nothing, and offers a new one", async () => {
    renderPage(<TracePage />);

    expect(
      await screen.findByRole("heading", { level: 1, name: pt.goneHeading }),
    ).toBeInTheDocument();
    expect(screen.getByText(pt.goneNote)).toBeInTheDocument();
    expect(screen.getByRole("link", { name: pt.startChat })).toHaveAttribute(
      "href",
      "/chat",
    );
    expect(screen.queryByRole("region", { name: pt.roll })).toBeNull();
  });

  it("says in one line that the trace could not load when the server fails", async () => {
    server.answers.trace.push("network");
    renderPage(<TracePage />);

    expect(await screen.findByText(pt.loadFailed)).toBeInTheDocument();
  });

  it("speaks the page's language", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />, "en");

    expect(
      await screen.findByRole("heading", {
        level: 1,
        name: "Conversation Xy7G…, started on Nov 12 at 12:03, with 2 turns",
      }),
    ).toBeInTheDocument();
    expect(screen.getByText(en.trace.share)).toBeInTheDocument();
    expect(server.traces()[0]?.headers.get("Accept-Language")).toBe("en");
  });

  it("leads home, and to nothing that does not exist yet", async () => {
    server.answers.trace.push(trace());
    renderPage(<TracePage />);
    await screen.findByRole("region", { name: pt.roll });

    expect(screen.getByRole("link", { name: pt.home })).toHaveAttribute(
      "href",
      "/",
    );
    expect(
      screen.queryByRole("link", { name: /status|privacidade/i }),
    ).toBeNull();
  });
});

describe("FR-12 the trace page follows the conversation live", () => {
  it("draws a span its stream brings at once, and fetches the turn's words once the turn ends", async () => {
    server.defaults.trace = trace(answeredTurn("t1"));
    const cable = fakeCable();
    renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByRole("region", { name: pt.roll });
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });
    expect(cable.active()[0]?.params).toEqual({
      channel: "TraceChannel",
      token: LINK,
    });
    cable.connect();
    await waitFor(() => {
      expect(server.traces()).toHaveLength(2);
    });

    const [root, call] = runningTurn("t3", 9);
    cable.send({ type: "span", span: root });
    cable.send({ type: "span", span: call });

    expect(
      await within(roll()).findByRole("heading", {
        level: 2,
        name: /^turno 2/,
      }),
    ).toBeInTheDocument();
    expect(within(turn(2)).getByText("claude-opus-5-5")).toBeInTheDocument();
    expect(server.traces()).toHaveLength(2);

    cable.send({
      type: "span",
      span: { ...root, finished_at: "2026-11-12T15:09:14.000Z" },
    });
    await waitFor(() => {
      expect(server.traces()).toHaveLength(3);
    });
  });

  // Design §10, note of 2026-11-13: the tab's cross dims while a turn of the
  // conversation runs, as it does on the chat, a WhatsApp turn included.
  it("dims the tab's cross while a turn runs, and lights it once the turn ends", async () => {
    const icon = tabIcon();
    server.defaults.trace = trace(answeredTurn("t1"));
    const cable = fakeCable();
    renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByRole("region", { name: pt.roll });
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });
    expect(icon.getAttribute("href")).toBe(LIT_ICON);

    const [root, call] = runningTurn("t3", 9);
    cable.send({ type: "span", span: root });
    cable.send({ type: "span", span: call });
    await waitFor(() => {
      expect(icon.getAttribute("href")).not.toBe(LIT_ICON);
    });

    cable.send({
      type: "span",
      span: { ...root, finished_at: "2026-11-12T15:09:14.000Z" },
    });
    await waitFor(() => {
      expect(icon.getAttribute("href")).toBe(LIT_ICON);
    });
  });
});

// Review findings C2 and C5 of pull request #17 (the verifier's examples).
describe("FR-12 the trace page keeps what it drew", () => {
  it("keeps the receipt it drew when a later fetch fails", async () => {
    server.answers.trace.push(trace(answeredTurn("t1")), "network");
    const cable = fakeCable();
    const { client } = renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByRole("region", { name: pt.roll });
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });

    cable.connect();
    await waitFor(() => {
      expect(server.traces()).toHaveLength(2);
    });
    await waitFor(() => {
      expect(client.getQueryState(["traces", LINK])?.fetchStatus).toBe("idle");
    });

    expect(screen.queryByText(pt.loadFailed)).toBeNull();
    expect(roll()).toHaveTextContent("tem dipirona?");
  });

  it("asks for the stream again a while after the server refused it", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.defaults.trace = trace(answeredTurn("t1"));
    const cable = fakeCable();
    renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByRole("region", { name: pt.roll });
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });

    act(() => {
      cable.active()[0]?.handlers.rejected();
    });
    await act(() => vi.advanceTimersByTimeAsync(31_000));

    expect(cable.subscriptions.length).toBeGreaterThan(1);
    vi.useRealTimers();
  });
});

// Review finding G2 of pull request #17: the deletion's word reaches the
// trace's stream, and the page drops what it showed (FR-05).
describe("FR-05 the trace page of a conversation whose data is deleted", () => {
  it("says the conversation is no longer here as soon as its stream says so", async () => {
    server.defaults.trace = trace(answeredTurn("t1"));
    const cable = fakeCable();
    renderPage(<TracePage />, "pt-BR", cable.cable);
    await screen.findByRole("region", { name: pt.roll });
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });

    cable.send({ type: "deleted" });

    expect(
      await screen.findByRole("heading", { level: 1, name: pt.goneHeading }),
    ).toBeInTheDocument();
    expect(screen.queryByRole("region", { name: pt.roll })).toBeNull();
    expect(screen.queryByText("tem dipirona?")).toBeNull();
  });
});

describe("NFR-10 the trace page before any script runs", () => {
  it("is the receipt's head in the page's language, with no token of any link in it", () => {
    const { html, title } = prerender("trace", "pt-BR");

    expect(title).toBe(pt.title);
    expect(html).toContain(pt.loading);
    expect(html).not.toContain("Xy7G");
  });
});

describe("Design §6.7 the trace page's route", () => {
  it("is the page of the /trace address, whatever follows its #", () => {
    expect(pageOf("/trace")).toBe("trace");
    expect(pageOf("/trace/")).toBe("trace");
    expect(pageOf(`/trace/${LINK}`)).toBe("landing");
  });
});
