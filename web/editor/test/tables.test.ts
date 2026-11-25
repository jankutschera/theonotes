// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { hideMarkdown } from "../src/editor/features/hiding";
import {
  blockHeightEstimate,
  blockMode,
  blocks,
  collapsedLinesEstimate,
  recordBlockHeight,
  renderedBlocks,
  scanBlocks,
  setRenderedBlocks,
  syncBlocks,
} from "../src/editor/features/blocks";
import { MAX_GRID_ROWS, spacerPlan, spacerWidths, tableRenderer, tables } from "../src/editor/features/tables";

const doc = ["Intro", "| a | b |", "|---|--:|", "| 1 | **2** |", "", "| x |", "|---|", "after"].join("\n");

function create(anchor: number, extra: Extension = []): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(anchor),
    extensions: [markdown({ base: bearMarkdown }), blocks, tables, extra],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

/** What the layer's scanner does after an update. */
function scan(state: EditorState): EditorState {
  const next = syncBlocks(state, [{ from: 0, to: state.doc.length }]);
  return next ? state.update({ effects: setRenderedBlocks.of(next) }).state : state;
}

const widgets = (state: EditorState) => {
  const out: { from: number; rendered: boolean }[] = [];
  const set = state.field(renderedBlocks).decorations;
  for (let it = set.iter(); it.value; it.next()) {
    const widget = it.value.spec.widget as { role?: string } | undefined;
    if (widget?.role) out.push({ from: it.from, rendered: widget.role === "rendered" });
  }
  return out;
};

describe("table renderer", () => {
  test("matches whole tables, from line start to line end", () => {
    const state = create(0);
    const found = scanBlocks(state, [{ from: 0, to: state.doc.length }]);
    expect(found.map((b) => [b.kind, b.key])).toEqual([
      ["table", "| a | b |\n|---|--:|\n| 1 | **2** |"],
      ["table", "| x |\n|---|"],
    ]);
  });

  test("a table over MAX_GRID_ROWS rows always shows its source (M6-R82)", () => {
    const table = (rows: number) => ["| a | b |", "|---|---|", ...Array.from({ length: rows }, (_, i) => `| ${i} | x |`)].join("\n");
    const spec = (key: string) => ({ kind: "table" as const, from: 0, to: key.length, key });
    // MAX_GRID_ROWS counts the header and the body rows, not the delimiter.
    expect(MAX_GRID_ROWS).toBe(1000);
    expect(tableRenderer.sourceOnly!(spec(table(MAX_GRID_ROWS - 1)))).toBe(false);
    expect(tableRenderer.sourceOnly!(spec(table(MAX_GRID_ROWS)))).toBe(true);
    expect(tableRenderer.sourceOnly!(spec(table(6000)))).toBe(true);
    expect(tableRenderer.sourceOnly!(spec(table(2)))).toBe(false);
    const big = table(1200);
    const state = scan(
      EditorState.create({ doc: `intro\n\n${big}`, extensions: [markdown({ base: bearMarkdown }), blocks, tables] }),
    );
    const [block] = state.field(renderedBlocks).blocks;
    expect(block?.kind).toBe("table");
    expect(blockMode(state, block!)).toBe("source");
  });

  test("grid widget eq() by source", () => {
    const state = scan(create(0));
    const [first, second] = state.field(renderedBlocks).blocks;
    const a = tableRenderer.rendered(first!);
    expect(a.eq(tableRenderer.rendered({ ...first!, from: first!.from + 10, to: first!.to + 10 }))).toBe(true);
    expect(a.eq(tableRenderer.rendered(second!))).toBe(false);
    expect(a.eq(tableRenderer.rendered({ ...first!, key: first!.key.replace("1", "3") }))).toBe(false);
    // Typing before the tables keeps both widgets (same source, mapped positions).
    const before = widgets(state);
    const typed = scan(state.update({ changes: { from: 0, insert: "More " } }).state);
    const decos = typed.field(renderedBlocks).decorations;
    const kept: unknown[] = [];
    for (let it = decos.iter(); it.value; it.next()) kept.push(it.value.spec.widget);
    const old: unknown[] = [];
    for (let it = state.field(renderedBlocks).decorations.iter(); it.value; it.next()) old.push(it.value.spec.widget);
    expect(kept.filter((w) => w && old.includes(w))).toHaveLength(before.length);
  });

  test("entry points: the first cell of the header from above, of the last row from below", () => {
    const state = scan(create(0));
    const [first] = state.field(renderedBlocks).blocks;
    expect(tableRenderer.entry(state, first!, "above")).toBe(doc.indexOf("a |"));
    expect(tableRenderer.entry(state, first!, "below")).toBe(doc.indexOf("1 |"));
  });

  test("spacer plan is \"map\" while composing", () => {
    expect(spacerPlan({ composing: true, changed: true })).toBe("map");
    expect(spacerPlan({ composing: true, changed: false })).toBe("map");
    expect(spacerPlan({ composing: false, changed: true })).toBe("measure");
    expect(spacerPlan({ composing: false, changed: false })).toBe("keep");
  });

  test("spacer widths line up every closing pipe", () => {
    // Rows: start x, content widths, the pipe gap after each cell.
    const rows = [
      { start: 0, widths: [10, 30], gaps: [5, 0] },
      { start: 2, widths: [20, 10, 4], gaps: [5, 5, 0] },
      null,
    ];
    const widths = spacerWidths(rows);
    expect(widths[2]).toBeNull();
    // Column 0 ends at 22 (row 1); column 1 at 22 + 5 + 30 = 57.
    expect(widths[0]).toEqual([12, 0]);
    expect(widths[1]).toEqual([0, 20, 0]);
  });

  test("Hide Markdown off: source mode", () => {
    const state = scan(create(0, hideMarkdown.of(false)));
    const list = state.field(renderedBlocks).blocks;
    expect(list).toHaveLength(2);
    expect(list.every((b) => blockMode(state, b) === "source")).toBe(true);
    expect(widgets(state).filter((w) => w.rendered)).toEqual([]);
    // With it on, both render; the caret on a table's line shows that one's source.
    const on = scan(create(doc.indexOf("| 1")));
    expect(widgets(on)).toEqual([{ from: doc.indexOf("| x"), rendered: true }]);
  });

  test("height estimate: the measured height first, less CodeMirror's estimate of the collapsed lines", () => {
    const metrics = { width: 700, lineHeight: 20, charWidth: 10 };
    const key = "| a |\n|---|\n| 1 |";
    recordBlockHeight("table", "unused", 0, metrics);
    // Three short lines: one line height each.
    expect(collapsedLinesEstimate(key)).toBe(60);
    // A 154-character row at 70 characters per line: CodeMirror guesses 3 wrapped lines.
    expect(collapsedLinesEstimate(`| ${"x".repeat(150)} |\n|---|`)).toBe(80);
    // Not measured yet: the renderer's guess.
    expect(blockHeightEstimate("table", key, 100)).toBe(40);
    recordBlockHeight("table", key, 300, metrics);
    expect(blockHeightEstimate("table", key, 100)).toBe(240);
    expect(blockHeightEstimate("mathBlock", key, 100)).toBe(40);
    // At another content width the measured height does not apply.
    recordBlockHeight("table", "unused", 0, { ...metrics, width: 500 });
    expect(blockHeightEstimate("table", key, 100)).toBe(40);
    // The line height follows the editor's (font size setting); a height measured at another
    // line height does not apply either.
    recordBlockHeight("table", "unused", 0, { ...metrics, lineHeight: 32 });
    expect(collapsedLinesEstimate(key)).toBe(96);
    recordBlockHeight("table", "unused", 0, metrics);
    expect(blockHeightEstimate("table", key, 100)).toBe(240);
    recordBlockHeight("table", "unused", 0, { ...metrics, lineHeight: 24 });
    expect(blockHeightEstimate("table", key, 100)).toBe(28);
  });
});
