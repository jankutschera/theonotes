// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { visibleText } from "./visible";

type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): { dispatch(spec: unknown): void };
  mock?: { sent: { type: string; [key: string]: unknown }[]; deliver(msg: unknown): void };
};

const hooks = (page: Page) => ({
  text: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText()),
  selection: () => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection()),
  sent: (type: string) =>
    page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.sent.filter((m) => m.type === t), type),
  select: (anchor: number) =>
    page.evaluate((a) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: a } }), anchor),
});

/** Every request leaving the dev server (there must be none: languages come from the bundle). */
async function offline(page: Page): Promise<string[]> {
  const external: string[] = [];
  await page.route("**/*", (route) => {
    const url = new URL(route.request().url());
    if (url.hostname === "localhost") return route.continue();
    external.push(url.href);
    return route.abort();
  });
  return external;
}

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
  return content;
}

const NOTE = "Intro\n```swift\nlet greeting = \"hi\" // note\n```\nOutro";

test("a swift block is highlighted with the language loaded lazily from the bundle, offline", async ({ page }) => {
  const external = await offline(page);
  await openWith(page, "plain note", 0);
  const scripts = () =>
    page.evaluate(() => performance.getEntriesByType("resource").map((e) => e.name).filter((n) => /\.m?js(\?|$)/.test(n)));
  const before = await scripts();
  await page.evaluate((d) => (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert(d), `\n${NOTE}`);
  const keyword = page.locator(".cm-line .cm-bc-tok-keyword", { hasText: "let" });
  await expect(keyword).toHaveCount(1);
  await expect(page.locator(".cm-line .cm-bc-tok-string")).toHaveText('"hi"');
  await expect(page.locator(".cm-line .cm-bc-tok-comment")).toHaveText("// note");
  // Colored through the theme token.
  expect(await keyword.evaluate((el) => getComputedStyle(el).color)).toBe("rgb(176, 52, 127)");
  // The language module arrived after boot, from the dev server; nothing left the machine.
  const loaded = (await scripts()).filter((n) => !before.includes(n));
  expect(loaded.length).toBeGreaterThan(0);
  for (const url of loaded) expect(new URL(url).hostname).toBe("localhost");
  expect(external).toEqual([]);
  // Typing keeps the tokens (mapped) and re-highlights once typing pauses.
  const commentEnd = await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText().indexOf("// note") + 7);
  await hooks(page).select(commentEnd);
  await page.keyboard.type(" more");
  await expect(page.locator(".cm-line .cm-bc-tok-keyword", { hasText: "let" })).toHaveCount(1);
  await expect(page.locator(".cm-line .cm-bc-tok-comment")).toHaveText("// note more");
  // An unknown language stays plain.
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugInsert("\n```nope\nlet x\n```\n"));
  await expect(page.locator(".cm-line .cm-bc-tok-keyword")).toHaveCount(1);
});

test("fences collapse while the caret is outside the block; the block keeps its height", async ({ page }) => {
  const content = await openWith(page, NOTE, 2);
  const lines = content.locator(".cm-line");
  const open = lines.nth(1);
  const close = lines.nth(3);
  await expect(open).toHaveClass(/cm-bc-fence-collapsed/);
  await expect(close).toHaveClass(/cm-bc-fence-collapsed/);
  expect(await visibleText(open)).toBe("");
  expect(await visibleText(close)).toBe("");
  // The language label is drawn by CSS and aria-hidden; the DOM text stays the document text.
  const label = open.locator(".cm-bc-code-lang");
  await expect(label).toHaveAttribute("data-language", "swift");
  await expect(label).toHaveAttribute("aria-hidden", "true");
  expect(await label.evaluate((el) => getComputedStyle(el, "::before").content)).toBe('"swift"');
  await expect(open).toHaveText("```swift", { useInnerText: false });
  await expect(close).toHaveText("```", { useInnerText: false });
  const height = () => page.evaluate(() => {
    const ls = [...document.querySelectorAll(".cm-line")].slice(1, 4);
    return ls.reduce((h, l) => h + l.getBoundingClientRect().height, 0);
  });
  const collapsed = await height();

  await hooks(page).select(20);
  await expect(open).not.toHaveClass(/cm-bc-fence-collapsed/);
  expect(await visibleText(open)).toBe("```swift");
  expect(await visibleText(close)).toBe("```");
  await expect(open.locator(".cm-bc-code-lang")).toHaveCount(0);
  expect(Math.abs((await height()) - collapsed)).toBeLessThan(0.5);

  await hooks(page).select(NOTE.length);
  await expect(open).toHaveClass(/cm-bc-fence-collapsed/);
});

test("Copy Code sends the exact code with copyText and leaves caret and focus alone", async ({ page }) => {
  const doc = "```js\n  const a = 1;\n\n\tb() 👋\n```\nafter";
  const content = await openWith(page, doc);
  const button = page.locator(".cm-bc-copy");
  await expect(button).toHaveCount(1);
  await expect(page.getByRole("button", { name: "Copy Code", exact: true })).toHaveCount(1);
  // Desktop: hidden until the block is hovered (touch screens show it always, see below).
  expect(await button.evaluate((el) => getComputedStyle(el).opacity)).toBe("0");
  // Hovering any line of the block shows it.
  await content.locator(".cm-line").nth(3).hover();
  await expect(button).toHaveClass(/cm-bc-copy-shown/);
  await expect.poll(() => button.evaluate((el) => getComputedStyle(el).opacity)).toBe("1");
  const selection = await hooks(page).selection();
  await button.click();
  expect(await hooks(page).sent("copyText")).toEqual([{ type: "copyText", text: "  const a = 1;\n\n\tb() 👋" }]);
  expect(await hooks(page).selection()).toEqual(selection);
  expect(await page.evaluate(() => document.activeElement?.classList.contains("cm-content"))).toBe(true);
  await expect(button).toHaveAttribute("data-copied", "true");
  expect(await hooks(page).text()).toBe(doc);
  // Leaving the block hides it again.
  await content.locator(".cm-line").nth(5).hover();
  await expect(button).not.toHaveClass(/cm-bc-copy-shown/);
});

test("spellcheck and autocorrect are off on code lines and inline code only", async ({ page }) => {
  const content = await openWith(page, "Some `inline` text\n```\ncode\n```\nprose", 0);
  const lines = content.locator(".cm-line");
  for (const i of [1, 2, 3]) {
    await expect(lines.nth(i)).toHaveAttribute("spellcheck", "false");
    await expect(lines.nth(i)).toHaveAttribute("autocorrect", "off");
    await expect(lines.nth(i)).toHaveAttribute("writingsuggestions", "false");
  }
  for (const i of [0, 4]) await expect(lines.nth(i)).not.toHaveAttribute("spellcheck", "false");
  await expect(lines.nth(0).locator('[spellcheck="false"][autocorrect="off"]')).toHaveText("`inline`", { useInnerText: false });
});

test("typing a fence language offers completions; Enter right after ``` is a new line", async ({ page }) => {
  await openWith(page, "", 0);
  await page.keyboard.type("```sw");
  const tooltip = page.locator(".cm-tooltip-autocomplete");
  await expect(tooltip).toBeVisible();
  await expect(tooltip.locator("li", { hasText: "swift" }).first()).toBeVisible();
  // CodeMirror ignores Enter for 75 ms after the list opens (interactionDelay).
  await page.waitForTimeout(150);
  await page.keyboard.press("Enter");
  expect(await hooks(page).text()).toBe("```swift");
  await page.keyboard.press("Enter");
  await page.keyboard.type("x\n```\n\n```");
  await page.keyboard.press("Enter");
  await expect(tooltip).toHaveCount(0);
  expect(await hooks(page).text()).toBe("```swift\nx\n```\n\n```\n");
});

test("Paste as Code (applyCommand pasteCode) wraps the text in a fence, one undo step", async ({ page }) => {
  await openWith(page, "before", 6);
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.deliver({
      type: "applyCommand",
      name: "pasteCode",
      args: { text: "let a = 1\nlet b = 2\n" },
    }),
  );
  expect(await hooks(page).text()).toBe("before\n```\nlet a = 1\nlet b = 2\n```");
  await page.keyboard.press("Meta+z");
  expect(await hooks(page).text()).toBe("before");
});


test("Copy Code supports keyboard activation in read-only notes without changing source", async ({ page }) => {
  const doc = "```text\n  exact é 👋\n\twith whitespace  \n```\nafter";
  const content = await openWith(page, doc);
  await page.evaluate((text) => {
    const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
    api.mock!.deliver({ type: "loadNote", noteId: "mock-note", text, revision: 0, readOnly: true });
  }, doc);
  await expect(content).toHaveAttribute("aria-readonly", "true");
  const button = page.getByRole("button", { name: "Copy Code", exact: true });
  await button.focus();
  await expect(button).toBeFocused();
  await button.press("Enter");
  await page.locator(".cm-bc-copy").press("Space");
  expect(await hooks(page).sent("copyText")).toEqual([
    { type: "copyText", text: "  exact é 👋\n\twith whitespace  " },
    { type: "copyText", text: "  exact é 👋\n\twith whitespace  " },
  ]);
  expect(await hooks(page).text()).toBe(doc);
  expect(await content.innerText()).toBe(doc);
});

test("Copy Code is discoverable and tappable without hover on a touch screen", async ({ browser }) => {
  const context = await browser.newContext({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const doc = "```swift\nlet value = 42\n```\nafter";
  await openWith(page, doc);
  const button = page.getByRole("button", { name: "Copy Code", exact: true });
  await expect(button).toBeVisible();
  const box = (await button.boundingBox())!;
  expect(box.width).toBeGreaterThanOrEqual(44);
  expect(box.height).toBeGreaterThanOrEqual(44);
  await button.tap();
  expect(await hooks(page).sent("copyText")).toEqual([{ type: "copyText", text: "let value = 42" }]);
  expect(await hooks(page).text()).toBe(doc);
  await context.close();
});
