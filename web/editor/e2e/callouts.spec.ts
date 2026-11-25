// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// M6 Task 10: callouts. The marker stays in the DOM as hidden markup; the icon and the default
// title have no text nodes, so `.cm-content`'s innerText is the document.

type Sent = { type: string; [key: string]: unknown };
type View = { state: { doc: { length: number } }; dispatch(spec: unknown): void };
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): View;
  mock: { sent: Sent[]; deliver(msg: unknown): void };
};

const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  sent: (type: string) =>
    page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.filter((m) => m.type === t), type),
  deliver: (msg: Record<string, unknown>) =>
    page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg),
});

const settle = (page: Page) =>
  page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 50)))));

async function openWith(page: Page, doc: string, caret = 0) {
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
  await settle(page);
  return content;
}

const five = [
  "Callouts",
  "",
  "> [!NOTE]",
  "> Useful information users should know.",
  "",
  "> [!TIP] Shortcut",
  "> Helpful advice for doing things better.",
  "",
  "> [!IMPORTANT]",
  "> Key information users need to know.",
  "",
  "> [!WARNING]",
  "> Urgent info that needs immediate attention.",
  "",
  "> [!CAUTION]",
  "> Advises about risks or negative outcomes.",
  "> > [!TIP] Nested",
  "> > inside the caution box",
  "> > - a list item that is long enough to wrap onto a second row inside the nested box",
  "",
  "End.",
].join("\n");

test("innerText equals the document", async ({ page }) => {
  const content = await openWith(page, five, five.length);
  await expect(page.locator(".cm-line.cm-bc-callout-first")).toHaveCount(6);
  await expect(page.locator(".cm-bc-callout-default-title")).toHaveCount(4);
  expect(await content.innerText()).toBe(five);
  // The default title shows through a pseudo-element.
  const title = await page
    .locator(".cm-bc-callout-default-title")
    .first()
    .evaluate((el) => getComputedStyle(el, "::after").content);
  expect(title).toBe('"Note"');
});

test("icon click posts calloutMenu with the type", async ({ page }) => {
  await openWith(page, five, five.length);
  const head = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head);
  await page.locator(".cm-bc-callout-icon-warning").click();
  await expect.poll(() => hooks(page).sent("calloutMenu")).toHaveLength(1);
  const [menu] = await hooks(page).sent("calloutMenu");
  expect(menu).toMatchObject({ type: "calloutMenu", calloutType: "warning" });
  expect(typeof menu!.menuId).toBe("string");
  // The caret stays where it was; the menu's choice lands on the clicked callout.
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection().head)).toBe(head);
  await hooks(page).deliver({ type: "applyCommand", name: "setCalloutType", args: { type: "tip", menuId: menu!.menuId } });
  await expect.poll(() => hooks(page).text()).toBe(five.replace("> [!WARNING]", "> [!TIP]"));
  await expect(page.locator(".cm-bc-callout-icon-warning")).toHaveCount(0);
});

test("callouts screenshot: the five types and a nested box", async ({ page }) => {
  await page.setViewportSize({ width: 800, height: 820 });
  await openWith(page, five, five.length);
  await page.mouse.move(5, 810);
  await settle(page);
  await expect(page).toHaveScreenshot("callouts.png", { maxDiffPixelRatio: 0.002 });
});
