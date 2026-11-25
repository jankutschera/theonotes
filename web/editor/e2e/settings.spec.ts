// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";

// `setSettings` (M3 Task 10) applies Hide Markdown, auto-sort todos, typography and theme in place:
// no reload, the document, selection and undo history stay. Read-only notes (Trash, Archive,
// read-only) refuse edits but keep selection, copy and find.

type Hooks = {
  debugText(): string;
  debugInsert(text: string): void;
  debugSelection(): { anchor: number; head: number };
  debugUndo(): boolean;
  debugView(): {
    dispatch(spec: unknown): void;
    focus(): void;
    coordsAtPos(pos: number): { left: number } | null;
    contentDOM: HTMLElement;
    composing: boolean;
  };
  mock: { text: string; revision: number; sent: { type: string }[]; deliver(msg: unknown): void };
};

async function open(page: Page, doc: string, opts: { readOnly?: boolean; caret?: number } = {}) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate(
    ([d, ro, c]) => {
      const a = (window as unknown as { __baerchen: Hooks }).__baerchen;
      if (ro) {
        a.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: a.mock.revision, readOnly: true });
      } else {
        a.debugView().focus();
        a.debugInsert(d as string);
      }
      if (c !== null) a.debugView().dispatch({ selection: { anchor: c } });
    },
    [doc, opts.readOnly ?? false, opts.caret ?? null] as const,
  );
  await expect(content).toHaveText(doc.replaceAll("\n", ""));
  return content;
}

const deliver = (page: Page, msg: unknown) =>
  page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg);
const selection = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
const docText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const mockText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text);

test("Hide Markdown off shows all markup dimmed, on hides it again; doc, selection and undo stay", async ({ page }) => {
  const doc = "# Head\nsome **bold** and [l](https://u.v)\nend";
  const content = await open(page, doc, { caret: doc.length });
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 9, head: 12 } }));
  const lines = content.locator(".cm-line");
  expect(await visibleText(lines.nth(1))).toBe("some bold and l");
  const loadsBefore = await page.evaluate(() => document.querySelectorAll(".cm-content").length);

  await deliver(page, { type: "setSettings", hideMarkdown: false });
  await expect(page.locator(".cm-bc-hidden")).toHaveCount(0);
  expect(await visibleText(lines.nth(1))).toBe("some **bold** and [l](https://u.v)");
  expect(await visibleText(lines.nth(0))).toBe("# Head");
  const dimmed = await page.locator(".cm-bc-markup").allTextContents();
  expect(dimmed).toEqual(["#", "**", "**", "[", "]", "(", ")"]);
  const colors = await page.evaluate(() => {
    const mark = document.querySelector(".cm-bc-markup")!;
    const text = mark.closest(".cm-line")!;
    return [getComputedStyle(mark).color, getComputedStyle(text).color];
  });
  expect(colors[0]).not.toBe(colors[1]);
  expect(await selection(page)).toEqual({ anchor: 9, head: 12 });
  expect(await docText(page)).toBe(doc);

  await deliver(page, { type: "setSettings", hideMarkdown: true });
  await expect.poll(() => visibleText(lines.nth(1))).toBe("some bold and l");
  expect(await selection(page)).toEqual({ anchor: 9, head: 12 });
  // The same editor (no reload), with its undo history: the insert is still undoable.
  expect(await page.evaluate(() => document.querySelectorAll(".cm-content").length)).toBe(loadsBefore);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(true);
  expect(await docText(page)).toBe("");
});

test("Show heading levels off removes the badges, the text column and heading text stay put", async ({ page }) => {
  const doc = "# Head\n## Sub\nplain text";
  const content = await open(page, doc, { caret: doc.length });
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 9, head: 11 } }));
  const badges = page.locator(".cm-bc-hbadge");
  await expect(badges).toHaveText(["H1", "H2"]);
  // x of the first heading character, of the paragraph and the gutter's box.
  const geometry = () =>
    page.evaluate(() => {
      const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
      const gutters = document.querySelector(".cm-gutters")!.getBoundingClientRect();
      return { heading: view.coordsAtPos(2)!.left, sub: view.coordsAtPos(10)!.left, plain: view.coordsAtPos(14)!.left, gutterWidth: gutters.width };
    });
  const before = await geometry();
  const loads = await page.evaluate(() => document.querySelectorAll(".cm-content").length);

  await deliver(page, { type: "setSettings", showHeadingLevels: false });
  await expect(badges).toHaveCount(0);
  await expect(content.locator(".cm-bc-heading")).toHaveCount(2);
  expect(await geometry()).toEqual(before);
  expect(await selection(page)).toEqual({ anchor: 9, head: 11 });
  expect(await docText(page)).toBe(doc);
  expect(await page.evaluate(() => document.querySelectorAll(".cm-content").length)).toBe(loads);

  await deliver(page, { type: "setSettings", showHeadingLevels: true });
  await expect(badges).toHaveText(["H1", "H2"]);
  expect(await geometry()).toEqual(before);
  expect(await selection(page)).toEqual({ anchor: 9, head: 11 });
});

test("the caret reveals markup in the secondary color", async ({ page }) => {
  const doc = "x **bold** y";
  const content = await open(page, doc, { caret: 5 });
  await expect(content.locator(".cm-bc-markup")).toHaveText(["**", "**"]);
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0 } }));
  await expect(content.locator(".cm-bc-markup")).toHaveCount(0);
  await expect(content.locator(".cm-bc-hidden")).toHaveText(["**", "**"]);
});

test("settings survive loading another note", async ({ page }) => {
  await open(page, "a **b**");
  await deliver(page, { type: "setSettings", hideMarkdown: false, typography: { fontSize: 20 } });
  await deliver(page, { type: "loadNote", noteId: "mock-note", text: "c **d**", revision: 0, readOnly: false });
  await expect(page.locator(".cm-content")).toHaveText("c **d**");
  await expect(page.locator(".cm-bc-hidden")).toHaveCount(0);
  expect(await page.locator(".cm-editor").evaluate((el) => getComputedStyle(el).getPropertyValue("--bc-size").trim())).toBe("20px");
});

test("typography and theme change the look in place", async ({ page }) => {
  const content = await open(page, "hello");
  const size = () => content.locator(".cm-line").first().evaluate((el) => getComputedStyle(el).fontSize);
  expect(await size()).toBe("16px");
  await deliver(page, { type: "setSettings", typography: { fontSize: 20, lineWidth: 500 }, theme: { "--bc-color-bg": "#0a141e" } });
  await expect.poll(size).toBe("20px");
  expect(await content.evaluate((el) => el.getBoundingClientRect().width)).toBeLessThanOrEqual(500.5);
  expect(await page.locator(".cm-editor").evaluate((el) => getComputedStyle(el).backgroundColor)).toBe("rgb(10, 20, 30)");
  await deliver(page, { type: "setSettings", typography: {}, theme: {} });
  await expect.poll(size).toBe("16px");
});

// M7 Task 6: the editor's appearance, Reduce Motion and the selection colour.
const nord = {
  "--bc-color-bg": "#2e3440",
  "--bc-color-text": "#d8dee9",
  "--bc-color-selection": "#5e81ac",
  "--bc-color-popup-bg": "#3b4252",
  "--bc-color-popup-text": "#eceff4",
  "--bc-color-popup-selected-bg": "#81a1c1",
  "--bc-color-popup-selected-text": "#2e3440",
};
const rgb = (hex: string) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgb(${n >> 16}, ${(n >> 8) & 255}, ${n & 255})`;
};

test("appearance dark: computed color-scheme is dark and the autocomplete popup uses the popup tokens", async ({ page }) => {
  await open(page, "");
  await page.evaluate(
    (c) => {
      (window as unknown as { __baerchen: { mock: { completions: Record<string, unknown[]> } } }).__baerchen.mock.completions = c;
    },
    { tag: [{ label: "work", insert: "#work ", detail: "12" }, { label: "wonder", insert: "#wonder " }] },
  );
  const editor = page.locator(".cm-editor");
  expect(await editor.evaluate((el) => getComputedStyle(el).colorScheme)).toBe("light");
  await deliver(page, { type: "setSettings", appearance: "dark", theme: nord });
  await expect.poll(() => editor.evaluate((el) => getComputedStyle(el).colorScheme)).toBe("dark");
  expect(await editor.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(rgb(nord["--bc-color-bg"]));
  await page.locator(".cm-content").click();
  await page.keyboard.type("#wo");
  const popup = page.locator(".cm-tooltip-autocomplete");
  await expect(popup.locator("li")).toHaveCount(2);
  const colors = await popup.evaluate((el) => {
    const selected = el.querySelector("li[aria-selected]")!;
    return [getComputedStyle(el).backgroundColor, getComputedStyle(el).color, getComputedStyle(selected).backgroundColor, getComputedStyle(selected).color];
  });
  expect(colors).toEqual(
    [nord["--bc-color-popup-bg"], nord["--bc-color-popup-text"], nord["--bc-color-popup-selected-bg"], nord["--bc-color-popup-selected-text"]].map(rgb),
  );
  // Back to light, in place.
  await deliver(page, { type: "setSettings", appearance: "light", theme: {} });
  await expect.poll(() => editor.evaluate((el) => getComputedStyle(el).colorScheme)).toBe("light");
});

test("the selection takes the theme's selection colour (native selection, M7-R3)", async ({ page }) => {
  const content = await open(page, "select this text");
  await deliver(page, { type: "setSettings", theme: nord });
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0, head: 6 } }));
  await content.focus();
  const background = () => content.locator(".cm-line").first().evaluate((el) => getComputedStyle(el, "::selection").backgroundColor);
  await expect.poll(background).toBe(rgb(nord["--bc-color-selection"]));
  expect(await page.locator(".cm-selectionBackground").count()).toBe(0); // still the native selection
});

test("reduceMotion suppresses descendant transitions in place", async ({ page }) => {
  await open(page, "```js\nlet a = 1\n```\nafter");
  const copy = page.locator(".cm-bc-copy").first();
  // Copy is always visible since the accessibility change; give this fixture explicit motion
  // so the preference is tested against a real transition rather than its removed hover fade.
  await copy.evaluate((el) => { (el as HTMLElement).style.transition = "opacity 0.12s"; });
  const duration = () => copy.evaluate((el) => getComputedStyle(el).transitionDuration);
  expect(await duration()).toBe("0.12s");
  await deliver(page, { type: "setSettings", reduceMotion: true });
  await expect.poll(duration).toBe("0s");
  expect(await page.locator(".cm-editor").evaluate((el) => el.classList.contains("cm-bc-reduce-motion"))).toBe(true);
  expect(await page.locator(".cm-scroller").evaluate((el) => getComputedStyle(el).scrollBehavior)).toBe("auto");
  await deliver(page, { type: "setSettings", reduceMotion: false });
  await expect.poll(duration).toBe("0.12s");
});

test("the system's reduced-motion preference applies the same rule without the setting", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page, "```js\nlet a = 1\n```\nafter");
  await page.locator(".cm-bc-copy").first().evaluate((el) => { (el as HTMLElement).style.transition = "opacity 0.12s"; });
  expect(await page.locator(".cm-bc-copy").first().evaluate((el) => getComputedStyle(el).transitionDuration)).toBe("0s");
});

test("a theme change during composition waits for compositionend", async ({ page }) => {
  const content = await open(page, "abc", { caret: 3 });
  const editor = page.locator(".cm-editor");
  const background = () => editor.evaluate((el) => getComputedStyle(el).backgroundColor);
  const white = await background();
  await page.evaluate(() => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    api.debugView().contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
  });
  // The IME writes the composed text into the DOM (CodeMirror reads it and counts the composition
  // from this first change), then the host changes the theme.
  await page.evaluate(() => {
    const line = document.querySelector(".cm-line")!;
    (line.firstChild as Text).data = "abcあ";
  });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().composing)).toBe(true);
  await deliver(page, { type: "setSettings", appearance: "dark", theme: nord });
  await page.waitForTimeout(150);
  expect(await background()).toBe(white);
  expect(await editor.evaluate((el) => getComputedStyle(el).colorScheme)).toBe("light");
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { data: "あ", bubbles: true }));
  });
  await expect.poll(background).toBe(rgb(nord["--bc-color-bg"]));
  expect(await editor.evaluate((el) => getComputedStyle(el).colorScheme)).toBe("dark");
  expect(await docText(page)).toBe("abcあ");
  await expect(content).toHaveText("abcあ");
});

test("auto-sort todos follows the setting", async ({ page }) => {
  await open(page, "- [ ] a\n- [ ] b\n- [ ] c");
  await deliver(page, { type: "setSettings", autoSortTodos: true });
  await page.locator(".cm-bc-todo").first().click();
  await expect.poll(() => docText(page)).toBe("- [ ] b\n- [ ] c\n- [x] a");
  await deliver(page, { type: "setSettings", autoSortTodos: false });
  await page.locator(".cm-bc-todo").first().click();
  await expect.poll(() => docText(page)).toBe("- [x] b\n- [ ] c\n- [x] a");
});

test("a read-only note refuses typing, paste and cut but keeps selection, copy and find", async ({ page }) => {
  const doc = "alpha beta\ngamma";
  const content = await open(page, doc, { readOnly: true });
  await expect(content).toHaveAttribute("aria-readonly", "true");
  await content.click();
  await page.keyboard.press("Meta+Home");
  await page.keyboard.type("XYZ");
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Enter");
  await page.keyboard.insertText("dictated");
  await page.waitForTimeout(50);
  expect(await docText(page)).toBe(doc);
  await expect(content).toHaveText(doc.replaceAll("\n", ""));

  // Selection with the keyboard.
  await page.keyboard.press("Meta+Home");
  await page.keyboard.press("Alt+Shift+ArrowRight");
  expect(await selection(page)).toEqual({ anchor: 0, head: 5 });

  // Copy puts the selection on the pasteboard; cut copies without deleting; paste is refused.
  const clip = await content.evaluate((el) => {
    const copy = new DataTransfer();
    el.dispatchEvent(new ClipboardEvent("copy", { clipboardData: copy, bubbles: true, cancelable: true }));
    const cut = new DataTransfer();
    el.dispatchEvent(new ClipboardEvent("cut", { clipboardData: cut, bubbles: true, cancelable: true }));
    const paste = new DataTransfer();
    paste.setData("text/plain", "pasted");
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: paste, bubbles: true, cancelable: true }));
    return [copy.getData("text/plain"), cut.getData("text/plain")];
  });
  expect(clip).toEqual(["alpha", "alpha"]);
  expect(await docText(page)).toBe(doc);

  // Find works.
  await deliver(page, { type: "applyCommand", name: "find" });
  await page.keyboard.type("gam");
  await page.keyboard.press("Enter");
  expect(await selection(page)).toEqual({ anchor: 11, head: 14 });
  // Nothing was sent to the host.
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.some((m) => m.type === "changes"))).toBe(false);
  expect(await mockText(page)).toBe("");
});

// Review fix round 1: keymap commands (hiding's Backspace/Delete over hidden markup, Tab) never ran
// through `beforeinput`; a read-only note refuses every document change from the user.
const keyCases: [string, string, number, string][] = [
  ["Backspace after **bold**", "a **bold** z", 10, "Backspace"],
  ["Delete before **bold**", "a **bold** z", 2, "Delete"],
  ["Tab", "- item\n- next", 9, "Tab"],
  ["Tab in plain text", "plain", 2, "Tab"],
  ["Enter in a list", "- item", 6, "Enter"],
  ["Meta+Backspace", "a **bold** z", 10, "Meta+Backspace"],
];

for (const [name, doc, caret, key] of keyCases) {
  test(`a read-only note ignores ${name}: no change, nothing sent`, async ({ page }) => {
    const content = await open(page, doc, { readOnly: true });
    await content.click();
    await page.evaluate((c) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: c } }), caret);
    await page.keyboard.press(key);
    await page.waitForTimeout(50);
    expect(await docText(page)).toBe(doc);
    expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.some((m) => m.type === "changes"))).toBe(false);
  });
}

// M3 Task 10 carry: the single read-only filter (setup.ts refuseChanges) in the running editor.
const sentChanges = (page: Page) =>
  page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.some((m) => m.type === "changes"));

test("a read-only note ignores a checkbox click: no change, nothing sent", async ({ page }) => {
  const doc = "- [ ] task\n- [x] done";
  const content = await open(page, doc, { readOnly: true });
  await content.locator(".cm-bc-todo").first().click({ force: true }); // aria-disabled (M7 Task 11)
  await page.waitForTimeout(50);
  expect(await docText(page)).toBe(doc);
  await expect(content.locator(".cm-bc-todo").first()).toHaveAttribute("data-done", "false");
  expect(await sentChanges(page)).toBe(false);
});

test("a read-only note ignores the host's applyCommand bold and undo: no change, nothing sent", async ({ page }) => {
  const doc = "some words here";
  const content = await open(page, doc, { readOnly: true });
  await content.click();
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 5, head: 10 } }));
  await deliver(page, { type: "applyCommand", name: "bold" });
  await page.waitForTimeout(50);
  expect(await docText(page)).toBe(doc);
  await page.keyboard.press("Meta+z");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(false);
  await page.waitForTimeout(50);
  expect(await docText(page)).toBe(doc);
  expect(await selection(page)).toEqual({ anchor: 5, head: 10 });
  expect(await sentChanges(page)).toBe(false);
});

test("undo cannot reach back into edits made before a note turned read-only", async ({ page }) => {
  // The host reloads a note read-only when it moves to Trash or Archive (same id, same text).
  const content = await open(page, "draft");
  await page.keyboard.type(" more");
  const typed = await docText(page);
  expect(typed).toBe("draft more");
  await page.evaluate((text) => {
    const a = (window as unknown as { __baerchen: Hooks }).__baerchen;
    a.mock.deliver({ type: "loadNote", noteId: "mock-note", text, revision: a.mock.revision, readOnly: true });
  }, typed);
  await content.click();
  await page.keyboard.press("Meta+z");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugUndo())).toBe(false);
  await page.waitForTimeout(50);
  expect(await docText(page)).toBe(typed);
});

test("the empty placeholder editor (no note) is locked: not editable, no find", async ({ page }) => {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await deliver(page, { type: "loadNote", noteId: "", text: "", revision: 0, readOnly: true });
  await expect(content).toHaveAttribute("contenteditable", "false");
  await deliver(page, { type: "applyCommand", name: "find" });
  await expect(page.locator(".cm-bc-find")).toHaveCount(0);
});
