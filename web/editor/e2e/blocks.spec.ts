// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 3: the block widget layer, with the dev-only test renderer (`?testBlocks`: `$$` math
// blocks drawn as a labelled `.test-block` box). The source lines stay in the DOM, collapsed.

type Hooks = { debugInsert(text: string): void; debugText(): string; debugSelection(): { anchor: number; head: number }; debugView(): View };
type View = { state: { doc: { length: number; toString(): string } }; dispatch(spec: unknown): void };

const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
});

async function openWith(page: Page, doc: string, caret?: number) {
  await page.goto("/index.html?mock&testBlocks");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, c]) => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    api.debugInsert(d as string);
    const view = api.debugView();
    (window as unknown as { __view: View }).__view = view;
    if (c !== null) view.dispatch({ selection: { anchor: c } });
  }, [doc, caret ?? null] as const);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));
  return content;
}

const doc = ["first line", "$$", "x^2 + y^2", "$$", "middle line", "$$", "a = b", "$$", "last line"].join("\n");
const firstBlock = { from: doc.indexOf("$$"), to: doc.indexOf("$$", doc.indexOf("x^2")) + 2 };
const secondBlock = { from: doc.indexOf("$$", firstBlock.to + 1), to: doc.lastIndexOf("$$") + 2 };

const rendered = (page: Page) => page.locator(".cm-content .cm-bc-block-rendered");
const collapsed = (page: Page) => page.locator(".cm-content .cm-line.cm-bc-block-collapsed");

test("innerText of .cm-content equals the document while blocks are rendered", async ({ page }) => {
  const content = await openWith(page, doc, 0);
  await expect(rendered(page)).toHaveCount(2);
  // The widget shows text of its own, in its shadow root: not part of the content text.
  await expect(page.locator(".test-block").first()).toHaveText("Rendered block (3 lines)");
  await expect(page.locator(".test-block").first()).toBeVisible();
  expect(await content.innerText()).toBe(doc);
  expect(await content.evaluate((el) => el.textContent)).toBe(doc.replaceAll("\n", ""));
  // Screen readers get the widget's label; it is not editable.
  await expect(page.getByRole("img", { name: "Test block" })).toHaveCount(2);
  expect(await rendered(page).first().getAttribute("contenteditable")).toBe("false");
  expect(await hooks(page).text()).toBe(doc);
});

test("collapsed lines have zero height and no display/visibility hiding", async ({ page }) => {
  await openWith(page, doc, 0);
  await expect(collapsed(page)).toHaveCount(6);
  // The lines next to a block keep their height; the block takes the widget's height only.
  const [above, widget, below] = await page.evaluate(() => {
    const all = [...document.querySelectorAll(".cm-content > *")];
    const at = all.findIndex((el) => el.classList.contains("cm-bc-block-rendered"));
    return [all[at - 1]!, all[at]!, all[at + 4]!].map((el) => el.getBoundingClientRect());
  });
  expect(above!.height).toBeGreaterThan(10);
  expect(widget!.height).toBeGreaterThan(10);
  expect(below!.top).toBeCloseTo(widget!.bottom, 0);

  // Paragraph spacing (and M7's indents) on `.cm-line` must not give collapsed lines a height
  // (cross-plan X16): a stronger line rule is added on top of the editor's own.
  const paddedLine = await page.locator(".cm-content .cm-line").first().evaluate((el) => parseFloat(getComputedStyle(el).paddingBottom));
  expect(paddedLine).toBeGreaterThan(0);
  await page.addStyleTag({
    content: "#editor .cm-editor .cm-content div.cm-line { padding: 6px 0 14px; margin: 3px 0; text-indent: 2em; border-top: 2px solid; }",
  });
  const lines = await collapsed(page).evaluateAll((els) =>
    els.map((el) => {
      const style = getComputedStyle(el);
      return { text: el.textContent, height: el.getBoundingClientRect().height, display: style.display, visibility: style.visibility };
    }),
  );
  expect(lines.map((l) => l.text)).toEqual(["$$", "x^2 + y^2", "$$", "$$", "a = b", "$$"]);
  for (const line of lines) {
    expect(line.height, line.text!).toBe(0);
    expect(line.display).toBe("block");
    expect(line.visibility).toBe("visible");
  }
  expect(await page.locator(".cm-content").innerText()).toBe(doc);
});

test("ArrowDown/ArrowUp enter a rendered block from the line above and below", async ({ page }) => {
  // From the end of the line above: the caret lands on the block's first line, the block shows
  // its source.
  await openWith(page, doc, firstBlock.from - 1);
  await expect(rendered(page)).toHaveCount(2);
  await page.keyboard.press("ArrowDown");
  expect((await hooks(page).selection()).head).toBe(firstBlock.from);
  await expect(rendered(page)).toHaveCount(1);
  await expect(page.locator(".cm-line", { hasText: "x^2 + y^2" })).not.toHaveClass(/cm-bc-block-collapsed/);
  // On through the source line by line, then out below; the block renders again.
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  expect((await hooks(page).selection()).head).toBeGreaterThan(firstBlock.from + 3);
  await page.keyboard.press("ArrowDown");
  const out = (await hooks(page).selection()).head;
  expect(out).toBeGreaterThan(firstBlock.to);
  expect(out).toBeLessThan(secondBlock.from);
  await expect(rendered(page)).toHaveCount(2);

  // From the line below: the caret lands on the block's last line.
  await page.evaluate((pos) => (window as unknown as { __view: View }).__view.dispatch({ selection: { anchor: pos } }), firstBlock.to + 1);
  await expect(rendered(page)).toHaveCount(2);
  await page.keyboard.press("ArrowUp");
  expect((await hooks(page).selection()).head).toBe(firstBlock.to);
  await expect(rendered(page)).toHaveCount(1);

  // The second block from the line below it (the last line).
  await page.evaluate((pos) => (window as unknown as { __view: View }).__view.dispatch({ selection: { anchor: pos } }), doc.length);
  await page.keyboard.press("ArrowUp");
  expect((await hooks(page).selection()).head).toBe(secondBlock.to);
  expect(await hooks(page).text()).toBe(doc);
});

test("Shift-ArrowDown across a block selects through it", async ({ page }) => {
  await openWith(page, doc, 5);
  await page.keyboard.press("Shift+ArrowDown");
  let sel = await hooks(page).selection();
  expect(sel).toEqual({ anchor: 5, head: firstBlock.from });
  // Through the block's three source lines onto "middle line".
  for (let i = 0; i < 3; i++) await page.keyboard.press("Shift+ArrowDown");
  sel = await hooks(page).selection();
  expect(sel.anchor).toBe(5);
  expect(sel.head).toBeGreaterThan(firstBlock.to);
  expect(sel.head).toBeLessThan(secondBlock.from);
  // The selected block shows its source, the other one stays rendered; the text is unchanged.
  await expect(rendered(page)).toHaveCount(1);
  expect(await page.evaluate(() => document.getSelection()!.toString().includes("x^2 + y^2"))).toBe(true);
  expect(await hooks(page).text()).toBe(doc);
});

test("⌘A, Delete, ⌘Z restores the exact text", async ({ page }) => {
  await openWith(page, doc, 0);
  await expect(rendered(page)).toHaveCount(2);
  await page.keyboard.press("Meta+a");
  await expect(rendered(page)).toHaveCount(0);
  await page.keyboard.press("Backspace");
  await expect.poll(() => hooks(page).text()).toBe("");
  await page.keyboard.press("Meta+z");
  await expect.poll(() => hooks(page).text()).toBe(doc);
  // Back with the whole text selected: still source; a caret elsewhere renders both again.
  await page.evaluate(() => (window as unknown as { __view: View }).__view.dispatch({ selection: { anchor: 0 } }));
  await expect(rendered(page)).toHaveCount(2);
  expect(await page.locator(".cm-content").innerText()).toBe(doc);
});

test("a click on a rendered widget puts the caret in the block and shows its source", async ({ page }) => {
  await openWith(page, doc, doc.length);
  await page.locator(".test-block").first().click();
  expect((await hooks(page).selection()).head).toBe(firstBlock.from);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.type("Q");
  expect(await hooks(page).text()).toBe(doc.slice(0, firstBlock.from) + "Q" + doc.slice(firstBlock.from));
});

test("typing next to a rendered block keeps its widget and DOM", async ({ page }) => {
  await openWith(page, doc, firstBlock.to + 1);
  await page.evaluate(() => {
    (window as unknown as { __widget: Element }).__widget = document.querySelector(".cm-bc-block-rendered")!;
  });
  await page.keyboard.type("abc");
  await page.keyboard.insertText("de");
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe(doc.slice(0, firstBlock.to + 1) + "abcde\n" + doc.slice(firstBlock.to + 1));
  await expect(rendered(page)).toHaveCount(2);
  expect(await page.evaluate(() => (window as unknown as { __widget: Element }).__widget.isConnected)).toBe(true);
  expect(await page.locator(".cm-content").innerText()).toBe(await hooks(page).text());
});

test("ArrowDown while composing does not enter the block", async ({ page }) => {
  await openWith(page, doc, firstBlock.from - 1);
  await expect(rendered(page)).toHaveCount(2);
  // A started composition (a pending dead key or IME before its first text change): CodeMirror
  // still sees the key, the layer must not switch the block mid-composition.
  await page.evaluate(() => document.querySelector(".cm-content")!.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true })));
  await page.keyboard.press("ArrowDown");
  expect((await hooks(page).selection()).head).toBe(firstBlock.from - 1);
  await expect(rendered(page)).toHaveCount(2);
  await page.evaluate(() => document.querySelector(".cm-content")!.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true })));
  await page.evaluate(() => new Promise((r) => setTimeout(r, 150)));
  await page.keyboard.press("ArrowDown");
  expect((await hooks(page).selection()).head).toBe(firstBlock.from);
  await expect(rendered(page)).toHaveCount(1);
});

test("ArrowDown on a folded heading whose section holds a block and a table does not unfold it or enter them", async ({ page }) => {
  // M6 Task 7: the fold is CodeMirror's (`foldedRanges`), which block entry skips.
  // The rendered block sits right below the heading, where a move would otherwise enter it.
  const folded = ["# Section", "$$", "x^2", "$$", "| a | b |", "|---|---|", "| 1 | 2 |", "", "# Next", "end"].join("\n");
  const sectionEnd = folded.indexOf("| 1 | 2 |") + "| 1 | 2 |".length;
  await openWith(page, folded, "# Section".length);
  // The `$$` test block and the table (M6 Task 4's grid) both render.
  await expect(rendered(page)).toHaveCount(2);
  await page.keyboard.press("Meta+Quote");
  const placeholder = page.locator(".cm-content .cm-bc-fold-placeholder");
  await expect(placeholder).toHaveCount(1);
  await expect(rendered(page)).toHaveCount(0);

  await page.keyboard.press("ArrowDown");
  const below = (await hooks(page).selection()).head;
  expect(below).toBeGreaterThan(sectionEnd);
  await expect(placeholder).toHaveCount(1);
  await expect(rendered(page)).toHaveCount(0);
  // And back up onto the heading's row (CodeMirror puts the caret after the ⋯, at the fold's end).
  await page.keyboard.press("ArrowUp");
  expect((await hooks(page).selection()).head).toBeLessThanOrEqual(sectionEnd);
  await expect(rendered(page)).toHaveCount(0);
  await expect(placeholder).toHaveCount(1);
  expect(await hooks(page).text()).toBe(folded);
});

test("a click the renderer handles leaves the selection and the block alone; Shift-click extends", async ({ page }) => {
  await openWith(page, doc, 3);
  // The test renderer answers ⌘-click with "handled" (a link in a table cell).
  await page.locator(".test-block").first().click({ modifiers: ["Meta"] });
  expect(await hooks(page).selection()).toEqual({ anchor: 3, head: 3 });
  await expect(rendered(page)).toHaveCount(2);
  // Shift-click on the second block extends the selection from the caret to its entry point.
  await page.locator(".test-block").nth(1).click({ modifiers: ["Shift"] });
  expect(await hooks(page).selection()).toEqual({ anchor: 3, head: secondBlock.from });
  await expect(rendered(page)).toHaveCount(0);
  expect(await hooks(page).text()).toBe(doc);
});

test("a click on the first pixel row of the line below a block lands on that line", async ({ page }) => {
  await openWith(page, doc, doc.length);
  const below = page.locator(".cm-line", { hasText: "middle line" });
  const box = (await below.boundingBox())!;
  const y = box.y + 0.5;
  const hit = await page.evaluate(([px, py]) => {
    const el = document.elementFromPoint(px!, py!);
    return { inCollapsed: !!el?.closest(".cm-bc-block-collapsed"), line: el?.closest(".cm-line")?.textContent ?? null };
  }, [box.x + 20, y]);
  expect(hit).toEqual({ inCollapsed: false, line: "middle line" });
  // At the line start: exactly `block.to + 1`; the block stays rendered.
  await page.mouse.click(box.x + 1, y);
  expect((await hooks(page).selection()).head).toBe(firstBlock.to + 1);
  await expect(rendered(page)).toHaveCount(2);
  // Further right on the same pixel row: still on that line.
  await page.mouse.click(box.x + 40, y);
  const head = (await hooks(page).selection()).head;
  expect(head).toBeGreaterThan(firstBlock.to + 1);
  expect(head).toBeLessThanOrEqual(firstBlock.to + 1 + "middle line".length);
  await expect(rendered(page)).toHaveCount(2);
});

test("in a locked editor a click on a rendered widget changes nothing", async ({ page }) => {
  await page.goto("/index.html?mock&testBlocks");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  await page.evaluate((d) => {
    const api = (window as unknown as { __baerchen: { mock: { revision: number; deliver(msg: unknown): void } } }).__baerchen;
    // noteId "" is the host's placeholder: loaded locked.
    api.mock.deliver({ type: "loadNote", noteId: "", text: d, revision: api.mock.revision });
  }, doc);
  await expect.poll(() => hooks(page).text()).toBe(doc);
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "false");
  await expect(rendered(page)).toHaveCount(2);
  const before = await hooks(page).selection();
  await page.locator(".test-block").first().click();
  expect(await hooks(page).selection()).toEqual(before);
  await expect(rendered(page)).toHaveCount(2);
});
