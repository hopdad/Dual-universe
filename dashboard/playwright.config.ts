import { defineConfig } from "@playwright/test";

// Smoke tests against a production build that points at an unreachable Supabase URL
// (NEXT_PUBLIC_* values are fixed at build time; see dashboard/README.md). They check the
// signed-out paths only; tests against a live project come once one exists.
const PORT = 3100;

export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    // Set PW_CHROMIUM_PATH to use an already installed Chromium instead of Playwright's own.
    launchOptions: { executablePath: process.env.PW_CHROMIUM_PATH || undefined },
  },
  webServer: {
    command: `npx next start -p ${PORT}`,
    url: `http://127.0.0.1:${PORT}/login`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
