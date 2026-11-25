// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// Typewriter mode (M6 Task 14): while on, the caret line stays at the vertical centre of the editor
// when the user types or moves the caret with the keyboard; not for pointer clicks, the user's own
// scrolling, or a note opening.

type Hooks = {
  debugText(): string;
  debugInsert(text: string): void;
  debugSelection(): { anchor: number; head: number };
  debugUndo(): boolean;
  debugRedo(): boolean;
  debugView(): {
    dispatch(spec: unknown): void;
    focus(): void;
    coordsAtPos(pos: number): { top: number; bottom: number } | null;
    scrollDOM: HTMLElement;
    contentDOM: HTMLElement;
    state: { selection: { main: { head: number } }; doc: { length: number } };
  };
  mock: { revision: number; deliver(msg: unknown): void };
};

async function open(page: Page, opts: { typewriter?: boolean } = {}) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  if (opts.typewriter ?? true) await deliver(page, { type: "setSettings", typewriterMode: true });
  await content.click();
  return content;
}

const deliver = (page: Page, msg: unknown) =>
  page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg);

/** Distance in px between the caret line's centre and the scroller's centre. */
const offCentre = (page: Page) =>
  page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const rect = view.coordsAtPos(view.state.selection.main.head)!;
    const box = view.scrollDOM.getBoundingClientRect();
    return (rect.top + rect.bottom) / 2 - (box.top + box.bottom) / 2;
  });

const scrollTop = (page: Page) =>
  page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().scrollDOM.scrollTop);

const selectionHead = (page: Page) =>
  page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head);

const setScrollTop = (page: Page, top: number) =>
  page.evaluate((t) => {
    (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().scrollDOM.scrollTop = t;
  }, top);

const longDoc = Array.from({ length: 120 }, (_, i) => `line ${i + 1}`).join("\n");

async function fill(page: Page, text: string, caret: number) {
  await page.evaluate(
    ([t, c]) => {
      const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
      api.debugView().focus();
      api.debugInsert(t as string);
      api.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [text, caret] as const,
  );
}

test("the caret line stays within 2 px of the viewport centre while typing 30 lines", async ({ page }) => {
  await open(page);
  for (let i = 1; i <= 30; i++) {
    await page.keyboard.type(`typed line ${i}`);
    await page.keyboard.press("Enter");
    await expect.poll(() => offCentre(page).then(Math.abs), { message: `after line ${i}` }).toBeLessThanOrEqual(2);
  }
  // Mid-line typing keeps it too.
  await page.keyboard.type("more text");
  expect(Math.abs(await offCentre(page))).toBeLessThanOrEqual(2);
});

test("off by default: typing near the top does not scroll and the text starts at the top", async ({ page }) => {
  const content = await open(page, { typewriter: false });
  await page.keyboard.type("hello\nworld");
  expect(await scrollTop(page)).toBe(0);
  const padding = await content.evaluate((el) => getComputedStyle(el).paddingTop);
  expect(padding).toBe("32px");
});

test("arrow keys and deleting centre the caret line; a click does not move the view", async ({ page }) => {
  const content = await open(page);
  await fill(page, longDoc, 0);
  await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  for (let i = 0; i < 40; i++) await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  // Page navigation in typewriter mode moves and recentres the caret.
  const beforePageHead = await selectionHead(page);
  await page.keyboard.press("PageDown");
  await expect.poll(() => selectionHead(page)).toBeGreaterThan(beforePageHead);
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const afterPageHead = await selectionHead(page);
  await page.keyboard.press("PageUp");
  await expect.poll(() => selectionHead(page)).toBeLessThan(afterPageHead);
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  // Ctrl-Down is the native page motion that moves the caret and should centre it.
  await page.keyboard.press("Control+ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  await page.keyboard.press("Backspace");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);

  // A click puts the caret where the pointer is: the view stays.
  const before = await scrollTop(page);
  const headBefore = await selectionHead(page);
  const centreY = await page.evaluate(() => {
    const box = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().scrollDOM.getBoundingClientRect();
    return box.top + box.height / 2;
  });
  const box = (await content.boundingBox())!;
  await page.mouse.click(box.x + 40, centreY - 120);
  await page.waitForTimeout(150);
  expect(await selectionHead(page)).not.toBe(headBefore);
  expect(await scrollTop(page)).toBe(before);
  expect(Math.abs(await offCentre(page))).toBeGreaterThan(60);
});

test("the user's own scrolling is not fought; the next key press centres again", async ({ page }) => {
  await open(page);
  await fill(page, longDoc, 0);
  await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const centred = await scrollTop(page);
  await setScrollTop(page, centred + 300);
  await page.waitForTimeout(150);
  expect(await scrollTop(page)).toBe(centred + 300);
  await page.keyboard.type("x");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
});

test("opening a note does not centre the caret, with the mode on", async ({ page }) => {
  await open(page);
  await setScrollTop(page, 0);
  await deliver(page, {
    type: "loadNote",
    noteId: "other-note",
    text: longDoc,
    revision: 0,
    readOnly: false,
    selection: { anchor: 400, head: 400 },
  });
  await expect(page.locator(".cm-content")).toContainText("line 1");
  await page.waitForTimeout(150);
  // The restored caret (line ~60) is far below the centre and the view stayed at the top.
  expect(await scrollTop(page)).toBeLessThan(100);
  expect(Math.abs(await offCentre(page))).toBeGreaterThan(500);
});

test("read-only notes: the mode pads the text and keyboard navigation centres the caret line", async ({ page }) => {
  const content = await open(page);
  await deliver(page, { type: "loadNote", noteId: "ro-note", text: longDoc, revision: 0, readOnly: true });
  await expect(content).toContainText("line 1");
  expect(await content.evaluate((el) => getComputedStyle(el).paddingTop)).not.toBe("32px");
  await content.click({ position: { x: 10, y: 10 }, force: true });
  await page.keyboard.press("ControlOrMeta+Home");
  for (let i = 0; i < 30; i++) await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
});

test("turning the mode on centres the caret line; turning it off restores the padding", async ({ page }) => {
  const content = await open(page, { typewriter: false });
  await fill(page, longDoc, 600);
  expect(await content.evaluate((el) => getComputedStyle(el).paddingTop)).toBe("32px");
  await deliver(page, { type: "setSettings", typewriterMode: true });
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const viewportHalf = await page.evaluate(() => window.innerHeight / 2);
  expect(await content.evaluate((el) => parseFloat(getComputedStyle(el).paddingTop))).toBeCloseTo(viewportHalf, 0);
  await deliver(page, { type: "setSettings", typewriterMode: false });
  await expect.poll(() => content.evaluate((el) => getComputedStyle(el).paddingTop)).toBe("32px");
});

test("composition does not scroll; the centre catches up on compositionend", async ({ page }) => {
  await open(page);
  await fill(page, longDoc, 0);
  await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const centred = await scrollTop(page);
  await setScrollTop(page, centred + 300);
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const head = view.state.selection.main.head;
    view.dispatch({ changes: { from: head, insert: "あ" }, selection: { anchor: head + 1 }, userEvent: "input.type.compose" });
  });
  await page.waitForTimeout(150);
  expect(await scrollTop(page)).toBe(centred + 300);
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { data: "あ", bubbles: true }));
  });
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
});

/** The top and bottom of the caret line relative to the scroller's top. */
const caretBox = (page: Page) =>
  page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const rect = view.coordsAtPos(view.state.selection.main.head)!;
    return rect.top - view.scrollDOM.getBoundingClientRect().top;
  });

const matchVisible = (page: Page) =>
  page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const box = view.scrollDOM.getBoundingClientRect();
    const match = document.querySelector(".cm-bc-searchMatch-current")?.getBoundingClientRect();
    return !!match && match.top >= box.top && match.bottom <= box.bottom;
  });

const findDoc = Array.from({ length: 140 }, (_, i) => (i === 40 ? "first needle here" : i === 110 ? "second needle here" : `line ${i + 1}`)).join("\n");

test("Find Next and the note-list highlight show the match with the mode on; the caret does not pull the view back", async ({ page }) => {
  await open(page);
  await fill(page, findDoc, 0);
  await deliver(page, { type: "searchHighlight", noteId: "mock-note", query: "needle", terms: ["needle"] });
  await expect.poll(() => matchVisible(page)).toBe(true);
  await page.waitForTimeout(150);
  expect(await matchVisible(page)).toBe(true);
  expect(await selectionHead(page)).toBe(0);
  const firstTop = await scrollTop(page);
  await deliver(page, { type: "applyCommand", name: "findNext" });
  await expect.poll(() => scrollTop(page)).toBeGreaterThan(firstTop + 500);
  await page.waitForTimeout(150);
  expect(await matchVisible(page)).toBe(true);
  await expect(page.locator(".cm-bc-searchMatch-current")).toHaveText("needle");
  expect(await selectionHead(page)).toBe(0);
});

test("turning the mode off keeps the caret line where it was on screen", async ({ page }) => {
  await open(page);
  await fill(page, longDoc, 0);
  for (let i = 0; i < 50; i++) await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const before = await caretBox(page);
  await deliver(page, { type: "setSettings", typewriterMode: false });
  await expect.poll(() => page.locator(".cm-content").evaluate((el) => getComputedStyle(el).paddingTop)).toBe("32px");
  await page.waitForTimeout(150);
  expect(Math.abs((await caretBox(page)) - before)).toBeLessThanOrEqual(2);
});

test("undo and redo centre the caret line", async ({ page }) => {
  await open(page);
  await fill(page, longDoc, 0);
  await page.keyboard.type("X");
  await page.keyboard.press("ControlOrMeta+End");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const topAtEnd = await scrollTop(page);
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo());
  await expect.poll(() => scrollTop(page)).toBeLessThan(topAtEnd - 500);
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  await page.keyboard.press("ControlOrMeta+End");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugRedo());
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
});

test("a todo checkbox click does not move the view", async ({ page }) => {
  const lines = [
    ...Array.from({ length: 60 }, (_, i) => `line ${i}`),
    "- [ ] todo 1",
    "- [ ] todo 2",
    "- [ ] todo 3",
    ...Array.from({ length: 40 }, (_, i) => `after ${i}`),
  ];
  const doc = lines.join("\n");
  const content = await open(page);
  await fill(page, doc, lines.slice(0, 64).join("\n").length + 1);
  await page.keyboard.press("ArrowDown");
  await expect.poll(() => offCentre(page).then(Math.abs)).toBeLessThanOrEqual(2);
  const before = await scrollTop(page);
  const head = await selectionHead(page);
  await content.locator(".cm-bc-todo").nth(1).click();
  await expect(content.locator(".cm-bc-todo-done")).toHaveCount(1);
  await page.waitForTimeout(200);
  expect(await scrollTop(page)).toBe(before);
  expect(await selectionHead(page)).toBe(head);
});
