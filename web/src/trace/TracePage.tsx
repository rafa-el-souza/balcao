import { useEffect } from "react";
import { Trans, useTranslation } from "react-i18next";

import { rateOf, type Trace } from "../chat/api";
import { Text } from "../chat/Thread";
import { cx } from "../ui/cx";
import { Cross, Icon } from "../ui/Icon";
import { LanguageSwitch } from "../ui/LanguageSwitch";
import parts from "../ui/parts.module.css";
import { useTabLamp } from "../ui/tabLamp";
import {
  formatDuration,
  formatTokens,
  TIME_ZONE,
  type Turn,
  turnsOf,
} from "./model";
import {
  Cost,
  costOf,
  RateContext,
  rowStyles,
  TurnRows,
  useTicking,
  useTurnLine,
} from "./Rows";
import styles from "./TracePage.module.css";
import { useToken, useTrace } from "./useTrace";

// The trace page, `/trace#<token>` (FR-12, design §6.7, §6.8;
// docs/prototype/trace.html and trace-expired.html): the glass box's rows at
// full length, on one receipt, every row closed, and live while the
// conversation goes on. For a WhatsApp conversation it is the only glass
// box. The words of the conversation stay in the counter's face: the
// visitor's beside the turn, the reply under its rows, and the turn's cost
// closes it; the foot totals the costs, the tokens and the turns' time
// (FR-12, FR-14). Hidden until their source exists: the status link (M3) and
// the privacy link (PR-17).

// A link outlives its day, so the title gives the day as well as the hour,
// in São Paulo's time.
function started(iso: string, locale: string) {
  const at = new Date(iso);
  const date = new Intl.DateTimeFormat(
    locale,
    locale === "en"
      ? { timeZone: TIME_ZONE, month: "short", day: "numeric" }
      : { timeZone: TIME_ZONE, day: "2-digit", month: "2-digit" },
  ).format(at);
  const time = new Intl.DateTimeFormat(locale, {
    timeZone: TIME_ZONE,
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(at);
  return { date, time };
}

function Masthead() {
  const { t } = useTranslation();
  return (
    <header className={cx(parts.letterhead, styles.masthead)}>
      <a className={parts.wordmark} href="/">
        <Cross />
        {t("app.name")}
      </a>
      <span className={styles.pageName}>{t("trace.pageName")}</span>
      <LanguageSwitch className={styles.langs} />
    </header>
  );
}

function TurnSection({ turn, trace }: { turn: Turn; trace: Trace }) {
  const { t } = useTranslation();
  const line = useTurnLine();
  const messages = trace.messages.filter(
    (message) => message.turn_id === turn.id,
  );
  const said = messages.find((message) => message.author === "visitor");
  const reply = messages.find((message) => message.author !== "visitor");
  return (
    <section className={styles.turn}>
      <h2 className={styles.turnHead}>
        <span className={styles.turnNumber}>
          {t("instrument.turn", { number: turn.number })}
        </span>{" "}
        {said && <span className={styles.said}>{said.body}</span>}{" "}
        <span className={styles.turnTime}>{line.time(turn)}</span>
      </h2>
      <ol className={rowStyles.events}>
        <TurnRows turn={turn} open={false} />
      </ol>
      {reply && (
        <div className={cx(styles.said, styles.reply)}>
          <Text text={reply.body} />
        </div>
      )}
      {turn.cost !== null && turn.cost > 0 && (
        <p className={styles.turnCost}>
          <span className={rowStyles.quiet}>{t("instrument.turnCost")}</span>{" "}
          <span>
            <Cost cost={turn.cost} />
          </span>
        </p>
      )}
    </section>
  );
}

function Roll({ trace, turns }: { trace: Trace; turns: Turn[] }) {
  const { t, i18n } = useTranslation();
  const sum = (pick: (turn: Turn) => number) =>
    turns.reduce((total, turn) => total + pick(turn), 0);
  const tokens = (n: number) => formatTokens(n, i18n.language);
  const time = formatDuration(
    sum((turn) => turn.durationMs ?? 0),
    i18n.language,
  );
  // The receipt's total is the cost, and the turns' time a line of its own;
  // a conversation with no cost to show totals its time (docs/prototype/
  // trace.html).
  const cost = costOf(turns);
  const priced = cost !== null && cost > 0;
  return (
    <section
      className={cx(parts.slip, styles.roll)}
      aria-label={t("trace.roll")}
    >
      {turns.map((turn) => (
        <TurnSection key={turn.id} turn={turn} trace={trace} />
      ))}
      <dl className={styles.total}>
        <div>
          <dt>{t("trace.total", { count: turns.length })}</dt>
          <dd>{priced ? <Cost cost={cost} /> : time}</dd>
        </div>
        <div>
          <dt>{t("trace.inputTokens")}</dt>
          <dd>
            {t("trace.inputValue", {
              total: tokens(sum((turn) => turn.input)),
              cached: tokens(sum((turn) => turn.cached)),
            })}
          </dd>
        </div>
        <div>
          <dt>{t("trace.outputTokens")}</dt>
          <dd>{tokens(sum((turn) => turn.output))}</dd>
        </div>
        {priced && (
          <div>
            <dt>{t("trace.turnsTime")}</dt>
            <dd>{time}</dd>
          </div>
        )}
      </dl>
    </section>
  );
}

export function TracePage() {
  const { t, i18n } = useTranslation();
  const token = useToken();
  const view = useTrace(token);
  const running =
    view.kind === "ok" && turnsOf(view.spans).some((turn) => turn.running);
  useTicking(running);
  // The tab's cross dims while a turn runs, as on the chat (design §10).
  useTabLamp(running);

  useEffect(() => {
    document.title = t("trace.title");
  }, [t]);

  let note;
  let body;
  if (view.kind === "gone") {
    note = (
      <>
        <h1>{t("trace.goneHeading")}</h1>
        <p>{t("trace.goneNote")}</p>
        <p className={styles.start}>
          <a href="/chat">
            {t("trace.startChat")} <Icon name="send" />
          </a>
        </p>
      </>
    );
  } else if (view.kind === "ok" && token !== null) {
    const turns = turnsOf(view.spans);
    const { date, time } = started(
      view.trace.conversation.started_at,
      i18n.language,
    );
    note = (
      <>
        <h1>
          <Trans
            i18nKey="trace.heading"
            count={turns.length}
            values={{ token: `${token.slice(0, 4)}…`, date, time }}
            components={{ token: <span className={styles.token} /> }}
          />
        </h1>
        <p>{t("trace.share")}</p>
      </>
    );
    body = (
      <RateContext value={rateOf(view.trace.brl)}>
        <Roll trace={view.trace} turns={turns} />
      </RateContext>
    );
  } else {
    note = <h1>{t("trace.loading")}</h1>;
    body =
      view.kind === "failed" ? (
        <section
          className={cx(parts.slip, styles.roll)}
          aria-label={t("trace.roll")}
        >
          <p className={styles.failed}>{t("trace.loadFailed")}</p>
        </section>
      ) : (
        <div className={cx(parts.slip, styles.roll, styles.loading)} />
      );
  }

  return (
    <div className={styles.page}>
      <Masthead />
      <main>
        <div className={styles.note}>{note}</div>
        {body}
      </main>
      <footer className={styles.foot}>
        <a href="/">
          <Icon name="back" /> {t("trace.home")}
        </a>
      </footer>
    </div>
  );
}
