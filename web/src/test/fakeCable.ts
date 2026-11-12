import { act } from "@testing-library/react";

import type { Cable, CableHandlers, ChannelParams } from "../cable";

// A cable the test drives: it records each subscription and lets the test
// confirm it, drop it or send on it, as the server would.
export function fakeCable() {
  const subscriptions: {
    params: ChannelParams;
    handlers: CableHandlers;
    active: boolean;
  }[] = [];
  const cable: Cable = {
    subscribe(params, handlers) {
      const subscription = { params, handlers, active: true };
      subscriptions.push(subscription);
      return () => {
        subscription.active = false;
      };
    },
  };
  const current = () => {
    const subscription = subscriptions.filter((each) => each.active).at(-1);
    if (!subscription) throw new Error("no active subscription");
    return subscription;
  };
  return {
    cable,
    subscriptions,
    active: () => subscriptions.filter((each) => each.active),
    connect: () => {
      act(() => {
        current().handlers.connected();
      });
    },
    drop: () => {
      act(() => {
        current().handlers.disconnected();
      });
    },
    send: (data: unknown) => {
      act(() => {
        current().handlers.received(data);
      });
    },
  };
}
