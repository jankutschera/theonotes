// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 4: tables render as a grid (the block widget layer); the source stays in `.cm-content`,
// collapsed. In source mode the table holding the caret has its pipes lined up.

type Sent = { type: string; [key: string]: unknown };
type Item = { label: string; insert: string; detail?: string; icon?: string };
type View = { state: { doc: { length: number; toString(): string } }; dispatch(spec: unknown): void };
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
  mock: { sent: Sent[]; completions: Record<string, Item[]>; deliver(msg: unknown): void };
};


const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
  sent: (type: string) =>
    page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.filter((m) => m.type === t), type),
  select: (anchor: number) =>
    page.evaluate((a) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: a } }), anchor),
});

const deliver = (page: Page, msg: Record<string, unknown>) =>
  page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg);

const settle = (page: Page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 30)))));

async function openWith(page: Page, doc: string, caret: number) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(
    ([d, c]) => {
      const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
      b.mock.completions = { tag: [{ label: "work", insert: "#work ", detail: "12" }] };
      b.debugInsert(d as string);
      b.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [doc, caret] as const,
  );
  await page.evaluate(() => document.fonts.ready);
  await settle(page);
  return content;
}

const doc = [
  "Intro line",
  "| Name | Qty | Note |",
  "|:--|--:|:-:|",
  "| **Apple** | 3 | [[Fruit List]] |",
  "| Kiwi | 12 | a \\| b `x|y` |",
  "| Banana |",
  "After line",
].join("\n");
const tableFrom = doc.indexOf("| Name");
const tableTo = doc.indexOf("\nAfter line");

const rendered = (page: Page) => page.locator(".cm-content .cm-bc-block-rendered");
const cell = (page: Page, row: number, column: number) => page.locator(`.bc-cell[data-row="${row}"][data-column="${column}"]`);

test("innerText equals the document with tables in grid mode", async ({ page }) => {
  const content = await openWith(page, doc, 0);
  await expect(rendered(page)).toHaveCount(1);
  await expect(cell(page, 0, 0)).toHaveText("Name");
  await expect(cell(page, 1, 0)).toHaveText("Apple");
  await expect(cell(page, 1, 0).locator(".cm-bc-strong")).toHaveText("Apple");
  await expect(cell(page, 2, 2)).toHaveText("a | b x|y");
  // The ragged last row is padded with empty cells.
  await expect(cell(page, 3, 2)).toHaveText("");
  await expect(cell(page, 3, 2)).toHaveClass(/bc-pad/);
  // Alignment from the delimiter row.
  expect(await cell(page, 1, 1).evaluate((el) => getComputedStyle(el).textAlign)).toBe("right");
  expect(await cell(page, 1, 2).evaluate((el) => getComputedStyle(el).textAlign)).toBe("center");
  expect(await content.innerText()).toBe(doc);
  expect(await content.evaluate((el) => el.textContent)).toBe(doc.replaceAll("\n", ""));
  expect(await hooks(page).text()).toBe(doc);
});

test("the AX mirror exposes a table with the header and cells", async ({ page }) => {
  await openWith(page, doc, 0);
  const table = page.getByRole("table", { name: "Table 1" });
  await expect(table).toHaveCount(1);
  await expect(table.getByRole("columnheader")).toHaveText(["Name", "Qty", "Note"]);
  await expect(table.getByRole("cell")).toHaveText(["Apple", "3", "Fruit List", "Kiwi", "12", "a | b x|y", "Banana", "", ""]);
  // Outside `.cm-content`, off-screen.
  expect(await page.evaluate(() => !!document.querySelector(".cm-content .cm-bc-ax-tables"))).toBe(false);
  expect(await page.evaluate(() => document.querySelector(".cm-editor > .cm-bc-ax-tables") !== null)).toBe(true);
  // In source mode the table is not mirrored (VoiceOver reads the source).
  await hooks(page).select(tableFrom + 3);
  await expect(page.getByRole("table")).toHaveCount(0);
});

test("the grid widget is aria-hidden and not editable", async ({ page }) => {
  await openWith(page, doc, 0);
  const host = rendered(page).first();
  await expect(host).toHaveAttribute("aria-hidden", "true");
  await expect(host).toHaveAttribute("contenteditable", "false");
  expect(await host.getAttribute("role")).toBeNull();
  // Pointer-only menu buttons stay outside the keyboard and accessibility trees.
  const focusable = await host.evaluate(
    (el) => Array.from(el.shadowRoot!.querySelectorAll<HTMLElement>("a, button, input, textarea, select, [tabindex], [contenteditable]")).filter(node => node.tabIndex >= 0 || node.isContentEditable).length,
  );
  expect(focusable).toBe(0);
});

test("click on a cell puts the caret at the end of that cell and shows the aligned source", async ({ page }) => {
  const content = await openWith(page, doc, doc.length);
  await cell(page, 2, 0).click();
  expect((await hooks(page).selection()).head).toBe(doc.indexOf("Kiwi") + "Kiwi".length);
  await expect(rendered(page)).toHaveCount(0);
  await expect(page.locator(".cm-line.cm-bc-table-header")).toHaveText("| Name | Qty | Note |");
  await expect(page.locator(".cm-content .cm-bc-table-spacer").first()).toBeAttached();
  // The spacers are aria-hidden and no part of the content text.
  expect(await content.innerText()).toBe(doc);
  await page.keyboard.type("s");
  expect(await hooks(page).text()).toBe(doc.replace("Kiwi", "Kiwis"));
  // Out of the table: rendered again.
  await hooks(page).select(doc.length);
  await expect(rendered(page)).toHaveCount(1);
});

/** The x (centre) of each unescaped pipe outside code, per line of `.cm-line`s matching `rows`. */
async function pipeColumns(page: Page): Promise<number[][]> {
  return page.evaluate(() => {
    const lines = [...document.querySelectorAll(".cm-content .cm-line")].filter((l) => l.textContent!.trim().startsWith("|"));
    return lines.map((line) => {
      const out: number[] = [];
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      let prev = "";
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const text = node.textContent!;
        for (let i = 0; i < text.length; i++) {
          if (text[i] === "|" && prev !== "\\") {
            const range = document.createRange();
            range.setStart(node, i);
            range.setEnd(node, i + 1);
            // The centre: WebKit rounds some glyph rects outwards to whole pixels.
            const rect = range.getBoundingClientRect();
            out.push((rect.left + rect.right) / 2);
          }
          prev = text[i]!;
        }
      }
      return out;
    });
  });
}

test("columns line up in source mode", async ({ page }) => {
  const source = ["Text", "| a | bbbbbbbb | c |", "|---|:-:|---|", "| wide cell here | x | **bold** |", "| y | 漢字 |", "end"].join("\n");
  await openWith(page, source, source.indexOf("| y") + 2);
  await expect(rendered(page)).toHaveCount(0);
  await expect.poll(async () => (await pipeColumns(page)).length).toBe(4);
  await expect
    .poll(async () => {
      const rows = await pipeColumns(page);
      const columns = Math.max(...rows.map((r) => r.length));
      let worst = 0;
      for (let k = 0; k < columns; k++) {
        const xs = rows.filter((r) => k < r.length).map((r) => r[k]!);
        worst = Math.max(worst, Math.max(...xs) - Math.min(...xs));
      }
      return worst;
    })
    .toBeLessThanOrEqual(1);
  // Typing in a cell keeps them lined up.
  await page.keyboard.type("yyyyyyyyyyyyyyyyyy");
  await settle(page);
  await expect
    .poll(async () => {
      const rows = await pipeColumns(page);
      const xs = rows.map((r) => r[1]!);
      return Math.max(...xs) - Math.min(...xs);
    })
    .toBeLessThanOrEqual(1);
  expect(await page.locator(".cm-content").innerText()).toBe(await hooks(page).text());
});

test("⌘-click on a wiki link in the grid posts openLink", async ({ page }) => {
  await openWith(page, doc, 0);
  await page.locator(".bc-cell .cm-bc-wikilink", { hasText: "Fruit List" }).click({ modifiers: ["Meta"] });
  expect(await hooks(page).sent("openLink")).toEqual([
    expect.objectContaining({ type: "openLink", kind: "wiki", target: "Fruit List", newWindow: false }),
  ]);
  // The table stays rendered and the caret where it was.
  expect((await hooks(page).selection()).head).toBe(0);
  await expect(rendered(page)).toHaveCount(1);
});

test("# in a cell opens tag autocomplete", async ({ page }) => {
  await openWith(page, doc, doc.length);
  await cell(page, 2, 0).click();
  await page.keyboard.type(" #wo");
  await expect(page.locator(".cm-tooltip-autocomplete li")).toHaveText(["work12"]);
  // CodeMirror ignores Enter for `interactionDelay` (75 ms) after the list opens; a loaded
  // machine made this the known flake (Enter inserted a line break).
  await page.waitForTimeout(150);
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe(doc.replace("Kiwi", "Kiwi #work"));
});

test("Backspace below and Delete above a rendered table first enter it", async ({ page }) => {
  await openWith(page, doc, tableTo + 1);
  await page.keyboard.press("Backspace");
  expect(await hooks(page).text()).toBe(doc);
  expect((await hooks(page).selection()).head).toBe(tableTo);
  await expect(rendered(page)).toHaveCount(0);
  await hooks(page).select(tableFrom - 1);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.press("Delete");
  expect(await hooks(page).text()).toBe(doc);
  expect((await hooks(page).selection()).head).toBe(tableFrom);
  await expect(rendered(page)).toHaveCount(0);
  // An empty line next to the table is just removed.
  const spaced = doc.replace("\nAfter line", "\n\nAfter line");
  await openWith(page, spaced, tableTo + 1);
  await page.keyboard.press("Backspace");
  expect(await hooks(page).text()).toBe(doc);
});

test("Ctrl-N enters a rendered table like ArrowDown, Ctrl-P from below", async ({ page }) => {
  await openWith(page, doc, tableFrom - 1);
  await page.keyboard.press("Control+n");
  expect((await hooks(page).selection()).head).toBe(doc.indexOf("Name"));
  await expect(rendered(page)).toHaveCount(0);
  await hooks(page).select(tableTo + 1);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.press("Control+p");
  expect((await hooks(page).selection()).head).toBe(doc.indexOf("Banana"));
});

test("caret page motions (Ctrl-↓/↑) go past a rendered table instead of into it", async ({ page }) => {
  const filler = (n: number) => Array.from({ length: n }, (_, i) => `Line ${i}`).join("\n");
  const rows = Array.from({ length: 41 }, (_, i) => `| r${i} | ${i} |`).join("\n");
  const long = `${filler(4)}\n| a | b |\n|---|---|\n${rows}\n${filler(40)}`;
  const from = long.indexOf("| a |");
  const to = long.indexOf("\nLine 0", from);
  await openWith(page, long, 0);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.press("Control+ArrowDown");
  let head = (await hooks(page).selection()).head;
  expect(head).toBeGreaterThan(0);
  expect(head < from || head > to).toBe(true);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.press("Control+ArrowUp");
  head = (await hooks(page).selection()).head;
  expect(head < from || head > to).toBe(true);
  await expect(rendered(page)).toHaveCount(1);
  expect(await hooks(page).text()).toBe(long);
});

test("drag-selecting across a rendered table selects it whole and keeps it rendered", async ({ page }) => {
  await openWith(page, doc, doc.length);
  const intro = (await page.locator(".cm-line", { hasText: "Intro line" }).boundingBox())!;
  const grid = (await rendered(page).boundingBox())!;
  const after = (await page.locator(".cm-line", { hasText: "After line" }).boundingBox())!;
  await page.mouse.move(intro.x + 10, intro.y + intro.height / 2);
  await page.mouse.down();
  // Over the grid the head stays at the table's first position, outside it (an end at
  // `block.from` with the other end above counts as outside); the grid stays.
  await page.mouse.move(grid.x + 40, grid.y + grid.height / 2, { steps: 4 });
  await settle(page);
  let sel = await hooks(page).selection();
  expect(sel.anchor).toBeLessThan(tableFrom);
  expect(sel.head === tableFrom || sel.head === tableTo + 1).toBe(true);
  await expect(rendered(page)).toHaveCount(1);
  await page.mouse.move(after.x + 30, after.y + after.height / 2, { steps: 4 });
  await page.mouse.up();
  await settle(page);
  sel = await hooks(page).selection();
  expect(sel.head).toBeGreaterThan(tableTo);
  await expect(rendered(page)).toHaveCount(1);
  // A keyboard change of that selection shows the source as before.
  await page.keyboard.press("Shift+ArrowLeft");
  await expect(rendered(page)).toHaveCount(0);
  expect(await hooks(page).text()).toBe(doc);
});

test("PageDown scrolls through a tall rendered table page by page; the selection stays", async ({ page }) => {
  const rows = Array.from({ length: 41 }, (_, i) => `| r${i} | ${i} |`).join("\n");
  const long = `Line 0\n| a | b |\n|---|---|\n${rows}\nBelow 0\n${Array.from({ length: 40 }, (_, i) => `More ${i}`).join("\n")}`;
  await openWith(page, long, 0);
  await expect(rendered(page)).toHaveCount(1);
  const scrollTop = () => page.evaluate(() => document.querySelector(".cm-scroller")!.scrollTop);
  const top0 = await scrollTop();
  await page.keyboard.press("PageDown");
  await settle(page);
  expect(await hooks(page).selection()).toEqual({ anchor: 0, head: 0 });
  await expect(rendered(page)).toHaveCount(1);
  const height = await page.evaluate(() => document.querySelector(".cm-scroller")!.clientHeight);
  expect(await scrollTop()).toBeGreaterThan(top0 + height / 2);
  // The middle of the window shows the table, not the line after it.
  const middle = await page.evaluate(() => {
    const scroller = document.querySelector(".cm-scroller")!.getBoundingClientRect();
    const el = document.elementFromPoint(scroller.left + scroller.width / 2, scroller.top + scroller.height / 2);
    return !!el?.closest(".cm-bc-block-rendered");
  });
  expect(middle).toBe(true);
  // On to the table's last row.
  await page.keyboard.press("PageDown");
  await settle(page);
  const last = await cell(page, 41, 0).boundingBox();
  const viewport = page.viewportSize()!;
  expect(last!.y).toBeGreaterThan(0);
  expect(last!.y + last!.height).toBeLessThan(viewport.height);
  await page.keyboard.press("PageUp");
  await settle(page);
  expect(await hooks(page).selection()).toEqual({ anchor: 0, head: 0 });
});

test("triple-click on the line above a table selects that line only", async ({ page }) => {
  await openWith(page, doc, doc.length);
  await page.locator(".cm-line", { hasText: "Intro line" }).click({ clickCount: 3 });
  await settle(page);
  const sel = await hooks(page).selection();
  expect(Math.min(sel.anchor, sel.head)).toBe(0);
  expect(Math.max(sel.anchor, sel.head)).toBe(tableFrom);
  await expect(rendered(page)).toHaveCount(1);
  await page.keyboard.press("Delete");
  expect(await hooks(page).text()).toBe(doc.slice(tableFrom));
});

test("Table N is the position among all tables of the note", async ({ page }) => {
  const filler = Array.from({ length: 150 }, (_, i) => `Filler ${i}`).join("\n");
  const two = `Top\n| A1 | A2 |\n|---|---|\n| a | b |\nMiddle\n| B1 | B2 |\n|---|---|\n| c | d |\n${filler}\n| C1 |\n|---|\nEnd`;
  await openWith(page, two, 0);
  const names = () => page.locator(".cm-bc-ax-tables table").evaluateAll((els) => els.map((e) => e.getAttribute("aria-label")));
  await expect.poll(names).toEqual(["Table 1", "Table 2"]);
  // The caret enters A: A is not mirrored, B keeps its number.
  await hooks(page).select(two.indexOf("A1"));
  await expect.poll(names).toEqual(["Table 2"]);
  await expect(page.getByRole("table", { name: "Table 2" }).getByRole("columnheader")).toHaveText(["B1", "B2"]);
  // Scrolled to the end: the third table is "Table 3", not "Table 1".
  await hooks(page).select(two.length);
  await page.evaluate(() => {
    const scroller = document.querySelector(".cm-scroller")!;
    scroller.scrollTop = scroller.scrollHeight;
  });
  await expect.poll(names).toEqual(["Table 3"]);
  // Typing above renumbers nothing.
  await hooks(page).select(0);
  await page.keyboard.type("x");
  await page.evaluate(() => {
    const scroller = document.querySelector(".cm-scroller")!;
    scroller.scrollTop = scroller.scrollHeight;
  });
  await expect.poll(names).toEqual(["Table 3"]);
  // A table added above renumbers.
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ changes: { from: 0, insert: "| N |\n|---|\n\n" } }),
  );
  await page.evaluate(() => {
    const scroller = document.querySelector(".cm-scroller")!;
    scroller.scrollTop = scroller.scrollHeight;
  });
  await expect.poll(names).toEqual(["Table 4"]);
});

test("Table N follows a source table deleted between mirrored ones", async ({ page }) => {
  const three = `Top\n| A1 |\n|---|\nOne\n| B1 |\n|---|\nTwo\n| C1 |\n|---|\nEnd`;
  await openWith(page, three, three.indexOf("B1"));
  const names = () => page.locator(".cm-bc-ax-tables table").evaluateAll((els) => els.map((e) => e.getAttribute("aria-label")));
  await expect.poll(names).toEqual(["Table 1", "Table 3"]);
  // One transaction: text typed above A, B (the source table) deleted.
  const b = three.indexOf("| B1 |");
  await page.evaluate(
    ([from, to]) =>
      (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({
        changes: [{ from: 0, insert: "x" }, { from: from as number, to: to as number }],
        selection: { anchor: 0 },
      }),
    [b, three.indexOf("Two")],
  );
  await expect.poll(names).toEqual(["Table 1", "Table 2"]);
});

test("alignment re-measures after a Hide Markdown change and TagCons", async ({ page }) => {
  const source = ["Text", "| **a** | b |", "|---|---|", "| a much longer cell #work | c |", "end"].join("\n");
  await openWith(page, source, source.indexOf("| a much") + 3);
  // Within 2 px (bold header pipes and rounded glyph rects); a stale cache is ~30 px off.
  const worst = async () => {
    const rows = await pipeColumns(page);
    let bad = 0;
    for (let k = 0; k < 3; k++) {
      const xs = rows.map((r) => r[k]!).filter((x) => x !== undefined);
      bad = Math.max(bad, Math.max(...xs) - Math.min(...xs));
    }
    return bad;
  };
  await expect.poll(worst).toBeLessThanOrEqual(2);
  await deliver(page, { type: "setSettings", hideMarkdown: false });
  await expect(page.locator(".cm-line", { hasText: "**a**" })).toBeVisible();
  await expect.poll(worst).toBeLessThanOrEqual(2);
  await deliver(page, { type: "tagIcons", icons: { work: "briefcase" } });
  await expect(page.locator(".cm-content .cm-bc-tagcon")).toHaveCount(1);
  await expect.poll(worst).toBeLessThanOrEqual(2);
});

test("paragraph indent: table lines and the grid are not indented", async ({ page }) => {
  await openWith(page, doc, doc.length);
  await deliver(page, { type: "setSettings", typography: { paragraphIndent: 2 } });
  const intro = page.locator(".cm-line", { hasText: "Intro line" });
  await expect.poll(() => intro.evaluate((el) => getComputedStyle(el).textIndent)).toBe("32px");
  expect(await page.locator(".bc-table").evaluate((el) => getComputedStyle(el).textIndent)).toBe("0px");
  expect(await cell(page, 1, 0).evaluate((el) => getComputedStyle(el).textIndent)).toBe("0px");
  await hooks(page).select(tableFrom + 2);
  await expect(rendered(page)).toHaveCount(0);
  const lines = page.locator(".cm-line.cm-bc-table-line");
  await expect(lines).toHaveCount(5);
  expect(await lines.evaluateAll((els) => els.map((el) => getComputedStyle(el).textIndent))).toEqual(Array(5).fill("0px"));
});

test("code and tags look the same in the grid and in the text", async ({ page }) => {
  const note = "Prose `code` and #tag\n| `code` #tag |\n|---|\nend";
  await openWith(page, note, note.length);
  await expect(rendered(page)).toHaveCount(1);
  const style = (el: Element) => {
    const s = getComputedStyle(el);
    return { color: s.color, background: s.backgroundColor, font: s.fontFamily, size: s.fontSize, radius: s.borderRadius };
  };
  const prose = page.locator(".cm-line", { hasText: "Prose" });
  for (const cls of [".cm-bc-code", ".cm-bc-tag"]) {
    const inText = await prose.locator(cls).first().evaluate(style);
    const inGrid = await page.locator(`.bc-cell ${cls}`).first().evaluate(style);
    expect(inGrid, cls).toEqual(inText);
  }
});

test("table grid matches the screenshot baseline", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 500 });
  const note = [
    "# Shopping",
    "",
    "| Item | Qty | Price | Notes |",
    "|:--|:-:|--:|---|",
    "| **Apples** | 3 | 2.40 | from the *market* |",
    "| Bread | 1 | 3.10 | [[Bakery]] #food |",
    "| Cheese | 2 | 7.95 | `aged` ==12 months== |",
    "| Tea |",
    "",
    "After the table.",
  ].join("\n");
  await openWith(page, note, note.length);
  await expect(rendered(page)).toHaveCount(1);
  // No hover outline: the pointer away from the grid.
  await page.mouse.move(5, 490);
  await settle(page);
  await expect(page).toHaveScreenshot("table-grid.png", { maxDiffPixelRatio: 0.002 });
});

// M6 Task 5: table editing.

const small = "| a | b |\n|---|---|\n| c | d |";

test("⌥⌘T then typing fills the first header cell", async ({ page }) => {
  await openWith(page, "", 0);
  await page.keyboard.press("Meta+Alt+t");
  expect(await hooks(page).text()).toBe("|  |  |  |\n|---|---|---|\n|  |  |  |\n|  |  |  |");
  await page.keyboard.type("Name");
  expect(await hooks(page).text()).toBe("| Name |  |  |\n|---|---|---|\n|  |  |  |\n|  |  |  |");
  await page.keyboard.press("Tab");
  await page.keyboard.type("Qty");
  expect((await hooks(page).text()).split("\n")[0]).toBe("| Name | Qty |  |");
});

test("Tab walks the cells and appends a row in the last one; Shift-Tab goes back", async ({ page }) => {
  await openWith(page, small, 3);
  await page.keyboard.press("Tab");
  expect(await hooks(page).selection()).toEqual({ anchor: 6, head: 7 });
  await page.keyboard.press("Tab");
  expect(await hooks(page).selection()).toEqual({ anchor: small.indexOf("c"), head: small.indexOf("c") + 1 });
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  expect(await hooks(page).text()).toBe(`${small}\n|  |  |`);
  expect((await hooks(page).selection()).head).toBe(small.length + 1 + 2);
  await page.keyboard.type("x");
  expect((await hooks(page).text()).split("\n")[3]).toBe("| x |  |");
  await page.keyboard.press("Shift+Tab");
  expect(await hooks(page).selection()).toEqual({ anchor: small.indexOf("d"), head: small.indexOf("d") + 1 });
});

test("Tab in a table inside a list item moves between cells instead of indenting", async ({ page }) => {
  const list = "- | a | b |\n  |---|---|\n  | c | d |";
  await openWith(page, list, 4);
  await page.keyboard.press("Tab");
  expect(await hooks(page).text()).toBe(list);
  expect(await hooks(page).selection()).toEqual({ anchor: list.indexOf("b"), head: list.indexOf("b") + 1 });
});

test("⌃⌘↓ adds a row below the caret row; ⌃⌘→ adds a column; ⌃⌘⌫ deletes the row", async ({ page }) => {
  await openWith(page, small, 3);
  await page.keyboard.press("Control+Meta+ArrowDown");
  expect(await hooks(page).text()).toBe("| a | b |\n|---|---|\n|  |  |\n| c | d |");
  expect((await hooks(page).selection()).head).toBe(3);
  await page.keyboard.press("Control+Meta+ArrowRight");
  expect(await hooks(page).text()).toBe("| a |  | b |\n|---|---|---|\n|  |  |  |\n| c |  | d |");
  await page.keyboard.press("Control+Meta+Backspace");
  // The caret was in the header: deleting it promotes the first body row.
  expect(await hooks(page).text()).toBe("|  |  |  |\n|---|---|---|\n| c |  | d |");
  await page.keyboard.press("Meta+z");
  expect((await hooks(page).text()).split("\n")).toHaveLength(4);
});

test("Return in a cell adds a line (<br>) shown in the grid", async ({ page }) => {
  const withAfter = `${small}\n\nafter`;
  await openWith(page, withAfter, small.indexOf("d") + 1);
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe(withAfter.replace("d |", "d<br> |"));
  await page.keyboard.type("e");
  await hooks(page).select(withAfter.length + 4);
  await settle(page);
  await expect(cell(page, 1, 1)).toHaveText("de");
  expect(await cell(page, 1, 1).evaluate((el) => el.querySelectorAll("br").length)).toBe(1);
});

test("Return in an empty last row leaves the table", async ({ page }) => {
  const empty = "| a |\n|---|\n| c |\n|  |";
  await openWith(page, empty, empty.length - 2);
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe("| a |\n|---|\n| c |\n");
  expect((await hooks(page).selection()).head).toBe("| a |\n|---|\n| c |\n".length);
  await page.keyboard.type("after");
  expect(await hooks(page).text()).toBe("| a |\n|---|\n| c |\nafter");
});

test("a table that is the whole note can be left by keyboard: ↩ at its end and at its start (M6-R77)", async ({ page }) => {
  const only = "| a | b |\n|---|---|\n| c | d |";
  await openWith(page, only, 0);
  await page.keyboard.press("Meta+ArrowDown");
  await page.keyboard.press("Enter");
  await page.keyboard.type("below");
  expect(await hooks(page).text()).toBe(only + "\nbelow");
  await page.keyboard.press("Meta+ArrowUp");
  expect((await hooks(page).selection()).head).toBe(0);
  await page.keyboard.press("Enter");
  await page.keyboard.press("ArrowUp");
  await page.keyboard.type("above");
  expect(await hooks(page).text()).toBe("above\n" + only + "\nbelow");
  // Inside a cell ↩ still adds a line in the cell.
  await hooks(page).select(("above\n" + only).indexOf("d") + 1);
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe("above\n" + only.replace("d |", "d<br> |") + "\nbelow");
});

// M6 Task 6: the cell ⋯ button, Copy Table As, TSV and in-cell paste.

const grid = "Intro\n\n| a | b |\n|---|---|\n| c | d |\n| e | f |\n\nafter";

test("the cell ⋯ button shows on hover, is aria-hidden and posts tableMenu without leaving the grid", async ({ page }) => {
  await openWith(page, grid, grid.length);
  await expect(rendered(page)).toHaveCount(1);
  const button = cell(page, 2, 1).locator(".bc-cell-menu");
  await expect(button).toHaveAttribute("aria-hidden", "true");
  await expect(button).toBeHidden();
  // Not focusable: widget DOM holds no focusable element.
  expect(await page.locator(".cm-bc-block-rendered button, .cm-bc-block-rendered [tabindex]").count()).toBe(0);
  await cell(page, 2, 1).hover();
  await expect(button).toBeVisible();
  expect(await button.evaluate((el) => getComputedStyle(el, "::before").content)).toBe('"⋯"');
  await expect(cell(page, 2, 1)).toHaveText("f");
  const before = await hooks(page).selection();
  await button.click();
  const [menu] = (await hooks(page).sent("tableMenu")) as unknown as {
    menuId: string;
    row: number;
    column: number;
    rows: number;
    columns: number;
    rect: { width: number };
  }[];
  expect(menu).toMatchObject({ type: "tableMenu", noteId: "mock-note", row: 2, column: 1, rows: 3, columns: 2 });
  expect(menu!.menuId).toMatch(/^menu-/);
  expect(menu!.rect.width).toBeGreaterThan(0);
  // The caret did not move and the table stays rendered; the document is untouched.
  expect(await hooks(page).selection()).toEqual(before);
  await expect(rendered(page)).toHaveCount(1);
  expect(await hooks(page).text()).toBe(grid);

  // The host answers with the menu's choice: the command lands on the clicked cell's row.
  await deliver(page, { type: "applyCommand", name: "tableAddRow", args: { menuId: menu!.menuId } });
  expect(await hooks(page).text()).toBe(grid.replace("| e | f |", "| e | f |\n|  |  |"));
});

test("a ⋯ button on a padded cell of a ragged row names that column", async ({ page }) => {
  await openWith(page, doc, 0);
  await cell(page, 3, 2).hover();
  await cell(page, 3, 2).locator(".bc-cell-menu").click();
  const [menu] = (await hooks(page).sent("tableMenu")) as unknown as { menuId: string; row: number; column: number; rows: number; columns: number }[];
  expect(menu).toMatchObject({ row: 3, column: 2, rows: 4, columns: 3 });
  // Final review I2: Delete Column from that padding cell deletes column 3, not the row's last real one.
  await deliver(page, { type: "applyCommand", name: "tableDeleteColumn", args: { menuId: menu!.menuId } });
  expect(await hooks(page).text()).toBe(
    ["Intro line", "| Name | Qty |", "|:--|--:|", "| **Apple** | 3 |", "| Kiwi | 12 |", "| Banana |", "After line"].join("\n"),
  );
});

test("Copy Table As posts copyText: CSV and Markdown as text, HTML as text and html", async ({ page }) => {
  const source = '| A | B |\n|---|--:|\n| **x, y** | "q" |';
  await openWith(page, source, 0);
  await deliver(page, { type: "applyCommand", name: "copyTable", args: { format: "csv" } });
  await deliver(page, { type: "applyCommand", name: "copyTable", args: { format: "markdown" } });
  await deliver(page, { type: "applyCommand", name: "copyTable", args: { format: "html" } });
  const html =
    "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td><strong>x, y</strong></td><td>&quot;q&quot;</td></tr></tbody></table>";
  expect(await hooks(page).sent("copyText")).toEqual([
    { type: "copyText", text: 'A,B\r\n"x, y","""q"""' },
    { type: "copyText", text: source },
    { type: "copyText", text: html, html },
  ]);
  expect(await hooks(page).text()).toBe(source);
});

test("Copy Table As works in a read-only note", async ({ page }) => {
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  const source = "| A |\n|---|\n| 1 |";
  await page.evaluate((d) => {
    const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
    b.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: (b.mock as unknown as { revision: number }).revision, readOnly: true });
    b.debugView().dispatch({ selection: { anchor: 2 } });
  }, source);
  await expect.poll(() => hooks(page).text()).toBe(source);
  await deliver(page, { type: "applyCommand", name: "copyTable", args: { format: "csv" } });
  expect(await hooks(page).sent("copyText")).toEqual([{ type: "copyText", text: "A\r\n1" }]);
});

/** Dispatches a paste event with clipboard data on the editor. */
const paste = (page: Page, data: { text?: string; html?: string }) =>
  page.evaluate((d) => {
    const clipboardData = new DataTransfer();
    if (d.text !== undefined) clipboardData.setData("text/plain", d.text);
    if (d.html !== undefined) clipboardData.setData("text/html", d.html);
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
  }, data);

test("TSV pastes as a table", async ({ page }) => {
  await openWith(page, "", 0);
  await paste(page, { text: "Name\tQty\nApple\t3\n" });
  expect(await hooks(page).text()).toBe("| Name | Qty |\n| --- | --- |\n| Apple | 3 |");
});

test("text pasted into a cell stays in the cell", async ({ page }) => {
  const source = "| a | b |\n|---|---|\n| c | d |";
  await openWith(page, source, source.indexOf("c") + 1);
  await paste(page, { text: "x|y\nz" });
  expect(await hooks(page).text()).toBe("| a | b |\n|---|---|\n| cx\\|y<br>z | d |");
});
