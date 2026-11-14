import {
  act,
  fireEvent,
  screen,
  waitFor,
  within,
} from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import ptBR from "../locales/pt-BR.json";
import { fakeCable } from "../test/fakeCable";
import {
  BRL,
  conversation,
  fakeServer,
  message,
  replyTo,
} from "../test/fakeServer";
import { renderPage } from "../test/render";
import { LIT_ICON, tabIcon } from "../test/tabIcon";
import {
  answeredTurn,
  commandTurn,
  failedTool,
  refusedTool,
  reservationTool,
  runningTurn,
} from "../test/spans";
import { Chat } from "./Chat";

const pt = ptBR;
let server: ReturnType<typeof fakeServer>;

beforeEach(() => {
  server = fakeServer();
  vi.stubGlobal("fetch", server.fetch);
  window.history.replaceState(null, "", "/chat");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

const glass = () => screen.getByRole("region", { name: pt.chat.glass.title });
const events = () =>
  within(glass()).getByRole("list", { name: pt.instrument.events_label });
const thread = () => screen.getByRole("list", { name: pt.chat.conversation });
const ready = () =>
  waitFor(() => {
    expect(server.polls()).toHaveLength(1);
  });

// React applies the updates made inside one act() when it ends, so a timer
// the page re-arms after an answer needs time to pass in steps.
async function elapse(ms: number) {
  for (let passed = 0; passed < ms; passed += 500) {
    await act(() => vi.advanceTimersByTimeAsync(500));
  }
}

// The rows of a list, each as its own text: its hour, then what it says.
const rowsOf = (list: HTMLElement) =>
  within(list)
    .getAllByRole("listitem")
    .map((item) =>
      [...item.children]
        .map((part) => part.textContent)
        .join(" ")
        .replace(/\s+/g, " ")
        .trim(),
    );

describe("FR-12 the glass box draws the turn as the server traced it", () => {
  it("shows each row with its São Paulo hour: the receipt, every model call, the tool and the reply", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    renderPage(<Chat />);
    await ready();

    const rows = await waitFor(() => {
      const found = rowsOf(events());
      expect(found.length).toBeGreaterThan(4);
      return found;
    });
    expect(rows[0]).toBe("12:03:41 mensagem recebida");
    expect(rows[1]).toContain("modelo parou em tool_use 1,1 s");
    expect(rows[2]).toContain("search_products 38 ms");
    expect(rows[3]).toContain("modelo parou em end_turn 1,6 s");
    expect(rows[4]).toBe("12:03:44 mensagem enviada");
    expect(within(glass()).queryByText(pt.chat.glass.empty)).toBeNull();
  });

  it("opens the last turn's calls: model, effort, prompt by size and digest, the whole input, the cache and the output", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    renderPage(<Chat />);
    await ready();

    const [first, second] = await within(glass()).findAllByText("modelo", {
      selector: "summary span",
    });
    const call = first?.closest("details");
    expect(call).toHaveAttribute("open");
    const detail = within(call as HTMLElement);
    expect(detail.getByText("claude-opus-5-5")).toBeInTheDocument();
    expect(detail.getByText("medium")).toBeInTheDocument();
    expect(detail.getByText("11,8k caracteres · 9f2c41d0")).toBeInTheDocument();
    expect(detail.getByText("3,1k")).toBeInTheDocument();
    expect(detail.getByText(/2,8k · gravou 300/)).toBeInTheDocument();
    expect(detail.getByRole("img", { name: "leu" })).toBeInTheDocument();
    expect(detail.getByText("42")).toBeInTheDocument();
    // A call that read nothing from the cache says so: a miss is the news.
    const missed = within(second?.closest("details") as HTMLElement);
    expect(missed.getByText(/nada lido · gravou 3,7k/)).toBeInTheDocument();
    expect(missed.getByRole("img", { name: "não leu" })).toBeInTheDocument();
  });

  it("opens the tool call to its arguments, its raw result and how many it found", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    renderPage(<Chat />);
    await ready();

    const tool = (await within(glass()).findByText("search_products")).closest(
      "details",
    ) as HTMLElement;
    expect(within(tool).getByText('{"query":"dipirona"}')).toBeInTheDocument();
    expect(within(tool).getByText(/"products":\[/)).toBeInTheDocument();
    expect(within(tool).getByText("2 resultados")).toBeInTheDocument();
    expect(within(tool).queryByText(/cortado/)).toBeNull();
  });

  it("says when a result was cut at 500 characters, from its length before the cut", async () => {
    const tool = {
      "gen_ai.tool.name": "get_store_info",
      "gen_ai.tool.call.arguments": '{"topic":"delivery"}',
      "anthropic.tool_result.content": `${"x".repeat(499)}…`,
      "balcao.tool_result.characters": 812,
      "balcao.tool_result.unit": "areas",
      "balcao.tool_result.count": 4,
      "balcao.latency_ms": 4,
    };
    server.answers.current.push(
      conversation(1, [], false, answeredTurn("t1", { tool })),
    );
    renderPage(<Chat />);
    await ready();

    const row = (await within(glass()).findByText("get_store_info")).closest(
      "details",
    ) as HTMLElement;
    expect(within(row).getByText(/4 bairros/)).toBeInTheDocument();
    expect(
      within(row).getByText("cortado em 500 caracteres"),
    ).toBeInTheDocument();
  });

  it("says a fixed reply's reason in the sent row, and a failed call's error in words, in the error colour", async () => {
    server.answers.current.push(
      conversation(
        1,
        [],
        false,
        answeredTurn("t1", { error: "Anthropic::Errors::OverloadedError" }),
      ),
    );
    renderPage(<Chat />);
    await ready();

    expect(
      await within(glass()).findByText("o modelo não respondeu"),
    ).toBeInTheDocument();
    expect(within(glass()).getByText("resposta fixa")).toBeInTheDocument();
    const failed = within(glass()).getByText("sobrecarga").closest("li");
    expect(failed).toHaveAttribute("data-state", "error");
    expect(
      within(failed as HTMLElement).getByText("4,2 s"),
    ).toBeInTheDocument();
  });

  it("says why the job gave up on a turn, after its attempts, in the sent row (NFR-03)", async () => {
    server.answers.current.push(
      conversation(
        1,
        [],
        false,
        answeredTurn("t1", { error: "RuntimeError", outcome: "dead_letter" }),
      ),
    );
    renderPage(<Chat />);
    await ready();

    expect(
      await within(glass()).findByText("o sistema falhou"),
    ).toBeInTheDocument();
  });

  it("draws a command as a turn of one row", async () => {
    server.answers.current.push(
      conversation(1, [], false, [
        ...answeredTurn("t1"),
        ...commandTurn("t2", "trace"),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    await waitFor(() => {
      expect(rowsOf(events()).at(-1)).toBe("12:12:10 comando trace 12 ms");
    });
  });

  it("shows no cost and no zero in its place for a turn traced before the costs", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    renderPage(<Chat />);
    await ready();
    await within(glass()).findByText("search_products");

    expect(glass().textContent).not.toMatch(/US\$|R\$|custo/);
  });
});

// FR-12, FR-14: each model call's cost in dollars and in reais at the
// server's rate, the turn's in the totals and in the line that stands for the
// glass box at 390 px (docs/prototype/chat.html, chat-many-turns.html).
describe("FR-12 FR-14 the costs in the glass box", () => {
  const priced = (turn: string, minute = 3) =>
    answeredTurn(turn, { minute, costs: [0.003, 0.006] });

  it("writes each call's cost beside its time, and in its detail with the reais", async () => {
    server.answers.current.push(conversation(1, [], false, priced("t1")));
    renderPage(<Chat />);
    await ready();

    await waitFor(() => {
      expect(rowsOf(events())[1]).toContain(
        "12:03:41 modelo parou em tool_use US$ 0,003 · 1,1 s",
      );
    });
    const call = within(events())
      .getAllByText("modelo")[0]
      ?.closest("li") as HTMLElement;
    const detail = within(call)
      .getByText("custo")
      .closest("div") as HTMLElement;
    expect(detail.textContent.replace(/\s+/g, " ")).toBe(
      "custoUS$ 0,003 · R$ 0,02",
    );
  });

  it("totals the turn's cost under the rows and in the line of the glass box at 390 px", async () => {
    server.answers.current.push(conversation(1, [], false, priced("t1")));
    renderPage(<Chat />);
    await ready();

    const total = await within(glass()).findByText("custo do turno");
    expect(total.closest("div")?.textContent.replace(/\s+/g, " ")).toBe(
      "custo do turnoUS$ 0,009 · R$ 0,05",
    );
    expect(
      screen.getByRole("button", {
        name: /turno 1 · 5 eventos · US\$ 0,009 · 3,0 s/,
      }),
    ).toBeInTheDocument();
  });

  it("gives each earlier turn its cost, and the fold their sum", async () => {
    server.answers.current.push(
      conversation(1, [], false, [
        ...priced("t1", 3),
        ...priced("t2", 5),
        ...priced("t3", 7),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    const fold = await within(glass()).findByText(
      "2 turnos anteriores · 10 eventos · US$ 0,018 · 6,0 s",
    );
    const group = fold.closest("details") as HTMLElement;
    const first = within(group)
      .getByText("turno 1")
      .closest("summary") as HTMLElement;
    expect(first.textContent.replace(/\s+/g, " ")).toBe(
      "turno 1 5 eventos US$ 0,009 · 3,0 s",
    );
  });

  it("writes the dollars alone when the server gave no rate", async () => {
    server.answers.session.push({
      status: 201,
      body: { conversation_id: "1", trace_token: "t1", language: "pt-BR" },
    });
    server.answers.current.push(
      conversation(1, [], false, priced("t1"), { mode: "normal" }),
    );
    renderPage(<Chat />);
    await ready();

    const total = await within(glass()).findByText("custo do turno");
    expect(total.closest("div")?.textContent).toBe("custo do turnoUS$ 0,009");
    expect(glass().textContent).not.toMatch(/R\$/);
  });

  it("draws no zero for a turn that cost nothing, a failed call's", async () => {
    server.answers.current.push(
      conversation(
        1,
        [],
        false,
        answeredTurn("t1", { error: "Anthropic::Errors::OverloadedError" }),
      ),
    );
    renderPage(<Chat />);
    await ready();
    await within(glass()).findByText("o modelo não respondeu");

    expect(glass().textContent).not.toMatch(/US\$|R\$|custo/);
  });
});

// FR-14: the budget's mode in the glass box's head, from the session and
// the polling, and from a turn the stream closes (docs/prototype/chat.html).
describe("FR-14 the budget's mode in the glass box's head", () => {
  const mode = () => within(glass()).queryByText(/^(normal|economia|pausado)$/);

  it("names the mode the server gave, with its meaning's mark", async () => {
    renderPage(<Chat />);
    await ready();

    await waitFor(() => {
      expect(mode()).toHaveTextContent("normal");
    });
    expect(mode()?.closest("[data-mode]")).toHaveAttribute(
      "data-mode",
      "normal",
    );
    expect(within(glass()).getByText("modo")).toBeInTheDocument();
  });

  it("follows the polling's answer when the month pauses", async () => {
    server.answers.current.push(
      conversation(1, [], false, [], { mode: "paused", brl: BRL }),
    );
    renderPage(<Chat />);
    await ready();

    await waitFor(() => {
      expect(mode()).toHaveTextContent("pausado");
    });
    expect(mode()?.closest("[data-mode]")).toHaveAttribute(
      "data-mode",
      "paused",
    );
  });

  it("shows no mode when the server named none", async () => {
    server.answers.session.push({
      status: 201,
      body: { conversation_id: "1", trace_token: "t1", language: "pt-BR" },
    });
    server.answers.current.push(conversation(1, [], false, [], {}));
    renderPage(<Chat />);
    await ready();
    await within(glass()).findByText(pt.chat.glass.empty);

    expect(mode()).toBeNull();
    expect(glass().querySelector("[data-mode]")).toBeNull();
  });
});

// docs/prototype/chat-reservation.html and chat-tool-refused.html: the row
// names the reservation a call made, and a rule the tool enforces is told
// from a failure by the reason code the server gives it (design §10).
describe("FR-07 FR-12 a tool's reservation, refusal and failure in the glass box", () => {
  async function toolRow(tool: Record<string, unknown>) {
    server.answers.current.push(
      conversation(1, [], false, answeredTurn("t1", { tool })),
    );
    renderPage(<Chat />);
    await ready();
    const name = tool["gen_ai.tool.name"] as string;
    return (await within(glass()).findByText(name)).closest(
      "li",
    ) as HTMLElement;
  }

  it("names the reservation a call made, from its result", async () => {
    const row = await toolRow(reservationTool("4K2QHM"));

    expect(within(row).getByText("reserva 4K2QHM")).toBeInTheDocument();
    expect(row).not.toHaveAttribute("data-state");
  });

  it("words a refusal by its reason, in the instrument's own ink, since a rule at work is no failure", async () => {
    const row = await toolRow(
      refusedTool(
        "create_reservation",
        "over_limit",
        "The quantity is over the limit of 10 units per reservation. Offer 10 units, or the pharmacist on duty for a larger order.",
      ),
    );

    expect(
      within(row).getByText("recusado: acima de 10 unidades"),
    ).toBeInTheDocument();
    expect(row).toHaveAttribute("data-state", "refused");
    expect(within(row).queryByText(/reserva /)).toBeNull();
  });

  it("says only that the tool refused when the page has no word for the reason", async () => {
    const row = await toolRow(
      refusedTool("create_reservation", "brand_new", "No."),
    );

    expect(within(row).getByText("recusado")).toBeInTheDocument();
    expect(row).toHaveAttribute("data-state", "refused");
  });

  it("says the tool failed, in the error colour, when no rule refused", async () => {
    const row = await toolRow(failedTool("search_products"));

    expect(within(row).getByText("a ferramenta falhou")).toBeInTheDocument();
    expect(row).toHaveAttribute("data-state", "error");
  });

  it("has a word for every reason in each of the three languages", async () => {
    const { default: en } = await import("../locales/en.json");
    const { default: es } = await import("../locales/es.json");
    const keys = Object.keys(pt.instrument.tool.reasons).sort();

    expect(keys.length).toBeGreaterThan(0);
    expect(Object.keys(en.instrument.tool.reasons).sort()).toEqual(keys);
    expect(Object.keys(es.instrument.tool.reasons).sort()).toEqual(keys);
  });
});

describe("FR-12 a long conversation in the glass box", () => {
  it("folds the earlier turns into one line, which opens to a line per turn, and keeps the last turn open", async () => {
    server.answers.current.push(
      conversation(1, [], false, [
        ...answeredTurn("t1", { minute: 3 }),
        ...answeredTurn("t2", { minute: 5 }),
        ...answeredTurn("t3", { minute: 7 }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    const fold = await within(glass()).findByText(
      "2 turnos anteriores · 10 eventos · 6,0 s",
    );
    const group = fold.closest("details") as HTMLElement;
    expect(group).not.toHaveAttribute("open");
    expect(within(group).getByText("turno 1")).toBeInTheDocument();
    expect(within(group).getByText("turno 2")).toBeInTheDocument();
    // The last turn's rows stand open outside the fold.
    const open = within(events())
      .getAllByText("mensagem recebida")
      .filter((row) => !group.contains(row));
    expect(open).toHaveLength(1);
    expect(within(glass()).getByText("turno 3")).toBeInTheDocument();
  });

  it("names the one earlier turn on its own line", async () => {
    server.answers.current.push(
      conversation(1, [], false, [
        ...answeredTurn("t1", { minute: 3 }),
        ...answeredTurn("t2", { minute: 5 }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    expect(
      await within(glass()).findByText("turno 1 · 5 eventos · 3,0 s"),
    ).toBeInTheDocument();
  });

  it("keeps the last turn open beside the one that runs, which shows what is known at its start", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-11-12T15:05:12Z")); // the turn started at 15:05:10Z
    server.answers.current.push(
      conversation(1, [], true, [
        ...answeredTurn("t1", { minute: 3 }),
        ...runningTurn("t2", 5),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    await waitFor(() => {
      expect(within(events()).getAllByText("mensagem recebida")).toHaveLength(
        2,
      );
    });
    const running = within(glass())
      .getAllByText("modelo")
      .map((name) => name.closest("li"))
      .find((row) => row?.getAttribute("data-state") === "running");
    expect(running).toBeDefined();
    expect(
      within(running as HTMLElement).getByText("claude-opus-5-5"),
    ).toBeInTheDocument();
    // The totals speak of the turn in progress, whose time counts up.
    expect(within(glass()).getByText("turno 2")).toBeInTheDocument();
    expect(within(glass()).getByText(/^\d+,\d s …$/)).toBeInTheDocument();
  });
});

// Review findings C3 and C4 of pull request #17 (the verifier's examples).
describe("FR-12 the glass box and the clocks", () => {
  it("counts the running turn's time up in the totals and the summary line", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-11-12T15:05:12Z")); // the turn started at 15:05:10Z
    server.answers.current.push(conversation(1, [], true, runningTurn("t1")));
    renderPage(<Chat />);
    await ready();

    expect(
      await screen.findByRole("button", { name: /turno 1 · .* · 2,\d s …/ }),
    ).toBeInTheDocument();
    await act(() => vi.advanceTimersByTimeAsync(1000));
    expect(
      screen.getByRole("button", { name: /turno 1 · .* · 3,\d s …/ }),
    ).toBeInTheDocument();
  });

  it("writes the queued row whatever the browser's clock says", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-11-12T15:04:00Z")); // the server's turn started at 15:05:10Z
    server.answers.current.push(conversation(1, [], true, runningTurn("t1")));
    server.answers.messages.push({
      status: 202,
      body: { turn_id: "t2", message_id: "m2", conversation_id: "1" },
    });
    renderPage(<Chat />);
    await ready();
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "e a de gotas?" },
    });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(
      await within(glass()).findByText("mensagem na fila"),
    ).toBeInTheDocument();
  });

  it("dates the page's own rows by the server's clock, from the answers' Date", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-11-12T15:00:00Z"));
    const date = { Date: "Wed, 12 Nov 2026 15:04:02 GMT" };
    server.fetch.mockImplementation((path: string, init: RequestInit = {}) => {
      const limited = init.method === "POST" && path === "/api/messages";
      const body = limited
        ? { error: "limit", text: "Você chegou ao limite da demo por agora." }
        : path === "/api/session"
          ? { conversation_id: "1", trace_token: "t1", language: "pt-BR" }
          : conversation(1, [], false, answeredTurn("t1")).body;
      return Promise.resolve(
        new Response(JSON.stringify(body), {
          status: limited ? 429 : 200,
          headers: { "Content-Type": "application/json", ...date },
        }),
      );
    });
    renderPage(<Chat />);
    await within(glass()).findByText("search_products");

    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    const row = (await within(glass()).findByText("limite da demo")).closest(
      "li",
    ) as HTMLElement;
    expect(within(row).getByText("12:04:02")).toBeInTheDocument();
  });

  // Review finding R2 of pull request #17: a Date has whole seconds, so it
  // cannot tell a right clock a second off; the browser's clock stands while
  // the answer allows it, and the row stays under the turn it came after.
  async function sendInTheSecondOfTurnTwo(answer: {
    status: number;
    body: object;
  }) {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    vi.setSystemTime(new Date("2026-11-12T15:05:10.700Z")); // the browser's clock is right
    const date = { Date: "Thu, 12 Nov 2026 15:05:10 GMT" };
    const turns = [
      ...answeredTurn("t1", { minute: 3 }),
      ...runningTurn("t2", 5).map((span) => ({
        ...span,
        started_at: "2026-11-12T15:05:10.300Z",
      })),
    ];
    server.fetch.mockImplementation((path: string, init: RequestInit = {}) => {
      const sent = init.method === "POST" && path === "/api/messages";
      const body = sent
        ? answer.body
        : path === "/api/session"
          ? { conversation_id: "1", trace_token: "t1", language: "pt-BR" }
          : conversation(1, [], true, turns).body;
      return Promise.resolve(
        new Response(JSON.stringify(body), {
          status: sent ? answer.status : 200,
          headers: { "Content-Type": "application/json", ...date },
        }),
      );
    });
    renderPage(<Chat />);
    await waitFor(() => {
      expect(within(events()).getAllByText("mensagem recebida")).toHaveLength(
        2,
      );
    });

    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
  }

  it("keeps a limit met in the second the turn ahead began under that turn", async () => {
    await sendInTheSecondOfTurnTwo({
      status: 429,
      body: {
        error: "limit",
        text: "Você chegou ao limite da demo por agora.",
      },
    });

    await within(glass()).findByText("limite da demo");
    expect(rowsOf(events()).at(-1)).toContain("limite da demo");
  });

  it("keeps a message queued in the second the turn ahead began after that turn", async () => {
    await sendInTheSecondOfTurnTwo({
      status: 202,
      body: { turn_id: "t3", message_id: "m3", conversation_id: "1" },
    });

    await within(glass()).findByText("mensagem na fila");
    expect(rowsOf(events()).at(-1)).toContain("mensagem na fila");
  });
});

describe("FR-12 the glass box's own rows", () => {
  it("writes a row for a message the edge refused, with no model call (FR-14)", async () => {
    server.answers.messages.push({
      status: 429,
      body: {
        error: "limit",
        text: "Você chegou ao limite da demo por agora.",
      },
    });
    renderPage(<Chat />);
    await ready();

    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(
      await within(glass()).findByText("limite da demo"),
    ).toBeInTheDocument();
    expect(
      within(glass()).getByText("sem chamada ao modelo"),
    ).toBeInTheDocument();
  });

  it("writes a row for a message that waits for the turn ahead, until its own turn starts", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    server.answers.current.push(conversation(1, [], true, runningTurn("t1")));
    server.answers.messages.push({
      status: 202,
      body: { turn_id: "t2", message_id: "m2", conversation_id: "1" },
    });
    renderPage(<Chat />);
    await ready();
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "e a de gotas?" },
    });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(
      await within(glass()).findByText("mensagem na fila"),
    ).toBeInTheDocument();
    expect(
      within(glass()).getByText("espera o turno 1 terminar"),
    ).toBeInTheDocument();

    server.defaults.current = conversation(1, [], true, [
      ...answeredTurn("t1", { minute: 5 }),
      ...runningTurn("t2", 6),
    ]);
    await act(() => vi.advanceTimersByTimeAsync(3000));
    await waitFor(() => {
      expect(within(glass()).queryByText("mensagem na fila")).toBeNull();
    });
  });
});

describe("FR-12 the way to the conversation's trace page", () => {
  it("links the glass box to the page of the conversation's own trace", async () => {
    renderPage(<Chat />);
    await ready();

    const link = await within(glass()).findByRole("link", {
      name: pt.chat.glass.openTrace,
    });
    expect(link).toHaveAttribute("href", "/trace#t1");
  });
});

describe("FR-12 the glass box at 390 px", () => {
  it("stands as one line for the last turn, which opens the drawer and closes it with Escape", async () => {
    server.answers.current.push(
      conversation(1, [], false, [
        ...answeredTurn("t1", { minute: 3 }),
        ...commandTurn("t2", "trace"),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    const line = await screen.findByRole("button", {
      name: /turno 2 · 1 evento · 12 ms/,
    });
    expect(line).toHaveAttribute("aria-expanded", "false");
    expect(line).toHaveAttribute("aria-controls", "glass");

    fireEvent.click(line);
    expect(line).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("main")).toHaveAttribute("data-drawer");

    fireEvent.keyDown(document, { key: "Escape" });
    expect(line).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByRole("main")).not.toHaveAttribute("data-drawer");
  });

  it("says there is nothing yet on a first visit", async () => {
    renderPage(<Chat />);
    await ready();

    expect(
      await screen.findByRole("button", { name: /0 eventos/ }),
    ).toBeInTheDocument();
    expect(within(glass()).getByText(pt.chat.glass.empty)).toBeInTheDocument();
  });
});

describe("FR-01 the demo notice, stamped apart from the reply", () => {
  it("stamps the notice the server sent apart, with its label, before the reply's own words", async () => {
    server.answers.current.push(
      conversation(1, [
        message({ author: "visitor", body: "oi" }),
        message({
          author: "bot",
          notice:
            "Aviso: esta é uma demonstração de portfólio, com uma farmácia fictícia.",
          body: "Olá! Posso ajudar?",
        }),
      ]),
    );
    renderPage(<Chat />);
    await ready();

    const label = await within(thread()).findByText("Aviso:");
    expect(label.tagName).toBe("STRONG");
    const stamp = label.closest("li");
    expect(stamp).toHaveAttribute("data-voice", "stamp");
    expect(stamp).toHaveTextContent(/demonstração de portfólio/);
    const reply = within(thread())
      .getByText("Olá! Posso ajudar?")
      .closest("li");
    expect(reply).toHaveAttribute("data-voice", "attendant");
    expect(reply).not.toHaveTextContent("Aviso");
  });
});

describe("FR-18 the conversation's stream, with the polling as its fallback", () => {
  async function live() {
    const cable = fakeCable();
    renderPage(<Chat />, "pt-BR", cable.cable);
    await ready();
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });
    return cable;
  }

  it("follows the conversation's own stream once it knows the conversation", async () => {
    const cable = await live();

    expect(cable.active()[0]?.params).toEqual({
      channel: "ConversationChannel",
      conversation_id: "1",
    });
  });

  it("asks the server once when the stream connects, for what it carried before", async () => {
    const cable = await live();

    cable.connect();

    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });
  });

  it("draws a span the stream brings as it happens, without asking the server", async () => {
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });

    const [root, call] = runningTurn("t1");
    cable.send({ type: "span", span: root });
    cable.send({ type: "span", span: call });

    expect(
      await within(glass()).findByText("mensagem recebida"),
    ).toBeInTheDocument();
    expect(within(glass()).getByText("claude-opus-5-5")).toBeInTheDocument();
    expect(server.polls()).toHaveLength(2);
  });

  // FR-14: a turn the month's pause answered closes with its mode, and the
  // glass box's head follows it without asking the server.
  it("takes the month's mode a turn the stream closes recorded, after the turn's own charge", async () => {
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(within(glass()).getByText("normal")).toBeInTheDocument();
    });

    // The turn ran in normal mode and its charge reached the cap (review
    // finding C3 of pull request #29).
    const [root] = answeredTurn("t1", { mode: "normal", budgetMode: "paused" });
    if (root) cable.send({ type: "span", span: root });

    await waitFor(() => {
      expect(within(glass()).getByText("pausado")).toBeInTheDocument();
    });
  });

  it("keeps a pause the polling answered when a turn that started before it closes", async () => {
    server.defaults.current = conversation(1, [], false, [], {
      mode: "paused",
      brl: BRL,
    });
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(within(glass()).getByText("pausado")).toBeInTheDocument();
    });

    const [root] = answeredTurn("t1", { mode: "normal" });
    if (root) cable.send({ type: "span", span: root });
    await act(() => new Promise((resolve) => setTimeout(resolve, 50)));

    expect(within(glass()).getByText("pausado")).toBeInTheDocument();
  });

  // Design §10, note of 2026-11-13 on the chat's stream: the reply is drawn
  // from the stream, after the visitor's message the 202 brought as the
  // server stored it, with no request.
  describe("a reply the stream brings", () => {
    const texts = () =>
      within(thread())
        .getAllByRole("listitem")
        .map((item) => item.textContent.trim());

    async function asked(text = "tem dipirona?") {
      const cable = await live();
      cable.connect();
      await waitFor(() => {
        expect(server.polls()).toHaveLength(2);
      });
      fireEvent.change(screen.getByRole("textbox"), {
        target: { value: text },
      });
      fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
      // "pensando…" once the 202 brought the message as the server stored it.
      await within(thread()).findByText(pt.chat.thinking);
      return { cable, question: server.copy() };
    }

    it("is drawn after the visitor's message, without asking the server", async () => {
      const { cable, question } = await asked();

      cable.send({
        type: "message",
        message: replyTo(question, "Temos duas."),
      });

      expect(texts()).toEqual(["tem dipirona?", "Temos duas."]);
      expect(server.polls()).toHaveLength(2);
    });

    it("keeps the visitor's message on the element it was drawn on as it was sent", async () => {
      const cable = await live();
      cable.connect();
      await waitFor(() => {
        expect(server.polls()).toHaveLength(2);
      });
      fireEvent.change(screen.getByRole("textbox"), {
        target: { value: "tem dipirona?" },
      });
      fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
      const sent = within(thread()).getByText("tem dipirona?").closest("li");
      await within(thread()).findByText(pt.chat.thinking);

      cable.send({
        type: "message",
        message: replyTo(server.copy(), "Temos duas."),
      });

      expect(within(thread()).getByText("Temos duas.")).toBeInTheDocument();
      expect(within(thread()).getByText("tem dipirona?").closest("li")).toBe(
        sent,
      );
    });

    it("stops 'pensando…' and lights the tab's cross again", async () => {
      const icon = tabIcon();
      const { cable, question } = await asked();
      expect(icon.getAttribute("href")).not.toBe(LIT_ICON);

      cable.send({ type: "message", message: replyTo(question, "Temos.") });

      expect(within(thread()).queryByText(pt.chat.thinking)).toBeNull();
      expect(icon.getAttribute("href")).toBe(LIT_ICON);
    });

    it("stays when a fetch on its way answers with what was there before", async () => {
      const { cable, question } = await asked();
      let release: (value: Response) => void = () => undefined;
      // A reconnection's fetch, which the server answers late.
      server.fetch.mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            release = resolve;
          }),
      );
      const calls = server.fetch.mock.calls.length;
      cable.connect();
      await waitFor(() => {
        expect(server.fetch).toHaveBeenCalledTimes(calls + 1);
      });

      cable.send({ type: "message", message: replyTo(question, "Temos.") });
      release(
        new Response(JSON.stringify(conversation(1, [question], true).body), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }),
      );
      await act(() => Promise.resolve());

      expect(texts()).toEqual(["tem dipirona?", "Temos."]);
      expect(within(thread()).queryByText(pt.chat.thinking)).toBeNull();
    });

    it("makes the page ask when it answers a message the page does not hold, another tab's", async () => {
      const cable = await live();
      cable.connect();
      await waitFor(() => {
        expect(server.polls()).toHaveLength(2);
      });
      const other = message({
        author: "visitor",
        body: "tem entrega?",
        client_id: "c0ffee00-0000-4000-8000-000000000001",
        turn_id: "t7",
      });
      const answer = replyTo(other, "Entregamos sim.");
      server.answers.current.push(conversation(1, [other, answer]));

      cable.send({ type: "message", message: answer });

      expect(
        await within(thread()).findByText("tem entrega?"),
      ).toBeInTheDocument();
      expect(texts()).toEqual(["tem entrega?", "Entregamos sim."]);
      expect(server.polls()).toHaveLength(3);
    });

    it("makes the page ask when the message has no known shape", async () => {
      const cable = await live();
      cable.connect();
      await waitFor(() => {
        expect(server.polls()).toHaveLength(2);
      });

      cable.send({
        type: "message",
        message: { id: "m2", conversation_id: "1", body: "Temos duas." },
      });

      await waitFor(() => {
        expect(server.polls()).toHaveLength(3);
      });
      expect(within(thread()).queryByText("Temos duas.")).toBeNull();
    });

    // Review finding C1 of pull request #24: the fetch each reply made was
    // also the poll that answered, and so took away what earlier polls met.
    describe("ends what the earlier polls met, as an answer of the server", () => {
      const ask = async (text: string) => {
        fireEvent.change(screen.getByRole("textbox"), {
          target: { value: text },
        });
        fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
        await within(thread()).findByText(pt.chat.thinking);
      };

      it("so the next turn shows no limit the edge put on a poll before", async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        const { cable, question } = await asked();
        const limit = "Você chegou ao limite da demo por agora.";
        server.answers.current.push({
          status: 429,
          body: { error: "limit", text: limit },
        });
        await act(() => vi.advanceTimersByTimeAsync(15_000));
        expect(within(thread()).getByText(limit)).toBeInTheDocument();

        cable.send({ type: "message", message: replyTo(question, "Temos.") });
        await ask("e de gotas?");

        expect(within(thread()).queryByText(limit)).toBeNull();
      });

      it("so the next turn does not say the connection is lost", async () => {
        vi.useFakeTimers({ shouldAdvanceTime: true });
        const { cable, question } = await asked();
        server.answers.current.push("network", "network");
        await act(() => vi.advanceTimersByTimeAsync(30_000));
        expect(within(thread()).getByText(pt.chat.offline)).toBeInTheDocument();

        cable.send({ type: "message", message: replyTo(question, "Temos.") });
        await ask("e de gotas?");

        expect(within(thread()).queryByText(pt.chat.offline)).toBeNull();
      });
    });
  });

  it("does not ask every 3 s while the stream is live, and asks again every 3 s when it drops", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });
    server.defaults.current = conversation(1, [], true);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });

    await act(() => vi.advanceTimersByTimeAsync(9000));
    expect(server.polls()).toHaveLength(2);

    cable.drop();
    await act(() => vi.advanceTimersByTimeAsync(3000));
    expect(server.polls()).toHaveLength(3);
    await act(() => vi.advanceTimersByTimeAsync(3000));
    expect(server.polls()).toHaveLength(4);
  });

  it("still asks now and then while a turn waits on a live stream, for a reply whose broadcast failed", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });
    server.defaults.current = conversation(1, [], true);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });

    await act(() => vi.advanceTimersByTimeAsync(15_000));
    expect(server.polls()).toHaveLength(3);
  });

  it("moves to the next conversation's stream after a reset, and its glass box starts empty (FR-04)", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    const cable = fakeCable();
    renderPage(<Chat />, "pt-BR", cable.cable);
    await ready();
    await within(glass()).findByText("search_products");
    await waitFor(() => {
      expect(cable.active()).toHaveLength(1);
    });
    cable.connect();
    // The reset's reply opens the next conversation, on the stream of the
    // one it closed.
    const opened = message({
      author: "bot",
      body: "Pronto, começamos de novo.",
      conversation_id: 2,
      turn_id: "t-reset",
    });
    server.answers.current.push(conversation(2, [opened]));

    cable.send({ type: "message", message: opened });

    await waitFor(() => {
      expect(cable.active()[0]?.params).toEqual({
        channel: "ConversationChannel",
        conversation_id: "2",
      });
    });
    expect(cable.active()).toHaveLength(1);
    expect(within(glass()).queryByText("search_products")).toBeNull();
    expect(within(glass()).getByText(pt.chat.glass.empty)).toBeInTheDocument();
    expect(
      within(glass()).getByRole("link", { name: pt.chat.glass.openTrace }),
    ).toHaveAttribute("href", "/trace#t2");
  });

  it("shows only the confirmation when the stream says the data is gone (FR-05)", async () => {
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });
    server.defaults.current = {
      status: 200,
      body: { deleted: true, text: "Pronto: apaguei os seus dados." },
    };

    cable.send({ type: "deleted", text: "Pronto: apaguei os seus dados." });

    expect(
      await within(thread()).findByText("Pronto: apaguei os seus dados."),
    ).toBeInTheDocument();
    await waitFor(() => {
      expect(cable.active()).toHaveLength(0);
    });
  });

  // A fetch on its way when the data goes may answer with what was there
  // before: the stream's word stands, and that answer is dropped.
  it("drops a fetch that was on its way when the stream says the data is gone", async () => {
    server.answers.current.push(conversation(1, [], false, answeredTurn("t1")));
    const cable = await live();
    let release: (value: Response) => void = () => undefined;
    server.fetch.mockImplementationOnce(
      () =>
        new Promise<Response>((resolve) => {
          release = resolve;
        }),
    );
    cable.connect();
    await waitFor(() => {
      expect(server.fetch).toHaveBeenCalledTimes(3);
    });

    cable.send({ type: "deleted", text: "Pronto: apaguei os seus dados." });
    release(
      new Response(JSON.stringify(conversation(1, [], false).body), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    expect(
      await within(thread()).findByText("Pronto: apaguei os seus dados."),
    ).toBeInTheDocument();
    await act(() => Promise.resolve());
    expect(
      within(thread()).getByText("Pronto: apaguei os seus dados."),
    ).toBeInTheDocument();
  });

  // Review finding C1 of pull request #17: the 202 named a conversation the
  // page did not follow (FR-04's 24 hours), whose turn then came 15 s late.
  it("follows the stream of the conversation the server accepted the message into", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const cable = await live();
    cable.connect();
    await waitFor(() => {
      expect(server.polls()).toHaveLength(2);
    });
    server.answers.messages.push({
      status: 202,
      body: { turn_id: "t2", message_id: "m2", conversation_id: "2" },
    });
    server.defaults.current = conversation(2, [], true);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await waitFor(() => {
      expect(server.sent()).toHaveLength(1);
    });

    await act(() => vi.advanceTimersByTimeAsync(1000));
    expect(cable.active().at(-1)?.params).toEqual({
      channel: "ConversationChannel",
      conversation_id: "2",
    });
  });

  // Review finding C5 of pull request #17: a refused subscription was never
  // tried again.
  it("asks for the stream again a while after the server refused it", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const cable = await live();

    act(() => {
      cable.active()[0]?.handlers.rejected();
    });
    await act(() => vi.advanceTimersByTimeAsync(31_000));

    expect(cable.subscriptions.length).toBeGreaterThan(1);
    expect(cable.active()).toHaveLength(1);
  });

  // Review findings C9 and C11 of pull request #17.
  it("ignores a span that is no span, and counts a poll that finds nothing as failed", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true });
    const cable = await live();
    cable.send({ type: "span", span: null });
    expect(glass()).toBeInTheDocument();

    cable.drop();
    server.defaults.current = { status: 404, body: { error: "not_found" } };
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "oi" } });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await elapse(3000 + 6000 + 1000);

    expect(
      await within(thread()).findByText(pt.chat.offline),
    ).toBeInTheDocument();
  });

  it("ignores what is not one of the stream's events", async () => {
    const cable = await live();
    cable.connect();

    cable.send("<img src=x onerror=alert(1)>");
    cable.send({ type: "span" });
    cable.send(null);

    expect(within(glass()).getByText(pt.chat.glass.empty)).toBeInTheDocument();
  });
});
