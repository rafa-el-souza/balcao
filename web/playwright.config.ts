import { defineConfig, devices } from "@playwright/test";

// NFR-10's gate (e2e/gate.e2e.ts), over the build in web/dist: `npm run
// build` first. Chromium's headless shell only, which CI installs with
// `npm run e2e:browser`. Vitest never reads these files: they end in
// .e2e.ts.
export default defineConfig({
  testDir: "e2e",
  testMatch: "**/*.e2e.ts",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? [["list"], ["github"]] : "list",
  use: { ...devices["Desktop Chrome"], trace: "off" },
});
