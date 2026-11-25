// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test } from "@playwright/test";

type API = {
  debugText(): string;
  debugParsedLength(timeout: number): number;
  debugInsert(value: string): void;
  debugView(): { dispatch(spec: unknown): void };
  mock: { noteId: string; sent: { type: string; folds?: unknown[] }[]; deliver(message: unknown): void };
};

test("perf: 500k chars with every rich block and fifty folded headings", async ({ page }) => {
  const engineRequests = new Map<string, number>();
  page.on("request", request => {
    const url = request.url().split("?")[0]!;
    if (/\/mathjax\.js$|\/mermaid(?:\.core)?\.m?js$/.test(url)) engineRequests.set(url, (engineRequests.get(url) ?? 0) + 1);
  });
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  const length = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: API }).__baerchen;
    const block = ["Some **bold** #work and [[Other]] plus $x^2$.",
      "| A | B | C | D | E | F | G | H | I | J | K |", "|---|---|---|---|---|---|---|---|---|---|---|",
      ...Array.from({ length: 5 }, () => "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |"), "",
      "> [!WARNING] Title", "> body", "", "$$", "x^2", "$$", "",
      "```mermaid", "flowchart LR", "A --> B", "```", "", "text[^1]", "", "[^1]: def", ""].join("\n");
    let doc = "Type here\n\n" + block + "\n";
    const headings: number[] = [];
    while (doc.length < 500_000) { headings.push(doc.length); doc += "# Section " + headings.length + "\n\n" + block + "\n"; }
    api.debugInsert(doc);
    await new Promise(resolve => setTimeout(resolve, 500));
    if (api.debugParsedLength(20_000) !== doc.length) throw new Error("Full parse did not finish");
    for (const pos of headings.slice(0, 50)) {
      api.debugView().dispatch({ selection: { anchor: pos } });
      api.mock.deliver({ type: "applyCommand", name: "toggleFold" });
    }
    api.debugView().dispatch({ selection: { anchor: 0 }, scrollIntoView: true });
    await new Promise(resolve => setTimeout(resolve, 1000));
    return doc.length;
  });
  expect(length).toBeGreaterThanOrEqual(500_000);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: API }).__baerchen.mock.sent.filter(message => message.type === "foldState").at(-1)?.folds?.length)).toBe(50);
  await expect(page.locator(".cm-bc-math-inline svg").first()).toBeVisible();
  await page.locator(".cm-content").focus();
  const times = await page.evaluate(async () => {
    const api = (window as unknown as { __baerchen: API }).__baerchen, times: number[] = [];
    for (let i = 0; i < 200; i++) {
      const start = performance.now(); api.debugInsert(String.fromCharCode(97 + i % 26));
      times.push(performance.now() - start);
      await new Promise(resolve => requestAnimationFrame(resolve));
    }
    return times.sort((a, b) => a - b);
  });
  const p95 = times[190]!;
  console.log(`perf: 500k chars rich blocks: p50 ${times[100]} ms, p95 ${p95} ms, max ${times[199]} ms`);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: API }).__baerchen.debugText().length)).toBe(length + 200);
  expect(p95).toBeLessThan(16);
  expect(engineRequests.size).toBeGreaterThanOrEqual(2);
  for (const count of engineRequests.values()) expect(count).toBe(1);
});
