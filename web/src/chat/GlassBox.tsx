import { useTranslation } from "react-i18next";

import { type LocalRow, placeLocal, type Turn, turnsOf } from "../trace/model";
import { EventRow, rowStyles, TurnRows, useTurnLine } from "../trace/Rows";
import type { State } from "./conversation";

// What the glass box draws of the conversation (FR-12; docs/prototype/chat.html
// and chat-many-turns.html): for the visitor who stays two minutes and clicks
// nothing, the turn in progress and the last turn are open; the earlier ones
// fold into one line, which opens to one line per turn and each of those to
// its rows. The page adds its own rows for what the server did not trace: a
// message the edge refused (FR-14) and one that waits for the turn ahead.
export interface Glass {
  leading: LocalRow[];
  earlier: Turn[];
  open: Turn[];
  last: Turn | null;
}

function localRows(state: State, turns: Turn[]): LocalRow[] {
  const rows: LocalRow[] = [];
  for (const entry of state.own)
    if (entry.status === "limited" && entry.clientId && entry.at)
      rows.push({ kind: "limit", key: `x${entry.clientId}`, at: entry.at });

  // A message the server accepted while a turn runs waits, unrecorded, until
  // its own turn starts; then the server's received row takes its place.
  const running = turns.find((turn) => turn.running);
  if (!running) return rows;
  const traced = new Set(turns.map((turn) => turn.id));
  // The page's own messages were sent while it was open; a server's copy is
  // compared by the server's own hours (review finding C3 of pull request #17).
  const waiting = [
    ...state.own.flatMap((entry) =>
      entry.status === "sent" && entry.turnId && entry.at
        ? [{ turnId: entry.turnId, at: entry.at, own: true }]
        : [],
    ),
    ...state.server.flatMap((message) =>
      message.author === "visitor" && message.turn_id
        ? [{ turnId: message.turn_id, at: message.created_at, own: false }]
        : [],
    ),
  ];
  const queued = new Set<string>();
  for (const { turnId, at, own } of waiting) {
    if (traced.has(turnId) || queued.has(turnId)) continue;
    if (!own && Date.parse(at) < Date.parse(running.startedAt)) continue;
    queued.add(turnId);
    rows.push({
      kind: "queued",
      key: `q${turnId}`,
      at,
      waitsFor: running.number,
    });
  }
  return rows;
}

export function glassOf(state: State): Glass {
  const traced = turnsOf(state.spans);
  const { leading, turns } = placeLocal(traced, localRows(state, traced));
  const last = turns.at(-1) ?? null;
  const openCount = last?.running && turns.length > 1 ? 2 : last ? 1 : 0;
  return {
    leading,
    earlier: turns.slice(0, turns.length - openCount),
    open: turns.slice(turns.length - openCount),
    last,
  };
}

const eventsOf = (turn: Turn) => turn.rows.length + turn.local.length;

function Earlier({ turns }: { turns: Turn[] }) {
  const { t } = useTranslation();
  const line = useTurnLine();
  const [only] = turns;
  if (turns.length === 1 && only)
    return (
      <li className={rowStyles.turnGroup}>
        <details>
          <summary>
            <span className={rowStyles.name}>
              {line.number(only)} · {line.events(eventsOf(only))} ·{" "}
              {line.time(only)}
            </span>
          </summary>
          <ol className={rowStyles.nested}>
            <TurnRows turn={only} open={false} />
          </ol>
        </details>
      </li>
    );

  const events = turns.reduce((sum, turn) => sum + eventsOf(turn), 0);
  const time = turns.reduce((sum, turn) => sum + (turn.durationMs ?? 0), 0);
  return (
    <li className={rowStyles.turnGroup}>
      <details>
        <summary>
          <span className={rowStyles.name}>
            {t("instrument.earlier", { count: turns.length })} ·{" "}
            {line.events(events)} · {line.total(time)}
          </span>
        </summary>
        <ol className={rowStyles.nested}>
          {turns.map((turn) => (
            <li key={turn.id} className={rowStyles.turnLine}>
              <details>
                <summary>
                  <span className={rowStyles.name}>{line.number(turn)}</span>{" "}
                  <span className={rowStyles.stop}>
                    {line.events(eventsOf(turn))}
                  </span>{" "}
                  <span className={rowStyles.figure}>{line.time(turn)}</span>
                </summary>
                <ol className={rowStyles.nested}>
                  <TurnRows turn={turn} open={false} />
                </ol>
              </details>
            </li>
          ))}
        </ol>
      </details>
    </li>
  );
}

export function GlassRows({ glass }: { glass: Glass }) {
  const { t } = useTranslation();
  return (
    <ol className={rowStyles.events} aria-label={t("instrument.events_label")}>
      {glass.leading.map((row) => (
        <EventRow key={row.key} row={row} open />
      ))}
      {glass.earlier.length > 0 && <Earlier turns={glass.earlier} />}
      {glass.open.map((turn, index) => (
        <TurnRows key={turn.id} turn={turn} open separated={index > 0} />
      ))}
    </ol>
  );
}

// The line that stands for the glass box at 390 px: the last turn alone, its
// number, rows and time (docs/prototype/chat.html).
export function useSummary(glass: Glass): string {
  const line = useTurnLine();
  const { last } = glass;
  if (!last) return line.events(glass.leading.length);
  return `${line.number(last)} · ${line.events(eventsOf(last))} · ${line.time(last)}`;
}
