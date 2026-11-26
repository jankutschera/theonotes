// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";
import nord from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-nord.json" with { type: "json" };

/** Nord's editor tokens as the CSS variables the host sends (`--bc-<token>`). */
const nordVariables = Object.fromEntries(Object.entries(nord.editor).map(([token, value]) => [`--bc-${token}`, value]));

type Hooks = {
  debugSelection(): { anchor: number; head: number };
  debugText(): string;
  debugInsert(text: string): void;
  debugParsedLength(timeout: number): number;
  debugView(): {
    state: { replaceSelection(text: string): unknown; selection: { main: { head: number } } };
    dispatch(...specs: unknown[]): void;
    coordsAtPos(pos: number): unknown;
  };
  mock: { deliver(msg: unknown): void };
};

async function openEditor(page: Page) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  return content;
}

const hooks = (page: Page) => ({
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head),
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
});

test("caret behavior around hidden marks", async ({ page }) => {
  const content = await openEditor(page);
  const { selection, text } = hooks(page);

  // Bold at line end: typing after the hidden closer stays outside, Backspace deletes text, not marks.
  await page.keyboard.type("**bold**");
  await expect.poll(() => visibleText(content)).toBe("bold");
  await page.keyboard.press("End");
  await page.keyboard.type("x");
  expect(await text()).toBe("**bold**x");
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Backspace");
  expect(await text()).toBe("**bol**");
  await expect.poll(() => visibleText(content)).toBe("bol");
  // Home before the hidden opener: typed text goes before it, not into the bold text.
  await page.keyboard.press("Home");
  await page.keyboard.type("x");
  expect(await text()).toBe("x**bol**");
  await page.keyboard.press("Backspace");
  expect(await text()).toBe("**bol**");
  await page.keyboard.press("End");

  // Link followed by text: the caret skips the hidden `](url)` in one step.
  await page.keyboard.press("Enter");
  await page.keyboard.type("[link](https://x.y) more");
  const lineStart = (await text()).indexOf("[link]");
  await expect.poll(() => visibleText(content.locator(".cm-line").nth(1))).toBe("link more");
  for (let i = 0; i < 5; i++) await page.keyboard.press("ArrowLeft");
  expect(await selection()).toBe(lineStart + 19);
  await page.keyboard.press("ArrowLeft");
  expect(await selection()).toBe(lineStart + 5);

  // Tag at the end of a line, then a new line: the tag text stays intact.
  await page.keyboard.press("ControlOrMeta+End");
  await page.keyboard.press("Enter");
  await page.keyboard.type("see #tag");
  await page.keyboard.press("Enter");
  await page.keyboard.type("next");
  expect(await text()).toBe("**bol**\n[link](https://x.y) more\nsee #tag\nnext");
  await expect.poll(() => visibleText(content.locator(".cm-line").nth(2))).toBe("see #tag");

  // Heading mark at line start: hidden on other lines, revealed on its own line.
  await page.keyboard.press("Enter");
  await page.keyboard.type("# Title");
  await page.keyboard.press("Enter");
  await page.keyboard.type("body");
  await expect.poll(() => visibleText(content.locator(".cm-line").nth(4))).toBe("Title");
  await page.keyboard.press("ArrowUp");
  await expect.poll(() => visibleText(content.locator(".cm-line").nth(4))).toBe("# Title");
  await page.keyboard.press("Home");
  expect(await selection()).toBe((await text()).indexOf("# Title"));
});

test("line boundary keys keep CodeMirror behavior: wrapped lines, smart Home", async ({ page }) => {
  await page.setViewportSize({ width: 420, height: 600 });
  await openEditor(page);
  const { selection, text } = hooks(page);
  const words = Array.from({ length: 30 }, (_, i) => `word${i}`).join(" ");
  await page.keyboard.type(words);
  await page.keyboard.press("Home");
  const visualStart = await selection();
  expect(visualStart).toBeGreaterThan(0);
  await page.keyboard.press("Home");
  expect(await selection()).toBe(0);
  await page.keyboard.press("End");
  const visualEnd = await selection();
  expect(visualEnd).toBeLessThan(words.length);
  await page.keyboard.press("End");
  expect(await selection()).toBe(words.length);

  // Indentation first, then the line start.
  await page.keyboard.press("Enter");
  await page.keyboard.type("    indented **bold**");
  const line = (await text()).lastIndexOf("\n") + 1;
  await page.keyboard.press("Home");
  expect(await selection()).toBe(line + 4);
  await page.keyboard.press("Home");
  expect(await selection()).toBe(line);
  await page.keyboard.press("End");
  expect(await selection()).toBe((await text()).length);
  await page.keyboard.press("Shift+Home");
  await page.keyboard.press("Shift+End");
  expect(await selection()).toBe((await text()).length);
});

test("Bear marks render hidden: highlight dot, underline, wiki alias, escapes", async ({ page }) => {
  const content = await openEditor(page);
  await page.keyboard.type("==🟢hi==");
  await expect.poll(() => visibleText(content)).toBe("hi");
  await expect(content.locator(".cm-highlight-dot-green")).toHaveCount(1);
  // Backspace right after the hidden highlight closer deletes the visible "i".
  await page.keyboard.press("Backspace");
  expect(await hooks(page).text()).toBe("==🟢h==");
  await expect(content.locator(".cm-highlight-dot-green")).toHaveCount(1);

  await page.keyboard.press("Enter");
  await page.keyboard.type("~u~ [[Note|alias]] \\*no\\* end");
  await expect.poll(() => visibleText(content.locator(".cm-line").nth(1))).toBe("u alias *no* end");
});

// With typewriter mode on every keystroke also centres the caret line (M6 Task 14): the timing then
// includes the forced layout of the scroll and its correction, like the keystroke a user types.
for (const typewriter of [false, true]) {
test(`perf: 500k chars${typewriter ? ", typewriter mode on" : ""}`, async ({ page }) => {
  await openEditor(page);
  // A dark theme (Nord) is applied before timing (M7 Task 6): its variables and `appearance: dark` must not slow typing.
  await page.evaluate((theme) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "setSettings", appearance: "dark", theme }), nordVariables);
  await expect(page.locator(".cm-editor")).toHaveCSS("color-scheme", "dark");
  if (typewriter) await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "setSettings", typewriterMode: true }));
  if (typewriter) await expect(page.locator(".cm-editor.cm-bc-typewriter")).toHaveCount(1);
  const stats = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    // Bare fences first: the timed edits sit before them. The first keystroke turns the opening
    // fence into prose, so every bare fence after it is reparsed (ruling R4); the rest is typing
    // on that line, which cannot change fence pairing (the guard in dialect-blocks.ts).
    const block = [
      "```",
      "plain fence #notatag",
      "```",
      "- ```",
      "  list fence",
      "  ```",
      "# Heading #tag",
      "Some **bold** and *italic* text with ==🟢highlight== and ~underline~ and `code`, a [link](https://example.com),",
      "[[Wiki Note|alias]], #nested/tag, #multi word tag# and https://example.com/faq/ plus $x^2$ and \\*escaped\\*.",
      "- [ ] todo item with #work",
      "- [x] done item ~~struck~~",
      "> quote with <!-- a comment --> inside",
      "```swift",
      "let x = 1 // #notatag",
      "```",
      "| a | b |",
      "|---|---|",
      "| 1 | [[Other]] |",
      "",
      "",
    ].join("\n");
    let doc = "";
    while (doc.length < 500_000) doc += block;
    // TagCons on (M3 Task 7): the widget path for every visible #work and #nested/tag is timed too.
    api.mock.deliver({ type: "tagIcons", icons: { work: "briefcase", "nested/tag": "folder", tag: "number" } });
    api.debugInsert(doc);
    await new Promise((r) => setTimeout(r, 500));
    return { length: doc.length, parsed: api.debugParsedLength(20_000) };
  });
  expect(stats.length).toBeGreaterThanOrEqual(500_000);
  // The whole note is parsed before timing starts (not just the viewport).
  expect(stats.parsed).toBe(stats.length);
  expect(await page.locator(".cm-content .cm-bc-tagcon").count()).toBeGreaterThan(0);
  // Tables render as grids (M6 Task 4): the block layer and the table renderer are timed too.
  expect(await page.locator(".cm-content .cm-bc-block-rendered.cm-bc-block-table").count()).toBeGreaterThan(0);

  // Type at the start of the note, before the first (bare) fence: the incremental parse has to
  // carry the whole rest along.
  await page.keyboard.press("ControlOrMeta+Home");
  const times = await page.evaluate(async (centred) => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const out: number[] = [];
    for (let i = 0; i < 200; i++) {
      const start = performance.now();
      if (centred) {
        const view = api.debugView();
        view.dispatch(view.state.replaceSelection(String.fromCharCode(97 + (i % 26))), { userEvent: "input.type", scrollIntoView: true });
        // Reading the geometry runs the pending measure (the scroll); the microtask is the correction.
        view.coordsAtPos(view.state.selection.main.head);
        await Promise.resolve();
      } else {
        api.debugInsert(String.fromCharCode(97 + (i % 26)));
      }
      out.push(performance.now() - start);
      await new Promise((r) => requestAnimationFrame(() => r(null)));
    }
    return out;
  }, typewriter);
  const sorted = [...times].sort((a, b) => a - b);
  const pct = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
  console.log(`perf: 500k chars${typewriter ? ", typewriter mode on" : ""}, 200 keystrokes: p50 ${pct(50).toFixed(2)} ms, p95 ${pct(95).toFixed(2)} ms, max ${sorted.at(-1)!.toFixed(2)} ms`);
  const typed = await hooks(page).text();
  expect(typed.length).toBe(stats.length + 200);
  expect(typed.slice(0, 26)).toBe("abcdefghijklmnopqrstuvwxyz");
  expect(pct(95)).toBeLessThan(16);
});
}

// M6 Task 19: the same 500k gate with every rich block in the note — an 11-column table, a
// callout, block math, a Mermaid diagram and footnotes — and the first 50 headings folded.
// MathJax and Mermaid load lazily: each of their modules is requested at most once.
test("perf: 500k chars rich blocks", async ({ page }) => {
  const requests = new Map<string, number>();
  page.on("request", (r) => {
    const path = new URL(r.url()).pathname;
    if (/node_modules\/.*(mathjax|mermaid)/i.test(path)) requests.set(path, (requests.get(path) ?? 0) + 1);
  });
  await openEditor(page);
  const stats = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const wide = Array.from({ length: 11 }, (_, i) => `c${i}`);
    const block = [
      "```",
      "plain fence #notatag",
      "```",
      "# Heading #tag",
      "Some **bold** text with ==🟢highlight==, a [link](https://example.com), [[Wiki Note|alias]] and $x^2$.",
      "- [ ] todo item with #work",
      `| ${wide.join(" | ")} |`,
      `|${wide.map(() => "---").join("|")}|`,
      ...Array.from({ length: 4 }, (_, r) => `| ${wide.map((c) => `${c}r${r}`).join(" | ")} |`),
      "",
      "> [!WARNING] Title",
      "> body",
      "",
      "$$",
      "x^2",
      "$$",
      "",
      "```mermaid",
      "flowchart LR",
      "  A --> B",
      "```",
      "",
      "text[^1]",
      "",
      "[^1]: def",
      "",
      "",
    ].join("\n");
    let doc = "";
    while (doc.length < 500_000) doc += block;
    api.debugInsert(doc);
    await new Promise((r) => setTimeout(r, 500));
    // Fold the first 50 headings (Toggle Fold with the caret on each).
    const view = api.debugView() as unknown as {
      state: { doc: { toString(): string } };
      dispatch(spec: unknown): void;
    };
    const text = view.state.doc.toString();
    let at = 0;
    for (let n = 0; n < 50; n++) {
      at = text.indexOf("# Heading #tag", at);
      if (at < 0) break;
      view.dispatch({ selection: { anchor: at } });
      api.mock.deliver({ type: "applyCommand", name: "toggleFold" });
      at += 1;
    }
    await new Promise((r) => setTimeout(r, 300));
    return { length: doc.length, parsed: api.debugParsedLength(20_000) };
  });
  expect(stats.length).toBeGreaterThanOrEqual(500_000);
  expect(stats.parsed).toBe(stats.length);
  expect(await page.locator(".cm-bc-fold-placeholder").count()).toBeGreaterThan(0);

  await page.keyboard.press("ControlOrMeta+Home");
  const times = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const out: number[] = [];
    for (let i = 0; i < 200; i++) {
      const start = performance.now();
      api.debugInsert(String.fromCharCode(97 + (i % 26)));
      out.push(performance.now() - start);
      await new Promise((r) => requestAnimationFrame(() => r(null)));
    }
    return out;
  });
  const sorted = [...times].sort((a, b) => a - b);
  const pct = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
  console.log(`perf: 500k chars rich blocks, 200 keystrokes: p50 ${pct(50).toFixed(2)} ms, p95 ${pct(95).toFixed(2)} ms, max ${sorted.at(-1)!.toFixed(2)} ms`);
  const typed = await hooks(page).text();
  expect(typed.length).toBe(stats.length + 200);
  expect(pct(95)).toBeLessThan(16);
  // Each lazily loaded module at most once.
  expect([...requests.entries()].filter(([, n]) => n > 1)).toEqual([]);
});

// Final review M4: a 6000-line `$$` block (over MAX_TEX, so it can never render) and a
// 6000-row table (over MAX_GRID_ROWS) right below the typing line always show their source, so
// CodeMirror's viewport settles: no "Viewport failed to stabilize" while typing above them, and
// the 500k gate holds.
test("perf: 500k chars huge blocks", async ({ page }) => {
  const warnings: string[] = [];
  page.on("console", (m) => {
    if (m.text().includes("Viewport failed to stabilize")) warnings.push(m.text());
  });
  await openEditor(page);
  const stats = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const math = ["$$", ...Array.from({ length: 6000 }, (_, i) => `x_{${i}} +`), "$$"].join("\n");
    const table = ["| n | value |", "|---|---|", ...Array.from({ length: 6000 }, (_, i) => `| ${i} | v${i} |`)].join("\n");
    let doc = `Typing line\n\n${math}\n\n${table}\n\n`;
    const filler = "# Heading\nSome **bold** text with a [link](https://example.com) and #tag.\n\n";
    while (doc.length < 500_000) doc += filler;
    api.debugInsert(doc);
    await new Promise((r) => setTimeout(r, 500));
    return { length: doc.length, parsed: api.debugParsedLength(20_000) };
  });
  expect(stats.length).toBeGreaterThanOrEqual(500_000);
  expect(stats.parsed).toBe(stats.length);
  await page.keyboard.press("ControlOrMeta+Home");
  await page.evaluate(() => new Promise((r) => setTimeout(r, 300)));
  // Both blocks show their source (no rendered widget over collapsed lines).
  await expect(page.locator(".cm-content .cm-bc-block-rendered")).toHaveCount(0);
  await expect(page.locator(".cm-content .cm-line", { hasText: "x_{0} +" })).toBeVisible();
  // 200 keystrokes above the blocks, then 200 inside a cell of the 6000-row table (residual
  // round: the table's source mode must not build its model or align its pipes per keystroke).
  // Each timing includes the measure the keystroke scheduled (`coordsAtPos` runs it).
  const type200 = () =>
    page.evaluate(async () => {
      const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
      const view = api.debugView();
      const out: number[] = [];
      for (let i = 0; i < 200; i++) {
        const start = performance.now();
        api.debugInsert(String.fromCharCode(97 + (i % 26)));
        view.coordsAtPos(view.state.selection.main.head);
        out.push(performance.now() - start);
        await new Promise((r) => requestAnimationFrame(() => r(null)));
      }
      return out;
    });
  const pct = (times: number[], p: number) => {
    const sorted = [...times].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
  };
  const report = (where: string, times: number[]) =>
    console.log(
      `perf: 500k chars huge blocks, 200 keystrokes ${where}: p50 ${pct(times, 50).toFixed(2)} ms, p95 ${pct(times, 95).toFixed(2)} ms, max ${Math.max(...times).toFixed(2)} ms, stabilize warnings ${warnings.length}`,
    );

  warnings.length = 0;
  const above = await type200();
  report("above", above);
  expect(warnings).toEqual([]);
  expect((await hooks(page).text()).length).toBe(stats.length + 200);
  expect(pct(above, 95)).toBeLessThan(16);

  // The caret into a cell near the table's top (so it is on screen).
  await page.evaluate(() => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    const at = api.debugText().indexOf("| 10 | v10 |") + "| 10 | v10".length;
    api.debugView().dispatch({ selection: { anchor: at }, scrollIntoView: true });
  });
  await page.evaluate(() => new Promise((r) => setTimeout(r, 300)));
  warnings.length = 0;
  const inside = await type200();
  report("inside the 6000-row table", inside);
  expect(warnings).toEqual([]);
  const typed = await hooks(page).text();
  expect(typed.length).toBe(stats.length + 400);
  expect(typed).toContain("| 10 | v10abcdefghijklmnopqrstuvwxyz");
  // A table over the row cap gets no aligned pipes (no spacer widgets) while the caret is in it.
  await expect(page.locator(".cm-content .cm-bc-table-spacer")).toHaveCount(0);
  // Not gated: each keystroke in the table re-parses the whole 6000-row Table leaf block
  // (Lezer markdown reuses fragments only at block boundaries), about 20 ms of the 20 ms
  // Work.Apply parse budget per keystroke. Fixing that is a parser change.
});
