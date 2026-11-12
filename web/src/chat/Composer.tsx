import {
  type KeyboardEvent,
  useId,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";

import { Icon } from "../ui/Icon";
import parts from "../ui/parts.module.css";
import styles from "./Chat.module.css";

// FR-18: a message holds at most 1,000 characters, and the page says so.
export const MAX_TEXT = 1000;
const COUNT_FROM = 800;

const SUGGESTIONS = ["reserve", "pharmacist"] as const;

// The browsers without `field-sizing` (docs/prototype notes: "needs a plan
// B") grow the field by script, up to the six lines its CSS allows.
const sizesItself = () =>
  typeof CSS !== "undefined" && CSS.supports("field-sizing", "content");

export function Composer({ onSend }: { onSend: (text: string) => void }) {
  const { t, i18n } = useTranslation();
  const [text, setText] = useState("");
  const field = useRef<HTMLTextAreaElement>(null);
  const countId = useId();
  const number = new Intl.NumberFormat(i18n.language);
  const count =
    text.length > COUNT_FROM
      ? t("chat.composer.count", {
          count: number.format(text.length),
          max: number.format(MAX_TEXT),
        })
      : null;
  const full = text.length >= MAX_TEXT;

  // The count is announced when it appears and at the limit, not at every key:
  // the live region changes only when the field crosses one of the two marks.
  const phase = full ? "full" : count !== null ? "counting" : "quiet";
  const [announcedPhase, setAnnouncedPhase] = useState(phase);
  const [announced, setAnnounced] = useState("");
  if (phase !== announcedPhase) {
    setAnnouncedPhase(phase);
    setAnnounced(count ?? "");
  }

  useLayoutEffect(() => {
    const element = field.current;
    if (!element || sizesItself()) return;
    element.style.height = "auto";
    element.style.height = `${String(element.scrollHeight)}px`;
  }, [text]);

  const submit = () => {
    const message = text.trim();
    if (message === "") return;
    onSend(message);
    setText("");
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (
      event.key !== "Enter" ||
      event.shiftKey ||
      event.nativeEvent.isComposing
    )
      return;
    event.preventDefault();
    submit();
  };

  return (
    <form
      className={styles.composer}
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <div className={styles.composerRow}>
        <label className={parts.visuallyHidden} htmlFor="message">
          {t("chat.composer.label")}
        </label>
        <textarea
          ref={field}
          id="message"
          rows={1}
          maxLength={MAX_TEXT}
          autoComplete="off"
          placeholder={t("chat.composer.placeholder")}
          value={text}
          {...(count !== null ? { "aria-describedby": countId } : {})}
          onChange={(event) => {
            setText(event.target.value);
          }}
          onKeyDown={onKeyDown}
        />
        <div className={styles.composerSide}>
          {count !== null && (
            <span
              className={styles.count}
              id={countId}
              {...(full ? { "data-full": "" } : {})}
            >
              {count}
            </span>
          )}
          <button type="submit" className={styles.send}>
            {t("chat.composer.send")} <Icon name="send" />
          </button>
        </div>
      </div>
      <p className={parts.visuallyHidden} role="status">
        {announced}
      </p>
      <p className={styles.suggest}>
        <span className={styles.suggestLabel}>
          {t("chat.composer.suggestions")}
        </span>
        {SUGGESTIONS.map((name) => (
          <button
            key={name}
            type="button"
            className={styles.suggestion}
            onClick={() => {
              setText(t(`chat.composer.${name}Text`));
              field.current?.focus();
            }}
          >
            {t(`chat.composer.${name}`)}
          </button>
        ))}
      </p>
    </form>
  );
}
