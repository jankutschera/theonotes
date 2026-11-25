// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// Autocomplete in mock mode: the MockHost answers `requestCompletions` from `mock.completions`
// (items whose label contains the query), standing in for the Swift CompletionProvider.

type Sent = { type: string; [key: string]: unknown };
type Item = { label: string; insert: string; detail?: string; icon?: string };
type View = { dispatch(spec: unknown): void; state: { doc: { length: number } } };
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugView(): View;
  mock: { sent: Sent[]; completions: Record<string, Item[]>; deliver(msg: unknown): void };
};

const completions: Record<string, Item[]> = {
  tag: [
    { label: "work", insert: "#work ", detail: "12", icon: "briefcase" },
    { label: "work/projects", insert: "#work/projects ", detail: "3", icon: "folder" },
  ],
  note: [
    { label: "Project Plan", insert: "Project Plan" },
    { label: "Private", insert: "Private", detail: "Archive" },
    { label: "Food", insert: "Food" },
  ],
  heading: [
    { label: "Intro", insert: "Intro", detail: "H1" },
    { label: "Next Steps", insert: "Next Steps", detail: "H2" },
  ],
  emoji: [
    { label: "🐈 cat", insert: "🐈" },
    { label: "🐱 cat face", insert: "🐱" },
  ],
};

async function open(page: Page, doc = "") {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(
    ([d, c]) => {
      const b = (window as unknown as { __baerchen: Hooks }).__baerchen;
      b.mock.completions = c as Record<string, Item[]>;
      if (d) b.debugInsert(d as string);
    },
    [doc, completions] as const,
  );
  return content;
}

const text = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const sent = (page: Page, type: string) =>
  page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.filter((m) => m.type === t), type);
const deliver = (page: Page, msg: Record<string, unknown>) =>
  page.evaluate((m) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver(m), msg);

const popup = (page: Page) => page.locator(".cm-tooltip-autocomplete");
const options = (page: Page) => popup(page).locator("li");

/** Lets the popup's interaction delay pass before a key accepts. */
const settle = (page: Page) => page.waitForTimeout(120);

test("typing #wo shows work with its TagCon and Enter inserts #work ", async ({ page }) => {
  await open(page);
  await page.keyboard.type("Today #wo");
  await expect(options(page).first()).toContainText("work");
  await expect(options(page)).toHaveCount(2);
  const icon = options(page).first().locator(".cm-bc-tagcon");
  await expect(icon).toHaveAttribute("aria-hidden", "true");
  expect(await icon.evaluate((el) => getComputedStyle(el).getPropertyValue("--bc-tagcon"))).toContain(
    "baerchen-asset://tagcon/v2/briefcase.png",
  );
  expect(await sent(page, "requestCompletions")).toContainEqual(
    expect.objectContaining({ kind: "tag", query: "wo", noteId: "mock-note" }),
  );
  await settle(page);
  await page.keyboard.press("Enter");
  expect(await text(page)).toBe("Today #work ");
  await expect(popup(page)).toHaveCount(0);
  await page.keyboard.type("done");
  expect(await text(page)).toBe("Today #work done");
});

test("arrow keys pick another tag; Escape closes without inserting", async ({ page }) => {
  await open(page);
  await page.keyboard.type("#wo");
  await expect(options(page)).toHaveCount(2);
  await settle(page);
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  expect(await text(page)).toBe("#work/projects ");
  await page.keyboard.type("#wo");
  await expect(options(page)).toHaveCount(2);
  await page.keyboard.press("Escape");
  await expect(popup(page)).toHaveCount(0);
  expect(await text(page)).toBe("#work/projects #wo");
});

test("[[ lists notes and Enter inserts the title with ]]", async ({ page }) => {
  await open(page);
  await page.keyboard.type("See [[Pro");
  await expect(options(page).first()).toContainText("Project Plan");
  await settle(page);
  await page.keyboard.press("Enter");
  expect(await text(page)).toBe("See [[Project Plan]]");
});

test("a typed / lists that title's headings; Enter closes the link", async ({ page }) => {
  await open(page);
  await page.keyboard.type("See [[Project Plan/");
  await expect(options(page).first()).toContainText("Intro");
  expect(await sent(page, "requestCompletions")).toContainEqual(
    expect.objectContaining({ kind: "heading", query: "", noteTitle: "Project Plan" }),
  );
  await page.keyboard.type("Ne");
  await expect(options(page)).toHaveCount(1);
  await settle(page);
  await page.keyboard.press("Enter");
  expect(await text(page)).toBe("See [[Project Plan/Next Steps]]");
  await page.keyboard.type(" ok");
  expect(await text(page)).toBe("See [[Project Plan/Next Steps]] ok");
});

// Ruling R28: only Enter and Tab accept (Bear); / and | are always plain text.
for (const delay of [0, 150]) {
  test(`[[a/b typed ${delay ? "slowly" : "fast"} stays [[a/b while note titles are listed`, async ({ page }) => {
    await open(page);
    await page.keyboard.type("[[a", { delay });
    await expect(options(page).first()).toContainText("Project Plan");
    await settle(page);
    await page.keyboard.type("/b", { delay });
    expect(await text(page)).toBe("[[a/b");
  });
}

test("[[foo| stays as typed while a matching title is listed", async ({ page }) => {
  await open(page);
  await page.keyboard.type("[[foo");
  await expect(options(page).first()).toContainText("Food");
  await settle(page);
  await page.keyboard.type("|");
  expect(await text(page)).toBe("[[foo|");
  await expect(popup(page)).toHaveCount(0);
});

test(":ca shows emoji and Enter inserts the emoji", async ({ page }) => {
  await open(page);
  await page.keyboard.type("hi :ca");
  await expect(options(page).first()).toContainText("🐈 cat");
  await settle(page);
  await page.keyboard.press("Enter");
  expect(await text(page)).toBe("hi 🐈");
});

test("nothing is requested inside code or with the autocomplete setting off", async ({ page }) => {
  await open(page, "```\n");
  await page.keyboard.type("#wo :cat [[x");
  await page.waitForTimeout(250);
  await expect(popup(page)).toHaveCount(0);
  expect(await sent(page, "requestCompletions")).toEqual([]);

  await page.keyboard.press("Enter");
  await page.keyboard.type("```");
  await page.keyboard.press("Enter");
  await deliver(page, { type: "setSettings", autocomplete: false });
  await page.keyboard.type("#wo");
  await page.waitForTimeout(250);
  await expect(popup(page)).toHaveCount(0);
  expect(await sent(page, "requestCompletions")).toEqual([]);

  await deliver(page, { type: "setSettings", autocomplete: true });
  await page.keyboard.type("r");
  await expect(options(page).first()).toContainText("work");
});

test("tag pills show their TagCon as an aria-hidden widget; the text stays the document", async ({ page }) => {
  const doc = "Plan #work and #Work/Projects and #none\n`#work` stays code";
  const content = await open(page, doc);
  await deliver(page, { type: "tagIcons", icons: { work: "briefcase", "work/projects": "folder.fill" } });
  const icons = content.locator(".cm-bc-tagcon");
  await expect(icons).toHaveCount(2);
  for (const i of [0, 1]) await expect(icons.nth(i)).toHaveAttribute("aria-hidden", "true");
  expect(await icons.nth(1).evaluate((el) => getComputedStyle(el).getPropertyValue("--bc-tagcon"))).toContain(
    "tagcon/v2/folder.fill.png",
  );
  // Widgets add no characters: textContent and innerText (the AX text) are the note.
  expect(await content.innerText()).toBe(doc);
  expect(await text(page)).toBe(doc);
  // A new map replaces the old one.
  await deliver(page, { type: "tagIcons", icons: {} });
  await expect(icons).toHaveCount(0);
});
