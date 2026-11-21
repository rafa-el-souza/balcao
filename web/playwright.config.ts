import { defineConfig, devices } from "@playwright/test";

// NFR-10's gate (e2e/gate.e2e.ts), over the build in web/dist: `npm run
// build` first. Chromium's headless shell only, which CI installs with
// `npm run e2e:browser`. Vitest never reads these files: they end in
// .e2e.ts. The pages are drawn with reduced motion, so no row is caught
// fading in (from opacity 0) when axe measures its contrast; the reduced
// rules change no colour of a settled page (src/styles/base.css; the review
// of #66, W3).
export default defineConfig({
  testDir: "e2e",
  testMatch: "**/*.e2e.ts",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? [["list"], ["github"]] : "list",
  use: { ...devices["Desktop Chrome"], reducedMotion: "reduce", trace: "off" },
});
