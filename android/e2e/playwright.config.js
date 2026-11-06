import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  expect: { timeout: 8_000 },
  // The sharing tests use the real PeerJS broker; one at a time keeps it polite.
  workers: 1,
  fullyParallel: false,
  reporter: [["list"]],
  use: {
    ...devices["Pixel 7"],
    // Tall enough to have every panel on screen at once. A click on something scrolled away would
    // test Playwright's scrolling more than the app.
    viewport: { width: 412, height: 2000 },
    baseURL: "http://127.0.0.1:4173",
    screenshot: "only-on-failure",
  },
  webServer: {
    command: "node serve.mjs",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: true,
  },
});
