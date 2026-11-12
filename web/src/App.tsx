import { Chat } from "./chat/Chat";
import { Landing } from "./landing/Landing";
import type { Page } from "./pages";
import { TracePage } from "./trace/TracePage";

export function App({ page }: { page: Page }) {
  switch (page) {
    case "chat":
      return <Chat />;
    case "trace":
      return <TracePage />;
    case "landing":
      return <Landing />;
  }
}
