// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test } from "@playwright/test";
import type { ExportOptions, RenderedNote } from "../src/export/note-export";

test("full-note export renders beyond the viewport and never requests remote images", async ({ page }) => {
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  const source = "# Export\n\n" + Array.from({ length: 300 }, (_, i) => `Paragraph ${i} with **bold**.`).join("\n\n") +
    "\n\n| A | B |\n| --- | --- |\n| one | two |\n\n![local](pixel.png) ![remote](https://example.com/tracker.png)\n\nEND 👩‍💻";
  const result = await page.evaluate((source) => {
    const render = window.__baerchen!.renderNote as (source: string, options: ExportOptions) => RenderedNote;
    return render(source, { attachments: { "pixel.png": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1sAAAAASUVORK5CYII=" } });
  }, source);
  expect(result.text).toContain("Paragraph 299 with bold.");
  expect(result.text).toContain("END 👩‍💻");
  const external: string[] = [];
  page.on("request", request => { if (request.url().startsWith("https://example.com")) external.push(request.url()); });
  await page.setContent(`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><main>${result.html}</main>`);
  await expect(page.locator("h1")).toHaveText("Export");
  await expect(page.locator("strong")).toHaveCount(300);
  await expect(page.locator("td")).toHaveText(["one", "two"]);
  await expect(page.locator("img")).toHaveCount(1);
  expect(await page.locator("img").evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth > 0)).toBe(true);
  expect(external).toEqual([]);
});

test("rich exports include offline formulas diagrams callouts and footnote links", async ({ page }) => {
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  const external: string[] = [];
  page.on("request", request => { if (/^https?:/.test(request.url()) && !request.url().includes("localhost")) external.push(request.url()); });
  const source = "# Rich export\n\nInline $x^2$ and a reference[^n].\n\n$$\n\\frac{a}{b}\n$$\n\n> [!TIP]\n> **Keep this**\n\n```mermaid\nflowchart LR\n A[Start] --> B[Finish]\n```\n\n[^n]: Footnote **details**.";
  const result = await page.evaluate(source => (window.__baerchen!.renderNote as (source: string, options: ExportOptions) => Promise<RenderedNote>)(source, { foreground: "#e5e1dc" }), source);
  expect(result.html).toContain('class="inline-math"');
  expect(result.html).toContain('class="display-math"');
  expect(result.html).toContain('class="diagram"');
  expect(result.html).toContain('class="callout callout-tip"');
  expect(result.html).toContain('id="fn-n"');
  await page.setContent(`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"><style>img{max-width:100%}.inline-math{height:1.3em}.display-math{max-height:100px}</style><main>${result.html}</main>`);
  await expect(page.locator("img")).toHaveCount(3);
  await expect.poll(() => page.locator("img").evaluateAll(images => images.every(image => (image as HTMLImageElement).complete && (image as HTMLImageElement).naturalWidth > 0))).toBe(true);
  expect(await page.locator(".inline-math").evaluate((image: HTMLImageElement) => {
    const svg = new DOMParser().parseFromString(decodeURIComponent(image.src.split(",")[1]!), "image/svg+xml").documentElement;
    return (svg as unknown as SVGElement).style.color;
  })).toBe("rgb(229, 225, 220)");
  await expect(page.locator("blockquote strong").first()).toHaveText("Tip");
  await expect(page.locator(".footnote strong")).toHaveText("details");
  expect(external).toEqual([]);
});
