import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";

import openers from "../openers.json";
import { cx } from "../ui/cx";
import { Cross } from "../ui/Icon";
import parts from "../ui/parts.module.css";
import { useTabLamp } from "../ui/tabLamp";
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

// A reservation's code where a reply writes it, as a small stamp in the
// instrument's face, since it is what the visitor shows at the counter
// (FR-07; docs/prototype/chat-reservation.html). The codes are those the
// server lists for the reply (codesOf in conversation.ts), letters and digits
// alone, so each is its own pattern; a code inside a longer word is not one.
function stamped(line: string, marks: readonly string[]) {
  if (marks.length === 0) return line;
  return line
    .split(new RegExp(`\\b(${marks.join("|")})\\b`))
    .map((part, index) =>
      index % 2 === 1 ? (
        <strong key={index} className={styles.code}>
          {part}
        </strong>
      ) : (
        part
      ),
    );
}

// Plain text with its line breaks (design §6.9, threat model SR-03): a blank
// line opens a paragraph, a single one breaks the line. Nothing is markup;
// only the codes given are stamped.
export function Text({
  text,
  marks = [],
}: {
  text: string;
  marks?: readonly string[];
}) {
  return text
    .split(/\n{2,}/)
    .filter((paragraph) => paragraph.trim() !== "")
    .map((paragraph, index) => (
      <p key={index}>
        {paragraph.split("\n").map((line, at) => (
          <Fragment key={at}>
            {at > 0 && <br />}
            {stamped(line, marks)}
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
function Thinking({
  since,
  onSlow,
}: {
  since: string | null;
  onSlow: () => void;
}) {
  const { t } = useTranslation();
  const slow = useSlow(since);
  // The note grows the entry: the thread's end, with any stamp after it, is
  // brought into view again (review findings C1 and V2 of pull request #18).
  useEffect(() => {
    if (slow) onSlow();
  }, [slow, onSlow]);
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
      {entry.notice ? (
        <Notice text={entry.text} />
      ) : (
        <Text
          text={entry.text}
          {...(entry.marks ? { marks: entry.marks } : {})}
        />
      )}
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
  covered,
  onOpener,
  onRetry,
}: {
  state: State;
  offline: boolean;
  refused: string | null;
  // How much of the window's bottom the page keeps over the thread.
  covered: () => number;
  onOpener: (key: keyof typeof openers) => void;
  onRetry: (clientId: string, content: Content) => void;
}) {
  const { t } = useTranslation();
  const list = useRef<HTMLOListElement>(null);
  const entries = entriesOf(state);
  const firstVisit =
    state.phase === "ready" && state.deleted === null && entries.length === 0;
  const waiting = awaiting(state);
  // The tab's cross dims with the one beside "pensando…" (design §10).
  useTabLamp(waiting);

  // Brings an entry of the thread into view. Beside the glass box the thread
  // scrolls in its own column; stacked, the window scrolls and the composer's
  // foot, with the drawer while it is open, stays over its bottom, so the
  // window keeps that height clear (review findings V1 and R1 of pull request
  // #18), for this scroll alone: left on the root, the padding would move the
  // window whenever a control in the foot takes the focus, and outlive the
  // layout it measured (R2 and V4). The scroll keeps the destination it was
  // given when the padding goes.
  const reveal = useCallback(
    (element: Element | null | undefined) => {
      if (!element || !("scrollIntoView" in element)) return;
      const root = document.documentElement.style;
      root.scrollPaddingBottom = `${String(covered())}px`;
      element.scrollIntoView({ block: "end", behavior: "smooth" });
      root.scrollPaddingBottom = "";
    },
    [covered],
  );

  // What the thread ends with scrolls its column to itself: a new message,
  // "pensando…" when it appears (review finding C1 of pull request #18) and
  // the stamps of a limit or a lost connection (V2).
  const tail = `${String(entries.length)}:${String(waiting)}:${String(offline)}:${refused ?? ""}`;
  const revealEnd = useCallback(() => {
    reveal(list.current?.lastElementChild);
  }, [reveal]);
  useEffect(revealEnd, [tail, revealEnd]);

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
      {waiting && <Thinking since={waitingSince(state)} onSlow={revealEnd} />}
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
