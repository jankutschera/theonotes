// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 11: MathJax inline and block math. Renderings live in shadow roots (their text is not
// the content text); MathJax loads lazily from the bundle and fetches nothing from outside.

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
});

async function open(page: Page) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  return content;
}

async function openWith(page: Page, doc: string, caret = doc.length) {
  const content = await open(page);
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

/** The SVGs / errors inside the math widgets' shadow roots. */
const inShadow = (page: Page, selector: string, inner: string) =>
  page.evaluate(
    ([sel, q]) =>
      [...document.querySelectorAll(sel)].flatMap((host) => [...(host.shadowRoot?.querySelectorAll(q) ?? [])]).length,
    [selector, inner] as const,
  );

test("$E = mc^2$ renders an SVG and keeps the TeX in innerText", async ({ page }) => {
  const doc = "Energy $E = mc^2$ here\n\nend";
  const content = await openWith(page, doc);
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(1);
  expect(await content.innerText()).toBe(doc);
  // Caret inside: the source with a live preview after it.
  await hooks(page).caret(doc.indexOf("mc^2"));
  await expect.poll(() => inShadow(page, ".cm-bc-math-preview", "svg")).toBe(1);
  await expect(page.locator(".cm-bc-math-inline")).toHaveCount(0);
  expect(await content.innerText()).toBe(doc);
});

test("$$ block renders centred; caret inside shows source and preview below", async ({ page }) => {
  const doc = "Before\n\n$$\n\\sum_{i=1}^n i = \\frac{n(n+1)}{2}\n$$\n\nAfter";
  const content = await openWith(page, doc);
  const rendered = page.locator(".cm-bc-block-rendered.cm-bc-block-mathBlock");
  await expect(rendered).toHaveCount(1);
  await expect.poll(() => inShadow(page, ".cm-bc-block-rendered", "svg")).toBe(1);
  const centred = await page.evaluate(() => {
    const host = document.querySelector(".cm-bc-block-rendered")!;
    const svg = host.shadowRoot!.querySelector("svg")!.getBoundingClientRect();
    const box = host.getBoundingClientRect();
    return Math.abs(svg.left - box.left - (box.right - svg.right));
  });
  expect(centred).toBeLessThan(4);
  expect(await content.innerText()).toBe(doc);
  await hooks(page).caret(doc.indexOf("\\sum"));
  await expect(page.locator(".cm-bc-block-source.cm-bc-block-mathBlock")).toHaveCount(1);
  await expect.poll(() => inShadow(page, ".cm-bc-block-source", "svg")).toBe(1);
  const below = await page.evaluate(() => {
    const preview = document.querySelector(".cm-bc-block-source")!.getBoundingClientRect();
    const lines = [...document.querySelectorAll(".cm-line")].filter((l) => l.textContent === "$$");
    return preview.top >= lines.at(-1)!.getBoundingClientRect().bottom - 1;
  });
  expect(below).toBe(true);
});

test("$\\frac{1}{$ shows the MathJax error inline", async ({ page }) => {
  await openWith(page, "bad $\\frac{1}{$ here\n\nend");
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", ".cm-bc-math-error")).toBe(1);
  const message = await page.evaluate(() => document.querySelector(".cm-bc-math-inline")!.shadowRoot!.textContent);
  expect(message).toMatch(/missing|argument|close|brace/i);
});

test("\\mathbb{R} and \\mathfrak{A} render (dynamic font files load from the bundle)", async ({ page }) => {
  const failed: string[] = [];
  page.on("console", (m) => {
    if (m.type() === "warning" || m.type() === "error") failed.push(m.text());
  });
  await openWith(page, "sets $\\mathbb{R}$ and $\\mathfrak{A}$\n\nend");
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(2);
  // Each glyph drew a path (a missing dynamic file leaves an empty box).
  const paths = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-math-inline")].map((h) => h.shadowRoot!.querySelectorAll("path").length),
  );
  expect(paths.every((n) => n > 0)).toBe(true);
  expect(failed.filter((t) => /mathjax|dynamic/i.test(t))).toEqual([]);
});

// Review Focus 4.
test("\\href, \\class and \\html are not available", async ({ page }) => {
  await openWith(page, "$\\href{javascript:alert(1)}{x}$ and $\\class{a}{b}$ and $\\html{x}$\n\nend");
  await expect.poll(() => page.locator(".cm-bc-math-inline").count()).toBe(3);
  await expect.poll(async () => (await inShadow(page, ".cm-bc-math-inline", "svg, .cm-bc-math-error"))).toBe(3);
  expect(await inShadow(page, ".cm-bc-math-inline", "a")).toBe(0);
  // noundefined shows the unknown macro by name (red), never as a working command: no link and no
  // href anywhere (the TeX itself is kept in data-latex attributes, as text).
  // (Glyphs are `<use href="#…">` references inside the SVG: only those may carry an href.)
  const links = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-math-inline")].flatMap((h) =>
      [...h.shadowRoot!.querySelectorAll("a, [href], [*|href]")]
        .map((el) => (el.localName === "a" ? "<a>" : el.getAttribute("href") ?? el.getAttributeNS("http://www.w3.org/1999/xlink", "href") ?? ""))
        .filter((href) => !href.startsWith("#")),
    ),
  );
  expect(links).toEqual([]);
});

test("no request leaves the bundle", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await openWith(page, "a $\\mathbb{Z}$ $\\mathcal{L}$ $\\boldsymbol{x}$ $\\cancel{y}$\n\n$$\n\\begin{cases} a \\\\ b \\end{cases}\n$$\n");
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(4);
  await expect.poll(() => inShadow(page, ".cm-bc-block-rendered", "svg")).toBe(1);
  const origin = new URL(page.url()).origin;
  expect(requests.length).toBeGreaterThan(1);
  expect(requests.filter((u) => !u.startsWith(`${origin}/`) && !u.startsWith("data:") && !u.startsWith("blob:"))).toEqual([]);
});

test("MathJax is not loaded until a formula is visible", async ({ page }) => {
  const mathjax: string[] = [];
  page.on("request", (r) => {
    if (/mathjax/i.test(r.url())) mathjax.push(r.url());
  });
  await openWith(page, "plain text, no formula\n\n# heading");
  await page.waitForTimeout(500);
  expect(mathjax).toEqual([]);
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert("\n$x^2$\n"));
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(1);
  expect(mathjax.length).toBeGreaterThan(0);
});

test("arrow keys enter a rendered formula", async ({ page }) => {
  const doc = "a $x^2$ b";
  await openWith(page, doc, 2);
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(1);
  await page.keyboard.press("ArrowRight");
  expect(await hooks(page).head()).toBe(3);
  await expect(page.locator(".cm-bc-math-preview")).toHaveCount(1);
  await hooks(page).caret(doc.indexOf(" b"));
  await expect(page.locator(".cm-bc-math-inline")).toHaveCount(1);
  await page.keyboard.press("ArrowLeft");
  expect(await hooks(page).head()).toBe(doc.indexOf(" b") - 1);
  // A click on the rendering puts the caret in the source.
  await hooks(page).caret(doc.length);
  await page.locator(".cm-bc-math-inline").click();
  expect(await hooks(page).head()).toBe(doc.indexOf("$ b"));
  expect(await hooks(page).text()).toBe(doc);
});

// Fix round 1 (Codex review).

test("\\mmlToken and \\color cannot link or fetch: the SVG is sanitized", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", (r) => requests.push(r.url()));
  await openWith(
    page,
    [
      '$\\mmlToken{mi}[href="/probe-link"]{x}$',
      "$\\color{url(/probe.svg#x)}{y}$",
      '$\\mmlToken{mi}[style="background:url(/probe-bg.png)"]{z}$',
      // CSS escapes and image functions (re-review): `u\72l(` is `url(` to a browser.
      "$\\color{u\\72l(/probe-esc.svg#x)}{w}$",
      '$\\mmlToken{mi}[style="filter:u\\72l(/probe-filter.svg#x)"]{v}$',
      "$\\mmlToken{mi}[style='background-image:image-set(\"/probe-set.png\" 1x)']{u}$",
    ].join(" ") + "\n\nend",
  );
  await expect.poll(() => page.locator(".cm-bc-math-inline").count()).toBe(6);
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg, .cm-bc-math-error")).toBe(6);
  // The TeX itself stays in `data-latex` (inert text); every other attribute is checked.
  const unsafe = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-math-inline")].flatMap((h) =>
      [...h.shadowRoot!.querySelectorAll("*")].flatMap((el) => [
        ...(["a", "image", "foreignObject"].includes(el.localName) ? [el.localName] : []),
        ...[...el.attributes]
          .filter((a) => !a.localName.startsWith("data-"))
          .filter((a) => (a.localName === "href" && !a.value.startsWith("#")) || /\\|url|image/i.test(a.value))
          .map((a) => `${a.localName}=${a.value}`),
      ]),
    ),
  );
  expect(unsafe).toEqual([]);
  await page.waitForTimeout(300);
  expect(requests.filter((u) => /probe/.test(u))).toEqual([]);
});

test("a \\def in one formula does not reach the next", async ({ page }) => {
  await openWith(page, "$\\def\\frac{Z}\\frac$ then $\\frac{1}{2}$\n\nend");
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(2);
  const fractions = await page.evaluate(() =>
    [...document.querySelectorAll(".cm-bc-math-inline")].map((h) => h.shadowRoot!.querySelectorAll('[data-mml-node="mfrac"]').length),
  );
  expect(fractions).toEqual([0, 1]);
});

test("an overlong formula is refused with a message", async ({ page }) => {
  await openWith(page, `$${"x+".repeat(3000)}x$\n\nend`);
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", ".cm-bc-math-error")).toBe(1);
  const message = await page.evaluate(() => document.querySelector(".cm-bc-math-inline")!.shadowRoot!.textContent);
  expect(message).toMatch(/too long/);
});

test("Backspace and Delete next to a rendered formula reveal it instead of deleting", async ({ page }) => {
  const doc = "a $x^2$ b";
  await openWith(page, doc, doc.indexOf(" b"));
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(1);
  await page.keyboard.press("Backspace");
  expect(await hooks(page).text()).toBe(doc);
  expect(await hooks(page).head()).toBe(doc.indexOf(" b") - 1);
  await hooks(page).caret(2);
  await expect(page.locator(".cm-bc-math-inline")).toHaveCount(1);
  await page.keyboard.press("Delete");
  expect(await hooks(page).text()).toBe(doc);
  expect(await hooks(page).head()).toBe(3);
});

// ios-iphone-ipad 0061337: MathJax 4 emits one SVG per breakable inline segment; the widget keeps
// one SVG, so every term must be in it (`a+b` once lost `+b`).
test("a compound inline formula keeps every term in its one SVG", async ({ page }) => {
  await openWith(page, "Sum $a+b+c$ here\n\nend");
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "svg")).toBe(1);
  await expect.poll(() => inShadow(page, ".cm-bc-math-inline", "[data-mml-node=mi]")).toBe(3);
  expect(await inShadow(page, ".cm-bc-math-inline", "[data-mml-node=mo]")).toBe(2);
});
