// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { typographyNote as note } from "./fixtures/typography-note";
import { visibleText } from "./visible";

type View = {
  state: { doc: { length: number; line(n: number): { from: number; to: number } }; selection: { main: { head: number } } };
  dispatch(spec: unknown): void;
  coordsAtPos(pos: number, side?: number): { left: number; right: number; top: number; bottom: number } | null;
};
type Hooks = {
  debugInsert(text: string): void;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
  mock?: { sent: { type: string }[] };
};

const lineOf = (needle: string) => note.split("\n").findIndex((l) => l.startsWith(needle)) + 1;

async function openWith(page: Page, doc: string, caret = doc.length) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(
    ([d, c]) => {
      const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
      api.debugInsert(d as string);
      api.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [doc, caret] as const,
  );
  await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 50)))));
  return content;
}

const sent = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.sent);

test("typography fixture note matches the screenshot baseline", async ({ page }) => {
  await page.setViewportSize({ width: 1000, height: 1200 });
  await openWith(page, note);
  await expect(page).toHaveScreenshot("typography.png", { maxDiffPixelRatio: 0.002 });
});

test("every line's text is still the document line; bullets are aria-hidden additions", async ({ page }) => {
  // Without the trailing empty line: innerText adds a newline for its <br>.
  const doc = note.trimEnd();
  const content = await openWith(page, doc);
  const docLines = doc.split("\n");
  const lines = content.locator(".cm-line");
  await expect(lines).toHaveCount(docLines.length);
  for (let i = 0; i < docLines.length; i++) await expect(lines.nth(i)).toHaveText(docLines[i]!, { useInnerText: false });
  expect(await content.innerText()).toBe(doc);

  const bullets = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-bullet")].map((el) => ({
      glyph: getComputedStyle(el, "::before").content,
      text: el.textContent,
      ariaHidden: el.getAttribute("aria-hidden"),
      inHidden: !!el.closest(".cm-bc-hidden"),
      width: el.getBoundingClientRect().width,
    })),
  );
  expect(bullets.map((b) => b.glyph)).toEqual(['"•"', '"•"', '"◦"', '"▪"', '"•"']);
  for (const b of bullets) {
    expect(b).toMatchObject({ text: "", ariaHidden: "true", inHidden: false });
    expect(b.width).toBeGreaterThan(4);
  }
  // The markers are collapsed, not removed.
  expect(await visibleText(lines.nth(lineOf("- First") - 1))).toBe("First bullet");
  expect(await visibleText(lines.nth(lineOf("> A quote") - 1))).toBe("A quote that runs long enough to wrap onto a second visual line in the centered column of the editor.");
  expect(await visibleText(lines.nth(lineOf("---") - 1))).toBe("");
  await expect(lines.nth(lineOf("---") - 1)).toHaveClass(/cm-bc-hr/);
});

test("the caret on a bullet marker shows the raw marker; moving away brings the bullet back", async ({ page }) => {
  const at = note.indexOf("- Second");
  const content = await openWith(page, note, at);
  const line = content.locator(".cm-line").nth(lineOf("- Second") - 1);
  expect(await visibleText(line)).toBe("- Second bullet with bold");
  await expect(content.locator(".cm-bc-bullet")).toHaveCount(4);
  await page.evaluate((pos) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: pos } }), at + 3);
  await expect(content.locator(".cm-bc-bullet")).toHaveCount(5);
  expect(await visibleText(line)).toBe("Second bullet with bold");
});

test("content column: centered, at most 720 px wide", async ({ page }) => {
  await page.setViewportSize({ width: 1200, height: 800 });
  const content = await openWith(page, note);
  const box = (await content.boundingBox())!;
  expect(box.width).toBeLessThanOrEqual(720);
  expect(box.width).toBeGreaterThan(700);
  expect(Math.abs(box.x + box.width / 2 - 600)).toBeLessThan(1);
  // Over-scroll: half a window of space after the last line.
  const padding = await content.evaluate((el) => parseFloat(getComputedStyle(el).paddingBottom));
  expect(padding).toBe(400);
});

test("heading badges: H1…H6 in the gutter next to the text, text not shifted, click posts headingMenu", async ({ page }) => {
  await openWith(page, note);
  const badges = page.locator(".cm-bc-hbadge");
  await expect(badges).toHaveText(["H1", "H2", "H3", "H4", "H5", "H6"]);
  const geometry = await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const lines = [...document.querySelectorAll(".cm-line")];
    // The first visible character of a line: its left edge.
    const textLeft = (el: Element) => {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode as Text;
        if (node.parentElement?.closest(".cm-bc-hidden") || !node.data.trim()) continue;
        const range = document.createRange();
        range.setStart(node, 0);
        range.setEnd(node, 1);
        return range.getBoundingClientRect().left;
      }
      return NaN;
    };
    const headingLines = lines.filter((el) => el.classList.contains("cm-bc-heading"));
    return {
      paragraphLeft: textLeft(lines[1]!),
      headings: headingLines.map((el, i) => {
        const badge = document.querySelectorAll(".cm-bc-hbadge > span")[i]!.getBoundingClientRect();
        const line = el.getBoundingClientRect();
        const firstRow = view.coordsAtPos(view.state.doc.line(lines.indexOf(el) + 1).to, -1)!;
        return { left: textLeft(el), badgeRight: badge.right, badgeMid: (badge.top + badge.bottom) / 2, row: firstRow, lineTop: line.top };
      }),
    };
  });
  expect(geometry.headings).toHaveLength(6);
  for (const h of geometry.headings) {
    expect(Math.abs(h.left - geometry.paragraphLeft)).toBeLessThan(0.5);
    expect(h.badgeRight).toBeLessThanOrEqual(h.left);
    expect(h.badgeRight).toBeGreaterThan(h.left - 16);
    expect(h.badgeMid).toBeGreaterThan(h.row.top);
    expect(h.badgeMid).toBeLessThan(h.row.bottom);
  }

  const before = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
  const badgeBox = (await badges.nth(1).boundingBox())!;
  await badges.nth(1).click();
  await expect.poll(() => sent(page).then((s) => s.filter((m) => m.type === "headingMenu"))).toEqual([
    {
      type: "headingMenu",
      noteId: "mock-note",
      menuId: expect.stringMatching(/^menu-/),
      line: lineOf("## Colors"),
      level: 2,
      folded: false,
      // The badge's own rect.
      rect: { x: badgeBox.x, y: badgeBox.y, width: badgeBox.width, height: badgeBox.height },
    },
  ]);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection())).toEqual(before);
  // Revealing the heading mark (caret on the line) does not move the badge.
  const badgeX = (await badges.nth(1).boundingBox())!.x;
  await page.evaluate((pos) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: pos } }), note.indexOf("## Colors") + 5);
  await expect(page.locator(".cm-line").nth(lineOf("## Colors") - 1)).toHaveText("## Colors and links");
  expect((await badges.nth(1).boundingBox())!.x).toBe(badgeX);
});

test("a line whose content is entirely hidden still shows a caret when clicked", async ({ page }) => {
  const doc = "before\n==🟢==\n[](https://example.com)\nafter";
  const content = await openWith(page, doc);
  for (const n of [2, 3]) {
    const line = content.locator(".cm-line").nth(n - 1);
    const box = (await line.boundingBox())!;
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    const caret = await page.evaluate((lineNo) => {
      const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
      const { from, to } = view.state.doc.line(lineNo);
      const head = view.state.selection.main.head;
      const el = document.querySelectorAll(".cm-line")[lineNo - 1]!;
      const sel = document.getSelection()!;
      return {
        onLine: head >= from && head <= to,
        coords: view.coordsAtPos(head),
        line: el.getBoundingClientRect().toJSON() as DOMRect,
        domInLine: el.contains(sel.focusNode),
        domInHidden: !!(sel.focusNode?.nodeType === 3 ? sel.focusNode.parentElement : (sel.focusNode as Element))?.closest(".cm-bc-hidden"),
      };
    }, n);
    expect(caret.onLine, `line ${n}`).toBe(true);
    expect(caret.domInLine, `line ${n}`).toBe(true);
    expect(caret.domInHidden, `line ${n}`).toBe(false);
    expect(caret.coords, `line ${n}`).not.toBeNull();
    expect(caret.coords!.bottom - caret.coords!.top).toBeGreaterThan(10);
    expect(caret.coords!.top).toBeGreaterThanOrEqual(caret.line.top - 0.5);
    expect(caret.coords!.bottom).toBeLessThanOrEqual(caret.line.bottom + 0.5);
  }
});

const deliverSettings = (page: Page, msg: Record<string, unknown>) =>
  page.evaluate(
    (m) => (window as unknown as { __baerchen: { mock: { deliver(msg: unknown): void } } }).__baerchen.mock.deliver({ type: "setSettings", ...m }),
    msg,
  );

test("paragraph indent moves the first row of prose lines only, in place", async ({ page }) => {
  const doc = ["plain prose", "# Heading", "- item", "  wrapped item text", "> quoted", "```", "code", "```", "---", "end"].join("\n");
  const content = await openWith(page, doc);
  const lines = content.locator(".cm-line");
  const indents = () => lines.evaluateAll((els) => els.map((el) => getComputedStyle(el).textIndent));
  const firstX = (pos: number) =>
    page.evaluate((p) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().coordsAtPos(p)!.left, pos);
  const before = await indents();
  expect(before.every((v) => v === "0px" || v.startsWith("-")), `default: no indent ${before}`).toBe(true);
  const x0 = await firstX(0);

  await deliverSettings(page, { typography: { paragraphIndent: 2 } });
  await expect.poll(() => lines.first().evaluate((el) => getComputedStyle(el).textIndent)).toBe("32px");
  const after = await indents();
  // Prose (lines 1 and 10) and nothing else; the list item keeps its hanging indent.
  expect(after.map((v, i) => [i + 1, v === "32px"]).filter(([, hit]) => hit).map(([n]) => n)).toEqual([1, 10]);
  expect(after[2]).toBe(before[2]);
  expect(await firstX(0)).toBeCloseTo(x0 + 32, 0);
  // Inline-block widgets (the bullet) do not inherit it.
  expect(await page.locator(".cm-bc-bullet").first().evaluate((el) => getComputedStyle(el).textIndent)).toBe("0px");

  await deliverSettings(page, { typography: {} });
  await expect.poll(() => indents()).toEqual(before);
});

test("the gap after a code block is the paragraph spacing", async ({ page }) => {
  await openWith(page, "```\ncode\n```\nafter");
  const gap = () => page.locator(".cm-bc-codeblock-last").evaluate((el) => parseFloat(getComputedStyle(el).borderBottomWidth));
  // WebKit snaps border widths to whole pixels (16 * 0.4 = 6.4 draws as 6).
  expect(await gap()).toBe(6);
  await deliverSettings(page, { typography: { paragraphSpacing: 1 } });
  await expect.poll(gap).toBe(16);
  // The same gap as between two plain lines.
  expect(await page.locator(".cm-line").last().evaluate((el) => parseFloat(getComputedStyle(el).paddingBottom))).toBeCloseTo(16, 1);
});

test("font settings keep the fallback stack and headings follow the text font", async ({ page }) => {
  await openWith(page, "# Head\ntext `code`");
  const vars = () =>
    page.locator(".cm-editor").evaluate((el) => {
      const s = getComputedStyle(el);
      return ["--bc-font-text", "--bc-font-heading", "--bc-font-code"].map((n) => s.getPropertyValue(n).trim());
    });
  const defaults = await vars();
  await deliverSettings(page, { typography: { fontText: "Iowan Old Style", fontCode: "Menlo" } });
  await expect.poll(vars).toEqual([`"Iowan Old Style", ${defaults[0]}`, `"Iowan Old Style", ${defaults[1]}`, `"Menlo", ${defaults[2]}`]);
  await deliverSettings(page, { typography: {} });
  await expect.poll(vars).toEqual(defaults);
});
