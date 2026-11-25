// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

type Debug = { debugText(): string; mock?: { text: string } };

async function openEditor(page: Page) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
}

const editorText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.debugText());
const mockText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Debug }).__baerchen.mock?.text);

// Bear starts a list only with "1. " (number, dot, space): a bare "1." is text, so Enter after
// it just breaks the line (in a quote, the quote continues). CodeMirror's markdown keymap took
// it for an empty list item and deleted it (an empty note's first line vanished on Enter).
for (const [before, typed, expected] of [
  ["", "1.", "1.\n"],
  ["", "2)", "2)\n"],
  ["Intro\n\n", "3.", "Intro\n\n3.\n"],
  ["> ", "1.", "> 1.\n> "],
  ["- ", "1.", "- 1.\n- "],
  ["1. ", "1.", "1. 1.\n2. "],
] as const) {
  test(`Enter after a bare ${JSON.stringify(before + typed)} keeps it and adds a line`, async ({ page }) => {
    await openEditor(page);
    if (before) await page.keyboard.type(before);
    await page.keyboard.type(typed);
    await page.keyboard.press("Enter");
    await page.keyboard.type("x");
    expect(await editorText(page)).toBe(expected + "x");
    await expect.poll(() => mockText(page)).toBe(expected + "x");
  });
}

test("Backspace after a bare 1. deletes one character", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("1.");
  await page.keyboard.press("Backspace");
  expect(await editorText(page)).toBe("1");
});

test("Enter still continues a list started with a marker and a space", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("1. one");
  await page.keyboard.press("Enter");
  expect(await editorText(page)).toBe("1. one\n2. ");
});

test("Enter on an empty item started with a space still removes the marker", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("1. ");
  await page.keyboard.press("Enter");
  expect(await editorText(page)).toBe("");
});

// ---------------------------------------------------------------------------------------------
// Task 4: smart lists and line editing

type View = {
  state: { doc: { line(n: number): { from: number; to: number } } };
  dispatch(spec: unknown): void;
  coordsAtPos(pos: number, side?: number): { left: number; right: number; top: number; bottom: number } | null;
};
type Hooks = Debug & {
  debugInsert(text: string): void;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
};
const api = (page: Page) => ({
  text: editorText(page),
  head: page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head),
});

async function openWith(page: Page, doc: string, caret = doc.length) {
  await openEditor(page);
  await page.evaluate(
    ([d, c]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.debugInsert(d as string);
      hooks.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [doc, caret] as const,
  );
  await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30)))));
  return page.locator(".cm-content");
}

test("Enter continues bullets, todos and numbers; Enter on an empty item outdents, then ends the list; ⌘Z undoes one step", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("- a");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Tab");
  await page.keyboard.type("[ ] b");
  await page.keyboard.press("Enter");
  expect(await editorText(page)).toBe("- a\n  - [ ] b\n  - [ ] ");
  await page.keyboard.press("Enter");
  expect(await editorText(page)).toBe("- a\n  - [ ] b\n- [ ] ");
  await page.keyboard.press("Enter");
  expect(await editorText(page)).toBe("- a\n  - [ ] b\n");
  await page.keyboard.press("Meta+z");
  expect(await editorText(page)).toBe("- a\n  - [ ] b\n- [ ] ");
  await page.keyboard.press("Meta+z");
  expect(await editorText(page)).toBe("- a\n  - [ ] b\n  - [ ] ");
  await expect.poll(() => mockText(page)).toBe("- a\n  - [ ] b\n  - [ ] ");
});

test("ordered lists: Enter counts on and renumbers the rest; Tab starts a nested list at 1", async ({ page }) => {
  const doc = "1. a\n2. b\n3. c";
  await openWith(page, doc, "1. a".length);
  await page.keyboard.press("Enter");
  await page.keyboard.type("x");
  expect(await editorText(page)).toBe("1. a\n2. x\n3. b\n4. c");
  await page.keyboard.press("Tab");
  expect(await editorText(page)).toBe("1. a\n   1. x\n2. b\n3. c");
  await page.keyboard.press("Shift+Tab");
  expect(await editorText(page)).toBe("1. a\n2. x\n3. b\n4. c");
});

test("⇧↩ ends the list with a plain line; Backspace after a marker turns the item into text", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("- a");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("b");
  expect(await editorText(page)).toBe("- a\nb");
  await page.keyboard.press("Enter");
  await page.keyboard.type("- c");
  // Home goes to the item text first, then to the marker.
  await page.keyboard.press("Home");
  expect(await api(page).head).toBe("- a\nb\n- ".length);
  await page.keyboard.press("Backspace");
  expect(await editorText(page)).toBe("- a\nb\nc");
  await page.keyboard.press("Meta+z");
  await page.keyboard.press("Home");
  await page.keyboard.press("Home");
  expect(await api(page).head).toBe("- a\nb\n".length);
});

test("⇧↩ on a plain indented line is the default Enter: the indentation is kept", async ({ page }) => {
  await openWith(page, "  indented");
  await page.keyboard.press("Shift+Enter");
  await page.keyboard.type("x");
  expect(await editorText(page)).toBe("  indented\n  x");
});

test("⌥⌘↑/↓ move a list item with its children; one undo step", async ({ page }) => {
  const doc = "- a\n- b\n  - b1\n- c";
  await openWith(page, doc, doc.indexOf("b") + 1);
  await page.keyboard.press("Meta+Alt+ArrowUp");
  expect(await editorText(page)).toBe("- b\n  - b1\n- a\n- c");
  await page.keyboard.press("Meta+Alt+ArrowDown");
  await page.keyboard.press("Meta+Alt+ArrowDown");
  expect(await editorText(page)).toBe("- a\n- c\n- b\n  - b1");
  await page.keyboard.press("Meta+z");
  expect(await editorText(page)).toBe("- a\n- b\n  - b1\n- c");
});

test("typing a wrapper over a selection wraps it; -> and <- become arrows (not in code); ⌘Z brings back the typed text", async ({ page }) => {
  await openEditor(page);
  await page.keyboard.type("word");
  await page.keyboard.press("Shift+Home");
  await page.keyboard.type("*");
  await page.keyboard.type("*");
  expect(await editorText(page)).toBe("**word**");
  await page.keyboard.type("(");
  expect(await editorText(page)).toBe("**(word)**");
  await page.keyboard.press("End");
  await page.keyboard.type(" a->b <-");
  expect(await editorText(page)).toBe("**(word)** a→b ←");
  await page.keyboard.press("Meta+z");
  expect(await editorText(page)).toBe("**(word)** a→b <-");
  await page.keyboard.type(" `x->");
  expect(await editorText(page)).toBe("**(word)** a→b <- `x->");
});

/** Left edge of the first visible character at or after `pos` (skipping collapsed text). */
const textLeft = (page: Page, pos: number) =>
  page.evaluate((p) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().coordsAtPos(p, 1)!.left, pos);

test("nested items are indented ~1.5em per level; wrapped rows hang at the item text", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  const long = "Wrapped bullet text that is long enough to wrap onto a second visual row in the column of the editor";
  const doc = `- top\n  - ${long}\n1. ${long}\n- [ ] ${long}\n\nend`;
  const content = await openWith(page, doc);
  const top = await textLeft(page, 2);
  const nested = await textLeft(page, doc.indexOf("Wrapped"));
  expect(nested - top).toBeCloseTo(24, 0);
  for (const at of [doc.indexOf("Wrapped"), doc.indexOf("Wrapped", doc.indexOf("1. ")), doc.lastIndexOf("Wrapped")]) {
    const line = await page.evaluate((p) => {
      const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
      const first = view.coordsAtPos(p, 1)!;
      // The first character on the second visual row.
      let q = p;
      while (view.coordsAtPos(q, 1)!.top === first.top) q++;
      return { first: first.left, second: view.coordsAtPos(q, 1)!.left };
    }, at);
    expect(Math.abs(line.second - line.first), `item at ${at}`).toBeLessThan(1);
  }
  await expect(content.locator(".cm-bc-olmark")).toHaveCount(1);
});

test("no text jump when the caret reaches a bullet or a number", async ({ page }) => {
  // A blank line between: a list not starting at 1 does not interrupt a paragraph (CommonMark).
  const doc = "- bullet\n\n12. number\n\nend";
  await openWith(page, doc);
  const bullet = await textLeft(page, 2);
  const number = await textLeft(page, doc.indexOf("number"));
  for (const [caret, at, before] of [
    [0, 2, bullet],
    [1, 2, bullet],
    [doc.indexOf("12."), doc.indexOf("number"), number],
    [doc.indexOf("12.") + 2, doc.indexOf("number"), number],
  ] as const) {
    await page.evaluate((c) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: c } }), caret);
    await expect(page.locator(".cm-bc-li-raw")).toHaveCount(1);
    expect(Math.abs((await textLeft(page, at)) - before), `caret ${caret}`).toBeLessThan(0.5);
  }
});

test("the caret never stops in the hidden indentation: click, ← and → step over it", async ({ page }) => {
  const doc = "- a\n    - nested\n\nend";
  const content = await openWith(page, doc);
  const nested = content.locator(".cm-line").nth(1);
  const box = (await nested.boundingBox())!;
  // A click left of the bullet: the caret goes to the item text, and typing lands there.
  await page.mouse.click(box.x + 4, box.y + box.height / 2);
  expect(await api(page).head).toBe(doc.indexOf("nested"));
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  expect(await api(page).head).toBe(doc.indexOf("- nested"));
  await page.keyboard.press("ArrowLeft");
  expect(await api(page).head).toBe(3);
  await page.keyboard.press("ArrowRight");
  expect(await api(page).head).toBe(doc.indexOf("- nested"));
  // Backspace before the marker outdents the item.
  await page.keyboard.press("Backspace");
  expect(await editorText(page)).toBe("- a\n- nested\n\nend");
  // Each line's text is still the document line.
  const lines = content.locator(".cm-line");
  for (const [i, text] of (await editorText(page)).split("\n").entries()) await expect(lines.nth(i)).toHaveText(text, { useInnerText: false });
});
