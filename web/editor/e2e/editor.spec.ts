// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";

type Debug = {
  debugSelection(): { anchor: number; head: number };
  debugText(): string;
  debugInsert(text: string): void;
  debugUndo(): boolean;
  debugRedo(): boolean;
  mock?: { text: string; offline: boolean; loadNote(): void };
};

async function openEditor(page: Page) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  for (const [name, value] of [["spellcheck", "true"], ["autocorrect", "on"], ["autocapitalize", "sentences"], ["writingsuggestions", "true"]]) {
    await expect(content).toHaveAttribute(name!, value!);
  }
  await content.click();
  return content;
}

const selection = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugSelection());
const mockText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.mock?.text);

test("bold delimiters hide when caret leaves", async ({ page }) => {
  const content = await openEditor(page);
  await page.keyboard.type("**bold** x");
  await expect.poll(() => visibleText(content)).toBe("bold x");
  // The delimiters stay in the DOM (and the accessibility text), collapsed (finding F8).
  await expect(content).toHaveText("**bold** x");
});

test("caret skips hidden range", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("**bold** x");
  await page.keyboard.press("End");
  expect(await selection(page)).toEqual({ anchor: 10, head: 10 });
  for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowLeft");
  expect(await selection(page)).toEqual({ anchor: 6, head: 6 });
});

test("typing emoji keeps checksum", async ({ page }) => {
  const content = await openEditor(page);
  await page.keyboard.type("ab😀漢");
  await expect(content).toHaveText("ab😀漢");
  await expect.poll(() => mockText(page)).toBe(await content.innerText());
  expect(await selection(page)).toEqual({ anchor: 5, head: 5 });
});

test("halted bridge makes the editor read-only until the note is reloaded", async ({ page }) => {
  const content = await openEditor(page);
  await page.keyboard.type("ok");
  await expect.poll(() => mockText(page)).toBe("ok");
  await page.evaluate(() => {
    (window as unknown as { __baerchen: Debug }).__baerchen.mock!.offline = true;
  });
  await page.keyboard.type("!");
  await expect(content).toHaveAttribute("contenteditable", "false", { timeout: 5000 });
  await page.evaluate(() => {
    const mock = (window as unknown as { __baerchen: Debug }).__baerchen.mock!;
    mock.offline = false;
    mock.loadNote();
  });
  await expect(content).toHaveAttribute("contenteditable", "true");
  await expect(content).toHaveText("ok");
});

test("without the app bridge or ?mock the editor shows an error and does not start", async ({ page }) => {
  await page.goto("/index.html");
  await expect(page.getByRole("alert")).toContainText("Editor bridge unavailable");
  await expect(page.locator(".cm-content")).toHaveCount(0);
});

test("debug hooks insert, read and undo through the bridge", async ({ page }) => {
  await openEditor(page);
  await page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugInsert("hi 👩‍👩‍👧 漢字"));
  const debugText = () => page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugText());
  expect(await debugText()).toBe("hi 👩‍👩‍👧 漢字");
  await expect.poll(() => mockText(page)).toBe("hi 👩‍👩‍👧 漢字");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugUndo())).toBe(true);
  await expect.poll(() => mockText(page)).toBe("");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugRedo())).toBe(true);
  await expect.poll(() => mockText(page)).toBe("hi 👩‍👩‍👧 漢字");
});
