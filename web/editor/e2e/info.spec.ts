// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// The Info panel's table of contents (native) sends scrollToHeading; the MockHost stands in.

type Hooks = {
  debugInsert(text: string): void;
  debugSelection(): { anchor: number; head: number };
  mock: { noteId: string; deliver(msg: unknown): void };
};

const hooks = (page: Page) => ({
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
  scrollToHeading: (index: number) =>
    page.evaluate((i) => {
      const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
      b.mock.deliver({ type: "scrollToHeading", noteId: b.mock.noteId, index: i });
    }, index),
});

test("scrollToHeading puts the caret on that heading and scrolls it into view", async ({ page }) => {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  const filler = Array.from({ length: 80 }, (_, i) => `line ${i}`).join("\n");
  const doc = `# Top\n${filler}\n## Second\nbody\n## Third\nend`;
  await page.evaluate((d) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert(d), doc);
  await hooks(page).scrollToHeading(2);
  expect((await hooks(page).selection()).head).toBe(doc.indexOf("## Third") + "## Third".length);
  await expect(page.locator(".cm-line", { hasText: "Third" })).toBeInViewport();
  // An index past the last heading does nothing.
  await hooks(page).scrollToHeading(9);
  expect((await hooks(page).selection()).head).toBe(doc.indexOf("## Third") + "## Third".length);
});
