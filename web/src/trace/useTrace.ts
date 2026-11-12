import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from "react";
import { useTranslation } from "react-i18next";

import { CableContext } from "../cable";
import { createApi, type Span, type Trace } from "../chat/api";
import { DEFAULT_LOCALE, isLocale, type Locale } from "../locale";
import { withSpans } from "./model";

// The trace page's data (FR-12): GET /api/traces/:token, one query, and the
// trace's stream, whose spans are drawn as they come; a turn that ends makes
// the query fetch, which brings its words ("cable invalidates, query
// fetches", design §6.9). The token is the whole credential (threat model
// SR-11): the page reads it from its address and sends it nowhere else.

const TOKEN = /^\/trace\/([^/]+)\/?$/;
const noChange = () => () => undefined;

// The address's token; none in the prerender and while the page hydrates,
// whose markup carries no link's token.
export function useToken(): string | null {
  return useSyncExternalStore(
    noChange,
    () => TOKEN.exec(window.location.pathname)?.[1] ?? null,
    () => null,
  );
}

export type TraceView =
  | { kind: "loading" }
  | { kind: "gone" }
  | { kind: "failed" }
  | { kind: "ok"; trace: Trace; spans: Span[] };

function isDeleted(data: unknown): data is { type: "deleted" } {
  return (
    typeof data === "object" &&
    data !== null &&
    (data as { type?: unknown }).type === "deleted"
  );
}

function isSpanEvent(data: unknown): data is { type: "span"; span: Span } {
  return (
    typeof data === "object" &&
    data !== null &&
    (data as { type?: unknown }).type === "span" &&
    typeof (data as { span?: unknown }).span === "object" &&
    (data as { span?: unknown }).span !== null
  );
}

export function useTrace(token: string | null): TraceView {
  const { i18n } = useTranslation();
  const cable = useContext(CableContext);
  const queryClient = useQueryClient();
  const language = useCallback(
    (): Locale => (isLocale(i18n.language) ? i18n.language : DEFAULT_LOCALE),
    [i18n],
  );
  const api = useMemo(() => createApi(language), [language]);
  const [live, setLive] = useState<Span[]>([]);
  // The stream said the conversation's data is gone (FR-05).
  const [deleted, setDeleted] = useState(false);

  const query = useQuery({
    queryKey: ["traces", token],
    queryFn: ({ signal }) => api.trace(token ?? "", signal),
    enabled: token !== null,
    retry: false,
    refetchOnWindowFocus: false,
    networkMode: "always",
  });

  useEffect(() => {
    if (token === null) return;
    const refetch = () => {
      void queryClient.invalidateQueries({ queryKey: ["traces", token] });
    };
    return cable.subscribe(
      { channel: "TraceChannel", token },
      {
        // What the stream carried while it was down.
        connected: refetch,
        disconnected: () => undefined,
        rejected: () => undefined,
        received: (data) => {
          if (isDeleted(data)) {
            setDeleted(true);
            return;
          }
          if (!isSpanEvent(data)) return;
          setLive((spans) => withSpans(spans, [data.span]));
          // A turn that ends brings its words with the next fetch.
          if (data.span.parent_span_id === null && data.span.finished_at)
            refetch();
        },
      },
    );
  }, [cable, token, queryClient]);

  const answer = query.data;
  if (deleted) return { kind: "gone" };
  if (!answer) return { kind: "loading" };
  if (answer.kind === "missing") return { kind: "gone" };
  if (answer.kind !== "ok") return { kind: "failed" };
  return {
    kind: "ok",
    trace: answer.value,
    spans: withSpans(answer.value.spans, live),
  };
}
