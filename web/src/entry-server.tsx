import { renderToString } from "react-dom/server";

import { App } from "./App";
import "./i18n";

// Renders the app to HTML at build time, so the shell the server sends
// carries the page's text before any script runs (design NFR-10). The
// browser then hydrates the same markup (main.tsx). Only the build calls it
// (web/vite.config.ts).
export function render(): string {
  return renderToString(<App />);
}
