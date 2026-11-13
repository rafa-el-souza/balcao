import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";

import { serverNow } from "../chat/api";

import ptBR from "../locales/pt-BR.json";
import { cx } from "../ui/cx";
import {
  formatClock,
  formatDuration,
  formatTokens,
  MAX_RESULT,
  type Row,
  type Turn,
} from "./model";
import styles from "./Rows.module.css";

// One row of the instrument (FR-12; docs/prototype/chat.html, trace.html): a
// model call closed is one line with where it stopped and its time, and opens
// to its model, effort, prompt, tokens and cache; a tool call opens to its
// arguments and its result as the server keeps it. Every cost waits for the
// usage records (PR-16): until a figure exists nothing stands in its place,
// never a zero.

// The server's error names, in words; a name the page does not know gets the
// plain one (docs/prototype/chat-fallback.html).
type ErrorWord =
  | "overloaded"
  | "rateLimit"
  | "timeout"
  | "connection"
  | "server"
  | "deadline"
  | "interrupted"
  | "other";
const ERRORS: Partial<Record<string, ErrorWord>> = {
  "Anthropic::Errors::OverloadedError": "overloaded",
  "Anthropic::Errors::RateLimitError": "rateLimit",
  "Anthropic::Errors::APITimeoutError": "timeout",
  "Anthropic::Errors::RequestTimeoutError": "timeout",
  "Anthropic::Errors::GatewayTimeoutError": "timeout",
  "Anthropic::Errors::APIConnectionError": "connection",
  "Anthropic::Errors::InternalServerError": "server",
  "Anthropic::Errors::ServiceUnavailableError": "server",
  "AgentRunner::DeadlineExceeded": "deadline",
  interrupted: "interrupted",
};

// A turn's outcome, when its reply is a fixed text: the server's list
// (TurnProcessor::OUTCOMES, app/models/turn_processor.rb) is the keys of these
// words, which spec/models/turn_outcomes_spec.rb holds equal, so a slice that
// adds or renames an outcome gives it words in the same pull request (design
// §10, note of 2026-11-12).
type Outcome = Exclude<keyof typeof ptBR.instrument.outcomes, "other">;
const isOutcome = (value: string): value is Outcome =>
  value !== "other" && Object.hasOwn(ptBR.instrument.outcomes, value);

// What a tool's list holds (app/agent/tools), in words.
const UNITS = ["products", "areas", "methods", "services"] as const;
type Unit = (typeof UNITS)[number];
const isUnit = (value: string): value is Unit =>
  (UNITS as readonly string[]).includes(value);

// The reason code of a tool's refusal, in words: the tools' lists
// (REASONS in app/agent/tools) are the keys of these words, which
// spec/agent/tool_refusals_spec.rb holds equal (docs/prototype/
// chat-tool-refused.html). A reason the page does not know says only that
// the tool refused.
type Reason = keyof typeof ptBR.instrument.tool.reasons;
const isReason = (value: string): value is Reason =>
  Object.hasOwn(ptBR.instrument.tool.reasons, value);

function CacheMark({ hit }: { hit: boolean }) {
  const { t } = useTranslation();
  return (
    <svg
      className={styles.tick}
      viewBox="0 0 12 12"
      role="img"
      aria-label={t(
        hit ? "instrument.detail.cacheHit" : "instrument.detail.cacheNone",
      )}
      {...(hit ? {} : { "data-miss": "" })}
    >
      <path
        d={hit ? "M1.5 6.5l3 3 6-7" : "M2 2l8 8M10 2l-8 8"}
        strokeWidth="1.6"
      />
    </svg>
  );
}

function Time({ at }: { at: string }) {
  const { i18n } = useTranslation();
  return <time dateTime={at}>{formatClock(at, i18n.language)}</time>;
}

function ModelRow({
  row,
  open,
  className,
}: {
  row: Extract<Row, { kind: "model" }>;
  open: boolean;
  className?: string | undefined;
}) {
  const { t, i18n } = useTranslation();
  const tokens = (n: number) => formatTokens(n, i18n.language);
  const time =
    row.latencyMs === null
      ? null
      : formatDuration(row.latencyMs, i18n.language);

  if (row.running || row.error) {
    const error = row.error
      ? t(`instrument.errors.${ERRORS[row.error] ?? "other"}`)
      : null;
    return (
      <li
        className={cx(styles.event, className)}
        data-state={row.error ? "error" : "running"}
      >
        <Time at={row.at} />
        <div className={styles.what}>
          <span className={styles.name}>{t("instrument.model")}</span>{" "}
          {row.model && <span className={styles.value}>{row.model}</span>}{" "}
          <span className={styles.figure}>
            {row.running ? t("instrument.running") : time}
          </span>
          <dl className={styles.detail}>
            {row.effort && (
              <div>
                <dt>{t("instrument.detail.effort")}</dt>
                <dd>{row.effort}</dd>
              </div>
            )}
            {error && (
              <div>
                <dt>{t("instrument.detail.error")}</dt>
                <dd>{error}</dd>
              </div>
            )}
          </dl>
        </div>
      </li>
    );
  }

  const read = row.cacheRead ?? 0;
  const written = row.cacheWrite ?? 0;
  return (
    <li className={cx(styles.event, className)}>
      <Time at={row.at} />
      <details className={styles.what} open={open}>
        <summary>
          <span className={styles.name}>{t("instrument.model")}</span>{" "}
          {row.stop && (
            <span className={styles.stop}>
              {t("instrument.stop", { reason: row.stop })}
            </span>
          )}{" "}
          {time && <span className={styles.figure}>{time}</span>}
        </summary>
        <dl className={styles.detail}>
          {row.model && (
            <div>
              <dt>{t("instrument.detail.model")}</dt>
              <dd>{row.model}</dd>
            </div>
          )}
          {row.effort && (
            <div>
              <dt>{t("instrument.detail.effort")}</dt>
              <dd>{row.effort}</dd>
            </div>
          )}
          {row.prompt && (
            <div>
              <dt>{t("instrument.detail.prompt")}</dt>
              <dd>
                {t("instrument.detail.promptValue", {
                  size: tokens(row.prompt.characters),
                  digest: row.prompt.digest,
                })}
              </dd>
            </div>
          )}
          {row.input !== null && (
            <div>
              <dt>{t("instrument.detail.input")}</dt>
              <dd>{tokens(row.input)}</dd>
            </div>
          )}
          {(row.cacheRead !== null || row.cacheWrite !== null) && (
            <div>
              <dt>{t("instrument.detail.cache")}</dt>
              <dd>
                <span
                  className={styles.cache}
                  data-cache={read > 0 ? "hit" : "miss"}
                >
                  <CacheMark hit={read > 0} />{" "}
                  {read > 0
                    ? t("instrument.detail.cacheRead", {
                        read: tokens(read),
                        written: tokens(written),
                      })
                    : t("instrument.detail.cacheMiss", {
                        written: tokens(written),
                      })}
                </span>
              </dd>
            </div>
          )}
          {row.output !== null && (
            <div>
              <dt>{t("instrument.detail.output")}</dt>
              <dd>{tokens(row.output)}</dd>
            </div>
          )}
        </dl>
      </details>
    </li>
  );
}

function ToolRow({
  row,
  open,
  className,
}: {
  row: Extract<Row, { kind: "tool" }>;
  open: boolean;
  className?: string | undefined;
}) {
  const { t, i18n } = useTranslation();
  const time =
    row.latencyMs === null
      ? null
      : formatDuration(row.latencyMs, i18n.language);
  const cut = row.characters !== null && row.characters > MAX_RESULT;
  const counted =
    !row.failed && row.count !== null && row.unit !== null && isUnit(row.unit)
      ? t(`instrument.tool.units.${row.unit}`, { count: row.count })
      : null;
  // A rule the tool enforces is not a failure: it keeps the instrument's own
  // ink, and only a failure takes the error colour.
  const refused = row.failed && row.refusal !== null;
  const outcome = refused
    ? row.refusal !== null && isReason(row.refusal)
      ? t("instrument.tool.refusedFor", {
          reason: t(`instrument.tool.reasons.${row.refusal}`),
        })
      : t("instrument.tool.refused")
    : row.failed
      ? t("instrument.tool.failed")
      : row.reservation !== null
        ? t("instrument.tool.reservation", { code: row.reservation })
        : counted;

  return (
    <li
      className={cx(styles.event, className)}
      {...(row.failed ? { "data-state": refused ? "refused" : "error" } : {})}
    >
      <Time at={row.at} />
      <details className={styles.what} open={open}>
        <summary>
          <span className={styles.name}>{row.name}</span>{" "}
          <span className={styles.figure}>
            {row.running ? t("instrument.running") : time}
          </span>
        </summary>
        {row.args !== null && <pre className={styles.payload}>{row.args}</pre>}
        {row.result !== null && (
          <pre
            className={styles.payload}
            {...(row.failed ? { lang: "en" } : {})}
          >
            {row.result}
          </pre>
        )}
        {(outcome !== null || cut) && (
          <p className={styles.outcome}>
            {outcome}
            {cut && (
              <>
                {" "}
                <span className={styles.cut}>
                  {t("instrument.tool.cut", { max: MAX_RESULT })}
                </span>
              </>
            )}
          </p>
        )}
      </details>
    </li>
  );
}

export function EventRow({
  row,
  open,
  className,
}: {
  row: Row;
  open: boolean;
  className?: string | undefined;
}) {
  const { t, i18n } = useTranslation();
  switch (row.kind) {
    case "model":
      return <ModelRow row={row} open={open} className={className} />;
    case "tool":
      return <ToolRow row={row} open={open} className={className} />;
    case "received":
      return (
        <li className={cx(styles.event, className)}>
          <Time at={row.at} />
          <div className={styles.what}>
            <span className={styles.name}>{t("instrument.received")}</span>
          </div>
        </li>
      );
    case "sent":
      return (
        <li className={cx(styles.event, className)}>
          <Time at={row.at} />
          <div className={styles.what}>
            <span className={styles.name}>{t("instrument.sent")}</span>
            {row.outcome && (
              <dl className={styles.detail}>
                <div>
                  <dt>{t("instrument.detail.fixedReply")}</dt>
                  <dd>
                    {t(
                      `instrument.outcomes.${isOutcome(row.outcome) ? row.outcome : "other"}`,
                    )}
                  </dd>
                </div>
              </dl>
            )}
          </div>
        </li>
      );
    case "command":
      return (
        <li className={cx(styles.event, className)}>
          <Time at={row.at} />
          <div className={styles.what}>
            <span className={styles.name}>{t("instrument.command")}</span>{" "}
            <span className={styles.value}>{row.name}</span>{" "}
            {row.durationMs !== null && (
              <span className={styles.figure}>
                {formatDuration(row.durationMs, i18n.language)}
              </span>
            )}
          </div>
        </li>
      );
    case "limit":
      return (
        <li
          className={cx(styles.event, styles.turnStart, className)}
          data-state="local"
        >
          <Time at={row.at} />
          <div className={styles.what}>
            <span className={styles.name}>{t("instrument.limit")}</span>
            <p className={styles.outcome}>{t("instrument.limitNote")}</p>
          </div>
        </li>
      );
    case "queued":
      return (
        <li
          className={cx(styles.event, styles.turnStart, className)}
          data-state="local"
        >
          <Time at={row.at} />
          <div className={styles.what}>
            <span className={styles.name}>{t("instrument.queued")}</span>
            <p className={styles.outcome}>
              {t("instrument.queuedWait", { number: row.waitsFor })}
            </p>
          </div>
        </li>
      );
  }
}

// A turn's rows, then the page's own rows that came after it started.
export function TurnRows({
  turn,
  open,
  separated = false,
}: {
  turn: Turn;
  open: boolean;
  separated?: boolean;
}) {
  return (
    <>
      {turn.rows.map((row, index) => (
        <EventRow
          key={row.key}
          row={row}
          open={open}
          className={separated && index === 0 ? styles.turnStart : undefined}
        />
      ))}
      {turn.local.map((row) => (
        <EventRow key={row.key} row={row} open={open} />
      ))}
    </>
  );
}

// The words of a turn's line: its number, its rows and its time. While the
// turn runs, its time counts up from its receipt by the server's clock
// (docs/prototype/chat-queued.html; review finding C4 of pull request #17).
export function useTurnLine() {
  const { t, i18n } = useTranslation();
  return {
    number: (turn: Turn) => t("instrument.turn", { number: turn.number }),
    events: (count: number) => t("instrument.events", { count }),
    time: (turn: Turn) =>
      turn.durationMs === null
        ? `${formatDuration(Math.max(0, serverNow() - Date.parse(turn.startedAt)), i18n.language)} ${t("instrument.running")}`
        : formatDuration(turn.durationMs, i18n.language),
    total: (ms: number) => formatDuration(ms, i18n.language),
  };
}

// Draws again every tenth of a second while a turn runs, so its time counts.
export function useTicking(active: boolean) {
  const [, setTick] = useState(0);
  useEffect(() => {
    if (!active) return;
    const timer = window.setInterval(() => {
      setTick((tick) => tick + 1);
    }, 100);
    return () => {
      window.clearInterval(timer);
    };
  }, [active]);
}

export const rowStyles = styles;
