// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";

type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): { dispatch(spec: unknown): void };
  mock?: { text: string };
};
const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
  mockText: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock?.text),
});

async function openWith(page: Page, doc: string, caret?: number) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, c]) => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    api.debugInsert(d as string);
    if (c !== null) api.debugView().dispatch({ selection: { anchor: c } });
  }, [doc, caret ?? null] as const);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));
  return content;
}

/** The DOM caret is not inside a collapsed (hidden) span. */
const caretOutsideHidden = (page: Page) =>
  page.evaluate(() => {
    const node = document.getSelection()?.focusNode;
    const el = node && (node.nodeType === 1 ? (node as Element) : node.parentElement);
    return !el?.closest(".cm-bc-hidden");
  });

test("checkbox toggle is one undo step", async ({ page }) => {
  const content = await openWith(page, "- [ ] one\n- [ ] two\nend");
  await page.keyboard.type("!");
  const before = "- [ ] one\n- [ ] two\nend!";
  expect(await hooks(page).text()).toBe(before);
  const selection = await hooks(page).selection();

  await content.locator(".cm-bc-todo").first().click();
  const toggled = "- [x] one\n- [ ] two\nend!";
  expect(await hooks(page).text()).toBe(toggled);
  await expect.poll(() => hooks(page).mockText()).toBe(toggled);
  // The click moved neither the selection nor the focus.
  expect(await hooks(page).selection()).toEqual(selection);
  expect(await page.evaluate(() => document.activeElement?.classList.contains("cm-content"))).toBe(true);
  // Done: checked box, item text in the secondary color and struck through.
  await expect(content.locator(".cm-bc-todo").first()).toHaveAttribute("data-done", "true");
  const done = content.locator(".cm-bc-todo-done");
  await expect(done).toHaveText("one");
  expect(await done.evaluate((el) => getComputedStyle(el).textDecorationLine)).toBe("line-through");

  // One undo step reverts exactly the toggle (the typed "!" stays), redo re-applies it.
  await page.keyboard.press("Meta+z");
  expect(await hooks(page).text()).toBe(before);
  await expect(content.locator(".cm-bc-todo").first()).toHaveAttribute("data-done", "false");
  await page.keyboard.press("Meta+Shift+z");
  expect(await hooks(page).text()).toBe(toggled);
  await page.keyboard.press("Meta+z");
  await page.keyboard.press("Meta+z");
  expect(await hooks(page).text()).not.toContain("!");
});

test("checkboxes are checkbox controls without text; the line text equals the document (finding F8)", async ({ page }) => {
  const doc = "- [ ] open **bold**\n  * [x] nested done\n> + [X] quoted\nend";
  const content = await openWith(page, doc);
  const lines = content.locator(".cm-line");
  const docLines = doc.split("\n");
  for (let i = 0; i < docLines.length; i++) await expect(lines.nth(i)).toHaveText(docLines[i]!, { useInnerText: false });
  expect(await content.innerText()).toBe(doc);
  expect(await visibleText(lines.nth(0))).toBe("open bold");
  // The indentation is collapsed too (shown as padding).
  expect(await visibleText(lines.nth(1))).toBe("nested done");
  const boxes = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-todo")].map((el) => ({
      hidden: el.getAttribute("aria-hidden"),
      role: el.getAttribute("role"),
      checked: el.getAttribute("aria-checked"),
      label: el.getAttribute("aria-label"),
      text: el.textContent,
      insideHidden: !!el.parentElement?.closest(".cm-bc-hidden"),
      done: el.getAttribute("data-done"),
      width: el.getBoundingClientRect().width,
    })),
  );
  expect(boxes.map(({ width: _w, ...b }) => b)).toEqual([
    { hidden: null, role: "checkbox", checked: "false", label: "Todo", text: "", insideHidden: false, done: "false" },
    { hidden: null, role: "checkbox", checked: "true", label: "Todo", text: "", insideHidden: false, done: "true" },
    { hidden: null, role: "checkbox", checked: "true", label: "Todo", text: "", insideHidden: false, done: "true" },
  ]);
  for (const b of boxes) expect(b.width).toBeGreaterThan(8);
});

test("⌘T converts a line to a todo (and back); ⌘. toggles it", async ({ page }) => {
  await openWith(page, "");
  await page.keyboard.type("milk");
  await page.keyboard.press("Meta+t");
  expect(await hooks(page).text()).toBe("- [ ] milk");
  await page.keyboard.press("Meta+.");
  expect(await hooks(page).text()).toBe("- [x] milk");
  await page.keyboard.press("Meta+.");
  expect(await hooks(page).text()).toBe("- [ ] milk");
  await page.keyboard.press("Meta+t");
  expect(await hooks(page).text()).toBe("milk");
  // An empty line: ⌘T inserts `- [ ] `, typing goes after it.
  await page.keyboard.press("End");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Meta+t");
  await page.keyboard.type("eggs");
  expect(await hooks(page).text()).toBe("milk\n- [ ] eggs");
  await expect.poll(() => hooks(page).mockText()).toBe("milk\n- [ ] eggs");
});

test("typing a todo by hand and Enter continuing the checklist", async ({ page }) => {
  const content = await openWith(page, "");
  await page.keyboard.type("- [x] done");
  await page.keyboard.press("Enter");
  await page.keyboard.type("next");
  expect(await hooks(page).text()).toBe("- [x] done\n- [ ] next");
  await expect(content.locator(".cm-bc-todo")).toHaveCount(2);
  expect(await visibleText(content.locator(".cm-line").nth(1))).toBe("next");
});

test("caret around the checkbox: Home, arrows, typing and Backspace never land inside the collapsed range", async ({ page }) => {
  const content = await openWith(page, "- [ ] item");
  const line = content.locator(".cm-line").first();
  // Home goes to the start of the item text; typing lands after the checkbox.
  await page.keyboard.press("Home");
  expect((await hooks(page).selection()).head).toBe(6);
  expect(await caretOutsideHidden(page)).toBe(true);
  await page.keyboard.type("X");
  expect(await hooks(page).text()).toBe("- [ ] Xitem");
  await page.keyboard.press("Home");
  expect((await hooks(page).selection()).head).toBe(6);
  // ArrowLeft skips the collapsed `- [ ] ` to the line start, which shows `- `.
  await page.keyboard.press("ArrowLeft");
  expect((await hooks(page).selection()).head).toBe(0);
  await expect.poll(() => visibleText(line)).toBe("- Xitem");
  // ArrowRight: through `- `, then over the box in one step.
  const heads: number[] = [];
  for (let i = 0; i < 3; i++) {
    await page.keyboard.press("ArrowRight");
    heads.push((await hooks(page).selection()).head);
    expect(await caretOutsideHidden(page)).toBe(true);
  }
  expect(heads).toEqual([1, 2, 6]);
  await expect.poll(() => visibleText(line)).toBe("Xitem");
  // Backspace at the item text removes the whole todo markup, never a part of it.
  await page.keyboard.press("Backspace");
  expect(await hooks(page).text()).toBe("Xitem");
});
