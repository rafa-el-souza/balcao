import { Fragment, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";

import openers from "../openers.json";
import { cx } from "../ui/cx";
import parts from "../ui/parts.module.css";
import styles from "./Chat.module.css";
import type { Content } from "./api";
import { type Entry, entriesOf, type State } from "./conversation";
import { isOpener, openerLang } from "./useConversation";

// The conversation's four voices, told apart by form and never by an avatar
// (design brief §5): the visitor's words are a slip handed over the counter,
// the attendant speaks in the page's own voice, the pharmacist's words carry
// a rule down their side, and the system's are a stamp.

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
      <Text text={entry.text} />
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
