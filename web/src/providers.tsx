import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { type Cable, CableContext, idleCable } from "./cable";

// What every page shares: TanStack Query's client, one query per endpoint
// (design §6.9), and the Action Cable client. The browser gives the real
// cable (main.tsx); the prerender and the tests give one that never connects
// unless a test drives it.
export function createQueryClient(): QueryClient {
  return new QueryClient();
}

export function Providers({
  client,
  cable = idleCable,
  children,
}: {
  client: QueryClient;
  cable?: Cable;
  children: ReactNode;
}) {
  return (
    <QueryClientProvider client={client}>
      <CableContext.Provider value={cable}>{children}</CableContext.Provider>
    </QueryClientProvider>
  );
}
