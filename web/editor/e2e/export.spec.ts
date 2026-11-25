// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M8 Task 10: the export page (`/export.html`) renders a RenderRequest with the real renderers
// (MathJax, Mermaid, the Lezer highlighter) and returns the HTML. Review Focus 4: a hostile note
// runs no script and makes no request.

type Result = { html: string; headings: { level: number; text: string; anchor: string }[] };
type ExportWindow = { baerchenExport: { render(request: unknown): Promise<Result> }; __pwned?: unknown };

const NOTE_ID = "01990000-0000-7000-8000-000000000001";

const request = (overrides: Record<string, unknown> = {}) => ({
  v: 1,
  noteId: NOTE_ID,
  title: "Fixture",
  text: "# Fixture\n",
  mode: "document",
  theme: { "--bc-color-bg": "#fafafa", "--bc-color-text": "#202020" },
  appearance: "light",
  typography: { fontSize: 17, lineWidth: 680, fontText: "Iowan Old Style" },
  attachmentSources: {},
  wikiLinks: [],
  ...overrides,
});

async function open(page: Page) {
  await page.goto("/export.html");
  await page.waitForFunction(() => "baerchenExport" in window);
}

const render = (page: Page, req: unknown) =>
  page.evaluate((r) => (window as unknown as ExportWindow).baerchenExport.render(r), req);

test("renders a fixture note with math and mermaid as inline SVG", async ({ page }) => {
  await open(page);
  const text = [
    "# Maths and diagrams",
    "",
    "Inline $E = mc^2$ here.",
    "",
    "$$",
    "\\int_0^1 x\\,dx = \\tfrac12",
    "$$",
    "",
    "```mermaid",
    "flowchart LR",
    "  A[Start] --> B{Choice}",
    "```",
    "",
    "```ts",
    "const answer: number = 42; // comment",
    "```",
    "",
  ].join("\n");
  const { html } = await render(page, request({ text }));
  // MathJax output is inline SVG inside the math wrappers, not an image or a canvas.
  expect(html).toMatch(/<span class="bc-math"><svg/);
  expect(html).toMatch(/<div class="bc-math bc-math-display"><svg/);
  // Mermaid is an <img> of its SVG (a data URL: no live SVG DOM from note text).
  expect(html).toMatch(/<figure class="bc-mermaid"><img alt="" src="data:image\/svg\+xml/);
  // Code is highlighted by token class.
  expect(html).toContain('class="tok-keyword"');
  // The page itself shows the same body, decoded: SVG in the DOM, the diagram image loaded.
  expect(await page.locator(".bc-export .bc-math svg").count()).toBe(2);
  const diagram = page.locator(".bc-export .bc-mermaid img");
  await expect(diagram).toHaveCount(1);
  expect(await diagram.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth > 0)).toBe(true);
  // The highlighted token is coloured by the theme's code token, not left at the page's text colour.
  const keyword = page.locator(".bc-export .tok-keyword").first();
  expect(await keyword.evaluate((el) => getComputedStyle(el).color)).not.toBe(
    await page.locator(".bc-export h1").evaluate((el) => getComputedStyle(el).color),
  );
});

test("document mode returns a standalone html with the theme variables", async ({ page }) => {
  await open(page);
  const { html } = await render(
    page,
    request({ title: "A <b>title</b> & more", text: "Hello **world**\n", theme: { "--bc-color-bg": "#102030", "--bc-color-text": "#eeeeee" }, appearance: "dark" }),
  );
  expect(html.startsWith("<!doctype html>")).toBe(true);
  expect(html).toContain('<meta charset="utf-8">');
  expect(html).toContain("<title>A &lt;b&gt;title&lt;/b&gt; &amp; more</title>");
  expect(html.match(/<style/g)).toHaveLength(1);
  expect(html).not.toMatch(/<script/i);
  // The theme's variables override the default theme's; the rest of the schema keeps its default.
  expect(html).toMatch(/--bc-color-bg:\s*#102030/);
  expect(html).toMatch(/--bc-color-text:\s*#eeeeee/);
  expect(html).toMatch(/--bc-color-accent:\s*#c22c28/);
  expect(html).toMatch(/color-scheme:\s*dark/);
  // Typography variables, with the font family put before the default stack.
  expect(html).toMatch(/--bc-size:\s*17px/);
  expect(html).toMatch(/--bc-line-width:\s*680px/);
  expect(html).toMatch(/--bc-font-text:\s*"Iowan Old Style",/);
  expect(html).toContain("<strong>world</strong>");
  // Rich text mode is the bare body fragment with inline styles.
  const rich = await render(page, request({ mode: "richText", text: "==hi== **x**\n" }));
  expect(rich.html).not.toContain("<style");
  expect(rich.html).not.toContain("<html");
  expect(rich.html).toContain('<span style="background-color:');
});

test("headings are returned with anchors", async ({ page }) => {
  await open(page);
  const text = "# One\n\ntext\n\n## Two\n\n```\n# not a heading\n```\n\n### Three ###\n";
  const result = await render(page, request({ text }));
  expect(result.headings).toEqual([
    { level: 1, text: "One", anchor: "h-1" },
    { level: 2, text: "Two", anchor: "h-2" },
    { level: 3, text: "Three", anchor: "h-3" },
  ]);
  expect(result.html).toContain('id="h-2"');
  await expect(page.locator("#h-3")).toHaveCount(1);
});

test("an invalid request is refused with an error", async ({ page }) => {
  await open(page);
  for (const bad of [request({ v: 2 }), request({ theme: { "--bc-nonsense": "#ffffff" } }), request({ typography: { fontText: 'A"B' } }), null]) {
    const message = await page.evaluate(
      (r) =>
        (window as unknown as ExportWindow).baerchenExport.render(r).then(
          () => "rendered",
          (error: unknown) => (error instanceof Error ? error.message : String(error)),
        ),
      bad,
    );
    expect(message).toBe("Invalid render request");
  }
});

test("the export page runs no note script and makes no request", async ({ page }) => {
  const requests: string[] = [];
  const dialogs: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  page.on("dialog", (d) => {
    dialogs.push(d.message());
    void d.dismiss();
  });
  await open(page);
  // The hostile note of Task 9 (export-render.test.ts), plus a remote image.
  const text = [
    "<script>window.__pwned = 'script'</script>",
    "<img src=x onerror=\"window.__pwned='onerror'\">",
    "[a](javascript:window.__pwned='js') [b](file:///etc/passwd) <javascript:alert(2)> file:///etc/hosts",
    '![x](javascript:alert(3)) [[W]] [c](<https://ok.example/" onclick="x>)',
    "```css\n</style><script>window.__pwned = 'style'</script>\n```",
    "`</style>` &lt;script&gt;",
    "| <script>x</script> |\n|---|\n| </style> |",
    "> [!NOTE] <img src=x onerror=alert(5)>",
    "x[^<b>]\n\n[^<b>]: <script>y</script>",
    "$$\n</style><script>z</script>\n$$",
    "![](http://example.com/x.png)",
  ].join("\n\n");
  for (const mode of ["document", "richText"]) {
    const { html } = await render(page, request({ text, mode, wikiLinks: [{ href: "javascript:alert(6)" }] }));
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/<img/i);
  }
  // Let anything the markup might have started (an image, a script, a prefetch) fire.
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => (window as unknown as ExportWindow).__pwned)).toBeUndefined();
  expect(dialogs).toEqual([]);
  // The page holds no <script> from the note and no <img>: the http image stays a link.
  expect(await page.locator(".bc-export script").count()).toBe(0);
  expect(await page.locator(".bc-export img").count()).toBe(0);
  expect(await page.locator('.bc-export a[href="http://example.com/x.png"]').count()).toBeGreaterThan(0);
  // Only the page and its bundle files, from the page's own origin.
  const origin = new URL(page.url()).origin;
  expect(requests.length).toBeGreaterThan(0);
  expect(requests.filter((url) => !url.startsWith(`${origin}/`))).toEqual([]);
  expect(requests.filter((url) => url.includes("example.com") || url.includes("attacker"))).toEqual([]);
});
