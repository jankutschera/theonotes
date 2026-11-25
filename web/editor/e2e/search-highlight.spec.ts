// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

type Hooks = {
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugUndo(): boolean;
  debugView(): { focus(): void };
  mock: {
    text: string;
    revision: number;
    externalEdit(spec: { from: number; insert: string }): void;
    deliver(msg: unknown): void;
  };
};


/** Opens the editor on `doc` (as an external change, so undo history starts empty). */
async function openWith(page: Page, doc: string) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate((d) => {
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.externalEdit({ from: 0, insert: d });
  }, doc);
  await expect(content).toHaveText(doc.replaceAll("\n", ""));
  return content;
}

const highlight = (page: Page, terms: string[], noteId = "mock-note") =>
  page.evaluate(
    ([t, id]) => {
      (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({
        type: "searchHighlight",
        noteId: id,
        query: (t as string[]).join(" "),
        terms: t,
      });
    },
    [terms, noteId] as const,
  );

const selection = (page: Page) =>
  page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
const docText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const matches = (page: Page) => page.locator(".cm-content .cm-bc-searchMatch").allTextContents();
const current = (page: Page) => page.locator(".cm-content .cm-bc-searchMatch-current");

test("the highlight marks every match and the first word-start one as current, without selecting", async ({ page }) => {
  const filler = Array.from({ length: 80 }, (_, i) => `line ${i}`).join("\n");
  await openWith(page, `restart\nMüller art\n${filler}\nlast muller art`);
  const before = await selection(page);
  await highlight(page, ["muller", "art"]);
  await expect(current(page)).toHaveText("Müller");
  await expect.poll(() => matches(page)).toEqual(expect.arrayContaining(["art", "Müller", "art"]));
  expect(await selection(page)).toEqual(before);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(false);
});

test("typing after opening a result does not replace the match", async ({ page }) => {
  await openWith(page, "alpha beta gamma");
  await highlight(page, ["beta"]);
  await expect(current(page)).toHaveText("beta");
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().focus());
  await page.keyboard.type("X");
  await expect.poll(() => docText(page)).toContain("beta");
  expect(await docText(page)).toBe("Xalpha beta gamma");
});

test("⌘G and ⇧⌘G move the current match (wrapping) and leave the caret", async ({ page }) => {
  const content = await openWith(page, "one two\nthree two\nfour two");
  await content.click();
  await page.keyboard.press("Meta+Home");
  await highlight(page, ["two"]);
  await expect(current(page)).toHaveCount(1);
  const caret = await selection(page);
  const currentFrom = () =>
    page.evaluate(() => {
      const el = document.querySelector(".cm-bc-searchMatch-current");
      return el ? el.closest(".cm-line")?.textContent : null;
    });
  expect(await currentFrom()).toBe("one two");
  await page.keyboard.press("Meta+g");
  await expect.poll(currentFrom).toBe("three two");
  await page.keyboard.press("Meta+g");
  await expect.poll(currentFrom).toBe("four two");
  await page.keyboard.press("Meta+g");
  await expect.poll(currentFrom).toBe("one two");
  await page.keyboard.press("Meta+Shift+g");
  await expect.poll(currentFrom).toBe("four two");
  expect(await selection(page)).toEqual(caret);
  await expect(page.locator(".cm-search")).toHaveCount(0);
});

test("a highlight for another note is dropped; empty terms clear", async ({ page }) => {
  await openWith(page, "alpha beta alpha");
  await highlight(page, ["alpha"], "other-note");
  await expect(page.locator(".cm-bc-searchMatch")).toHaveCount(0);
  await highlight(page, ["alpha"]);
  await expect.poll(() => matches(page)).toEqual(["alpha", "alpha"]);
  await highlight(page, []);
  await expect(page.locator(".cm-bc-searchMatch")).toHaveCount(0);
});

test("highlights follow edits and a new loadNote drops them", async ({ page }) => {
  const content = await openWith(page, "cat dog");
  await highlight(page, ["cat"]);
  await expect.poll(() => matches(page)).toEqual(["cat"]);
  await content.click();
  await page.keyboard.press("End");
  await page.keyboard.type(" cat");
  await expect.poll(() => matches(page)).toEqual(["cat", "cat"]);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe("cat dog cat");
  await page.evaluate(() => {
    const a = (window as unknown as { __baerchen: Hooks }).__baerchen;
    a.mock.deliver({ type: "loadNote", noteId: "mock-note", text: a.mock.text, revision: a.mock.revision, readOnly: false });
  });
  await expect(page.locator(".cm-bc-searchMatch")).toHaveCount(0);
});

// Final review I4 (M6-R78): a current match inside a rendered block (a table grid) shows its source.
test("⌘G to a match inside a rendered table shows the table's source with the match; moving on renders it", async ({ page }) => {
  const doc = "intro zebra\n\n| a | b |\n|---|---|\n| zebra | c |\n\nend";
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  await page.evaluate((d) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.externalEdit({ from: 0, insert: d }), doc);
  await expect.poll(() => docText(page)).toBe(doc);
  const rendered = page.locator(".cm-content .cm-bc-block-rendered");
  await expect(rendered).toHaveCount(1);
  await highlight(page, ["zebra"]);
  await expect(current(page)).toHaveText("zebra");
  await expect(rendered).toHaveCount(1);
  const before = await selection(page);
  const step = () =>
    page.evaluate(() =>
      (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: "findNext" }),
    );
  await step();
  await expect(rendered).toHaveCount(0);
  await expect(current(page)).toBeVisible();
  expect(await current(page).evaluate((el) => el.closest(".cm-line")?.textContent)).toBe("| zebra | c |");
  expect(await selection(page)).toEqual(before);
  // Wrapping back to the first match renders the grid again.
  await step();
  await expect(current(page)).toHaveText("zebra");
  await expect(rendered).toHaveCount(1);
});
