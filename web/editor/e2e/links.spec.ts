// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// Links in mock mode: the MockHost records what the editor sends (openLink, editLinkRequest) and
// stands in for the native side (applyCommand setLink, scrollToHeading).

type Sent = { type: string; [key: string]: unknown };
type View = {
  state: { doc: { length: number; toString(): string }; selection: { main: { head: number; anchor: number } } };
  dispatch(spec: unknown): void;
  coordsAtPos(pos: number, side?: number): { left: number; top: number; right: number; bottom: number } | null;
};
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
  mock: { text: string; noteId: string; sent: Sent[]; deliver(msg: unknown): void; externalEdit(spec: unknown): void };
};

const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
  sent: (type: string) =>
    page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.filter((m) => m.type === t), type),
  deliver: (msg: Record<string, unknown>) =>
    page.evaluate((m) => {
      const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
      b.mock.deliver({ ...m, ...("noteId" in m ? { noteId: b.mock.noteId } : {}) });
    }, msg),
});

async function openWith(page: Page, doc: string, anchor: number, head = anchor) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, a, h]) => {
    const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
    b.debugInsert(d as string);
    b.debugView().dispatch({ selection: { anchor: a, head: h } });
  }, [doc, anchor, head] as const);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));
  return content;
}

/** Viewport point in the middle of the character at `pos`. */
async function pointAt(page: Page, pos: number) {
  return page.evaluate((p) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const a = view.coordsAtPos(p, 1)!;
    const b = view.coordsAtPos(p + 1, -1)!;
    return { x: (a.left + b.left) / 2, y: (a.top + a.bottom) / 2 };
  }, pos);
}

test("a plain click on a wiki link places the caret; ⌘-click opens it, ⌥⌘-click in a new window", async ({ page }) => {
  const doc = "see [[Project Plan/Next|plan]] and #work now";
  await openWith(page, doc, 0);
  const plan = await pointAt(page, doc.indexOf("plan]]") + 1);
  await page.mouse.click(plan.x, plan.y);
  expect((await hooks(page).selection()).head).toBeGreaterThan(doc.indexOf("|"));
  expect(await hooks(page).sent("openLink")).toEqual([]);

  await page.keyboard.down("Meta");
  await page.mouse.click(plan.x, plan.y);
  await page.keyboard.up("Meta");
  await page.keyboard.down("Alt");
  await page.keyboard.down("Meta");
  await page.mouse.click(plan.x, plan.y);
  await page.keyboard.up("Meta");
  await page.keyboard.up("Alt");
  const tag = await pointAt(page, doc.indexOf("#work") + 2);
  await page.keyboard.down("Meta");
  await page.mouse.click(tag.x, tag.y);
  await page.keyboard.up("Meta");

  expect(await hooks(page).sent("openLink")).toEqual([
    { type: "openLink", noteId: "mock-note", kind: "wiki", target: "Project Plan", heading: "Next", newWindow: false },
    { type: "openLink", noteId: "mock-note", kind: "wiki", target: "Project Plan", heading: "Next", newWindow: true },
    { type: "openLink", noteId: "mock-note", kind: "tag", target: "work", newWindow: false },
  ]);
  // ⌘-click opened links, it did not add cursors or edit.
  expect(await hooks(page).text()).toBe(doc);
});

test("external links get an aria-hidden open icon that opens them; the text stays the document", async ({ page }) => {
  const doc = "go [Bear](https://example.com) or [file](doc.pdf) and [[Note]]";
  const content = await openWith(page, doc, doc.length);
  const icons = page.locator(".cm-bc-link-open");
  await expect(icons).toHaveCount(1);
  expect(await icons.first().getAttribute("aria-hidden")).toBe("true");
  expect(await icons.first().textContent()).toBe("");
  await expect(content.locator(".cm-line").first()).toHaveText(doc, { useInnerText: false });
  expect(await content.innerText()).toBe(doc);

  const before = await hooks(page).selection();
  await icons.first().click();
  expect(await hooks(page).sent("openLink")).toEqual([
    { type: "openLink", noteId: "mock-note", kind: "url", target: "https://example.com", newWindow: false },
  ]);
  expect(await hooks(page).selection()).toEqual(before);
});

test("the open icon follows edits: typed links, code spans, a fence opened above, plain typing", async ({ page }) => {
  await openWith(page, "intro\n", 6);
  const icons = page.locator(".cm-bc-link-open");
  await page.keyboard.type("see [a](https://x.y) end");
  await expect(icons).toHaveCount(1);
  // Plain typing on another line (mapped, not rebuilt) keeps the icon right after the link.
  await page.keyboard.press("Meta+ArrowUp");
  await page.keyboard.type("so ");
  expect(await hooks(page).text()).toBe("so intro\nsee [a](https://x.y) end");
  const iconAfterLink = () =>
    page.evaluate(() => {
      const icon = document.querySelector(".cm-bc-link-open")!;
      const before = document.createRange();
      before.setStart(icon.closest(".cm-line")!, 0);
      before.setEndBefore(icon);
      return before.toString();
    });
  await expect.poll(iconAfterLink).toBe("see [a](https://x.y)");
  const view = (doc: string) =>
    page.evaluate((d) => {
      const v = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: d } });
    }, doc);
  await view("intro\nsee `[a](https://x.y)` end");
  await expect(icons).toHaveCount(0);
  await view("intro\nsee [a](https://x.y) end");
  await expect(icons).toHaveCount(1);
  await page.evaluate(() => {
    const v = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    v.dispatch({ changes: { from: 0, insert: "```\n" } });
  });
  await expect(icons).toHaveCount(0);
  // Any structural change counts (minor 6): front matter around the link line has no `](` edit.
  await view("intro\nsee [a](https://x.y) end");
  await expect(icons).toHaveCount(1);
  await page.evaluate(() => {
    const v = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    v.dispatch({ changes: [{ from: 0, insert: "---\n" }, { from: v.state.doc.length, insert: "\n---" }] });
  });
  await expect(icons).toHaveCount(0);
});

test("⌘K asks for the link panel; its setLink answer is one undo step", async ({ page }) => {
  await openWith(page, "visit bear today", 6, 10);
  await page.keyboard.press("Meta+k");
  const [request] = await hooks(page).sent("editLinkRequest");
  expect(request).toMatchObject({ type: "editLinkRequest", noteId: "mock-note", from: 6, to: 10, title: "bear", url: "" });
  const rect = request!.caretRect as { x: number; y: number; width: number; height: number };
  expect(rect.x).toBeGreaterThan(0);
  expect(rect.height).toBeGreaterThan(5);
  expect(await hooks(page).text()).toBe("visit bear today");

  expect(request).toMatchObject({ requestId: expect.any(String), editing: false });
  await hooks(page).deliver({ type: "applyCommand", name: "setLink", args: { requestId: request!.requestId, title: "Bear", url: "https://example.com/a b" } });
  expect(await hooks(page).text()).toBe("visit [Bear](https://example.com/a%20b) today");
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe(
    "visit [Bear](https://example.com/a%20b) today",
  );
  await page.keyboard.press("Meta+z");
  expect(await hooks(page).text()).toBe("visit bear today");
});

test("an external edit while the panel is open: Update still links the requested text (I1)", async ({ page }) => {
  await openWith(page, "visit bear today", 6, 10);
  await page.keyboard.press("Meta+k");
  const [request] = await hooks(page).sent("editLinkRequest");
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.externalEdit({ from: 0, insert: "Hi! " }));
  expect(await hooks(page).text()).toBe("Hi! visit bear today");
  await hooks(page).deliver({ type: "applyCommand", name: "setLink", args: { requestId: request!.requestId, title: "Bear", url: "https://example.com" } });
  expect(await hooks(page).text()).toBe("Hi! visit [Bear](https://example.com) today");
});

test("⌘K inside a link edits it; ⇧⌘K opens the link at the caret", async ({ page }) => {
  const doc = "a [Bear](https://example.com) b";
  await openWith(page, doc, 5);
  await page.keyboard.press("Meta+k");
  expect((await hooks(page).sent("editLinkRequest")).at(-1)).toMatchObject({ from: 2, to: 29, title: "Bear", url: "https://example.com", editing: true });
  await page.keyboard.press("Meta+Shift+k");
  await page.keyboard.press("Meta+Alt+Shift+k");
  expect(await hooks(page).sent("openLink")).toEqual([
    { type: "openLink", noteId: "mock-note", kind: "url", target: "https://example.com", newWindow: false },
    { type: "openLink", noteId: "mock-note", kind: "url", target: "https://example.com", newWindow: true },
  ]);
  expect(await hooks(page).text()).toBe(doc);
});

test("⌘D inserts a wiki link, ⇧⌘E a footnote", async ({ page }) => {
  await openWith(page, "see ", 4);
  await page.keyboard.press("Meta+d");
  await page.keyboard.type("Note");
  expect(await hooks(page).text()).toBe("see [[Note]]");
  await page.keyboard.press("End");
  await page.keyboard.press("Meta+Shift+e");
  await page.keyboard.type("source");
  expect(await hooks(page).text()).toBe("see [[Note]][^1]\n\n[^1]: source");
});

test("scrollToHeading puts the caret on that heading", async ({ page }) => {
  const filler = Array.from({ length: 80 }, (_, i) => `line ${i}`).join("\n");
  const doc = `# Top\n${filler}\n## Second\nbody\n## Third\nend`;
  await openWith(page, doc, 0);
  await hooks(page).deliver({ type: "scrollToHeading", noteId: "", index: 2 });
  const head = (await hooks(page).selection()).head;
  expect(head).toBe(doc.indexOf("## Third") + "## Third".length);
  await expect(page.locator(".cm-line", { hasText: "Third" })).toBeInViewport();
});

// M6 Task 13: footnotes.

test("clicking [^1] jumps to its definition and back", async ({ page }) => {
  const filler = Array.from({ length: 80 }, (_, i) => `line ${i}`).join("\n");
  const doc = `see[^1] here\n${filler}\n\n[^1]: the source`;
  await openWith(page, doc, doc.indexOf("here"));
  const ref = page.locator(".cm-content .cm-bc-footnote-ref").first();
  // Rendered: a superscript label, `[^` and `]` hidden.
  await expect(ref).toHaveText("1");
  expect(await ref.evaluate((el) => getComputedStyle(el).verticalAlign)).toBe("super");
  await ref.click();
  await expect.poll(async () => (await hooks(page).selection()).head).toBe(doc.indexOf("the source"));
  const def = page.locator(".cm-content .cm-bc-footnote-def").first();
  await expect(def).toBeInViewport();
  await def.click();
  await expect.poll(async () => (await hooks(page).selection()).head).toBe(doc.indexOf(" here"));
  await expect(page.locator(".cm-content .cm-line").first()).toBeInViewport();
  expect(await hooks(page).text()).toBe(doc);
});

test("editing a reference's label renames its definition", async ({ page }) => {
  const doc = "see[^1] here\n\n[^1]: the source";
  await openWith(page, doc, doc.indexOf("1]") + 1);
  await page.keyboard.type("a");
  expect(await hooks(page).text()).toBe("see[^1a] here\n\n[^1a]: the source");
  await page.keyboard.press("Meta+z");
  expect(await hooks(page).text()).toBe(doc);
});

// On a touch screen a tap on a link's text opens it; a scroll, a long press, a
// second finger or a tap while text is selected does not.
test.describe("touch", () => {
  test.use({ hasTouch: true });

  /**
   * Dispatches a touch sequence at the element under the first point (a stand-in finger: desktop
   * WebKit has no `Touch` constructor, so a plain event carries the touch lists).
   */
  async function gesture(page: Page, steps: { type: string; points: { x: number; y: number }[]; waitMs?: number }[]) {
    for (const step of steps) {
      if (step.waitMs) await page.waitForTimeout(step.waitMs);
      await page.evaluate(({ type, points }) => {
        const target = document.elementFromPoint(points[0]!.x, points[0]!.y)!;
        const touches = points.map((p, i) => ({ identifier: i, target, clientX: p.x, clientY: p.y }));
        const ended = type === "touchend" || type === "touchcancel";
        const event = new Event(type, { bubbles: true, cancelable: true, composed: true });
        Object.assign(event, { touches: ended ? [] : touches, targetTouches: ended ? [] : touches, changedTouches: touches });
        target.dispatchEvent(event);
      }, step);
    }
  }

  test("a tap opens a wiki link, a web link and a tag; a mouse click and a tap beside them do not", async ({ page }) => {
    const doc = "see [[Project Plan/Next|plan]] and [Bear](https://example.com) and #work now";
    await openWith(page, doc, doc.length);
    const plain = await pointAt(page, doc.indexOf("see") + 1);
    await page.touchscreen.tap(plain.x, plain.y);
    const plan = await pointAt(page, doc.indexOf("plan]]") + 1);
    await page.mouse.click(plan.x, plan.y);
    expect(await hooks(page).sent("openLink")).toEqual([]);
    await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0 } }));

    for (const at of [doc.indexOf("plan]]") + 1, doc.indexOf("Bear") + 1, doc.indexOf("#work") + 2]) {
      const p = await pointAt(page, at);
      await page.touchscreen.tap(p.x, p.y);
    }
    expect(await hooks(page).sent("openLink")).toEqual([
      { type: "openLink", noteId: "mock-note", kind: "wiki", target: "Project Plan", heading: "Next", newWindow: false },
      { type: "openLink", noteId: "mock-note", kind: "url", target: "https://example.com", newWindow: false },
      { type: "openLink", noteId: "mock-note", kind: "tag", target: "work", newWindow: false },
    ]);
    expect(await hooks(page).text()).toBe(doc);
  });

  test("a scroll, a long press, two fingers or a selection keep the system's behaviour", async ({ page }) => {
    const doc = "see [[Project Plan]] now";
    await openWith(page, doc, doc.length);
    const p = await pointAt(page, doc.indexOf("Plan"));
    const moved = { x: p.x, y: p.y + 40 };
    const second = { x: p.x + 60, y: p.y };
    await gesture(page, [{ type: "touchstart", points: [p] }, { type: "touchmove", points: [moved] }, { type: "touchend", points: [moved] }]);
    await gesture(page, [{ type: "touchstart", points: [p] }, { type: "touchend", points: [p], waitMs: 650 }]);
    await gesture(page, [{ type: "touchstart", points: [p, second] }, { type: "touchend", points: [p] }]);
    await gesture(page, [{ type: "touchstart", points: [p] }, { type: "touchcancel", points: [p] }, { type: "touchend", points: [p] }]);
    await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0, head: 3 } }));
    await page.touchscreen.tap(p.x, p.y);
    expect(await hooks(page).sent("openLink")).toEqual([]);
    // The same stand-in finger, short and still, does open: the gestures above are what kept it shut.
    await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 0 } }));
    await gesture(page, [{ type: "touchstart", points: [p] }, { type: "touchend", points: [p] }]);
    expect(await hooks(page).sent("openLink")).toEqual([
      { type: "openLink", noteId: "mock-note", kind: "wiki", target: "Project Plan", newWindow: false },
    ]);
  });

  test("a tap opens a link in a read-only note", async ({ page }) => {
    const doc = "see [[Project Plan]] now";
    await openWith(page, "", 0);
    await page.evaluate((d) => {
      const b = (window as unknown as { __baerchen: Hooks & { mock: { revision: number } } }).__baerchen;
      b.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: b.mock.revision, readOnly: true });
    }, doc);
    await expect(page.locator(".cm-content")).toHaveAttribute("aria-readonly", "true");
    const p = await pointAt(page, doc.indexOf("Plan"));
    await page.touchscreen.tap(p.x, p.y);
    expect(await hooks(page).sent("openLink")).toEqual([
      { type: "openLink", noteId: "mock-note", kind: "wiki", target: "Project Plan", newWindow: false },
    ]);
  });
});
