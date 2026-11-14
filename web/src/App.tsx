import { Chat } from "./chat/Chat";
import { Landing } from "./landing/Landing";
import type { Page } from "./pages";
import { Privacy } from "./privacy/Privacy";
import { TracePage } from "./trace/TracePage";

export function App({ page }: { page: Page }) {
  switch (page) {
    case "chat":
      return <Chat />;
    case "trace":
      return <TracePage />;
    case "privacy":
      return <Privacy />;
    case "landing":
      return <Landing />;
  }
}
