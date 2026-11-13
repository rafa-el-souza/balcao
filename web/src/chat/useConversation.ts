import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";

import { CableContext } from "../cable";
import { isLocale, DEFAULT_LOCALE, type Locale } from "../locale";
import openers from "../openers.json";
import {
  createApi,
  type Content,
  type Deleted,
  isServerMessage,
  type Outcome,
  serverNow,
  type Snapshot,
  type Span,
} from "./api";
import { awaiting, initialState, reduce } from "./conversation";

// FR-18: the replies and the trace's spans arrive over Action Cable, on the
// conversation's stream; while the socket is unavailable the page asks
// GET /api/conversations/current every 3 s instead, as long as a turn waits.
// Three seconds keep a waiting page at 20 of the 60 requests a minute FR-14
// allows a visitor. The endpoint is a TanStack Query query (design §6.9). The
// cable's spans and replies go into the conversation's reducer as they come:
// a reply is drawn in the server's order by the time and id it carries, after
// the visitor's message, which the 202 brought as the server stored it, so a
// reply costs no request. The query fetches when the page loads, when the
// stream (re)connects, while a turn waits as below, and when the stream
// brings what the page cannot place: a reset's reply, the reply to another
// tab's message, a message of no known shape (design §10, note of 2026-11-13
// on the chat's stream).
export const POLL_MS = 3000;
// A poll that fails, the edge's refusal included (which the edge counts too),
// doubles the wait, up to half a minute; one that answers brings it back to
// 3 s (review finding C5 of pull request #14).
export const POLL_MAX_MS = 30_000;
// While the cable is live and a turn waits, the page still asks this often: a
// reply whose broadcast failed is stored for the page to fetch
// (app/models/turn_processor.rb).
export const POLL_LIVE_MS = 15_000;
// How long after a glass box command's answer the same button stays quiet.
export const COMMAND_GAP_MS = 1000;
// How long after the server refused a subscription (a limit's minute) the
// page asks for it again (review finding C5 of pull request #17).
export const RESUBSCRIBE_MS = 30_000;

export const CURRENT = ["conversations", "current"] as const;

type OpenerKey = keyof typeof openers;
const LANG = { pt: "pt-BR", en: "en", es: "es" } as const;

export function isOpener(key: string | null): key is OpenerKey {
  return key !== null && Object.hasOwn(openers, key);
}

export function openerLang(key: OpenerKey): string {
  return LANG[openers[key].lang as keyof typeof LANG];
}

// What the conversation's stream carries (app/models/trace_recorder.rb,
// app/models/turn_processor.rb).
type StreamEvent =
  | { type: "span"; span: Span }
  | { type: "message"; message: unknown }
  | { type: "deleted"; text: string };

function isStreamEvent(data: unknown): data is StreamEvent {
  if (typeof data !== "object" || data === null) return false;
  const { type } = data as { type?: unknown };
  if (type === "span") {
    const { span } = data as { span?: unknown };
    return typeof span === "object" && span !== null;
  }
  if (type === "deleted")
    return typeof (data as { text?: unknown }).text === "string";
  return type === "message";
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
  const cable = useContext(CableContext);
  const queryClient = useQueryClient();
  const [state, dispatch] = useReducer(reduce, initialState);
  // The first session answered: the conversation may be asked for.
  const [opened, setOpened] = useState(false);
  // The cable's subscription to the conversation's stream is confirmed.
  const [live, setLive] = useState(false);
  const [pollDelay, setPollDelay] = useState(POLL_MS);
  // Polls failed in a row: from the second, the page says the connection is
  // lost (review finding V1 of pull request #14). A poll the edge refused is
  // the limit, said with its own text (review finding R5).
  const [pollFailures, setPollFailures] = useState(0);
  const [pollRefused, setPollRefused] = useState<string | null>(null);

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

  // Each answer of the conversation's query: the first is the page's load,
  // the others are polls.
  const loaded = useRef(false);
  const answered = useCallback(
    (answer: Outcome<Snapshot | Deleted>) => {
      if (answer.kind === "ok")
        dispatch({ type: "snapshot", answer: answer.value });
      if (!loaded.current) {
        loaded.current = true;
        // The edge's refusal is its limit, with its text (review finding R5).
        if (answer.kind === "limit")
          dispatch({ type: "limited", clientId: null, text: answer.text });
        else if (answer.kind !== "ok") dispatch({ type: "loadFailed" });
        dispatch({ type: "loaded" });
        return;
      }
      setPollDelay((delay) =>
        answer.kind === "ok" ? POLL_MS : Math.min(delay * 2, POLL_MAX_MS),
      );
      // An answer that finds nothing is no answer either (review finding C11).
      setPollFailures((failures) =>
        answer.kind === "failed" || answer.kind === "missing"
          ? failures + 1
          : 0,
      );
      setPollRefused(answer.kind === "limit" ? answer.text : null);
      // The cookie is gone: a new session, and the polls go on.
      if (answer.kind === "session") void session(language());
    },
    [language, session],
  );
  const onAnswer = useRef(answered);
  useEffect(() => {
    onAnswer.current = answered;
  }, [answered]);

  const waiting = awaiting(state);
  useQuery({
    queryKey: CURRENT,
    // A fetch the query gave up for a newer one (a reply on the cable while a
    // poll was on its way) says nothing: the newer one answers.
    queryFn: async ({ signal }) => {
      const answer = await api.current(signal);
      if (!signal.aborted) onAnswer.current(answer);
      return answer;
    },
    enabled: opened,
    refetchInterval: waiting
      ? live
        ? Math.max(POLL_LIVE_MS, pollDelay)
        : pollDelay
      : false,
    refetchIntervalInBackground: true,
    refetchOnWindowFocus: false,
    // The answer is never an error: a failure is an outcome the page says.
    retry: false,
    // A browser that knows it is offline still asks, so the page can say the
    // connection is lost.
    networkMode: "always",
  });

  // The conversation's stream, once the page knows its conversation, and the
  // next one's after a reset or the 24 hours of FR-04 (review finding V3 of
  // pull request #11). Every (re)connection fetches the conversation once,
  // for what the stream carried while it was down.
  const conversationId = state.conversationId;
  const following = useRef(conversationId);
  useEffect(() => {
    following.current = conversationId;
  }, [conversationId]);
  // A reply the stream brought that the page could not place: the
  // conversation's answer brings it, with what it answers.
  const unplaced = state.unplaced;
  useEffect(() => {
    if (unplaced > 0) void queryClient.invalidateQueries({ queryKey: CURRENT });
  }, [unplaced, queryClient]);

  // A refused subscription is asked for again a while later.
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (conversationId === null) return;
    let again: number | undefined;
    const refetch = () => {
      void queryClient.invalidateQueries({ queryKey: CURRENT });
    };
    const stop = cable.subscribe(
      { channel: "ConversationChannel", conversation_id: conversationId },
      {
        connected: () => {
          setLive(true);
          refetch();
        },
        disconnected: () => {
          setLive(false);
        },
        rejected: () => {
          setLive(false);
          again = window.setTimeout(() => {
            setAttempt((count) => count + 1);
          }, RESUBSCRIBE_MS);
        },
        received: (data) => {
          if (!isStreamEvent(data)) return;
          if (data.type === "span") dispatch({ type: "span", span: data.span });
          else if (data.type === "deleted") {
            // A fetch on its way may answer with what was there before.
            void queryClient.cancelQueries({ queryKey: CURRENT });
            dispatch({
              type: "snapshot",
              answer: { deleted: true, text: data.text },
            });
          } else if (isServerMessage(data.message)) {
            // The server answered: what earlier polls met is over, as the
            // answer of the fetch each reply made used to say (review
            // finding C1 of pull request #24). A fetch that follows says
            // its own.
            setPollDelay(POLL_MS);
            setPollFailures(0);
            setPollRefused(null);
            dispatch({ type: "message", message: data.message });
          } else refetch();
        },
      },
    );
    return () => {
      window.clearTimeout(again);
      stop();
      setLive(false);
    };
  }, [cable, conversationId, queryClient, attempt]);

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
      const at = new Date(serverNow()).toISOString();
      if (outcome.kind === "ok") {
        const { message } = outcome.value;
        dispatch({
          type: "accepted",
          clientId,
          conversationId: outcome.value.conversation_id,
          turnId: outcome.value.turn_id,
          at,
          ...(isServerMessage(message) ? { message } : {}),
        });
        // Accepted into a conversation the page does not follow (FR-04's 24
        // hours, a reset): the conversation's answer moves the page and its
        // stream there (review finding C1 of pull request #17).
        if (
          following.current !== null &&
          outcome.value.conversation_id !== following.current
        )
          void queryClient.invalidateQueries({ queryKey: CURRENT });
      } else if (outcome.kind === "limit")
        dispatch({ type: "limited", clientId, text: outcome.text, at });
      else dispatch({ type: "failed", clientId });
    },
    [api, language, session, queryClient],
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
  // is on its way, or within a second of its answer, sends nothing, or a
  // double click would reset or delete twice (review findings C8 and R6 of
  // pull request #14).
  const commands = useRef(new Set<string>());
  const sendCommand = useCallback(
    (text: string) => {
      if (commands.current.has(text)) return;
      commands.current.add(text);
      void send({ text }, text).finally(() => {
        window.setTimeout(() => {
          commands.current.delete(text);
        }, COMMAND_GAP_MS);
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
      setOpened(true);
    })();
  }, [language, sendOpener, session]);

  const refused = waiting ? pollRefused : null;
  const offline = waiting && refused === null && pollFailures >= 2;

  return {
    state,
    offline,
    refused,
    send,
    sendCommand,
    sendOpener,
    retry,
    changeLanguage,
  };
}
