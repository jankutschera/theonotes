// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { defineConfig } from "vitest/config";

// The production bundle test builds the whole editor; in parallel with the unit tests it slowed
// the timing tests (lists.test.ts "perf: large lists" measured 1.4 s against its 600 ms budget),
// so `pnpm test` runs it as a separate project after the unit tests.
export default defineConfig({
  test: {
    projects: [
      { extends: true, test: { name: "unit", include: ["test/**/*.test.ts"], exclude: ["test/production-bundle.test.ts"] } },
      { extends: true, test: { name: "bundle", include: ["test/production-bundle.test.ts"] } },
    ],
  },
});
