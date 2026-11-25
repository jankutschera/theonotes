// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";

// Finding F8: hidden markup must stay in the DOM so the accessibility text (VoiceOver, dictation,
// Writing Tools) has the document's offsets, while it renders with zero width.

type Hooks = { debugInsert(text: string): void; debugText(): string; debugSelection(): { head: number }; debugView(): View };
type View = {
  state: { doc: { length: number; toString(): string } };
  dispatch(spec: unknown): void;
  posAtDOM(node: Node, offset: number): number;
  coordsAtPos(pos: number, side?: number): { left: number; top: number; bottom: number } | null;
};


async function openWith(page: Page, doc: string, caret?: number) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, c]) => {
    (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert(d as string);
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    (window as unknown as { __view: View }).__view = view;
    if (c !== null) view.dispatch({ selection: { anchor: c } });
  }, [doc, caret ?? null] as const);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 30))));
  return content;
}

const doc = [
  "# Heading **bold**",
  "some **bold** and [link](https://example.com/path?q=1) text",
  "==🟢marked== and ~under~ and [[Note|alias]] and \\*esc\\*",
  "plain",
].join("\n");

test("hidden markup stays in the DOM: textContent and innerText equal the document", async ({ page }) => {
  const content = await openWith(page, doc);
  const lines = content.locator(".cm-line");
  const docLines = doc.split("\n");
  await expect(lines).toHaveCount(docLines.length);
  for (let i = 0; i < docLines.length; i++) await expect(lines.nth(i)).toHaveText(docLines[i]!, { useInnerText: false });
  // innerText runs WebKit's TextIterator, the same walk that builds the AX text.
  expect(await content.innerText()).toBe(doc);

  expect(await visibleText(lines.nth(0))).toBe("Heading bold");
  expect(await visibleText(lines.nth(1))).toBe("some bold and link text");
  expect(await visibleText(lines.nth(2))).toBe("marked and under and alias and *esc*");

  const hidden = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-hidden")].map((el) => {
      const r = el.getBoundingClientRect();
      return { text: el.textContent, width: r.width, height: r.height, editable: el.getAttribute("contenteditable") };
    }),
  );
  expect(hidden.map((h) => h.text)).toEqual([
    "# ", "**", "**", "**", "**", "[", "](https://example.com/path?q=1)",
    "==", "🟢", "==", "~", "~", "[[Note|", "]]", "\\", "\\",
  ]);
  for (const h of hidden) {
    expect(h.width, h.text!).toBeLessThan(0.5);
    expect(h.height, h.text!).toBeGreaterThan(5);
    expect(h.editable).toBe("false");
  }

  // The color dot is a separate aria-hidden widget; the emoji text stays (collapsed) next to it.
  const dot = await page.evaluate(() => {
    const el = document.querySelector(".cm-highlight-dot")!;
    return {
      ariaHidden: el.getAttribute("aria-hidden"),
      inHidden: !!el.parentElement?.closest(".cm-bc-hidden"),
      width: el.getBoundingClientRect().width,
      text: el.textContent,
    };
  });
  expect(dot).toEqual({ ariaHidden: "true", inHidden: false, width: expect.any(Number), text: "" });
  expect(dot.width).toBeGreaterThan(3);

  // Hidden inline boxes never make a line taller (the heading line has its own size).
  const heights = await lines.evaluateAll((els) => els.slice(1).map((el) => el.getBoundingClientRect().height));
  for (const h of heights) expect(Math.abs(h - heights.at(-1)!)).toBeLessThan(0.5);
});

test("caret geometry around hidden markup: real rects, zero width", async ({ page }) => {
  await openWith(page, doc);
  const boundaries = await page.evaluate(() => {
    const view = (window as unknown as { __view: View }).__view;
    return [...document.querySelectorAll(".cm-bc-hidden")].map((el) => {
      const from = view.posAtDOM(el, 0);
      const to = view.posAtDOM(el, el.childNodes.length);
      const line = el.closest(".cm-line")!.getBoundingClientRect();
      const at = (pos: number, side: number) => view.coordsAtPos(pos, side);
      const dotBefore = !!el.previousElementSibling?.classList.contains("cm-highlight-dot");
      return { text: el.textContent, from, to, dotBefore, line: { top: line.top, bottom: line.bottom }, coords: [at(from, -1), at(from, 1), at(to, -1), at(to, 1)] };
    });
  });
  for (const b of boundaries) {
    expect(b.to - b.from, b.text!).toBe(b.text!.length);
    for (const c of b.coords) {
      expect(c, `${b.text} @${b.from}-${b.to}`).not.toBeNull();
      // Text height (15 px), or the color dot widget's own rect next to the hidden emoji.
      expect(c!.bottom - c!.top).toBeGreaterThan(5);
      expect(c!.top).toBeGreaterThanOrEqual(b.line.top - 0.5);
      expect(c!.bottom).toBeLessThanOrEqual(b.line.bottom + 0.5);
    }
    // Zero advance: the caret is drawn at the same x on both sides of the hidden text (the color
    // emoji's `from` side is the dot widget drawn in its place).
    if (!b.dotBefore) expect(Math.abs(b.coords[1]!.left - b.coords[2]!.left), b.text!).toBeLessThan(0.5);
  }

  // Same visible text, with and without hidden link markup: identical glyph positions, apart from
  // the external-link icon after the link (visible content, not hidden markup).
  const x = await page.evaluate(() => {
    const view = (window as unknown as { __view: View }).__view;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "go [link](https://e.com/x) more AV\ngo link more AV\nend" } });
    const endOf = (line: number) => {
      const el = document.querySelectorAll(".cm-line")[line]!;
      return view.coordsAtPos(view.posAtDOM(el, el.childNodes.length), -1)!.left;
    };
    const icon = document.querySelector(".cm-line .cm-bc-link-open")!;
    const style = getComputedStyle(icon);
    const iconAdvance = icon.getBoundingClientRect().width + parseFloat(style.marginLeft) + parseFloat(style.marginRight);
    return [endOf(0) - iconAdvance, endOf(1), iconAdvance];
  });
  expect(x[2]!).toBeGreaterThan(3);
  expect(Math.abs(x[0]! - x[1]!)).toBeLessThan(0.5);
});

test("line wrapping is unchanged by hidden markup", async ({ page }) => {
  await page.setViewportSize({ width: 420, height: 700 });
  const words = Array.from({ length: 12 }, (_, i) => `word${i}`).join(" ");
  const marked = `${words} [link](https://example.com/a/very/long/path/that/never/ends?x=1) **more** ${words}`;
  const plain = `${words} link more ${words}`;
  const content = await openWith(page, `${marked}\n${plain}\nend`);
  const lines = content.locator(".cm-line");
  expect(await visibleText(lines.nth(0))).toBe(await visibleText(lines.nth(1)));
  const [a, b, single] = await lines.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().height));
  expect(a!).toBeGreaterThan(single! * 2);
  expect(Math.abs(a! - b!)).toBeLessThan(0.5);
  // The same visible word starts each wrapped row.
  const rows = await lines.evaluateAll((els) =>
    els.slice(0, 2).map((el) => {
      const range = document.createRange();
      range.selectNodeContents(el);
      const tops = new Map<number, string>();
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode as Text;
        if (node.parentElement?.closest(".cm-bc-hidden")) continue;
        for (let i = 0; i < node.length; i++) {
          range.setStart(node, i);
          range.setEnd(node, i + 1);
          const top = Math.round(range.getBoundingClientRect().top - el.getBoundingClientRect().top);
          if (!tops.has(top) && node.data[i] !== " ") tops.set(top, node.data.slice(i, i + 6));
        }
      }
      return [...tops.entries()];
    }),
  );
  expect(rows[0]).toEqual(rows[1]);
});

const typingCases: [string, string, number, string][] = [
  ["line start before an opener", "**bold** z", 0, "Q**bold** z"],
  ["after text before an opener", "x **bold** y", 2, "x Q**bold** y"],
  ["after a closer before text", "x **bold** y", 10, "x **bold**Q y"],
  ["line end after a closer", "a **bold**", 10, "a **bold**Q"],
  ["line end after a link", "a [l](https://u.v)", 18, "a [l](https://u.v)Q"],
  ["before a highlight color", "==🟢hi== b", 0, "Q==🟢hi== b"],
];

for (const [name, text, caret, expected] of typingCases) {
  test(`typing and dictation next to hidden markup land outside it: ${name}`, async ({ page }) => {
    for (const how of ["type", "insertText"] as const) {
      await openWith(page, text, caret);
      await page.evaluate(() => {
        const log: boolean[] = [];
        (window as unknown as { __intoHidden: boolean[] }).__intoHidden = log;
        new MutationObserver((ms) => {
          for (const m of ms) log.push(!!(m.target.nodeType === 3 ? m.target.parentElement : (m.target as Element))?.closest(".cm-bc-hidden"));
        }).observe(document.querySelector(".cm-content")!, { subtree: true, characterData: true, childList: true });
      });
      // `type` sends key events (like the keyboard and IME), `insertText` none (like dictation).
      if (how === "type") await page.keyboard.type("Q");
      else await page.keyboard.insertText("Q");
      await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText())).toBe(expected);
      expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head)).toBe(expected.indexOf("Q") + 1);
      // WebKit never put the new text into the collapsed markup (it would be invisible there).
      expect(await page.evaluate(() => (window as unknown as { __intoHidden: boolean[] }).__intoHidden), how).not.toContain(true);
    }
  });
}

// Revealed markup is dimmed (`cm-bc-markup`, Task 10). A class on a mark that partially overlapped
// a hidden range would make CodeMirror split the collapsed span (Task 2 concern 2): every hidden
// range must stay one whole `.cm-bc-hidden` element wherever the caret is, and no dimmed element
// may contain or sit inside hidden markup.
test("no outer mark cuts a hidden range (dimmed markup included), wherever the caret is", async ({ page }) => {
  const marked = [
    "# Heading **bold** and [[Note|alias]]",
    "some **bold _it_** and [**link**](https://example.com/p?q=1) and `code` text",
    "==🟢marked== and ~under~ ~~strike~~ and [[Note|alias]] and \\*esc\\* #tag",
    "> quoted **b** and [l](u)",
    "- item with [[Wiki]] and ==hi==",
    "- [ ] todo with **b** and [l](u)",
    "file [a.zip](a.zip)<!-- {\"embed\":\"true\"} --> and [doc.pdf](doc.pdf)<!-- {\"preview\":\"true\",\"embed\":\"true\"} --> end",
    "plain",
  ].join("\n");
  await openWith(page, marked);
  const problems = await page.evaluate(() => {
    type Api = { debugHiddenRanges(): { from: number; to: number }[] };
    const api = (window as unknown as { __baerchen: Api }).__baerchen;
    const view = (window as unknown as { __view: View }).__view;
    const out: string[] = [];
    for (let caret = 0; caret <= view.state.doc.length; caret++) {
      view.dispatch({ selection: { anchor: caret } });
      const elements = [...document.querySelectorAll(".cm-bc-hidden")]
        .filter((el) => !el.parentElement?.closest(".cm-bc-hidden"))
        .map((el) => ({ from: view.posAtDOM(el, 0), to: view.posAtDOM(el, el.childNodes.length) }));
      // Each hidden range lies inside one collapsed element (adjacent ranges may share one).
      for (const r of api.debugHiddenRanges()) {
        if (!elements.some((e) => e.from <= r.from && r.to <= e.to)) {
          out.push(`caret ${caret}: hidden ${r.from}-${r.to} split (${elements.map((e) => `${e.from}-${e.to}`).join(" ")})`);
        }
      }
      for (const el of document.querySelectorAll(".cm-bc-markup")) {
        if (el.closest(".cm-bc-hidden") || el.querySelector(".cm-bc-hidden")) out.push(`caret ${caret}: dimmed "${el.textContent}" overlaps hidden`);
      }
    }
    return out;
  });
  expect(problems).toEqual([]);
  // The walk did see both kinds, and the attachment cards.
  await expect(page.locator(".cm-bc-attachment")).toHaveCount(2);
  await page.evaluate(() => (window as unknown as { __view: View }).__view.dispatch({ selection: { anchor: 15 } }));
  await expect(page.locator(".cm-bc-markup").first()).toBeAttached();
  await expect(page.locator(".cm-bc-hidden").first()).toBeAttached();
});

// M7 Task 11: roles and labels for VoiceOver, attributes only (no text nodes, F8 holds).

test("roles and labels never add text: innerText equals the document (headings, todos, badges, highlights)", async ({ page }) => {
  const doc = ["# Title", "## Sub **bold**", "- [ ] milk", "- [x] eggs", "==🟢marked== text", "plain"].join("\n");
  const content = await openWith(page, doc, doc.length);
  expect(await content.innerText()).toBe(doc);
  const lines = content.locator(".cm-line");
  await expect(lines.nth(0)).toHaveAttribute("role", "heading");
  await expect(lines.nth(0)).toHaveAttribute("aria-level", "1");
  await expect(lines.nth(1)).toHaveAttribute("role", "heading");
  await expect(lines.nth(1)).toHaveAttribute("aria-level", "2");
  await expect(lines.nth(5)).not.toHaveAttribute("role", "heading");
  await expect(content).toHaveAttribute("aria-label", "Note text");
  await expect(content).not.toHaveAttribute("aria-readonly", "true");
});

test("a todo checkbox is a checkbox control; a click toggles aria-checked and the source", async ({ page }) => {
  await openWith(page, "- [ ] milk\nend", 13);
  const box = page.locator(".cm-content .cm-bc-todo").first();
  await expect(box).toHaveAttribute("role", "checkbox");
  await expect(box).toHaveAttribute("aria-checked", "false");
  await expect(box).toHaveAttribute("aria-label", "Todo");
  await box.click();
  await expect(page.locator(".cm-content .cm-bc-todo").first()).toHaveAttribute("aria-checked", "true");
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText())).toBe("- [x] milk\nend");
});

test("heading badges are labelled menu buttons while heading levels are shown, absent when hidden", async ({ page }) => {
  await openWith(page, "## Sub\ntext", 10);
  const badge = page.locator(".cm-bc-hbadge").first();
  await expect(badge).toHaveAttribute("role", "button");
  await expect(badge).toHaveAttribute("aria-label", "Heading level 2");
  await expect(badge).toHaveAttribute("aria-haspopup", "menu");
  await expect(badge).not.toHaveAttribute("aria-hidden", "true");
  await page.evaluate(() => {
    (window as unknown as { __baerchen: { mock: { deliver(m: unknown): void } } }).__baerchen.mock.deliver({ type: "setSettings", showHeadingLevels: false });
  });
  await expect(page.locator(".cm-bc-hbadge")).toHaveCount(0);
});

test("read-only note: aria-readonly content, aria-disabled checkboxes", async ({ page }) => {
  const content = await openWith(page, "x");
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: { mock: { revision: number; deliver(m: unknown): void } } }).__baerchen;
    hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: "- [ ] milk\nend", revision: hooks.mock.revision, readOnly: true });
  });
  await expect(content).toHaveAttribute("aria-readonly", "true");
  await expect(page.locator(".cm-content .cm-bc-todo").first()).toHaveAttribute("aria-disabled", "true");
  // An editable note again: both go.
  await page.evaluate(() => {
    const hooks = (window as unknown as { __baerchen: { mock: { revision: number; deliver(m: unknown): void } } }).__baerchen;
    hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: "- [ ] milk\nend", revision: hooks.mock.revision, readOnly: false });
  });
  await expect(content).not.toHaveAttribute("aria-readonly", "true");
  await expect(page.locator(".cm-content .cm-bc-todo").first()).not.toHaveAttribute("aria-disabled", "true");
});
