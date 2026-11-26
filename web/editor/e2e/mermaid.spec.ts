// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 12: Mermaid diagrams through the block layer, shown as an `<img>` of Mermaid's SVG
// (no live SVG DOM from note text), loaded lazily from the bundle.

type View = { state: { doc: { length: number } }; dispatch(spec: unknown): void };
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
};

const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  caret: (pos: number) =>
    page.evaluate((p) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: p } }), pos),
  head: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head),
  insert: (t: string) => page.evaluate((x) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert(x), t),
});

async function openWith(page: Page, doc: string, caret = doc.length) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(
    ([d, c]) => {
      const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
      b.debugInsert(d as string);
      b.debugView().dispatch({ selection: { anchor: c as number } });
    },
    [doc, caret] as const,
  );
  return content;
}

/** Loaded diagram images (and their natural width) in the rendered or preview widgets. */
const images = (page: Page, role: "rendered" | "source" = "rendered") =>
  page.evaluate(
    (r) =>
      [...document.querySelectorAll(`.cm-bc-block-${r}.cm-bc-block-mermaid`)].flatMap((h) =>
        [...(h.shadowRoot?.querySelectorAll("img") ?? [])].filter((img) => img.complete && img.naturalWidth > 0).map((img) => img.naturalWidth),
      ),
    role,
  );
const errors = (page: Page) =>
  page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-block-mermaid")].map((h) => h.shadowRoot?.querySelector(".error")?.textContent ?? null).filter(Boolean),
  );

const fence = (body: string) => "```mermaid\n" + body + "\n```";
const DIAGRAMS = {
  flowchart: "flowchart LR\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| A",
  sequence: "sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi",
  gantt: "gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section A\n  Task one :a1, 2026-01-01, 3d\n  Task two :after a1, 2d",
  mindmap: "mindmap\n  root((Notes))\n    Ideas\n    Tasks",
  class: "classDiagram\n  class Note {\n    +String title\n    +open()\n  }\n  Note <|-- Pinned",
  state: "stateDiagram-v2\n  [*] --> Draft\n  Draft --> Done\n  Done --> [*]",
};

test("flowchart, sequence, gantt, mindmap, class and state diagrams render", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 900 });
  for (const [name, body] of Object.entries(DIAGRAMS)) {
    await openWith(page, `${name}\n\n${fence(body)}\n\nend`);
    await expect.poll(() => images(page), { timeout: 15_000 }).toHaveLength(1);
    expect(await errors(page)).toEqual([]);
    await expect(page.locator(".cm-bc-block-rendered.cm-bc-block-mermaid")).toHaveScreenshot(`mermaid-${name}.png`, { maxDiffPixelRatio: 0.02 });
  }
});

// Elkjs is not in the app. A diagram that asks for the ELK layout (`flowchart-elk`; front
// matter and directives are removed) is drawn with the default layout, without an error box.
test("a diagram that asks for the ELK layout renders with the default layout", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 900 });
  const elk = "flowchart-elk TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| A";
  const config = "---\nconfig:\n  layout: elk\n---\nflowchart LR\n  X --> Y";
  const doc = `elk\n\n${fence(elk)}\n\n${fence(config)}\n\nend`;
  const content = await openWith(page, doc);
  await expect.poll(() => images(page), { timeout: 15_000 }).toHaveLength(2);
  expect(await errors(page)).toEqual([]);
  // The note text is untouched: the fallback happens only when drawing.
  expect(await content.innerText()).toBe(doc);
});

test("a syntax error shows inline", async ({ page }) => {
  const doc = `${fence("flowchart LR\n  A -->")}\n\nend`;
  await openWith(page, doc);
  await expect.poll(() => errors(page), { timeout: 15_000 }).toHaveLength(1);
  // Caret inside: the code block as usual, the error below it.
  await hooks(page).caret(doc.indexOf("A -->"));
  await expect(page.locator(".cm-bc-block-source.cm-bc-block-mermaid")).toHaveCount(1);
  await expect.poll(() => errors(page), { timeout: 15_000 }).toHaveLength(1);
  await expect(page.locator(".cm-line.cm-bc-codeblock")).not.toHaveCount(0);
});

test("innerText equals the document; a click on the diagram puts the caret in the code", async ({ page }) => {
  const doc = `before\n\n${fence(DIAGRAMS.flowchart)}\n\nafter`;
  const content = await openWith(page, doc);
  await expect.poll(() => images(page), { timeout: 15_000 }).toHaveLength(1);
  expect(await content.innerText()).toBe(doc);
  await page.locator(".cm-bc-block-rendered.cm-bc-block-mermaid").click();
  expect(await hooks(page).head()).toBe(doc.indexOf("flowchart LR"));
  // Source mode: the preview below the code.
  await expect.poll(() => images(page, "source"), { timeout: 15_000 }).toHaveLength(1);
  expect(await content.innerText()).toBe(doc);
});

// Review Focus 4.
test("click callbacks and script labels never run", async ({ page }) => {
  let dialogs = 0;
  page.on("dialog", (d) => {
    dialogs++;
    void d.dismiss();
  });
  const body = [
    "flowchart LR",
    '  A["<img src=x onerror=window.__pwned=1>"] --> B["<script>window.__pwned=2</script>"]',
    "  click A call alert()",
    '  click B "javascript:window.__pwned=3"',
  ].join("\n");
  await openWith(page, `${fence(body)}\n\nend`);
  await expect.poll(async () => (await images(page)).length + (await errors(page)).length, { timeout: 15_000 }).toBe(1);
  await page.locator(".cm-bc-block-rendered.cm-bc-block-mermaid").click().catch(() => {});
  await page.waitForTimeout(500);
  expect(dialogs).toBe(0);
  expect(await page.evaluate(() => (window as unknown as { __pwned?: number }).__pwned)).toBeUndefined();
  // No live SVG from the note anywhere in the page.
  expect(
    await page.evaluate(() =>
      [...document.querySelectorAll(".cm-bc-block-mermaid")].flatMap((h) => [...(h.shadowRoot?.querySelectorAll("svg, script, foreignObject") ?? [])]).length,
    ),
  ).toBe(0);
});

test('a 100k-character diagram shows "Diagram too large" and typing stays responsive', async ({ page }) => {
  const big = "flowchart LR\n" + Array.from({ length: 6000 }, (_, i) => `  n${i} --> n${i + 1}`).join("\n");
  expect(big.length).toBeGreaterThan(100_000);
  await openWith(page, `${fence(big)}\n\nend`);
  // The message sits below the 6000 code lines: scroll to it (the caret is at the end).
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.dispatch({ selection: { anchor: view.state.doc.length }, scrollIntoView: true });
  });
  await expect.poll(() => errors(page), { timeout: 15_000 }).toEqual(["Diagram too large"]);
  // Shown below its code (never collapsed: 6000 zero-height lines would not let the viewport settle).
  await expect(page.locator(".cm-bc-block-source.cm-bc-block-mermaid")).toHaveCount(1);
  await expect(page.locator(".cm-bc-block-rendered.cm-bc-block-mermaid")).toHaveCount(0);
  const start = Date.now();
  await hooks(page).insert("x");
  await page.keyboard.type("abc");
  expect(Date.now() - start).toBeLessThan(2000);
  expect(await hooks(page).text()).toContain("endxabc");
});

test("no request leaves the bundle", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await openWith(page, Object.values(DIAGRAMS).map(fence).join("\n\n") + "\n\nend");
  await expect.poll(() => images(page), { timeout: 20_000 }).toHaveLength(6);
  const origin = new URL(page.url()).origin;
  expect(requests.length).toBeGreaterThan(1);
  expect(requests.filter((u) => !u.startsWith(`${origin}/`) && !u.startsWith("data:") && !u.startsWith("blob:"))).toEqual([]);
});

test("Mermaid is not loaded until a diagram is visible", async ({ page }) => {
  const loads: string[] = [];
  page.on("request", (r) => {
    // The package (or its chunks), not the editor's own mermaid.ts modules.
    const path = new URL(r.url()).pathname;
    if (/node_modules/.test(path) && /mermaid/i.test(path)) loads.push(r.url());
  });
  await openWith(page, "plain text\n\n```js\nlet x = 1\n```\n");
  await page.waitForTimeout(500);
  expect(loads).toEqual([]);
  await hooks(page).insert(`\n${fence(DIAGRAMS.state)}\n`);
  await hooks(page).caret(0);
  await expect.poll(() => images(page), { timeout: 15_000 }).toHaveLength(1);
  expect(loads.length).toBeGreaterThan(0);
});

// Fix round 1 (Codex review): nothing a diagram says can make the page fetch.

test("labels, styles and directives cannot fetch anything", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  const hostile = [
    fence('flowchart LR\n  A["<img src=/probe-label.png>"] --> B'),
    fence("%%{init: {\"themeCSS\": \".node rect { fill: red }\", \"theme\": \"forest\"}}%%\nflowchart LR\n  C --> D"),
    fence("flowchart LR\n  E --> F\n  style E fill:url(/probe-style.svg#x)"),
    fence("flowchart LR\n  G --> H\n  classDef c fill:u\\72l(/probe-escape.svg#x)\n  class G c"),
    // Security review: per-diagram htmlLabels through a directive; an escape after `;`; an image shape.
    fence('%%{init: {"flowchart": {"htmlLabels": true}}}%%\nflowchart LR\n  I["<img src=/probe-directive.png>"] --> J'),
    fence("flowchart LR\n  K --> L; style K fill:u\\72l(/probe-semicolon.svg#x)"),
    fence('flowchart LR\n  M@{ img: "/probe-shape.png", label: "m" }'),
  ].join("\n\n");
  await openWith(page, `${hostile}\n\nend`);
  await expect.poll(async () => (await images(page)).length + (await errors(page)).length, { timeout: 20_000 }).toBe(7);
  await page.waitForTimeout(500);
  expect(requests.filter((u) => /probe/.test(u))).toEqual([]);
  // The labels' tags are text, the directives are removed, URLs, escapes and image shapes refused.
  expect(await errors(page)).toEqual([
    "Diagrams cannot load images, URLs or styles from outside the note",
    "Diagrams cannot contain escapes (a backslash before a digit, a-f or a line break)",
    "Diagrams cannot contain escapes (a backslash before a digit, a-f or a line break)",
    "Diagrams cannot load images, URLs or styles from outside the note",
  ]);
  expect(await images(page)).toHaveLength(3);
});
