/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The SPA (ADR-0001). `vite build` writes web/dist: the image serves
// index.html through Rails with no-cache and the hashed files under assets/
// as static files (Dockerfile, design §6.7). In development, bin/dev runs
// this server beside Rails and it forwards the API, the cable and /up.
const RAILS = "http://127.0.0.1:3000";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": RAILS,
      "/up": RAILS,
      "/cable": { target: RAILS, ws: true },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
