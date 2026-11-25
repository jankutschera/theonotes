// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test } from "@playwright/test";
import type { EditorView } from "@codemirror/view";

type Hooks = { debugView(): EditorView; mock: { text: string } };

// CodeMirror deliberately defers iOS composition deletions until the next animation frame.
// Reproduce the actual Japanese software-keyboard trace, including the mutation microtask
// between input(deleteCompositionText) and compositionend, rather than injecting editor text.
// Native composition keydown reports 229; keyup reports the ordinary character/key code.
for (const prefix of ["", "日本 👩‍💻 e\u{301} "]) {
 test(`iOS canceled preedit stays deleted after committed prefix ${JSON.stringify(prefix)}`, async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "maxTouchPoints", { get: () => 5 });
    // Match a 30 Hz iOS frame: the native keyboard trace delivered its first frame
    // after autocomplete's 20 ms timer. Faster desktop frames hide this race.
    window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 35);
    window.cancelAnimationFrame = clearTimeout;
  });
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate((prefix) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.dispatch({ changes: { from: 0, insert: prefix }, selection: { anchor: prefix.length } });
    view.focus();
  }, prefix);
  await expect(content).toHaveText(prefix);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe(prefix);
  await page.evaluate((prefix) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "k", code: "KeyK", keyCode: 229 }));
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true, data: "" }));
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: "k" }));
    const line = view.contentDOM.querySelector(".cm-line")!;
    if (line.firstChild?.nodeType === Node.TEXT_NODE) (line.firstChild as Text).data = prefix + "k";
    else line.textContent = prefix + "k";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "k", isComposing: true }));
  }, prefix);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().composing)).toBe(true);
  await page.evaluate((prefix) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    const text = view.contentDOM.querySelector(".cm-line")!.firstChild as Text;
    window.getSelection()!.collapse(text, prefix.length + 1);
    view.dispatch({ selection: { anchor: prefix.length + 1 }, userEvent: "select" });
    view.contentDOM.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true, key: "k", code: "KeyK", keyCode: 75, isComposing: true }));
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "a", code: "KeyA", keyCode: 229, isComposing: true }));
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionupdate", { bubbles: true, data: "か" }));
    view.contentDOM.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, inputType: "insertCompositionText", data: "か", isComposing: true }));
    text.data = prefix + "か";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "か", isComposing: true }));
  }, prefix);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().state.doc.toString())).toBe(prefix + "か");
  await page.evaluate((prefix) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.dispatch({ selection: { anchor: prefix.length + 1 }, userEvent: "select" });
    view.contentDOM.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true, key: "a", code: "KeyA", keyCode: 65, isComposing: true }));
  }, prefix);
  // Settle selection/measurement work before the separate Backspace interaction.
  await page.waitForTimeout(120);
  await page.evaluate(async (prefix) => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: "Backspace", code: "Backspace", keyCode: 229, isComposing: true }));
    view.contentDOM.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, inputType: "deleteCompositionText", isComposing: true }));
    const line = view.contentDOM.querySelector(".cm-line")!;
    if (prefix) {
      const text = line.firstChild as Text;
      text.data = prefix;
      window.getSelection()!.collapse(text, prefix.length);
    } else {
      // Actual iOS trace removes the text node and inserts BR when the line becomes empty.
      line.replaceChildren(document.createElement("br"));
      window.getSelection()!.collapse(line, 0);
    }
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "deleteCompositionText", isComposing: true }));
    // Deliver the deletion mutation while composing; CodeMirror queues its frame flush.
    await Promise.resolve();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "" }));
    view.contentDOM.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true, key: "Backspace", code: "Backspace", keyCode: 8 }));
  }, prefix);
  await page.waitForTimeout(150);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().state.doc.toString())).toBe(prefix);
  await expect(content).toHaveText(prefix);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe(prefix);
});

}

test("iOS committed preedit survives deferred presentation refresh", async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "maxTouchPoints", { get: () => 5 });
    // Match a 30 Hz iOS frame: the native keyboard trace delivered its first frame
    // after autocomplete's 20 ms timer. Faster desktop frames hide this race.
    window.requestAnimationFrame = (callback) => setTimeout(() => callback(performance.now()), 35);
    window.cancelAnimationFrame = clearTimeout;
  });
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.focus();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    view.contentDOM.querySelector(".cm-line")!.textContent = "日本 **太字**";
    view.contentDOM.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertCompositionText", data: "日本 **太字**", isComposing: true }));
  });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().composing)).toBe(true);
  await page.evaluate(() => {
    const view = (window as unknown as { __baerchen: Hooks }).__baerchen.debugView();
    view.contentDOM.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true, data: "日本 **太字**" }));
  });
  await page.waitForTimeout(150);
  expect(await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().state.doc.toString())).toBe("日本 **太字**");
  await expect(content.locator(".cm-bc-strong")).toHaveText("**太字**");
  await expect(content.locator(".cm-bc-strong")).toHaveCSS("font-weight", "700");
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock.text)).toBe("日本 **太字**");
});
