import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";

import { useTicking, useTurnLine } from "../trace/Rows";
import { Icon } from "../ui/Icon";
import { LanguageSwitch } from "../ui/LanguageSwitch";
import parts from "../ui/parts.module.css";
import styles from "./Chat.module.css";
import { Composer } from "./Composer";
import { glassOf, GlassRows, useSummary } from "./GlassBox";
import { Thread } from "./Thread";
import { useConversation } from "./useConversation";

// The chat, `/chat` (design §6.7, §6.8; docs/prototype/chat*.html): the
// counter and, beside it, the instrument. The glass box shows the turn's rows
// as the server traces them (FR-12); at 390 px it folds into one line above
// the composer, which opens it as a drawer over the lower half. Hidden until
// their source exists: the pharmacist's presence (M2), the budget's mode and
// every cost (PR-16), the anti-bot line (Turnstile, after the MVP) and the
// "agendar" suggestion (FR-08, M2). While a turn waits the thread says
// "pensando…", and past ten seconds that the answer is taking longer (NFR-03,
// Thread.tsx).
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
  const glass = glassOf(state);
  const summary = useSummary(glass);
  const line = useTurnLine();
  useTicking(glass.open.some((turn) => turn.running));
  const empty = glass.last === null && glass.leading.length === 0;
  const [drawer, setDrawer] = useState(false);
  const opener = useRef<HTMLButtonElement>(null);
  const closer = useRef<HTMLButtonElement>(null);
  const rows = useRef<HTMLDivElement>(null);
  const foot = useRef<HTMLDivElement>(null);
  const instrument = useRef<HTMLElement>(null);
  // Read when the thread scrolls, so the reveal's identity never changes
  // with the drawer and a toggle scrolls nothing by itself.
  const drawerOpen = useRef(false);
  useEffect(() => {
    drawerOpen.current = drawer;
  }, [drawer]);
  // How much of the window's bottom stays over the thread, which the thread
  // keeps clear when it brings an entry into view: stacked, the counter's
  // foot, and the drawer while it is open (review findings V1 and R1 of pull
  // request #18). Beside the glass box neither covers the thread's column.
  const covered = useCallback(() => {
    const over = [foot.current, drawerOpen.current ? instrument.current : null]
      .filter((element) => element !== null)
      .map((element) => element.getBoundingClientRect().top);
    return over.length === 0
      ? 0
      : Math.max(0, window.innerHeight - Math.min(...over));
  }, []);

  useEffect(() => {
    document.title = t("chat.title");
  }, [t]);

  // A new row scrolls the glass box to itself.
  const count = glass.open.reduce(
    (sum, turn) => sum + turn.rows.length + turn.local.length,
    glass.earlier.length + glass.leading.length,
  );
  useEffect(() => {
    const last = rows.current?.querySelector("ol")?.lastElementChild;
    if (last && "scrollIntoView" in last) last.scrollIntoView({ block: "end" });
  }, [count]);

  const command = (name: "resetCommand" | "deleteCommand") => {
    sendCommand(t(`chat.glass.${name}`));
  };

  // The drawer opens over the lower half, so the conversation scrolls its
  // last entry into the upper one; closing it gives the focus back.
  const openDrawer = () => {
    setDrawer(true);
    window.requestAnimationFrame(() => {
      closer.current?.focus();
      const last = [...document.querySelectorAll("[data-voice]")].at(-1);
      if (last && typeof window.scrollBy === "function") {
        const { bottom } = last.getBoundingClientRect();
        window.scrollBy({ top: bottom - window.innerHeight / 2 });
      }
    });
  };
  const closeDrawer = () => {
    setDrawer(false);
    opener.current?.focus();
  };
  // Escape closes the open drawer.
  useEffect(() => {
    if (!drawer) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setDrawer(false);
      opener.current?.focus();
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
    };
  }, [drawer]);

  return (
    <main className={styles.chat} {...(drawer ? { "data-drawer": "" } : {})}>
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
          covered={covered}
          onOpener={sendOpener}
          onRetry={retry}
        />

        <div className={styles.counterFoot} ref={foot}>
          <button
            ref={opener}
            type="button"
            className={styles.summary}
            aria-controls="glass"
            aria-expanded={drawer}
            onClick={() => {
              if (drawer) closeDrawer();
              else openDrawer();
            }}
          >
            <span>{summary}</span>
            <span className={styles.summaryOpen}>
              <span className={parts.visuallyHidden}>
                {t("chat.glass.open")}
              </span>
            </span>
          </button>
          <Composer
            onSend={(text) => {
              void send({ text }, text);
            }}
          />
        </div>
      </section>

      <section
        ref={instrument}
        className={styles.glass}
        id="glass"
        aria-labelledby="glass-title"
      >
        <header className={styles.glassHead}>
          <h2 id="glass-title">{t("chat.glass.title")}</h2>
          <LanguageSwitch
            variant="instrument"
            className={styles.glassLangs}
            onSwitch={changeLanguage}
          />
          <button
            ref={closer}
            type="button"
            className={styles.glassClose}
            onClick={closeDrawer}
          >
            {t("chat.glass.close")}
          </button>
        </header>
        <div className={styles.glassBody} ref={rows}>
          {empty ? (
            <p className={styles.glassEmpty}>{t("chat.glass.empty")}</p>
          ) : (
            <GlassRows glass={glass} />
          )}
        </div>
        {glass.last && (
          <dl className={styles.totals}>
            <div>
              <dt>{line.number(glass.last)}</dt>
              <dd>{line.time(glass.last)}</dd>
            </div>
          </dl>
        )}
        <div className={styles.glassActions}>
          <button
            type="button"
            className={styles.toolButton}
            onClick={(event) => {
              // A double click's second press sends nothing (review finding R6).
              if (event.detail <= 1) command("resetCommand");
            }}
          >
            <Icon name="reset" /> {t("chat.glass.reset")}
          </button>
          <button
            type="button"
            className={styles.toolButton}
            onClick={(event) => {
              if (event.detail <= 1) command("deleteCommand");
            }}
          >
            <Icon name="bin" /> {t("chat.glass.delete")}
          </button>
          {state.traceToken && (
            <a
              className={styles.toolButton}
              href={`/trace#${encodeURIComponent(state.traceToken)}`}
            >
              <Icon name="receipt" /> {t("chat.glass.openTrace")}
            </a>
          )}
        </div>
      </section>
    </main>
  );
}
