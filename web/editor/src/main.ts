// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { renderRichNote } from "./export/rich-note-export";
import { redo, undo } from "@codemirror/commands";
import { forceParsing, syntaxTree } from "@codemirror/language";
import { EditorView } from "@codemirror/view";
import { createEditor, viewHandle } from "./editor/setup";
import { bearchenRed } from "./editor/theme";
import { formatState } from "./editor/features/commands";
import type { CompletionBridge } from "./editor/features/autocomplete";
import { computeHiddenRanges } from "./editor/features/hiding";
import { rememberMenuTarget } from "./editor/features/menu-targets";
import { isFolded } from "./editor/features/folding";
import { HEADING_MENU_EVENT, type HeadingMenuDetail } from "./editor/features/typography";
import { CALLOUT_MENU_EVENT, type CalloutMenuDetail } from "./editor/features/callouts";
import { TABLE_MENU_EVENT, type TableMenuDetail } from "./editor/features/tables";
import { ATTACHMENT_EVENT, type AttachmentEventDetail, attachmentDecorationSpecs } from "./editor/features/attachments";
import { todoDecorations } from "./editor/features/todos";
import { testBlockRenderer } from "./editor/features/blocks-test-renderer";
import { BridgeClient } from "./bridge/client";
import { exposeGlobal, type Host, MockHost, WebKitHost } from "./bridge/hosts";
import { BRIDGE_VERSION } from "./bridge/protocol";

exposeGlobal({ renderNote: renderRichNote });

function pickHost(): { host: Host; mock: MockHost | null } | null {
  if (WebKitHost.isAvailable()) return { host: new WebKitHost(), mock: null };
  // Only an explicit ?mock in a dev build (vite dev, e2e) gets the in-memory host, so a broken
  // app bridge never silently "saves" into memory; production builds have no mock host.
  if (import.meta.env.DEV && new URLSearchParams(location.search).has("mock")) {
    const mock = new MockHost();
    return { host: mock, mock };
  }
  return null;
}

function boot(parent: HTMLElement): void {
  const picked = pickHost();
  if (!picked) {
    const banner = document.createElement("div");
    banner.className = "baerchen-bridge-error";
    banner.setAttribute("role", "alert");
    banner.textContent = "Editor bridge unavailable — notes cannot be edited or saved.";
    banner.style.cssText = "padding:24px;font:15px -apple-system,system-ui,sans-serif;color:var(--bc-color-error)";
    // No editor yet, so no theme variables on a `.cm-editor`: set the one token this banner uses.
    banner.style.setProperty("--bc-color-error", bearchenRed["--bc-color-error"]);
    parent.replaceChildren(banner);
    return;
  }
  const { host, mock } = picked;

  let client: BridgeClient | null = null;
  const completion: CompletionBridge = {
    request: (kind, query, noteTitle) => client?.completionBridge.request(kind, query, noteTitle) ?? Promise.resolve(null),
    enabled: () => client?.completionBridge.enabled() ?? false,
    tagIcons: () => client?.completionBridge.tagIcons() ?? new Map(),
  };
  // In the app the native Format menu owns the formatting shortcuts; mock mode has no menu.
  const view = createEditor(parent, {
    onTransaction: (tr) => client?.onTransaction(tr),
    shortcuts: new URLSearchParams(location.search).get("platform") === "ios" ? "ios" : mock ? "editor" : "menu",
    links: {
      openLink: (link) => client?.openLink(link),
      editLink: (request) => client?.editLinkRequest(request),
    },
    code: { copyText: (text, html) => client?.copyText(text, html) },
    completion,
    foldState: (folds) => client?.foldState(folds),
    // Dev builds only (e2e `?mock&testBlocks`): a stand-in renderer for the block widget layer.
    ...(import.meta.env.DEV && mock && new URLSearchParams(location.search).has("testBlocks") && {
      blockRenderers: [testBlockRenderer],
    }),
  });
  client = new BridgeClient(host, () => viewHandle(view), { formatState });
  exposeGlobal({ preserveForPrivacy: (noteId: string) => client?.preserveForPrivacy(noteId) ?? Promise.resolve(false) });
  host.onMessage((msg) => client?.handleHostMessage(msg));
  view.scrollDOM.addEventListener("scroll", () => client?.scrollChanged(view.scrollDOM.scrollTop), { passive: true });
  parent.addEventListener(HEADING_MENU_EVENT, (event) => {
    const { line, level, rect } = (event as CustomEvent<HeadingMenuDetail>).detail;
    if (line < 1 || line > view.state.doc.lines) return;
    // The target follows edits while the native menu is open and the menu opens at the badge;
    // `folded` picks Fold or Unfold.
    const pos = view.state.doc.line(line).from;
    client?.headingMenu(rememberMenuTarget(view, pos), line, level, isFolded(view.state, line), rect);
  });
  parent.addEventListener(CALLOUT_MENU_EVENT, (event) => {
    const { quoteFrom, calloutType, rect } = (event as CustomEvent<CalloutMenuDetail>).detail;
    if (quoteFrom < 0 || quoteFrom > view.state.doc.length) return;
    // The target is the callout's first line, so the menu's choice lands on it after edits.
    client?.calloutMenu(rememberMenuTarget(view, view.state.doc.lineAt(quoteFrom).from), calloutType, rect);
  });
  parent.addEventListener(TABLE_MENU_EVENT, (event) => {
    const { pos, row, column, rows, columns, rect } = (event as CustomEvent<TableMenuDetail>).detail;
    if (pos < 0 || pos > view.state.doc.length) return;
    // The target is the cell, so the menu's choice lands on it after edits; the column names a
    // padding cell's own column (its `pos` is the row's last real cell).
    client?.tableMenu(rememberMenuTarget(view, pos, column), row, column, rows, columns, rect);
  });
  parent.addEventListener(ATTACHMENT_EVENT, (event) => {
    const detail = (event as CustomEvent<AttachmentEventDetail>).detail;
    if (detail.kind === "quickLook") client?.quickLook(detail.filename);
    else if (detail.kind === "tap") client?.attachmentTap(detail.filename, detail.from, detail.to, detail.source);
    else if (detail.kind === "menu") client?.attachmentMenu(detail.filename, detail.from, detail.to, detail.source);
    else if (detail.kind === "refused") client?.attachmentsRefused(detail.filenames);
    else if (detail.kind === "copied") client?.attachmentsCopied(detail.filenames);
    else if (detail.kind === "pasteAttachments") client?.pasteAttachments(detail.insertId, detail.sourceNoteId, detail.text, detail.items);
    else void client?.insertAttachments(detail.insertId, detail.files);
  });

  // Dev builds only (vite dev, e2e): test hooks. Production bundles have none (a vitest greps the
  // built JS); the app's integration tests bring their own (Apps/TheoNotesMac/Tests).
  if (import.meta.env.DEV) {
    exposeGlobal({
      debugSelection: () => {
        const { anchor, head } = view.state.selection.main;
        return { anchor, head };
      },
      debugText: () => view.state.doc.toString(),
      debugInsert: (text: string) => view.dispatch(view.state.replaceSelection(text), { userEvent: "input.type" }),
      debugUndo: () => undo(view),
      debugRedo: () => redo(view),
      // Parses the whole note (up to `timeout` ms) and returns the length the syntax tree covers.
      debugParsedLength: (timeout: number) => {
        forceParsing(view, view.state.doc.length, timeout);
        return syntaxTree(view.state).length;
      },
      // The hidden ranges of the visible text: markup, todo markers and attachment sources (AX
      // e2e: no mark may cut one).
      debugHiddenRanges: () => {
        const ranges = [...computeHiddenRanges(view.state, view.visibleRanges)];
        for (const { from, to } of attachmentDecorationSpecs(view.state, view.visibleRanges)) ranges.push({ from, to });
        todoDecorations(view.state, view.visibleRanges).inner.between(0, view.state.doc.length, (from, to) => {
          if (from < to) ranges.push({ from, to });
        });
        return ranges;
      },
      ...(mock && { mock }),
      // The EditorView, found through CodeMirror's public API.
      debugView: () => EditorView.findFromDOM(parent),
    });
  }

  const report = (message: string, stack?: string) =>
    void host.send({ type: "error", message, ...(stack && { stack }) }).catch(() => {});
  window.addEventListener("error", (e) => report(e.message, e.error instanceof Error ? e.error.stack : undefined));
  window.addEventListener("unhandledrejection", (e) =>
    report(String(e.reason), e.reason instanceof Error ? e.reason.stack : undefined),
  );

  void host.send({ type: "ready", version: BRIDGE_VERSION }).catch((err: unknown) => report(String(err)));
}

const parent = document.getElementById("editor");
if (!parent) throw new Error("#editor not found");
boot(parent);
