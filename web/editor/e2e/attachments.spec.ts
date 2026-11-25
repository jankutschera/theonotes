// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { expect, test, type Page } from "@playwright/test";
import { imagePNGBase64 as png } from "./fixtures/image-png";

// Attachments and smart paste in mock mode: MockHost answers insertAttachments like the Swift
// host (applyCommand insertText). Bytes are not served here (no asset scheme), so widgets are
// checked for structure, not pixels.

type Sent = { type: string; [key: string]: unknown };
type Hooks = {
  debugInsert(text: string): void;
  debugText(): string;
  debugSelection(): { anchor: number; head: number };
  debugView(): { dispatch(spec: unknown): void };
  mock?: { text: string; sent: Sent[] };
};


const text = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugText());
const selection = (page: Page) => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugSelection());
const sent = (page: Page, type: string) =>
  page.evaluate((t) => (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.sent.filter((m) => m.type === t), type);

async function openWith(page: Page, doc: string, anchor = doc.length, head = anchor) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await expect(content).toHaveAttribute("contenteditable", "true");
  await content.click();
  await page.evaluate(([d, a, h]) => {
    const hooks = (window as unknown as { __baerchen: Hooks }).__baerchen;
    hooks.debugInsert(d as string);
    hooks.debugView().dispatch({ selection: { anchor: a, head: h } });
  }, [doc, anchor, head] as const);
  return content;
}

test("dropping a PNG inserts ![](image.png) at the drop point", async ({ page }) => {
  const content = await openWith(page, "before\nafter");
  const line = page.locator(".cm-line").first();
  const box = (await line.boundingBox())!;
  await page.evaluate(([b64, x, y]) => {
    const bytes = Uint8Array.from(atob(b64 as string), (c) => c.charCodeAt(0));
    const data = new DataTransfer();
    data.items.add(new File([bytes], "image.png", { type: "image/png" }));
    const target = document.querySelector(".cm-content")!;
    target.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: data, clientX: x as number, clientY: y as number }));
    target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data, clientX: x as number, clientY: y as number }));
  }, [png, box.x + box.width - 1, box.y + box.height / 2] as const);

  await expect.poll(() => text(page)).toBe("before![](image.png)\nafter");
  const upload = (await sent(page, "insertAttachments"))[0]!;
  expect(upload).toMatchObject({ noteId: "mock-note", items: [{ filename: "image.png", dataBase64: png }] });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.mock!.text)).toBe(
    "before![](image.png)\nafter",
  );
  await expect(content.locator(".cm-bc-attachment-image img")).toHaveAttribute("src", "baerchen-asset://attachment/mock-note/image.png");
});

test("attachments keep their text in the DOM, widgets are aria-hidden, the source is atomic", async ({ page }) => {
  const doc = 'a ![](p%202.png) b [r.pdf](r.pdf)<!-- {"preview":"true","embed":"true"} --> c';
  const content = await openWith(page, doc, 0);
  // AX-faithful: the accessibility text is the document text.
  await expect.poll(() => content.evaluate((el) => (el as HTMLElement).innerText.replace(/​/g, ""))).toContain("![](p%202.png)");
  const image = content.locator(".cm-bc-attachment-image");
  await expect(image).toHaveAttribute("aria-hidden", "true");
  await expect(content.locator(".cm-bc-attachment-pdf .cm-bc-attachment-name")).toHaveText("r.pdf");
  await expect(content.locator(".cm-bc-attachment-pdf .cm-bc-attachment-page")).toHaveAttribute(
    "src", "baerchen-asset://thumbnail/mock-note/r.pdf",
  );
  // The card text is visible (not the collapsed hidden-text style).
  const color = await content.locator(".cm-bc-attachment-name").evaluate((el) => getComputedStyle(el).color);
  expect(color).not.toBe("rgba(0, 0, 0, 0)");

  // Arrow keys step over the whole source.
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 2 } }));
  await page.keyboard.press("ArrowRight");
  expect((await selection(page)).head).toBe(16);
  // Backspace after it removes the whole attachment, one undo step brings it back.
  await page.keyboard.press("Backspace");
  expect(await text(page)).toBe('a  b [r.pdf](r.pdf)<!-- {"preview":"true","embed":"true"} --> c');
  await page.keyboard.press("Meta+z");
  expect(await text(page)).toBe(doc);
});

test("a click selects the attachment; Space and the context menu go to the host", async ({ page }) => {
  const doc = "x [d.zip](d.zip)<!-- {\"embed\":\"true\"} --> y";
  const content = await openWith(page, doc, 0);
  const card = content.locator(".cm-bc-attachment-file");
  await card.click();
  const end = doc.indexOf(" y");
  expect(await selection(page)).toEqual({ anchor: end, head: end });
  await expect(content.locator(".cm-bc-attachment-selected")).toHaveCount(1);
  await page.keyboard.press("Space");
  expect(await text(page)).toBe(doc);
  expect(await sent(page, "quickLook")).toEqual([{ type: "quickLook", noteId: "mock-note", filename: "d.zip" }]);

  // Backspace removes the selected attachment's link, ⌘Z brings it back.
  await page.keyboard.press("Backspace");
  expect(await text(page)).toBe("x  y");
  await page.keyboard.press("Meta+z");
  expect(await text(page)).toBe(doc);

  await card.click({ button: "right" });
  expect(await sent(page, "attachmentMenu")).toEqual([
    { type: "attachmentMenu", noteId: "mock-note", filename: "d.zip", from: 2, to: end, source: doc.slice(2, end) },
  ]);
});

async function paste(page: Page, data: Record<string, string>) {
  await page.evaluate((entries) => {
    const transfer = new DataTransfer();
    for (const [type, value] of Object.entries(entries)) transfer.setData(type, value);
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
  }, data);
}

test("smart paste: a URL on a selection links it, rich HTML becomes Markdown", async ({ page }) => {
  await openWith(page, "see docs", 4, 8);
  await paste(page, { "text/plain": "https://example.com/faq/" });
  expect(await text(page)).toBe("see [docs](https://example.com/faq/)");
  await page.keyboard.press("Meta+z");
  expect(await text(page)).toBe("see docs");

  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 8 } }));
  await paste(page, { "text/plain": "Hi there", "text/html": "<p><b>Hi</b> <a href='https://x.y'>there</a></p>" });
  expect(await text(page)).toBe("see docs**Hi** [there](https://x.y)");
});

test("rich HTML pasted inside a code block pastes its plain text and leaves the block intact", async ({ page }) => {
  // Turndown would wrap the snippet in its own ```` fence, closing this block early (final review I1).
  const doc = "````swift\nlet x = 1\n\n````\nafter";
  await openWith(page, doc, doc.indexOf("\n\n") + 1);
  await paste(page, { "text/plain": "a\n```\nb", "text/html": "<pre><code>a\n```\nb</code></pre>" });
  expect(await text(page)).toBe("````swift\nlet x = 1\na\n```\nb\n````\nafter");
});

test("attachment links copied from another note are pasted through the host; in the same note as is", async ({ page }) => {
  const doc = 'a ![](p.png) b';
  await openWith(page, doc, 0, doc.length);
  const copied = await page.evaluate(() => {
    const transfer = new DataTransfer();
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("copy", { bubbles: true, cancelable: true, clipboardData: transfer }));
    return { text: transfer.getData("text/plain"), refs: transfer.getData("application/x-baerchen-attachments") };
  });
  expect(copied).toEqual({ text: doc, refs: JSON.stringify({ noteId: "mock-note", filenames: ["p.png"] }) });

  // Same note: the default paste, no host round trip.
  await page.evaluate(() => (window as unknown as { __baerchen: Hooks }).__baerchen.debugView().dispatch({ selection: { anchor: 14 } }));
  await paste(page, { "text/plain": copied.text, "application/x-baerchen-attachments": copied.refs });
  expect(await text(page)).toBe(doc + doc);
  expect(await sent(page, "pasteAttachments")).toEqual([]);

  // From another note: the host copies the files and answers for the pending insert.
  await paste(page, { "text/plain": "![](q.png)", "application/x-baerchen-attachments": JSON.stringify({ noteId: "other", filenames: ["q.png"] }) });
  await expect.poll(() => text(page)).toBe(doc + doc + "![](q.png)");
  expect(await sent(page, "pasteAttachments")).toMatchObject([
    { noteId: "mock-note", sourceNoteId: "other", text: "![](q.png)", items: [{ from: 0, to: 10, filename: "q.png" }] },
  ]);
});

test("cut removes the selection and carries the attachment refs", async ({ page }) => {
  await openWith(page, "x ![](p.png) y", 0, 14);
  const refs = await page.evaluate(() => {
    const transfer = new DataTransfer();
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("cut", { bubbles: true, cancelable: true, clipboardData: transfer }));
    return transfer.getData("application/x-baerchen-attachments");
  });
  expect(JSON.parse(refs)).toEqual({ noteId: "mock-note", filenames: ["p.png"] });
  expect(await text(page)).toBe("");
  // The host keeps the file until the pasteboard changes (R30).
  expect(await sent(page, "cutAttachments")).toEqual([{ type: "cutAttachments", noteId: "mock-note", filenames: ["p.png"] }]);
});

test("files over the size cap are refused without being read", async ({ page }) => {
  await openWith(page, "a");
  await page.evaluate(() => {
    const transfer = new DataTransfer();
    transfer.items.add(new File([new Uint8Array(51 * 1024 * 1024)], "huge.mov", { type: "video/quicktime" }));
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
  });
  expect(await sent(page, "attachmentsRefused")).toEqual([{ type: "attachmentsRefused", noteId: "mock-note", reason: "tooLarge", filenames: ["huge.mov"] }]);
  expect(await sent(page, "insertAttachments")).toEqual([]);
  expect(await text(page)).toBe("a");
});

test("pasting an image from the pasteboard stores it like a drop", async ({ page }) => {
  await openWith(page, "a");
  await page.evaluate((b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const transfer = new DataTransfer();
    transfer.items.add(new File([bytes], "image.png", { type: "image/png" }));
    document.querySelector(".cm-content")!.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
  }, png);
  await expect.poll(() => text(page)).toBe("a![](image.png)");
});

test("a read-only note refuses dropped and pasted files and pasted attachment links", async ({ page }) => {
  await page.goto("/index.html?mock");
  await expect(page.locator(".cm-content")).toHaveAttribute("contenteditable", "true");
  await page.evaluate(() => {
    const mock = (window as unknown as { __baerchen: { mock: { revision: number; deliver(msg: unknown): void } } }).__baerchen.mock;
    mock.deliver({ type: "loadNote", noteId: "mock-note", text: "fixed", revision: mock.revision, readOnly: true });
  });
  await expect.poll(() => text(page)).toBe("fixed");
  await page.locator(".cm-content").click();
  await page.evaluate((b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const target = document.querySelector(".cm-content")!;
    const files = () => {
      const data = new DataTransfer();
      data.items.add(new File([bytes], "image.png", { type: "image/png" }));
      return data;
    };
    target.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: files(), clientX: 5, clientY: 5 }));
    target.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: files() }));
    const links = new DataTransfer();
    links.setData("text/plain", "![](q.png)");
    links.setData("application/x-baerchen-attachments", JSON.stringify({ noteId: "other", filenames: ["q.png"] }));
    target.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: links }));
  }, png);
  // A host answer arriving anyway (a stale insert id) changes nothing either.
  await page.evaluate(() =>
    (window as unknown as { __baerchen: { mock: { deliver(msg: unknown): void } } }).__baerchen.mock.deliver({
      type: "applyCommand", name: "insertText", args: { text: "![](x.png)", insertId: "late" },
    }),
  );
  expect(await sent(page, "insertAttachments")).toEqual([]);
  expect(await sent(page, "pasteAttachments")).toEqual([]);
  expect(await text(page)).toBe("fixed");
});

test("an SVG attachment renders through <img> and its script never runs", async ({ page }) => {
  // The host serves SVG as image/svg+xml under the attachment CSP (AssetSchemeHandler); a script
  // inside it must not run, and no SVG element may reach the editor's DOM.
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" onload="window.__svgRan = true">' +
    '<script>window.__svgRan = true</script><rect width="40" height="20" fill="red"/></svg>';
  const served: string[] = [];
  await page.route("baerchen-asset://attachment/**", (route) => {
    served.push(route.request().url());
    return route.fulfill({
      status: 200,
      headers: { "Content-Type": "image/svg+xml", "X-Content-Type-Options": "nosniff" },
      body: svg,
    });
  });
  const content = await openWith(page, "a ![](vector.svg) b", 0);
  const img = content.locator(".cm-bc-attachment-image img");
  await expect(img).toHaveAttribute("src", "baerchen-asset://attachment/mock-note/vector.svg");
  await expect.poll(() => img.evaluate((el) => (el as HTMLImageElement).complete)).toBe(true);
  expect(served).toContain("baerchen-asset://attachment/mock-note/vector.svg");
  expect(await img.evaluate((el) => (el as HTMLImageElement).naturalWidth)).toBe(40);
  // Only <img>: no inline SVG, <object>, <embed> or <iframe> anywhere, and nothing ran.
  expect(await page.locator("svg, object, embed, iframe").count()).toBe(0);
  expect(await page.evaluate(() => (window as unknown as { __svgRan?: boolean }).__svgRan)).toBeUndefined();
  // Quick Look goes to the host like any attachment; the SVG is never opened here.
  await img.dblclick();
  expect(await sent(page, "quickLook")).toEqual([{ type: "quickLook", noteId: "mock-note", filename: "vector.svg" }]);
});

test.describe("touch attachment actions", () => {
  test.use({ hasTouch: true });
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => Object.defineProperty(navigator, "maxTouchPoints", { get: () => 5 }));
  });

  test("visible accessible actions preserve source and work read-only", async ({ page }) => {
    const source = 'before ![alt](photo.png)<!-- {"width":"320"} --> after';
    await openWith(page, source, 0);
    const actions = page.getByRole("button", { name: "Attachment actions: photo.png" });
    await expect(actions).toBeVisible();
    const box = await actions.boundingBox();
    expect(box!.width).toBeGreaterThanOrEqual(44);
    expect(box!.height).toBeGreaterThanOrEqual(44);
    await actions.tap();
    await expect.poll(() => sent(page, "attachmentMenu")).toHaveLength(1);
    expect((await sent(page, "attachmentMenu"))[0]).toMatchObject({ filename: "photo.png", source: '![alt](photo.png)<!-- {"width":"320"} -->' });
    expect(await text(page)).toBe(source);
    await page.evaluate((doc) => {
      const api = (window as unknown as { __baerchen: { mock: { revision: number; deliver(msg: unknown): void } } }).__baerchen;
      api.mock.deliver({ type: "loadNote", noteId: "mock-note", text: doc, revision: api.mock.revision, readOnly: true });
    }, source);
    await actions.tap();
    await expect.poll(() => sent(page, "attachmentMenu")).toHaveLength(2);
    expect(await text(page)).toBe(source);
  });

  test("short touch sends exact attachment source; scroll and long press do not tap", async ({ page }) => {
    const source = 'before ![alt](photo.png)<!-- {"width":"320"} --> after';
    await openWith(page, source, 0);
    const image = page.locator('.cm-bc-attachment-image');
    await image.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await image.dispatchEvent('pointerup', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await expect.poll(() => sent(page, 'attachmentTap')).toEqual([{ type: 'attachmentTap', noteId: 'mock-note', filename: 'photo.png', from: 7, to: source.length - 6, source: '![alt](photo.png)<!-- {"width":"320"} -->' }]);
    await image.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await image.dispatchEvent('pointermove', { pointerType: 'touch', clientX: 100, clientY: 130 });
    await image.dispatchEvent('pointerup', { pointerType: 'touch', clientX: 100, clientY: 130 });
    expect(await sent(page, 'attachmentTap')).toHaveLength(1);
    await image.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await expect.poll(() => sent(page, 'attachmentMenu')).toHaveLength(1);
    await image.dispatchEvent('pointerup', { pointerType: 'touch', clientX: 100, clientY: 100 });
    expect(await sent(page, 'attachmentTap')).toHaveLength(1);
  });

  test("long press opens actions but a scrolling movement cancels it", async ({ page }) => {
    await openWith(page, '![alt](photo.png)\nend', 0);
    const image = page.locator('.cm-bc-attachment-image');
    await image.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await image.dispatchEvent('pointermove', { pointerType: 'touch', clientX: 100, clientY: 130 });
    await page.waitForTimeout(650);
    expect(await sent(page, 'attachmentMenu')).toHaveLength(0);
    await image.dispatchEvent('pointerdown', { pointerType: 'touch', clientX: 100, clientY: 100 });
    await expect.poll(() => sent(page, 'attachmentMenu')).toHaveLength(1);
    expect(await text(page)).toBe('![alt](photo.png)\nend');
  });
});
