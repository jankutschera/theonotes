// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M10 T2 (network audit): the editor page asks for nothing outside its own origin, whatever the note
// holds. A note with a remote image, a link, a Mermaid diagram, a math block, a code block and raw HTML
// is rendered; every request the page makes (including failed ones) is recorded. The hosts end in
// `.invalid`, which never resolves, so a leak would show up as a request, not as traffic.
// The app adds a second layer on top (CSP on the baerchen-asset scheme, navigation policy); this spec
// checks the layer that is not the browser's: what the editor itself tries to load.

type View = { state: { doc: { length: number } }; dispatch(spec: unknown): void };
type Hooks = { debugInsert(text: string): void; debugView(): View };

const doc = [
  "# Remote content",
  "",
  "![tracker](https://tracker.invalid/pixel.png)",
  "",
  "[a link](https://link.invalid/page) and <https://auto.invalid/> and https://bare.invalid/x",
  "",
  '<img src="https://html.invalid/a.png"> <script src="https://script.invalid/a.js"></script>',
  "",
  "```mermaid",
  "flowchart LR",
  "  A[Start] --> B{Choice}",
  "  B -->|yes| C[Done]",
  "```",
  "",
  "$$",
  "x^2 + y^2 = z^2",
  "$$",
  "",
  "```js",
  "const a = 1;",
  "```",
  "",
  "end",
].join("\n");

async function open(page: Page) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate((d) => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.debugInsert(d);
    const length = hooks.debugView().state.doc.length;
    hooks.debugView().dispatch({ selection: { anchor: length } });
  }, doc);
}

test("a note with remote content makes no request outside the editor's own origin", async ({ page, baseURL }) => {
  const origin = new URL(baseURL!).origin;
  const requests: string[] = [];
  page.on("request", (request) => requests.push(request.url()));
  await open(page);
  // Let the lazy chunks (Mermaid, MathJax) load and render, then wait for the page to go quiet.
  await expect
    .poll(
      () =>
        page.evaluate(() =>
          [...document.querySelectorAll(".cm-bc-block-mermaid")].some((host) =>
            [...(host.shadowRoot?.querySelectorAll("img") ?? [])].some((img) => img.complete && img.naturalWidth > 0),
          ),
        ),
      { timeout: 20_000 },
    )
    .toBe(true);
  await page.waitForLoadState("networkidle");
  expect(requests.length).toBeGreaterThan(0);
  const foreign = requests.filter((url) => !url.startsWith(`${origin}/`) && !url.startsWith("data:") && !url.startsWith("blob:"));
  expect(foreign).toEqual([]);
  expect(requests.filter((url) => url.includes(".invalid"))).toEqual([]);
});
