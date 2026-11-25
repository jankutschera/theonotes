// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Locator, type Page } from "@playwright/test";

// Edit ▸ Find (M3 Task 10): Find… / Find and Replace… open the styled find panel through
// `applyCommand`; ruling R32: with the panel open ⌘G / ⇧⌘G select the match, closed they move the
// note-list search highlight's marker and never the selection.

type Hooks = {
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugUndo(): boolean;
  debugView(): { focus(): void; dispatch(spec: unknown): void };
  mock: {
    text: string;
    revision: number;
    externalEdit(spec: { from: number; insert: string }): void;
    deliver(msg: unknown): void;
  };
};

async function openWith(page: Page, doc: string, readOnly = false) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate(
    ([d, ro]) => {
      const mock = (window as unknown as { __baerchen: Hooks }).__baerchen.mock;
      if (ro) mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: mock.revision, readOnly: true });
      else mock.externalEdit({ from: 0, insert: d as string });
    },
    [doc, readOnly] as const,
  );
  await expect(content).toHaveText((doc as string).replaceAll("\n", ""));
  return content;
}

const command = (page: Page, name: string) =>
  page.evaluate((n) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: n }), name);
const selection = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
const docText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const selectedText = (page: Page) =>
  page.evaluate(() => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const { anchor, head } = api.debugSelection();
    return api.debugText().slice(Math.min(anchor, head), Math.max(anchor, head));
  });
// The current match's ring: an inset box-shadow in the accent (no outline, no layout change).
async function expectRing(match: Locator, ring: boolean) {
  const style = await match.evaluate((el) => {
    const s = getComputedStyle(el);
    const accent = getComputedStyle(el.closest(".cm-editor")!).getPropertyValue("--bc-color-accent").trim();
    return { shadow: s.boxShadow, outline: s.outlineStyle, accent };
  });
  expect(style.outline).toBe("none");
  if (!ring) return expect(style.shadow).toBe("none");
  expect(style.shadow).toContain("inset");
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(style.accent.slice(i, i + 2), 16));
  expect(style.shadow).toContain(`rgb(${r}, ${g}, ${b})`);
}

const panel = (page: Page) => page.locator(".cm-bc-find");
const findField = (page: Page) => page.locator(".cm-bc-find-search");
const replaceField = (page: Page) => page.locator(".cm-bc-find-replace");
const count = (page: Page) => page.locator(".cm-bc-find-count");

test("Find… opens the panel focused; typing highlights every match; Enter and ⌘G select the next", async ({ page }) => {
  await openWith(page, "one Two\nthree two\nfour TWO");
  await command(page, "find");
  await expect(panel(page)).toBeVisible();
  await expect(findField(page)).toBeFocused();
  await expect(page.locator(".cm-bc-replace-row")).toBeHidden();
  await page.keyboard.type("two");
  // Literal and case-insensitive.
  await expect(page.locator(".cm-content .cm-searchMatch")).toHaveCount(3);
  await expect(count(page)).toHaveText("3 matches");
  await page.keyboard.press("Enter");
  expect(await selection(page)).toEqual({ anchor: 4, head: 7 });
  await expect(count(page)).toHaveText("1 of 3");
  await expect(page.locator(".cm-content .cm-searchMatch-selected")).toHaveText("Two");
  // M7-R10: the selected match has a non-colour cue (an inset ring in the accent), the others do not.
  await expectRing(page.locator(".cm-content .cm-searchMatch-selected"), true);
  await expectRing(page.locator(".cm-content .cm-searchMatch:not(.cm-searchMatch-selected)").first(), false);
  // Still typing in the field: ⌘G (mock mode: the editor keymap stands in for the native menu).
  await page.keyboard.press("Meta+g");
  expect(await selectedText(page)).toBe("two");
  await expect(count(page)).toHaveText("2 of 3");
  await page.keyboard.press("Meta+Shift+g");
  expect(await selectedText(page)).toBe("Two");
  // The host's applyCommand findNext / findPrevious do the same (R32).
  await command(page, "findPrevious");
  expect(await selectedText(page)).toBe("TWO");
  await page.keyboard.press("Shift+Enter");
  expect(await selectedText(page)).toBe("two");
  await page.keyboard.press("Escape");
  await expect(panel(page)).toHaveCount(0);
  await expect(page.locator(".cm-content")).toBeFocused();
  expect(await docText(page)).toBe("one Two\nthree two\nfour TWO");
});

test("with the panel closed ⌘G keeps the M4 behaviour: the highlight marker moves, the selection stays", async ({ page }) => {
  const content = await openWith(page, "a two\nb two");
  await command(page, "find");
  await page.keyboard.type("b");
  await page.keyboard.press("Escape");
  await content.click();
  await page.keyboard.press("Meta+Home");
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "searchHighlight", noteId: "mock-note", query: "two", terms: ["two"] }),
  );
  const caret = await selection(page);
  await page.keyboard.press("Meta+g");
  await expect(page.locator(".cm-bc-searchMatch-current")).toHaveCount(1);
  await expect.poll(() => page.evaluate(() => document.querySelector(".cm-bc-searchMatch-current")?.closest(".cm-line")?.textContent)).toBe("b two");
  expect(await selection(page)).toEqual(caret);
  await expectRing(page.locator(".cm-bc-searchMatch-current"), true);
  await expectRing(page.locator(".cm-bc-searchMatch:not(.cm-bc-searchMatch-current)").first(), false);
});

test("opening the panel prefills the selection and clears the note-list highlight", async ({ page }) => {
  const content = await openWith(page, "alpha beta alpha");
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "searchHighlight", noteId: "mock-note", query: "beta", terms: ["beta"] }),
  );
  await expect(page.locator(".cm-bc-searchMatch")).toHaveCount(1);
  await content.click();
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0, head: 5 } }));
  await command(page, "find");
  await expect(findField(page)).toHaveValue("alpha");
  await expect(page.locator(".cm-bc-searchMatch")).toHaveCount(0);
  await expect(page.locator(".cm-content .cm-searchMatch")).toHaveCount(2);
});

test("Find and Replace…: Replace replaces the selected match and selects the next; All replaces the rest; one undo step each", async ({ page }) => {
  await openWith(page, "cat and cat and cat");
  await command(page, "findAndReplace");
  await expect(page.locator(".cm-bc-replace-row")).toBeVisible();
  await expect(findField(page)).toBeFocused();
  await page.keyboard.type("cat");
  await page.keyboard.press("Enter");
  await replaceField(page).click();
  await page.keyboard.type("dog");
  await page.keyboard.press("Enter");
  await expect.poll(() => docText(page)).toBe("dog and cat and cat");
  expect(await selection(page)).toEqual({ anchor: 8, head: 11 });
  await page.locator(".cm-bc-find-button-replaceAll").click();
  await expect.poll(() => docText(page)).toBe("dog and dog and dog");
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe("dog and dog and dog");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(true);
  expect(await docText(page)).toBe("dog and cat and cat");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(true);
  expect(await docText(page)).toBe("cat and cat and cat");
  // ⌘F switches the open panel back to Find.
  await command(page, "find");
  await expect(page.locator(".cm-bc-replace-row")).toBeHidden();
});

test("a read-only note finds but never replaces", async ({ page }) => {
  await openWith(page, "cat and cat", true);
  await command(page, "findAndReplace");
  await expect(panel(page)).toBeVisible();
  await expect(page.locator(".cm-bc-replace-row")).toBeHidden();
  await page.keyboard.type("cat");
  await page.keyboard.press("Enter");
  expect(await selectedText(page)).toBe("cat");
  await command(page, "findNext");
  expect(await selection(page)).toEqual({ anchor: 8, head: 11 });
  await page.keyboard.press("Meta+Enter");
  expect(await docText(page)).toBe("cat and cat");
});

// An attachment link is a widget since M3 Task 9: its matches are covered by the next test.
test("matches inside a link and its hidden target are found and revealed when selected", async ({ page }) => {
  await openWith(page, "see [the report](https://example.com/report.pdf) and [x](https://example.com/report)\nend");
  await command(page, "find");
  await page.keyboard.type("report");
  await expect(count(page)).toHaveText("3 matches");
  await page.keyboard.press("Enter");
  await expect(page.locator(".cm-content .cm-searchMatch-selected")).toHaveText("report");
  await page.keyboard.press("Enter");
  // The file name inside the hidden link target: selecting it reveals the link markup.
  expect(await selection(page)).toEqual({ anchor: 37, head: 43 });
  const selected = page.locator(".cm-content .cm-searchMatch-selected");
  await expect(selected).toHaveText("report");
  expect(await selected.evaluate((el) => !!el.closest(".cm-bc-hidden"))).toBe(false);
  expect((await selected.boundingBox())!.width).toBeGreaterThan(10);
});

test("an attachment whose source matches is highlighted while the panel is open", async ({ page }) => {
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  const doc = 'see [Report.pdf](Report.pdf)<!-- {"preview":"false","embed":"true"} --> and the report';
  await page.evaluate((d) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.externalEdit({ from: 0, insert: d }), doc);
  await expect.poll(() => docText(page)).toBe(doc);
  const widget = page.locator(".cm-bc-attachment");
  await expect(widget).toHaveCount(1);
  await page.locator(".cm-content").click();
  await command(page, "find");
  await page.keyboard.type("report");
  await expect(count(page)).toHaveText("3 matches");
  // The widget hides its source text, so it carries the match class itself.
  await expect(widget).toHaveClass(/cm-searchMatch/);
  await expect(widget).not.toHaveClass(/cm-searchMatch-selected/);
  // Enter selects the first match, inside the attachment's source: the widget is the current one.
  await page.keyboard.press("Enter");
  await expect(widget).toHaveClass(/cm-searchMatch-selected/);
  await page.keyboard.press("Escape");
  await expect(panel(page)).toBeHidden();
  await expect(widget).not.toHaveClass(/cm-searchMatch/);
});

test("host callback query replaces the panel query literally without editing source", async ({ page }) => {
  await openWith(page, "alpha [a+b] and ALPHA [a+b]");
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: "findAndReplace", args: { query: "[a+b]" } }));
  await expect(findField(page)).toHaveValue("[a+b]");
  await expect(page.locator(".cm-content .cm-searchMatch")).toHaveCount(2);
  await expect(replaceField(page)).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText())).toBe("alpha [a+b] and ALPHA [a+b]");
});
