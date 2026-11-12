import { useEffect } from "react";
import { useTranslation } from "react-i18next";

import { Icon } from "../ui/Icon";
import parts from "../ui/parts.module.css";
import { LanguageSwitch } from "../ui/LanguageSwitch";
import styles from "./Chat.module.css";
import { Composer } from "./Composer";
import { entriesOf } from "./conversation";
import { Thread } from "./Thread";
import { useConversation } from "./useConversation";

// The chat, `/chat` (design §6.7, §6.8; docs/prototype/chat*.html): the
// counter and, beside it, the instrument. This pull request draws the counter
// whole and the glass box's frame with its two commands; the glass box's rows,
// its drawer at 390 px and the live stream arrive with PR-11, the "pensando…"
// state with PR-12 (design §9.1). Hidden until their source exists: the
// pharmacist's presence (M2), the budget's mode (PR-16), the anti-bot line
// (Turnstile, after the MVP) and the "agendar" suggestion (FR-08, M2).
export function Chat() {
  const { t } = useTranslation();
  const {
    state,
    offline,
    refused,
    send,
    sendCommand,
    sendOpener,
    retry,
    changeLanguage,
  } = useConversation();
  const empty = entriesOf(state).length === 0;

  useEffect(() => {
    document.title = t("chat.title");
  }, [t]);

  const command = (name: "resetCommand" | "deleteCommand") => {
    sendCommand(t(`chat.glass.${name}`));
  };

  return (
    <main className={styles.chat}>
      <section className={styles.counter} aria-labelledby="chat-title">
        <h1 className={parts.visuallyHidden} id="chat-title">
          {t("chat.heading")}
        </h1>
        <header className={styles.counterHead}>
          <a className={styles.back} href="/">
            <Icon name="back" /> {t("app.name")}
          </a>
          <LanguageSwitch
            className={styles.counterLangs}
            onSwitch={changeLanguage}
          />
        </header>

        <Thread
          state={state}
          offline={offline}
          refused={refused}
          onOpener={sendOpener}
          onRetry={retry}
        />

        <div className={styles.counterFoot}>
          <Composer
            onSend={(text) => {
              void send({ text }, text);
            }}
          />
        </div>
      </section>

      <section className={styles.glass} aria-labelledby="glass-title">
        <header className={styles.glassHead}>
          <h2 id="glass-title">{t("chat.glass.title")}</h2>
          <LanguageSwitch
            variant="instrument"
            className={styles.glassLangs}
            onSwitch={changeLanguage}
          />
        </header>
        <div className={styles.glassBody}>
          {empty && (
            <p className={styles.glassEmpty}>{t("chat.glass.empty")}</p>
          )}
        </div>
        <div className={styles.glassActions}>
          <button
            type="button"
            className={styles.toolButton}
            onClick={() => {
              command("resetCommand");
            }}
          >
            <Icon name="reset" /> {t("chat.glass.reset")}
          </button>
          <button
            type="button"
            className={styles.toolButton}
            onClick={() => {
              command("deleteCommand");
            }}
          >
            <Icon name="bin" /> {t("chat.glass.delete")}
          </button>
        </div>
      </section>
    </main>
  );
}
