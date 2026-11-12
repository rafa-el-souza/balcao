import { Chat } from "./chat/Chat";
import { Landing } from "./landing/Landing";
import type { Page } from "./pages";

export function App({ page }: { page: Page }) {
  return page === "chat" ? <Chat /> : <Landing />;
}
