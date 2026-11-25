// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// Read-only notes (Trash, Archive, read-only): selection, copy and find work, edits do not.
// (Folding and table copy read-only are covered with their features in M6 Task 19.)

type Hooks = {
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): { dispatch(spec: unknown): void };
  mock: { text: string; revision: number; deliver(msg: unknown): void };
};
const text = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const mockText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text);

async function openReadOnly(page: Page, doc: string, anchor = 0, head = anchor) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate(
    ([d, a, h]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: hooks.mock.revision, readOnly: true });
      hooks.debugView().dispatch({ selection: { anchor: a, head: h } });
    },
    [doc, anchor, head] as const,
  );
  await expect.poll(() => text(page)).toBe(doc);
  await content.click();
  await page.evaluate(
    ([a, h]) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: a, head: h } }),
    [anchor, head] as const,
  );
  return content;
}

test("checkbox click in a read-only note changes nothing and shows the default cursor", async ({ page }) => {
  const doc = "- [ ] one\n- [x] two";
  const content = await openReadOnly(page, doc);
  const box = content.locator(".cm-bc-todo").first();
  await expect(box).toHaveAttribute("data-done", "false");
  expect(await box.evaluate((el) => getComputedStyle(el).cursor)).toBe("default");
  // aria-disabled (M7 Task 11): Playwright would wait for an enabled control, so force the click.
  await box.click({ force: true });
  await content.locator(".cm-bc-todo").last().click({ force: true });
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));
  expect(await text(page)).toBe(doc);
  await expect(box).toHaveAttribute("data-done", "false");
  expect(await mockText(page)).not.toBe("- [x] one\n- [x] two");

  // Control: the same box in an editable note keeps the pointer and toggles.
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: "- [ ] one", revision: hooks.mock.revision, readOnly: false });
  });
  await expect.poll(() => text(page)).toBe("- [ ] one");
  const editable = content.locator(".cm-bc-todo").first();
  expect(await editable.evaluate((el) => getComputedStyle(el).cursor)).toBe("pointer");
  await editable.click();
  expect(await text(page)).toBe("- [x] one");
});

test("applyCommand bold in read-only changes nothing; ⌘Z has nothing to undo", async ({ page }) => {
  const doc = "plain text";
  await openReadOnly(page, doc, 0, 5);
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: "bold" }),
  );
  expect(await text(page)).toBe(doc);
  await page.keyboard.press("Meta+z");
  expect(await text(page)).toBe(doc);
  await page.keyboard.press("Meta+Shift+z");
  expect(await text(page)).toBe(doc);
  expect(await mockText(page)).not.toContain("**");
});

test("Tab in a read-only note is not swallowed", async ({ page }) => {
  const doc = "- a\n- b";
  const content = await openReadOnly(page, doc, doc.length);
  // The default action (focus navigation) is left to WebKit: the key event is not prevented.
  const prevented = (shiftKey: boolean) =>
    content.evaluate((el, shift) => {
      const event = new KeyboardEvent("keydown", { key: "Tab", code: "Tab", keyCode: 9, shiftKey: shift, bubbles: true, cancelable: true });
      el.dispatchEvent(event);
      return event.defaultPrevented;
    }, shiftKey);
  expect(await prevented(false)).toBe(false);
  expect(await prevented(true)).toBe(false);
  expect(await text(page)).toBe(doc);

  // Control: in an editable note Tab stays in the editor (indents the item).
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: "- a\n- b", revision: hooks.mock.revision, readOnly: false });
  });
  await expect.poll(() => text(page)).toBe(doc);
  await content.click();
  expect(await prevented(false)).toBe(true);
});

test("Tab in a table of a read-only note is not swallowed and moves nothing", async ({ page }) => {
  const doc = "| a | b |\n|---|---|\n| c | d |";
  const content = await openReadOnly(page, doc, 3);
  const prevented = (shiftKey: boolean) =>
    content.evaluate((el, shift) => {
      const event = new KeyboardEvent("keydown", { key: "Tab", code: "Tab", keyCode: 9, shiftKey: shift, bubbles: true, cancelable: true });
      el.dispatchEvent(event);
      return event.defaultPrevented;
    }, shiftKey);
  expect(await prevented(false)).toBe(false);
  expect(await prevented(true)).toBe(false);
  expect(await text(page)).toBe(doc);
  const selection = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
  expect(selection).toEqual({ anchor: 3, head: 3 });
  // Return and the table commands change nothing either.
  await page.keyboard.press("Enter");
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: "tableAddRow" }),
  );
  expect(await text(page)).toBe(doc);
});
