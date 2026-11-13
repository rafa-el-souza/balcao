import { Fragment, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";

import openers from "../openers.json";
import { cx } from "../ui/cx";
import { Cross } from "../ui/Icon";
import parts from "../ui/parts.module.css";
import styles from "./Chat.module.css";
import { type Content, serverNow } from "./api";
import {
  awaiting,
  type Entry,
  entriesOf,
  type State,
  waitingSince,
} from "./conversation";
import { isOpener, openerLang } from "./useConversation";

// The conversation's four voices, told apart by form and never by an avatar
// (design brief §5): the visitor's words are a slip handed over the counter,
// the attendant speaks in the page's own voice, the pharmacist's words carry
// a rule down their side, and the system's are a stamp.

// FR-01's notice opens with its label ("Aviso:"), which the stamp sets in
// bold, as the drawing does; the rest is plain text.
function Notice({ text }: { text: string }) {
  const colon = text.indexOf(": ");
  if (colon < 1) return <Text text={text} />;
  return (
    <p>
      <strong>{text.slice(0, colon + 1)}</strong> {text.slice(colon + 2)}
    </p>
  );
}

// Plain text with its line breaks (design §6.9, threat model SR-03): a blank
// line opens a paragraph, a single one breaks the line. Nothing is markup.
export function Text({ text }: { text: string }) {
  return text
    .split(/\n{2,}/)
    .filter((paragraph) => paragraph.trim() !== "")
    .map((paragraph, index) => (
      <p key={index}>
        {paragraph.split("\n").map((line, at) => (
          <Fragment key={at}>
            {at > 0 && <br />}
            {line}
          </Fragment>
        ))}
      </p>
    ));
}

// NFR-03: past ten seconds of waiting (NFR-01's p95), the attendant says the
// answer is taking longer.
export const SLOW_MS = 10_000;

// How often the page reads the server's clock while the note is due. A
// timer set for the deadline itself could fire before it by that clock, which
// is the browser's moved by a fraction of a millisecond that a timer drops, or
// moved back by a later answer (review finding C2 of pull request #18).
const SLOW_CHECK_MS = 250;

// Whether the wait that began at `since` has passed SLOW_MS, by the server's
// clock, read every SLOW_CHECK_MS until it has.
function useSlow(since: string | null): boolean {
  const due = since === null ? null : Date.parse(since) + SLOW_MS;
  const [now, setNow] = useState(serverNow);
  const slow = due !== null && now >= due;
  useEffect(() => {
    if (due === null || slow) return;
    const timer = window.setInterval(() => {
      setNow(serverNow());
    }, SLOW_CHECK_MS);
    return () => {
      window.clearInterval(timer);
    };
  }, [due, slow]);
  return slow;
}

// While a turn runs, the pharmacy's cross breathes beside "pensando…" as a
// lamp does, and stays lit and still for reduced motion
// (docs/prototype/chat-thinking.html); one for the whole wait, however many
// messages wait (chat-queued.html).
function Thinking({ since }: { since: string | null }) {
  const { t } = useTranslation();
  const slow = useSlow(since);
  return (
    <li
      className={cx(styles.msg, styles.attendant, styles.thinking)}
      data-voice="attendant"
    >
      <p>
        <Cross className={styles.lamp} /> {t("chat.thinking")}
      </p>
      {slow && <p>{t("chat.slow")}</p>}
    </li>
  );
}

const VOICE_CLASS = {
  visitor: styles.visitor,
  attendant: styles.attendant,
  pharmacist: styles.pharmacist,
  stamp: cx(styles.notice, parts.stamp),
} as const;

function Message({
  entry,
  onRetry,
}: {
  entry: Entry;
  onRetry: (clientId: string, content: Content) => void;
}) {
  const { t } = useTranslation();
  const { clientId, content } = entry;
  const failed = entry.status === "failed" && clientId && content;

  return (
    <li
      className={cx(styles.msg, VOICE_CLASS[entry.voice])}
      data-voice={entry.voice}
      {...(entry.lang ? { lang: entry.lang } : {})}
    >
      {entry.notice ? <Notice text={entry.text} /> : <Text text={entry.text} />}
      {failed && (
        <p className={styles.failed}>
          {t("chat.failed")} ·{" "}
          <button
            type="button"
            className={styles.retry}
            onClick={() => {
              onRetry(clientId, content);
            }}
          >
            {t("chat.retry")}
          </button>
        </p>
      )}
    </li>
  );
}

export function Thread({
  state,
  offline,
  refused,
  onOpener,
  onRetry,
}: {
  state: State;
  offline: boolean;
  refused: string | null;
  onOpener: (key: keyof typeof openers) => void;
  onRetry: (clientId: string, content: Content) => void;
}) {
  const { t } = useTranslation();
  const list = useRef<HTMLOListElement>(null);
  const entries = entriesOf(state);
  const firstVisit =
    state.phase === "ready" && state.deleted === null && entries.length === 0;

  // A new message scrolls its own column to itself.
  useEffect(() => {
    const last = list.current?.lastElementChild;
    if (last && "scrollIntoView" in last)
      last.scrollIntoView({ block: "end", behavior: "smooth" });
  }, [entries.length]);

  return (
    <ol
      ref={list}
      className={styles.thread}
      aria-label={t("chat.conversation")}
      aria-live="polite"
    >
      {state.phase === "failed" && (
        <li className={cx(styles.msg, VOICE_CLASS.stamp)} data-voice="stamp">
          <p>{t("chat.loadFailed")}</p>
        </li>
      )}
      {firstVisit && (
        <>
          <li
            className={cx(styles.msg, styles.attendant)}
            data-voice="attendant"
          >
            <p>{t("chat.greeting")}</p>
          </li>
          <li className={cx(styles.msg, styles.openers)}>
            <ul className={parts.chips}>
              {Object.entries(openers).map(([key, opener]) =>
                isOpener(key) ? (
                  <li key={key}>
                    <button
                      type="button"
                      className={parts.chip}
                      lang={openerLang(key)}
                      onClick={() => {
                        onOpener(key);
                      }}
                    >
                      {opener.text}
                    </button>
                  </li>
                ) : null,
              )}
            </ul>
          </li>
        </>
      )}
      {entries.map((entry) => (
        <Message key={entry.key} entry={entry} onRetry={onRetry} />
      ))}
      {awaiting(state) && <Thinking since={waitingSince(state)} />}
      {refused !== null && (
        <li className={cx(styles.msg, VOICE_CLASS.stamp)} data-voice="stamp">
          <p>{refused}</p>
        </li>
      )}
      {offline && (
        <li className={cx(styles.msg, VOICE_CLASS.stamp)} data-voice="stamp">
          <p>{t("chat.offline")}</p>
        </li>
      )}
    </ol>
  );
}
