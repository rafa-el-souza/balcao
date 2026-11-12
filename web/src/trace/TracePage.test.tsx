import { screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { render as prerender } from "../entry-server";
import en from "../locales/en.json";
import ptBR from "../locales/pt-BR.json";
import { pageOf } from "../pages";
import { fakeCable } from "../test/fakeCable";
import { fakeServer } from "../test/fakeServer";
import { renderPage } from "../test/render";
import { answeredTurn, commandTurn, runningTurn } from "../test/spans";
import { TracePage } from "./TracePage";

// A link of the shape the server draws (24 characters of base58).
const LINK = "Xy7GqR2mN8pLw4Kd9sTzVb3H";
const pt = ptBR.trace;
let server: ReturnType<typeof fakeServer>;

beforeEach(() => {
  server = fakeServer();
  vi.stubGlobal("fetch", server.fetch);
  window.history.replaceState(null, "", `/trace/${LINK}`);
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

function trace(spans = [...answeredTurn("t1"), ...commandTurn("t2", "trace")]) {
  return {
    status: 200,
    body: {
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
    expect(server.traces()[0]?.path).toBe(`/api/traces/${LINK}`);
    expect(server.traces()[0]?.headers.get("Accept-Language")).toBe("pt-BR");
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
  it("is the page of any /trace/:token address", () => {
    expect(pageOf(`/trace/${LINK}`)).toBe("trace");
    expect(pageOf("/trace/")).toBe("landing");
    expect(pageOf(`/trace/${LINK}/more`)).toBe("landing");
  });
});
