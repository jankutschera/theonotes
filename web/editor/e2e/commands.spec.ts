// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// Mock mode has no native menu, so the editor binds the Format shortcuts itself (commands.ts
// `commandKeymap`); in the app the menu owns them (Apps/TheoNotesMac tests).

type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): { dispatch(spec: unknown): void };
  mock?: { text: string; sent: { type: string; [key: string]: unknown }[] };
};
const api = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  mockText: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock?.text),
  lastFormatState: () =>
    page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.sent.filter((m) => m.type === "formatState").at(-1)),
});

async function openWith(page: Page, doc: string, anchor: number, head = anchor) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, a, h]) => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.debugInsert(d as string);
    hooks.debugView().dispatch({ selection: { anchor: a, head: h } });
  }, [doc, anchor, head] as const);
  return content;
}

test("⌘B bolds the selection, the format state follows, ⌘Z undoes it in one step", async ({ page }) => {
  await openWith(page, "say hello", 4, 9);
  await page.keyboard.press("Meta+b");
  expect(await api(page).text()).toBe("say **hello**");
  await expect.poll(() => api(page).mockText()).toBe("say **hello**");
  await expect.poll(() => api(page).lastFormatState()).toMatchObject({ type: "formatState", active: ["bold"], inCode: false });
  await page.keyboard.press("Meta+z");
  expect(await api(page).text()).toBe("say hello");
});

test("headings, lists, quote and inline code by shortcut", async ({ page }) => {
  await openWith(page, "Title", 5);
  await page.keyboard.press("Meta+2");
  expect(await api(page).text()).toBe("## Title");
  await expect.poll(() => api(page).lastFormatState()).toMatchObject({ active: ["heading"], headingLevel: 2 });
  await page.keyboard.press("Meta+2");
  await page.keyboard.press("Meta+l");
  expect(await api(page).text()).toBe("- Title");
  await page.keyboard.press("Meta+Shift+l");
  expect(await api(page).text()).toBe("1. Title");
  await page.keyboard.press("Meta+Shift+t");
  expect(await api(page).text()).toBe("> 1. Title");
  await page.keyboard.press("Meta+Alt+c");
  expect(await api(page).text()).toBe("> 1. Title``");
});

test("⇧⌘7 inserts the long date with time, ⌃⇧⌘0 the time", async ({ page }) => {
  await openWith(page, "", 0);
  await page.keyboard.press("Meta+Shift+7");
  expect(await api(page).text()).toMatch(/^\d{1,2} [A-Z][a-z]{2} \d{4}, \d\d:\d\d$/);
  await page.keyboard.press("Enter");
  await page.keyboard.press("Control+Meta+Shift+0");
  expect(await api(page).text()).toMatch(/\n\d\d:\d\d$/);
});

test("⌘A inside a code block selects the block first, then the note", async ({ page }) => {
  await openWith(page, "x\n```\ncode\n```\ny", 7);
  await page.keyboard.press("Meta+a");
  const sel = () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
  expect(await sel()).toEqual({ anchor: 6, head: 10 });
  await page.keyboard.press("Meta+a");
  expect(await sel()).toEqual({ anchor: 0, head: 16 });
});

test("iOS hardware history arrows never indent and Return keys edit tables", async ({ page }) => {
  await page.goto("/index.html?mock&platform=ios");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.focus();
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.debugInsert("- first\n- second"); hooks.debugView().dispatch({ selection: { anchor: 12 } });
  });
  await page.keyboard.press("Meta+Alt+ArrowRight");
  await page.keyboard.press("Meta+Alt+ArrowLeft");
  expect(await api(page).text()).toBe("- first\n- second");
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.debugView().dispatch({ selection: { anchor: 0, head: hooks.debugText().length } });
    hooks.debugInsert("| A | B |\n|---|---|\n| x | y |");
    hooks.debugView().dispatch({ selection: { anchor: 22 } });
  });
  await page.keyboard.press("Control+Meta+Enter");
  expect((await api(page).text()).split("\n")).toHaveLength(4);
  await page.keyboard.press("Meta+Shift+Enter");
  expect((await api(page).text()).split("\n")[0]!.match(/\|/g)).toHaveLength(4);
});
