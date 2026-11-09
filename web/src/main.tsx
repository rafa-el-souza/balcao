import { StrictMode } from "react";
import { createRoot, hydrateRoot } from "react-dom/client";

import { App } from "./App";
import "./i18n";
import "./styles/base.css";

const root = document.getElementById("root");
if (!root) throw new Error("index.html has no #root element");

const app = (
  <StrictMode>
    <App />
  </StrictMode>
);

// The built shell already holds the app's HTML (design NFR-10, vite.config.ts):
// hydrate it. The dev server's shell is empty: render into it.
if (root.hasChildNodes()) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
