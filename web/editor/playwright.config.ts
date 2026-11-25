// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { defineConfig } from "@playwright/test";

declare const process: { env: Record<string, string | undefined> };

// Parallel worktrees each run their own dev server: pick a free port with BAERCHEN_E2E_PORT.
// Never reuse an existing server, or one worktree's specs run against another worktree's code.
const port = Number(process.env.BAERCHEN_E2E_PORT ?? 5174);

export default defineConfig({
  testDir: "e2e",
  // Screenshot baselines (macOS WebKit, system fonts) live next to the specs.
  snapshotPathTemplate: "{testDir}/__screenshots__/{arg}{ext}",
  // The 500k-char typing budget runs alone after the other specs (ruling R12): under
  // parallel load its p95 sits on the 16 ms line.
  projects: [
    { name: "webkit", use: { browserName: "webkit" }, grepInvert: /perf: 500k chars/ },
    { name: "perf", use: { browserName: "webkit" }, grep: /perf: 500k chars/, dependencies: ["webkit"] },
  ],
  use: { baseURL: `http://localhost:${port}` },
  webServer: {
    command: `vite --port ${port} --strictPort`,
    url: `http://localhost:${port}/index.html`,
    reuseExistingServer: false,
  },
});
