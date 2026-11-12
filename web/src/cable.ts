import { createConsumer } from "@rails/actioncable";
import { createContext } from "react";

// The Action Cable client (design §6.9, FR-12, FR-18): the conversation's
// stream for the chat, a trace's stream for the trace page. The server reads
// the visitor cookie when the socket opens (app/channels), so each
// subscription opens a socket of its own and closes it when it ends: a
// subscription made after a new session carries the new cookie.

export interface CableHandlers {
  // The server confirmed the subscription, again after every reconnection.
  connected(): void;
  // The socket dropped; the client reconnects by itself.
  disconnected(): void;
  // The server refused the subscription (a limit, a stream not the visitor's).
  rejected(): void;
  received(data: unknown): void;
}

export type ChannelParams =
  | { channel: "ConversationChannel"; conversation_id: string }
  | { channel: "TraceChannel"; token: string };

export interface Cable {
  // Returns the way to end the subscription.
  subscribe(params: ChannelParams, handlers: CableHandlers): () => void;
}

export function createCable(): Cable {
  return {
    subscribe(params, handlers) {
      const consumer = createConsumer();
      const subscription = consumer.subscriptions.create(params, {
        connected: () => {
          handlers.connected();
        },
        disconnected: () => {
          handlers.disconnected();
        },
        rejected: () => {
          handlers.rejected();
        },
        received: (data: unknown) => {
          handlers.received(data);
        },
      });
      return () => {
        subscription.unsubscribe();
        consumer.disconnect();
      };
    },
  };
}

// A cable that never connects: the prerender's, and the tests' unless one
// drives a cable of its own. The page then asks the server by polling, which
// is FR-18's fallback.
export const idleCable: Cable = {
  subscribe: () => () => undefined,
};

export const CableContext = createContext<Cable>(idleCable);
