// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";

// W1: the capture-close freeze/drain against the real editor (docs/editor-bridge-capture-close.md).
// The unit tests (test/client.test.ts) cover the message flow with a fake editor; this spec covers
// what only the real CodeMirror view can show: refusing edits, composition, the restored mode.

type Sent = { type: string; [key: string]: unknown };
type Hooks = {
  debugText(): string;
  debugView(): {
    composing: boolean;
    contentDOM: HTMLElement;
    dispatch(spec: unknown): void;
    state: { doc: { toString(): string } };
  };
  mock: {
    text: string;
    revision: number;
    sent: Sent[];
    deliver(msg: unknown): void;
    send(msg: Sent): Promise<unknown>;
  };
};

const text = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const mockText = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text);
const frozenReplies = (page: Page) =>
  page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.sent.filter((m) => m.type === "frozenForClose"));
const sha256 = (page: Page, value: string) =>
  page.evaluate(async (v) => {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v));
    return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
  }, value);

async function open(page: Page, doc: string, readOnly = false) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate(
    ([d, ro]) => {
      const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
      hooks.mock.deliver({ type: "loadNote", noteId: "mock-note", text: d, revision: hooks.mock.revision, readOnly: ro });
    },
    [doc, readOnly] as const,
  );
  await expect.poll(() => text(page)).toBe(doc);
  return content;
}

const freeze = (page: Page, requestId = "f1") =>
  page.evaluate(
    (id) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "freezeForClose", requestId: id, noteId: "mock-note" }),
    requestId,
  );
const unfreeze = (page: Page, requestId = "f1") =>
  page.evaluate(
    (id) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "unfreeze", requestId: id, noteId: "mock-note" }),
    requestId,
  );

test("a frozen editor refuses typing, programmatic changes and host commands", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  await page.keyboard.type("a");
  await expect.poll(() => text(page)).toBe("a");

  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  expect((await frozenReplies(page))[0]).toMatchObject({ ok: true, editedSinceLoad: true });
  await expect(content).toHaveAttribute("contenteditable", "false");

  await page.keyboard.type("b");
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ changes: { from: 0, insert: "p" } }));
  await page.evaluate(() =>
    (window as unknown as { __baerchen: Hooks }).__baerchen.mock.deliver({ type: "applyCommand", name: "insertText", args: { text: "c" } }),
  );
  await page.waitForTimeout(150);
  expect(await text(page)).toBe("a");
  expect(await mockText(page)).toBe("a");
});

test("a transaction typed just before the freeze is acknowledged before the reply", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  // The host holds back its acknowledgement of changes until released.
  await page.evaluate(() => {
    const mock = (window as unknown as { __baerchen: Hooks & { release?: () => void } }).__baerchen.mock as Hooks["mock"] & { release?: () => void };
    const send = mock.send.bind(mock);
    let gate: Promise<void> = new Promise((resolve) => { mock.release = resolve; });
    mock.send = async (msg: Sent) => {
      if (msg.type === "changes") await gate;
      return send(msg);
    };
    void gate;
  });
  await page.keyboard.type("held");
  await freeze(page);
  await page.waitForTimeout(250);
  expect(await frozenReplies(page)).toEqual([]);
  expect(await mockText(page)).toBe("");

  await page.evaluate(() => ((window as unknown as { __baerchen: { mock: { release?: () => void } } }).__baerchen.mock.release as () => void)());
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  // By the time the reply exists the host holds every character, and the reply names their hash.
  expect(await mockText(page)).toBe("held");
  const [reply] = await frozenReplies(page);
  expect(reply).toMatchObject({ ok: true, editedSinceLoad: true, sha256: await sha256(page, "held") });
  expect(typeof reply!.lastAckedTxId).toBe("string");
});

test("a composition running at the freeze is committed, not lost", async ({ page }) => {
  await page.addInitScript(() => {
    // The 30 Hz frame of the iOS software keyboard (see ime.spec.ts): the deferred read of a
    // composition's DOM happens after the frame.
    window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 35);
    window.cancelAnimationFrame = clearTimeout;
  });
  const content = await open(page, "");
  await content.click();
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    view.contentDOM.querySelector(".cm-line")!.textContent = "k";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "k", isComposing: true }));
  });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().composing)).toBe(true);

  await freeze(page);
  // The keyboard confirms its candidate once it is asked to let go: the text is different from the preedit.
  await page.waitForTimeout(80);
  expect(await frozenReplies(page)).toEqual([]);
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.querySelector(".cm-line")!.textContent = "か";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "か", isComposing: true }));
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "か" }));
  });

  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  const [reply] = await frozenReplies(page);
  expect(reply).toMatchObject({ ok: true, editedSinceLoad: true, sha256: await sha256(page, "か") });
  expect(await text(page)).toBe("か");
  expect(await mockText(page)).toBe("か");
  await expect(content).toHaveAttribute("contenteditable", "false");
});

test("a composition that never ends keeps the note: not ok, and the editor still works", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    view.contentDOM.querySelector(".cm-line")!.textContent = "k";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "k", isComposing: true }));
  });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().composing)).toBe(true);

  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length, { timeout: 3000 }).toBe(1);
  expect((await frozenReplies(page))[0]).toMatchObject({ ok: false, reason: "composing" });
  await expect(content).toHaveAttribute("contenteditable", "true");
});

test("a change from the host (another window, CLI) does not reach a frozen editor until the unfreeze", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);

  await page.evaluate(() =>
    (window as unknown as { __baerchen: { mock: { externalEdit(spec: unknown): void } } }).__baerchen.mock.externalEdit({ from: 0, insert: "host" }),
  );
  await page.waitForTimeout(150);
  expect(await text(page)).toBe("");
  expect(await mockText(page)).toBe("host");

  await unfreeze(page);
  await expect.poll(() => text(page)).toBe("host");
  // The editor and the host agree again, and typing continues on the right revision.
  await page.keyboard.type("!");
  await expect.poll(() => mockText(page)).toContain("!");
  expect(await mockText(page)).toBe(await text(page));
});

test("unfreeze gives an editable note its typing back", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  await expect(content).toHaveAttribute("contenteditable", "false");

  await unfreeze(page);
  await expect(content).toHaveAttribute("contenteditable", "true");
  // Typing works again, with the caret where it was.
  await page.keyboard.type("again");
  await expect.poll(() => text(page)).toBe("again");
  await expect.poll(() => mockText(page)).toBe("again");
});

test("unfreeze leaves a read-only note read-only", async ({ page }) => {
  const content = await open(page, "locked text", true);
  await content.click();
  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  expect((await frozenReplies(page))[0]).toMatchObject({ ok: true, editedSinceLoad: false });

  await unfreeze(page);
  await page.keyboard.type("nope");
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ changes: { from: 0, insert: "x" } }));
  await page.waitForTimeout(150);
  expect(await text(page)).toBe("locked text");
  await expect(content).toHaveAttribute("aria-readonly", "true");
});

test("a host that never acknowledges gets ok:false and the editor stays frozen", async ({ page }) => {
  const content = await open(page, "");
  await content.click();
  await page.evaluate(() => {
    const mock = (window as unknown as { __baerchen: Hooks }).__baerchen.mock;
    const send = mock.send.bind(mock);
    mock.send = (msg: Sent) => (msg.type === "changes" ? new Promise(() => {}) : send(msg));
  });
  await page.keyboard.type("lost");
  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length, { timeout: 5000 }).toBe(1);
  expect((await frozenReplies(page))[0]).toMatchObject({ ok: false, reason: "timeout", editedSinceLoad: true });
  await expect(content).toHaveAttribute("contenteditable", "false");
});

test("editedSinceLoad is false for an untouched document", async ({ page }) => {
  await open(page, "from the host");
  await freeze(page);
  await expect.poll(async () => (await frozenReplies(page)).length).toBe(1);
  const [reply] = await frozenReplies(page);
  expect(reply).toMatchObject({ ok: true, editedSinceLoad: false, sha256: await sha256(page, "from the host") });
});
