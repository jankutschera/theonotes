// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 7: folding headings and list items, the Side Actions chevrons, ⌘' and the badge button.

type View = {
  state: { doc: { length: number; line(n: number): { from: number; to: number } }; selection: { main: { head: number } } };
  dispatch(spec: unknown): void;
};
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
  mock: { revision: number; sent: { type: string; folded?: boolean; line?: number; noteId?: string; folds?: { line: number; hash: string }[] }[]; deliver(msg: unknown): void };
};

const api = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  head: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head),
  deliver: (msg: unknown) => page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg),
  sent: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent),
  caret: (pos: number) =>
    page.evaluate((p) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: p } }), pos),
});

const settle = (page: Page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));

async function openWith(page: Page, doc: string, caret = doc.length) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(
    ([d, c]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.debugInsert(d as string);
      hooks.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [doc, caret] as const,
  );
  await settle(page);
  return content;
}

/** Moves the pointer over the middle of line `n` (1-based, of the visible `.cm-line`s). */
async function hoverLine(page: Page, text: string) {
  const box = (await page.locator(".cm-content .cm-line", { hasText: text }).first().boundingBox())!;
  await page.mouse.move(box.x + 20, box.y + box.height / 2);
  await settle(page);
}

const doc = ["# Plan", "intro", "## Tasks", "- a", "  - b", "- c", "", "# Notes", "end"].join("\n");
const chevrons = (page: Page) => page.locator(".cm-bc-fold-gutter .cm-bc-fold-chevron");
const placeholder = (page: Page) => page.locator(".cm-content .cm-bc-fold-placeholder");

test("hovering a heading shows its chevron; click folds; placeholder click unfolds", async ({ page }) => {
  const content = await openWith(page, doc);
  await expect(chevrons(page)).toHaveCount(0);
  await hoverLine(page, "## Tasks");
  await expect(chevrons(page)).toHaveCount(1);
  const chevron = page.getByRole("button", { name: "Fold", exact: true });
  await expect(chevron).toHaveAttribute("aria-expanded", "true");
  // Lines that cannot fold get none.
  await hoverLine(page, "intro");
  await expect(chevrons(page)).toHaveCount(0);
  // A list item with a nested list folds too.
  await hoverLine(page, "- a");
  await expect(chevrons(page)).toHaveCount(1);

  await hoverLine(page, "## Tasks");
  const before = await api(page).head();
  const changes = () => api(page).sent().then((s) => s.filter((m) => m.type === "changes").length);
  const changesBefore = await changes();
  await chevron.click();
  // The section leaves the DOM; the trailing blank line stays; a ⋯ button stands in.
  await expect(placeholder(page)).toHaveCount(1);
  await expect(page.getByRole("button", { name: "3 folded lines" })).toBeVisible();
  await expect(content.locator(".cm-line", { hasText: "- c" })).toHaveCount(0);
  await expect(content.locator(".cm-line", { hasText: "# Notes" })).toHaveCount(1);
  // A folded line always shows its chevron, as Unfold.
  await page.mouse.move(5, 5);
  await settle(page);
  const unfold = page.getByRole("button", { name: "Unfold" });
  await expect(unfold).toBeVisible();
  await expect(unfold).toHaveAttribute("aria-expanded", "false");
  expect(await api(page).text()).toBe(doc);
  expect(await api(page).head()).toBe(before);
  // Folding is not an edit: nothing goes to the host (no revision).
  expect(await changes()).toBe(changesBefore);

  await placeholder(page).click();
  await expect(placeholder(page)).toHaveCount(0);
  await expect(content.locator(".cm-line", { hasText: "- c" })).toHaveCount(1);
  expect(await api(page).text()).toBe(doc);
});

test("folded text leaves the DOM: the only innerText difference (X42)", async ({ page }) => {
  const content = await openWith(page, doc);
  expect(await content.innerText()).toBe(doc);
  await hoverLine(page, "## Tasks");
  await chevrons(page).click();
  await expect(placeholder(page)).toHaveCount(1);
  const from = doc.indexOf("## Tasks") + "## Tasks".length;
  const to = doc.indexOf("- c") + "- c".length;
  expect(await content.innerText()).toBe(doc.slice(0, from) + "⋯" + doc.slice(to));
  // Chevrons and badges are outside `.cm-content`.
  expect(await content.locator(".cm-bc-fold-chevron, .cm-bc-hbadge").count()).toBe(0);
  await placeholder(page).click();
  expect(await content.innerText()).toBe(doc);
});

test("the fold gutter sits left of the heading gutter inside the same gutter width", async ({ page }) => {
  await openWith(page, doc);
  const boxes = await page.evaluate(() => {
    const rect = (sel: string) => document.querySelector(sel)!.getBoundingClientRect();
    return { gutters: rect(".cm-gutters"), fold: rect(".cm-bc-fold-gutter"), heading: rect(".cm-bc-heading-gutter") };
  });
  expect(boxes.gutters.width).toBeCloseTo(52, 0);
  expect(boxes.fold.width).toBeCloseTo(16, 0);
  expect(boxes.fold.right).toBeCloseTo(boxes.heading.left, 0);
  expect(boxes.heading.right).toBeCloseTo(boxes.gutters.right, 0);
});

test("chevrons still appear with showHeadingLevels off", async ({ page }) => {
  await openWith(page, doc);
  await api(page).deliver({ type: "setSettings", showHeadingLevels: false });
  await settle(page);
  await expect(page.locator(".cm-bc-hbadge")).toHaveCount(0);
  await hoverLine(page, "# Plan");
  await expect(chevrons(page)).toHaveCount(1);
  await chevrons(page).click();
  await expect(placeholder(page)).toHaveCount(1);
});

test("chevrons hide while typing", async ({ page }) => {
  await openWith(page, doc);
  await hoverLine(page, "# Notes");
  await chevrons(page).click();
  await hoverLine(page, "## Tasks");
  await expect(chevrons(page)).toHaveCount(2);
  await api(page).caret(doc.indexOf("intro") + 5);
  await page.keyboard.type("x");
  // The folded line keeps its chevron, hidden; the hovered one is gone.
  await expect(chevrons(page)).toHaveCount(1);
  await expect(chevrons(page)).toBeHidden();
  await page.mouse.move(300, 20);
  await expect(chevrons(page).first()).toBeVisible();
});

test("scrollToHeading into a folded section unfolds it", async ({ page }) => {
  const filler = Array.from({ length: 60 }, (_, i) => `line ${i}`).join("\n");
  const long = `# Top\n${filler}\n## Inner\ninner body\n# Next\nx`;
  await openWith(page, long, 0);
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  await expect(page.locator(".cm-line", { hasText: "## Inner" })).toHaveCount(0);
  await api(page).deliver({ type: "scrollToHeading", noteId: "mock-note", index: 1 });
  await expect(placeholder(page)).toHaveCount(0);
  await expect(page.locator(".cm-line", { hasText: "## Inner" })).toBeInViewport();
  expect(await api(page).head()).toBe(long.indexOf("## Inner") + "## Inner".length);
});

test("the badge is reachable as a button and reports the real fold state", async ({ page }) => {
  await openWith(page, doc, 0);
  const badge = page.getByRole("button", { name: "Heading level 2" });
  await expect(badge).toHaveCount(1);
  await expect(page.getByRole("button", { name: "Heading level 1" })).toHaveCount(2);
  // A control now (M6-R23); `aria-haspopup` comes with M7 Task 11.
  expect(await page.locator(".cm-bc-hbadge").first().getAttribute("aria-hidden")).toBeNull();
  // M7 Task 11 adds the menu popup now that the badge is exposed (M6-R23).
  expect(await page.locator(".cm-bc-hbadge").first().getAttribute("aria-haspopup")).toBe("menu");

  const menus = () => api(page).sent().then((s) => s.filter((m) => m.type === "headingMenu").map((m) => [m.line, m.folded]));
  await badge.click();
  await expect.poll(menus).toEqual([[3, false]]);
  await hoverLine(page, "## Tasks");
  await chevrons(page).click();
  await badge.click();
  await expect.poll(menus).toEqual([[3, false], [3, true]]);
});

test("⌘' in a read-only note folds", async ({ page }) => {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate((d) => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: hooks.mock.revision, readOnly: true });
  }, doc);
  await expect.poll(() => api(page).text()).toBe(doc);
  await content.click();
  await api(page).caret(doc.indexOf("intro"));
  // A body line folds its section.
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  expect(await api(page).head()).toBe("# Plan".length);
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(0);
  expect(await api(page).text()).toBe(doc);
  expect((await api(page).sent()).filter((m) => m.type === "changes")).toHaveLength(0);
});

// Fix round 1 (review C1, I1, I2, M3, M6).

const fenced = ["# Plan", "intro", "```", "code", "```", "", "# Notes", "end"].join("\n");

test("⌘→ then typing on a folded heading types before the ⋯, not into the hidden fence", async ({ page }) => {
  await openWith(page, fenced, 0);
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  await page.keyboard.press("Meta+ArrowRight");
  await page.keyboard.type("X");
  expect(await api(page).text()).toBe(fenced.replace("# Plan", "# PlanX"));
  await expect(placeholder(page)).toHaveCount(1);
  // `# Notes` is still a heading (the closing fence is intact).
  await expect(page.getByRole("button", { name: "Heading level 1" })).toHaveCount(2);
});

test("a click right of the ⋯ then typing types before the ⋯", async ({ page }) => {
  await openWith(page, fenced, 0);
  await page.keyboard.press("Meta+Quote");
  const box = (await placeholder(page).boundingBox())!;
  await page.mouse.click(box.x + box.width + 40, box.y + box.height / 2);
  // The caret goes before the ⋯, never to the fold's end (fix round 2).
  expect(await api(page).head()).toBe("# Plan".length);
  await page.keyboard.type("Y");
  expect(await api(page).text()).toBe(fenced.replace("# Plan", "# PlanY"));
  await expect(placeholder(page)).toHaveCount(1);
});

// Fix round 2: a caret never rests at a fold's end (M6-R28).

const foldEnd = fenced.indexOf("```", fenced.indexOf("code")) + 3;
const afterFold = foldEnd + 1;

test("a dead-key composition after ⌘→ on a folded heading lands on the visible line", async ({ page }) => {
  await openWith(page, fenced, 0);
  await page.keyboard.press("Meta+Quote");
  await page.keyboard.press("Meta+ArrowRight");
  expect(await api(page).head()).toBe("# Plan".length);
  // Playwright cannot drive WebKit's marked text (´ + e): the composition is replayed the way
  // CodeMirror reports it, at the caret, between compositionstart and compositionend.
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView() as unknown as {
      state: { selection: { main: { head: number } } };
      dispatch(spec: unknown): void;
      contentDOM: HTMLElement;
    };
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    const head = view.state.selection.main.head;
    view.dispatch({ changes: { from: head, insert: "´" }, selection: { anchor: head + 1 }, userEvent: "input.type.compose" });
    view.dispatch({ changes: { from: head, to: head + 1, insert: "é" }, selection: { anchor: head + 1 }, userEvent: "input.type.compose" });
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { data: "é", bubbles: true }));
  });
  expect(await api(page).text()).toBe(fenced.replace("# Plan", "# Plané"));
  await expect(placeholder(page)).toHaveCount(1);
  // Text without key events (dictation) lands there too.
  await page.keyboard.insertText("!");
  expect(await api(page).text()).toBe(fenced.replace("# Plan", "# Plané!"));
});

test("ArrowRight and ArrowLeft step over a fold; End and ⌃E stay before the ⋯", async ({ page }) => {
  await openWith(page, fenced, 0);
  await page.keyboard.press("Meta+Quote");
  await api(page).caret("# Plan".length);
  await page.keyboard.press("ArrowRight");
  expect(await api(page).head()).toBe(afterFold);
  await page.keyboard.press("ArrowLeft");
  expect(await api(page).head()).toBe("# Plan".length);
  await page.keyboard.press("Control+f");
  expect(await api(page).head()).toBe(afterFold);
  await page.keyboard.press("Control+b");
  expect(await api(page).head()).toBe("# Plan".length);
  for (const key of ["End", "Control+e", "Meta+ArrowRight"]) {
    await api(page).caret(2);
    await page.keyboard.press(key);
    expect(await api(page).head(), key).toBe("# Plan".length);
  }
  await expect(placeholder(page)).toHaveCount(1);
  expect(await api(page).text()).toBe(fenced);
});

// Final review I1 (M6-R76): deletion keys at a fold's edge unfold it, never edit hidden text.

test("Delete before the ⋯ and Backspace after the fold unfold it; the next press deletes", async ({ page }) => {
  for (const [caret, key] of [
    ["# Plan".length, "Delete"],
    ["# Plan".length, "Alt+Delete"],
    ["# Plan".length, "Control+k"],
    [afterFold, "Backspace"],
    [afterFold, "Alt+Backspace"],
  ] as const) {
    await openWith(page, fenced, 0);
    await page.keyboard.press("Meta+Quote");
    await expect(placeholder(page)).toHaveCount(1);
    await api(page).caret(caret);
    await page.keyboard.press(key);
    expect(await api(page).text(), key).toBe(fenced);
    await expect(placeholder(page), key).toHaveCount(0);
    expect(await api(page).head(), key).toBe(caret);
    await page.keyboard.press(key);
    expect(await api(page).text(), key).not.toBe(fenced);
  }
});

test("Shift-→ still extends across the fold", async ({ page }) => {
  await openWith(page, fenced, 0);
  await page.keyboard.press("Meta+Quote");
  await api(page).caret("# Plan".length);
  await page.keyboard.press("Shift+ArrowRight");
  const sel = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
  expect(sel.anchor).toBe("# Plan".length);
  expect(sel.head).toBeGreaterThanOrEqual(foldEnd);
  await expect(placeholder(page)).toHaveCount(1);
});

test("Enter on a folded heading or todo adds the line after the fold; the fold stays", async ({ page }) => {
  await openWith(page, doc, 0);
  await page.keyboard.press("Meta+Quote");
  await api(page).caret("# Plan".length);
  await page.keyboard.press("Enter");
  await page.keyboard.type("new");
  expect(await api(page).text()).toBe(doc.replace("- c\n", "- c\nnew\n"));
  await expect(placeholder(page)).toHaveCount(1);
  await expect(page.locator(".cm-content .cm-line").first()).toContainText("# Plan");

  const todos = ["- [ ] Project", "    - [ ] sub1", "    - [ ] sub2", "- [ ] Other"].join("\n");
  await openWith(page, todos, "- [ ] Project".length);
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  await page.keyboard.press("Enter");
  await page.keyboard.type("next");
  expect(await api(page).text()).toBe(todos.replace("sub2\n", "sub2\n- [ ] next\n"));
  await expect(placeholder(page)).toHaveCount(1);
});

test("dragging across a folded section keeps it closed and selects through it", async ({ page }) => {
  const body = Array.from({ length: 30 }, (_, i) => `body ${i + 1}`).join("\n");
  const big = `above\n# Big\n${body}\n# After\nendline`;
  await openWith(page, big, big.indexOf("# Big"));
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  const from = (await page.locator(".cm-line", { hasText: "above" }).boundingBox())!;
  const to = (await page.locator(".cm-line", { hasText: "endline" }).boundingBox())!;
  await page.mouse.move(from.x + 2, from.y + from.height / 2);
  await page.mouse.down();
  await page.mouse.move(from.x + 40, (from.y + to.y) / 2, { steps: 5 });
  await page.mouse.move(to.x + 60, to.y + to.height / 2, { steps: 5 });
  await page.mouse.up();
  await expect(placeholder(page)).toHaveCount(1);
  const sel = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
  expect(Math.max(sel.anchor, sel.head)).toBeGreaterThanOrEqual(big.indexOf("endline"));
  expect(Math.min(sel.anchor, sel.head)).toBeLessThanOrEqual(2);
});

test("a mousemove without movement does not bring the chevrons back while typing", async ({ page }) => {
  await openWith(page, doc);
  await hoverLine(page, "# Notes");
  await chevrons(page).click();
  const moveAt = (x: number, y: number) =>
    page.evaluate(([sx, sy]) => {
      document.querySelector(".cm-scroller")!.dispatchEvent(
        new MouseEvent("mousemove", { bubbles: true, screenX: sx, screenY: sy, clientX: 5, clientY: 5 }),
      );
    }, [x, y] as const);
  await moveAt(100, 100);
  await expect(chevrons(page)).toBeVisible();
  await api(page).caret(doc.indexOf("intro") + 5);
  await page.keyboard.type("x");
  await expect(chevrons(page)).toBeHidden();
  // A scroll under the resting pointer: WebKit's mousemove at the same screen position.
  await moveAt(100, 100);
  await expect(chevrons(page)).toBeHidden();
  await moveAt(101, 100);
  await expect(chevrons(page)).toBeVisible();
});

test("the chevron glyph scales with the text size (em, not px)", async ({ page }) => {
  await openWith(page, doc, 0);
  await page.keyboard.press("Meta+Quote");
  const glyph = () =>
    page.locator(".cm-bc-fold-chevron").first().evaluate((el) => parseFloat(getComputedStyle(el, "::before").width));
  const base = await glyph();
  await api(page).deliver({ type: "setSettings", typography: { fontSize: 24 } });
  await settle(page);
  expect(await glyph()).toBeCloseTo(base * 1.5, 1);
});

// M6 Task 8: fold state persistence.

test("a fold posts foldState once the folds rest; a loaded note restores its stored folds", async ({ page }) => {
  await openWith(page, doc, doc.indexOf("intro"));
  const posts = async () => (await api(page).sent()).filter((m) => m.type === "foldState");
  await api(page).caret(doc.indexOf("- a"));
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  // Debounced: nothing yet right after the fold, one post once it rests.
  expect(await posts()).toHaveLength(0);
  await expect.poll(async () => (await posts()).length).toBe(1);
  const [post] = await posts();
  expect(post!.folds).toEqual([{ line: 4, hash: expect.stringMatching(/^[0-9a-f]{8}$/) }]);
  // Typing elsewhere leaves the folds as they are: no further post.
  await api(page).caret(doc.length);
  await page.keyboard.type("!");
  await settle(page);
  await page.waitForTimeout(400);
  expect(await posts()).toHaveLength(1);

  // The same note, two lines longer above the fold: the fold follows "- a".
  const longer = "new\nlines\n" + doc;
  await page.evaluate(
    ([d, folds]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: hooks.mock.revision, readOnly: false, foldState: folds });
    },
    [longer, post!.folds] as const,
  );
  await expect.poll(() => api(page).text()).toBe(longer);
  await expect(placeholder(page)).toHaveCount(1);
  await expect(page.locator(".cm-content .cm-line", { hasText: "- b" })).toHaveCount(0);
  await expect(page.locator(".cm-content .cm-line", { hasText: "- a" })).toHaveCount(1);
});

// Fix round 1 (Codex review of Task 8).

const loadNote = (page: Page, noteId: string, text: string, extra: Record<string, unknown> = {}) =>
  page.evaluate(
    ([id, d, more]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.mock.deliver({ type: "loadNote", noteId: id, text: d, revision: hooks.mock.revision, readOnly: false, ...(more as object) });
    },
    [noteId, text, extra] as const,
  );
const foldPosts = async (page: Page) => (await api(page).sent()).filter((m) => m.type === "foldState");

test("stored folds that no longer apply are cleared; an unfold right after a restore is posted", async ({ page }) => {
  await openWith(page, doc);
  // A stale entry (the line's hash changed while the note was closed): nothing folds, [] is posted.
  await loadNote(page, "mock-note", doc, { foldState: [{ line: 4, hash: "00000000" }] });
  await expect.poll(() => api(page).text()).toBe(doc);
  await expect(placeholder(page)).toHaveCount(0);
  await expect.poll(async () => (await foldPosts(page)).map((m) => m.folds)).toEqual([[]]);

  // A real stored fold, restored, then unfolded before the debounce ran: [] reaches the host.
  await api(page).caret(doc.indexOf("- a"));
  await page.keyboard.press("Meta+Quote");
  await expect.poll(async () => (await foldPosts(page)).length).toBe(2);
  const stored = (await foldPosts(page))[1]!.folds!;
  expect(stored).toHaveLength(1);
  await loadNote(page, "mock-note", doc, { foldState: stored, selection: { anchor: doc.indexOf("- a"), head: doc.indexOf("- a") } });
  await expect(placeholder(page)).toHaveCount(1);
  await page.locator(".cm-content").click({ position: { x: 1, y: 1 } });
  await api(page).caret(doc.indexOf("- a"));
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(0);
  await expect.poll(async () => (await foldPosts(page)).map((m) => m.folds)).toEqual([[], stored, []]);
});

test("a fold still pending when another note loads is dropped; the new note posts its own", async ({ page }) => {
  await openWith(page, doc);
  await api(page).caret(doc.indexOf("- a"));
  await page.keyboard.press("Meta+Quote");
  await expect(placeholder(page)).toHaveCount(1);
  // Within the 300 ms: switch notes.
  await loadNote(page, "other-note", doc);
  await expect(placeholder(page)).toHaveCount(0);
  await page.waitForTimeout(500);
  expect(await foldPosts(page)).toHaveLength(0);
  await page.locator(".cm-content").click({ position: { x: 1, y: 1 } });
  await api(page).caret(doc.indexOf("## Tasks"));
  await page.keyboard.press("Meta+Quote");
  await expect.poll(async () => (await foldPosts(page)).map((m) => [m.noteId, m.folds?.map((f) => f.line)])).toEqual([["other-note", [3]]]);
});
