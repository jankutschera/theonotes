// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Development only (vite dev, e2e `?mock&testBlocks`): a renderer for `$$` math blocks that draws
// a labelled box, so the block widget layer can be tested before the real renderers exist.
// main.ts imports it only in dev builds; production bundles do not contain it.

import type { EditorState } from "@codemirror/state";
import { WidgetType } from "@codemirror/view";
import type { SyntaxNodeRef } from "@lezer/common";
import type { BlockRenderer, BlockSpec } from "./blocks";

export function matchMathBlock(state: EditorState, node: SyntaxNodeRef): BlockSpec | null {
  if (node.name !== "MathBlock") return null;
  const from = state.doc.lineAt(node.from).from;
  const to = state.doc.lineAt(node.to).to;
  return { kind: "mathBlock", from, to, key: state.doc.sliceString(from, to) };
}

class TestBlockWidget extends WidgetType {
  constructor(readonly source: string) {
    super();
  }

  override eq(other: TestBlockWidget): boolean {
    return other.source === this.source;
  }

  toDOM(): HTMLElement {
    const el = document.createElement("div");
    el.className = "test-block";
    // Text on purpose: it must not show up in `.cm-content`'s innerText.
    el.textContent = `Rendered block (${this.source.split("\n").length} lines)`;
    return el;
  }
}

export const testBlockRenderer: BlockRenderer = {
  kind: "mathBlock",
  match: matchMathBlock,
  rendered: (block) => new TestBlockWidget(block.key),
  entry: (_state, block, from) => (from === "above" ? block.from : block.to),
  // ⌘-click stands in for a renderer acting on a click itself (a link in a table cell).
  click: (_view, _block, event) => (event.metaKey ? "handled" : null),
  label: () => "Test block",
  styles: ".test-block { padding: 8px; background: var(--bc-color-code-bg); color: var(--bc-color-text); }",
};
