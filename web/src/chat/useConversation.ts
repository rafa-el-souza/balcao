import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";

import { isLocale, DEFAULT_LOCALE, type Locale } from "../locale";
import openers from "../openers.json";
import { createApi, type Content } from "./api";
import { awaiting, initialState, reduce } from "./conversation";

// FR-18's polling, every 3 s: the way the reply reaches the page until the
// cable client arrives with the glass box (design §9.1, PR-11), and its
// fallback after that. Three seconds keep a waiting page at 20 of the 60
// requests a minute FR-14 allows a visitor.
export const POLL_MS = 3000;
// A poll that fails, the edge's refusal included (which the edge counts too),
// doubles the wait, up to half a minute; one that answers brings it back to
// 3 s (review finding C5 of pull request #14).
export const POLL_MAX_MS = 30_000;

type OpenerKey = keyof typeof openers;
const LANG = { pt: "pt-BR", en: "en", es: "es" } as const;

export function isOpener(key: string | null): key is OpenerKey {
  return key !== null && Object.hasOwn(openers, key);
}

export function openerLang(key: OpenerKey): string {
  return LANG[openers[key].lang as keyof typeof LANG];
}

// Takes ?say= off the address before anything else, so a reload or the back
// button never sends the opener twice (FR-21); only an allow-listed key is
// kept, anything else is dropped and nothing is sent (SR-34).
function takeSay(): OpenerKey | null {
  const url = new URL(window.location.href);
  if (!url.searchParams.has("say")) return null;
  const key = url.searchParams.get("say");
  url.searchParams.delete("say");
  window.history.replaceState(window.history.state, "", url);
  return isOpener(key) ? key : null;
}

export function useConversation() {
  const { i18n } = useTranslation();
  const [state, dispatch] = useReducer(reduce, initialState);
  const [polled, setPolled] = useState(0);
  const [pollDelay, setPollDelay] = useState(POLL_MS);
  // Polls failed in a row: from the second, the page says the connection is
  // lost (review finding V1 of pull request #14).
  const [pollFailures, setPollFailures] = useState(0);

  // The page's language at the moment of each request: the switch changes it
  // before it tells the conversation.
  const language = useCallback(
    (): Locale => (isLocale(i18n.language) ? i18n.language : DEFAULT_LOCALE),
    [i18n],
  );
  const api = useMemo(() => createApi(language), [language]);

  // One session request at a time, and messages only after the one in
  // flight: two requests without a cookie would mint two visitors, and the
  // last cookie to arrive would leave the page's message under the other
  // (review finding C4 of pull request #14).
  const sessions = useRef<Promise<unknown>>(Promise.resolve());
  const session = useCallback(
    (locale: Locale) => {
      const next = sessions.current.then(async () => {
        const opened = await api.session(locale);
        if (opened.kind === "ok")
          dispatch({
            type: "session",
            conversationId: opened.value.conversation_id,
          });
        return opened;
      });
      sessions.current = next.catch(() => undefined);
      return next;
    },
    [api],
  );

  const refresh = useCallback(async () => {
    const answer = await api.current();
    if (answer.kind === "ok")
      dispatch({ type: "snapshot", answer: answer.value });
    return answer.kind === "ok";
  }, [api]);

  const deliver = useCallback(
    async (clientId: string, content: Content) => {
      await sessions.current;
      let outcome = await api.send(clientId, content);
      if (outcome.kind === "session") {
        const renewed = await session(language());
        // A refused session is the edge's limit, said with its own text
        // (review finding C6 of pull request #14).
        outcome =
          renewed.kind === "ok"
            ? await api.send(clientId, content)
            : renewed.kind === "limit"
              ? renewed
              : outcome;
      }
      if (outcome.kind === "ok")
        dispatch({
          type: "accepted",
          clientId,
          conversationId: outcome.value.conversation_id,
        });
      else if (outcome.kind === "limit")
        dispatch({ type: "limited", clientId, text: outcome.text });
      else dispatch({ type: "failed", clientId });
    },
    [api, language, session],
  );

  const send = useCallback(
    (content: Content, text: string, lang?: string) => {
      const clientId = crypto.randomUUID();
      dispatch({
        type: "sending",
        clientId,
        content,
        text,
        ...(lang ? { lang } : {}),
      });
      return deliver(clientId, content);
    },
    [deliver],
  );

  // The glass box's commands, once per press: a second press while the first
  // is on its way sends nothing, or a double click would reset or delete
  // twice (review finding C8 of pull request #14).
  const commands = useRef(new Set<string>());
  const sendCommand = useCallback(
    (text: string) => {
      if (commands.current.has(text)) return;
      commands.current.add(text);
      void send({ text }, text).finally(() => {
        commands.current.delete(text);
      });
    },
    [send],
  );

  const sendOpener = useCallback(
    (key: OpenerKey) => {
      void send({ say: key }, openers[key].text, openerLang(key));
    },
    [send],
  );

  const retry = useCallback(
    (clientId: string, content: Content) => {
      dispatch({ type: "retrying", clientId });
      void deliver(clientId, content);
    },
    [deliver],
  );

  // The language of a conversation not yet answered follows the page's (FR-02).
  const changeLanguage = useCallback(
    (locale: Locale) => {
      void session(locale);
    },
    [session],
  );

  // Once per page load, even when React mounts twice in development.
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const say = takeSay();
    void (async () => {
      const opened = await session(language());
      if (opened.kind === "limit") {
        dispatch({ type: "limited", clientId: null, text: opened.text });
        dispatch({ type: "loaded" });
        return;
      }
      if (opened.kind !== "ok") {
        dispatch({ type: "loadFailed" });
        return;
      }
      if (say) sendOpener(say);
      if (!(await refresh())) dispatch({ type: "loadFailed" });
      dispatch({ type: "loaded" });
    })();
  }, [language, refresh, sendOpener, session]);

  const waiting = awaiting(state);
  useEffect(() => {
    if (!waiting) return;
    const timer = window.setTimeout(() => {
      void refresh().then((answered) => {
        setPollDelay((delay) =>
          answered ? POLL_MS : Math.min(delay * 2, POLL_MAX_MS),
        );
        setPollFailures((failures) => (answered ? 0 : failures + 1));
        setPolled((count) => count + 1);
      });
    }, pollDelay);
    return () => {
      window.clearTimeout(timer);
    };
  }, [waiting, polled, pollDelay, refresh]);

  const offline = waiting && pollFailures >= 2;

  return {
    state,
    offline,
    send,
    sendCommand,
    sendOpener,
    retry,
    changeLanguage,
  };
}
