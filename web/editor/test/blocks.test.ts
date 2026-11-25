// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { Compartment, EditorSelection, EditorState, type Extension, type Transaction, type TransactionSpec } from "@codemirror/state";
import { Decoration, WidgetType } from "@codemirror/view";
import { codeFolding, ensureSyntaxTree, foldEffect } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { hideMarkdown } from "../src/editor/features/hiding";
import {
  type BlockRenderer,
  type BlockSpec,
  blockMode,
  blockRenderers,
  blocks,
  blockUpdatePlan,
  COLLAPSED_LINE_CLASS,
  enteredBlock,
  renderedBlocks,
  scanBlocks,
  setRenderedBlocks,
  syncBlocks,
} from "../src/editor/features/blocks";
import { matchMathBlock } from "../src/editor/features/blocks-test-renderer";
import { currentMatch, searchHighlight, searchHighlightTransaction } from "../src/editor/features/search-highlight";
import { editorCommands } from "../src/editor/features/commands";

class TestWidget extends WidgetType {
  constructor(readonly source: string) {
    super();
  }
  override eq(other: TestWidget) {
    return other.source === this.source;
  }
  toDOM() {
    const el = document.createElement("div");
    el.className = "test-block";
    return el;
  }
}

/** The test renderer: `MathBlock` nodes, a `<div class="test-block">` widget; counts `rendered()`. */
function testRenderer(): BlockRenderer & { calls: number } {
  const renderer = {
    calls: 0,
    kind: "mathBlock" as const,
    match: matchMathBlock,
    rendered(block: BlockSpec) {
      renderer.calls++;
      return new TestWidget(block.key);
    },
    entry: (_state: EditorState, block: BlockSpec, from: "above" | "below") => (from === "above" ? block.from : block.to),
  };
  return renderer;
}

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function create(doc: string, renderer: BlockRenderer, anchor = 0, extra: Extension = []): EditorState {
  return parsed(
    EditorState.create({
      doc,
      selection: EditorSelection.cursor(anchor),
      extensions: [markdown({ base: bearMarkdown }), blocks, blockRenderers.of(renderer), extra],
    }),
  );
}

const all = (state: EditorState) => [{ from: 0, to: state.doc.length }];

/** What the scanner does after an update: dispatch the scanned list when it differs. */
function scan(state: EditorState): { state: EditorState; dispatched: boolean } {
  const next = syncBlocks(state, all(state));
  if (!next) return { state, dispatched: false };
  return { state: state.update({ effects: setRenderedBlocks.of(next) }).state, dispatched: true };
}

function apply(state: EditorState, spec: TransactionSpec): EditorState {
  const tr: Transaction = state.update(spec);
  return parsed(tr.state);
}

type Deco = { from: number; to: number; kind: "widget" | "collapsed" | "hidden" | "other" };
function decos(state: EditorState): Deco[] {
  const out: Deco[] = [];
  for (let it = state.field(renderedBlocks).decorations.iter(); it.value; it.next()) {
    const spec = it.value.spec;
    const kind = spec.widget ? "widget" : spec.class === COLLAPSED_LINE_CLASS ? "collapsed" : spec.class === "cm-bc-hidden" ? "hidden" : "other";
    out.push({ from: it.from, to: it.to, kind });
  }
  return out;
}

const doc = ["before", "$$", "x^2", "$$", "after"].join("\n");
const blockFrom = doc.indexOf("$$");
const blockTo = doc.lastIndexOf("$$") + 2;

describe("block widget layer", () => {
  test("rendered when the caret is elsewhere, source when it touches the lines", () => {
    const renderer = testRenderer();
    let state = scan(create(doc, renderer, 0)).state;
    const [block] = state.field(renderedBlocks).blocks;
    expect(block).toEqual({ kind: "mathBlock", from: blockFrom, to: blockTo, key: "$$\nx^2\n$$" });
    expect(blockMode(state, block!)).toBe("rendered");
    expect(renderer.calls).toBe(1);
    // A block widget at `from`, each source line collapsed with its text hidden.
    expect(decos(state)).toEqual([
      { from: blockFrom, to: blockFrom, kind: "widget" },
      { from: blockFrom, to: blockFrom, kind: "collapsed" },
      { from: blockFrom, to: blockFrom + 2, kind: "hidden" },
      { from: blockFrom + 3, to: blockFrom + 3, kind: "collapsed" },
      { from: blockFrom + 3, to: blockFrom + 6, kind: "hidden" },
      { from: blockFrom + 7, to: blockFrom + 7, kind: "collapsed" },
      { from: blockFrom + 7, to: blockTo, kind: "hidden" },
    ]);
    const widget = state.field(renderedBlocks).decorations.iter().value!.spec;
    expect(widget.block).toBe(true);
    expect(widget.side).toBe(-1);

    // The end of the line above and the start of the line below do not touch the block.
    state = apply(state, { selection: EditorSelection.cursor(blockFrom - 1) });
    expect(blockMode(state, block!)).toBe("rendered");
    state = apply(state, { selection: EditorSelection.cursor(blockTo + 1) });
    expect(blockMode(state, block!)).toBe("rendered");

    // The field flips the mode itself (no scan needed): no widget, nothing collapsed.
    for (const pos of [blockFrom, blockFrom + 4, blockTo]) {
      const inside = apply(state, { selection: EditorSelection.cursor(pos) });
      expect(blockMode(inside, block!)).toBe("source");
      expect(decos(inside)).toEqual([]);
      expect(syncBlocks(inside, all(inside))).toBeNull();
    }
    // A range selection reaching into the block from above.
    const across = apply(state, { selection: EditorSelection.range(0, blockFrom) });
    expect(blockMode(across, block!)).toBe("source");
    // Back out: rendered again (its mode changed, so one new widget).
    const back = apply(apply(state, { selection: EditorSelection.cursor(blockFrom + 4) }), { selection: EditorSelection.cursor(0) });
    expect(decos(back)[0]!.kind).toBe("widget");
    expect(renderer.calls).toBe(2);
    // Rendering never changes the text.
    expect(back.doc.toString()).toBe(doc);
  });

  test("the current search match shows a rendered block's source; stepping away renders it again (M6-R78)", () => {
    const renderer = testRenderer();
    const text = ["before x", "$$", "x^2", "$$", "after x"].join("\n");
    let state = scan(create(text, renderer, 0, searchHighlight)).state;
    const [block] = state.field(renderedBlocks).blocks;
    expect(blockMode(state, block!)).toBe("rendered");
    // The note-list highlight marks "before x" current: the block stays rendered.
    state = apply(state, searchHighlightTransaction(state, ["x"]));
    expect(currentMatch(state)).toEqual({ from: 7, to: 8 });
    expect(blockMode(state, block!)).toBe("rendered");
    // ⌘G to the match inside the block: its source shows, the selection stays.
    const step = (s: EditorState) => {
      let next = s;
      editorCommands.findNext({ state: s, dispatch: (tr: Transaction) => (next = tr.state) });
      return parsed(next);
    };
    state = step(state);
    expect(currentMatch(state)!.from).toBe(text.indexOf("x^2"));
    expect(state.selection.main.head).toBe(0);
    expect(blockMode(state, block!)).toBe("source");
    expect(decos(state)).toEqual([]);
    expect(syncBlocks(state, all(state))).toBeNull();
    // On to the match after it: rendered again.
    state = step(state);
    expect(currentMatch(state)!.from).toBe(text.lastIndexOf("x"));
    expect(blockMode(state, block!)).toBe("rendered");
    expect(decos(state)[0]!.kind).toBe("widget");
    // Clearing the highlight while the match is in the block renders it too.
    state = step(step(state));
    expect(blockMode(state, block!)).toBe("source");
    state = apply(state, searchHighlightTransaction(state, []));
    expect(blockMode(state, block!)).toBe("rendered");
  });

  test("Hide Markdown off keeps every block in source mode", () => {
    const renderer = testRenderer();
    const state = scan(create(doc, renderer, 0, hideMarkdown.of(false))).state;
    const [block] = state.field(renderedBlocks).blocks;
    expect(blockMode(state, block!)).toBe("source");
    expect(decos(state)).toEqual([]);
    expect(renderer.calls).toBe(0);
  });

  test("blockUpdatePlan maps while composing", () => {
    expect(blockUpdatePlan({ composing: true, changed: true })).toBe("map");
    expect(blockUpdatePlan({ composing: true, changed: false })).toBe("map");
    expect(blockUpdatePlan({ composing: false, changed: true })).toBe("rescan");
    expect(blockUpdatePlan({ composing: false, changed: false })).toBe("keep");
  });

  test("only blocks whose source or mode changed get new widgets", () => {
    const renderer = testRenderer();
    const parts: string[] = [];
    for (let i = 0; i < 50; i++) parts.push(`prose ${i}`, "$$", `x_{${i}}`, "$$");
    const big = parts.join("\n");
    let state = scan(create(big, renderer, 0)).state;
    expect(state.field(renderedBlocks).blocks).toHaveLength(50);
    expect(renderer.calls).toBe(50);

    // A keystroke between blocks only maps the field: the scan finds the same list.
    renderer.calls = 0;
    const between = big.indexOf("prose 20") + 5;
    state = apply(state, { changes: { from: between, insert: "a" }, selection: EditorSelection.cursor(between + 1), userEvent: "input.type" });
    let step = scan(state);
    expect(step.dispatched).toBe(false);
    expect(renderer.calls).toBe(0);
    // Even a forced re-dispatch of the same list reuses every widget.
    state = state.update({ effects: setRenderedBlocks.of(scanBlocks(state, all(state))) }).state;
    expect(renderer.calls).toBe(0);
    expect(state.field(renderedBlocks).blocks[20]!.from).toBe(state.doc.toString().indexOf("$$", between));

    // An external change inside one rendered block's source (the caret stays elsewhere).
    const target = state.doc.toString().indexOf("x_{30}") + 3;
    state = apply(state, { changes: { from: target, insert: "9" } });
    expect(renderer.calls).toBe(0);
    step = scan(state);
    expect(step.dispatched).toBe(true);
    expect(renderer.calls).toBe(1);
    state = step.state;
    expect(state.field(renderedBlocks).blocks[30]!.key).toBe("$$\nx_{930}\n$$");
    expect(scan(state).dispatched).toBe(false);

    // Moving the caret into one block renders nothing (source mode); leaving it renders that
    // block only (its mode changed), never the other 49.
    const inBlock = state.field(renderedBlocks).blocks[5]!.from + 3;
    state = apply(state, { selection: EditorSelection.cursor(inBlock) });
    expect(renderer.calls).toBe(1);
    state = apply(state, { selection: EditorSelection.cursor(0) });
    expect(renderer.calls).toBe(2);
  });

  test("a deleted block is dropped", () => {
    const renderer = testRenderer();
    let state = scan(create(doc, renderer, 0)).state;
    state = apply(state, { changes: { from: blockFrom - 1, to: blockTo } });
    expect(state.field(renderedBlocks).blocks).toEqual([]);
    expect(state.field(renderedBlocks).decorations).toEqual(Decoration.none);
  });

  test("toggling Hide Markdown at runtime flips every block", () => {
    const renderer = testRenderer();
    const hide = new Compartment();
    let state = scan(create(doc, renderer, 0, hide.of(hideMarkdown.of(true)))).state;
    expect(decos(state)[0]!.kind).toBe("widget");
    state = apply(state, { effects: hide.reconfigure(hideMarkdown.of(false)) });
    expect(decos(state)).toEqual([]);
    expect(syncBlocks(state, all(state))).toBeNull();
    state = apply(state, { effects: hide.reconfigure(hideMarkdown.of(true)) });
    expect(decos(state)[0]!.kind).toBe("widget");
    expect(renderer.calls).toBe(2);
  });

  test("arrow entry needs the block on the adjacent line and never enters a fold", () => {
    const renderer = testRenderer();
    // Line 1 "before" is adjacent to the block (line 2); a move from line 1 onto it enters it.
    let state = scan(create(doc, renderer, 0, codeFolding())).state;
    expect(enteredBlock(state, 3, blockFrom, true)).toMatchObject({ from: blockFrom });
    expect(enteredBlock(state, 3, 2, true)).toBeNull(); // the move stays on line 1 (wrapped line)
    // From the line below, upwards.
    expect(enteredBlock(state, blockTo + 2, blockTo, false)).toMatchObject({ from: blockFrom });
    expect(enteredBlock(state, blockTo + 2, blockTo + 1, false)).toBeNull();

    // A blank line in between: a move that jumps over hidden lines does not land in the block.
    const spaced = scan(create(`before\n\n${doc.slice(blockFrom)}`, renderer, 0, codeFolding())).state;
    const spacedFrom = "before\n\n".length;
    expect(enteredBlock(spaced, 3, spacedFrom, true)).toBeNull();

    // A folded block (the fold hides line 1's end through the block): the move skips the fold.
    state = apply(state, { effects: foldEffect.of({ from: blockFrom - 1, to: blockTo }) });
    expect(enteredBlock(state, 3, blockTo + 3, true)).toBeNull();
    expect(enteredBlock(state, blockTo + 3, 3, false)).toBeNull();
  });

  test("a partial scan matches whole blocks", () => {
    const renderer = testRenderer();
    const state = create(doc, renderer, 0);
    // A range that only reaches into the block's middle line still yields the whole block.
    expect(scanBlocks(state, [{ from: blockFrom + 4, to: blockFrom + 5 }])).toEqual([
      { kind: "mathBlock", from: blockFrom, to: blockTo, key: "$$\nx^2\n$$" },
    ]);
  });

  test("only the scanned ranges are matched", () => {
    const renderer = testRenderer();
    const state = create(`${doc}\n${doc}`, renderer, 0);
    expect(scanBlocks(state, [{ from: 0, to: 5 }])).toEqual([]);
    expect(scanBlocks(state, [{ from: 0, to: blockFrom + 1 }])).toHaveLength(1);
    expect(scanBlocks(state, all(state))).toHaveLength(2);
    // Without renderers the layer does nothing.
    const bare = parsed(EditorState.create({ doc, extensions: [markdown({ base: bearMarkdown }), blocks] }));
    expect(scanBlocks(bare, all(bare))).toEqual([]);
    expect(syncBlocks(bare, all(bare))).toBeNull();
  });
});
