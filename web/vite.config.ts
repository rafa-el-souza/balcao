/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// The SPA (ADR-0001). Where the build lands and how Rails serves it, and the
// dev proxy to the API, arrive with the deploy slice (design §9.1, PR-02).
export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
