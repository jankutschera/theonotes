// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { EditorState } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { type CellRef, cellAt, cellRuns, cellText, plainCellText, tableAt } from "../src/editor/features/table-model";

// CodeMirror bounds every parse slice by Date.now(); under machine load the
// slices run out and the state's tree stays partial. Freezing only Date makes
// the parse budgets unlimited here, so these tests check results, not timing.
beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
});
afterEach(() => {
  vi.useRealTimers();
});

function stateOf(doc: string): EditorState {
  const state = EditorState.create({ doc, extensions: markdown({ base: bearMarkdown }) });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state;
}

const texts = (state: EditorState, cells: readonly CellRef[]) => cells.map((c) => cellText(state, c));

describe("table model", () => {
  test("cells, alignment and ragged rows", () => {
    const doc = "Intro\n| l | c | r | n |\n|:--|:-:|--:|---|\n| 1 |\n| 1 | 2 | 3 | 4 | 5 |\n|  | x |\nafter";
    const state = stateOf(doc);
    const model = tableAt(state, doc.indexOf("| 1 |"))!;
    expect(model).not.toBeNull();
    expect(model.from).toBe(doc.indexOf("| l"));
    expect(model.to).toBe(doc.indexOf("\nafter"));
    expect(texts(state, model.header)).toEqual(["l", "c", "r", "n"]);
    expect(model.align).toEqual(["left", "center", "right", null]);
    expect(texts(state, model.delimiter.cells)).toEqual([":--", ":-:", "--:", "---"]);
    expect(model.rows.map((r) => texts(state, r))).toEqual([["1"], ["1", "2", "3", "4", "5"], ["", "x"]]);
    expect(model.lines).toHaveLength(5);
    // A cell runs from after its opening pipe to its closing pipe.
    const first = model.header[0]!;
    expect(doc[first.from - 1]).toBe("|");
    expect(doc[first.to]).toBe("|");
    // An empty cell: the caret spot after its first blank.
    const empty = model.rows[2]![0]!;
    expect(empty.contentFrom).toBe(empty.contentTo);
    expect(empty.contentFrom).toBe(empty.from + 1);
    // Lookups by position: the header is row 0, the delimiter row has no cell.
    expect(cellAt(model, doc.indexOf("c |"))).toEqual({ row: 0, column: 1 });
    expect(cellAt(model, doc.indexOf(":-:"))).toBeNull();
    expect(cellAt(model, doc.indexOf("5 |"))).toEqual({ row: 2, column: 4 });
    expect(cellAt(model, model.lines[2]!.from)).toEqual({ row: 1, column: 0 });
    // Any position on the table's lines finds it; the lines around it do not.
    expect(tableAt(state, model.from)?.from).toBe(model.from);
    expect(tableAt(state, model.to)?.from).toBe(model.from);
    expect(tableAt(state, 0)).toBeNull();
    expect(tableAt(state, doc.length)).toBeNull();
  });

  test("tables in a quote and a list item", () => {
    const quoted = "> | a | b |\n> |---|---|\n> | 1 | 2 |";
    let state = stateOf(quoted);
    let model = tableAt(state, 0)!;
    expect(model.from).toBe(0);
    expect(texts(state, model.header)).toEqual(["a", "b"]);
    expect(model.rows.map((r) => texts(state, r))).toEqual([["1", "2"]]);
    const listed = "- | a |\n  |---|\n  | 1 |";
    state = stateOf(listed);
    model = tableAt(state, listed.length)!;
    expect(texts(state, model.header)).toEqual(["a"]);
    expect(model.rows.map((r) => texts(state, r))).toEqual([["1"]]);
  });

  test("ragged and escaped rows render every cell", () => {
    // Review Focus 3: 11 columns × 41 body rows of masked pipes, <br>, empty cells, CJK, a ZWJ
    // emoji sequence and inline markup.
    const contents = [
      ["a \\| b", "a | b"],
      ["`a|b`", "a|b"],
      ["x<br>y<br/>z", "x\ny\nz"],
      ["", ""],
      ["漢字", "漢字"],
      ["👩‍👩‍👧", "👩‍👩‍👧"],
      ["**bold** and *em*", "bold and em"],
      ["[[Note|alias]]", "alias"],
      ["#tag x", "#tag x"],
      ["[link](https://x.y/a)", "link"],
      ["==hi== `<br>`", "hi <br>"],
    ] as const;
    const columns = contents.length;
    const row = (r: number) =>
      "|" + Array.from({ length: columns }, (_, c) => ` ${contents[(r + c) % columns]![0]} `).join("|") + "|";
    const header = "|" + Array.from({ length: columns }, (_, c) => ` h${c} `).join("|") + "|";
    const delimiter = "|" + Array.from({ length: columns }, () => "---").join("|") + "|";
    const body = Array.from({ length: 41 }, (_, r) => row(r));
    const doc = [header, delimiter, ...body].join("\n");
    const state = stateOf(doc);
    const model = tableAt(state, doc.length)!;
    expect(model.header).toHaveLength(columns);
    expect(model.rows).toHaveLength(41);
    model.rows.forEach((cells, r) => {
      expect(cells).toHaveLength(columns);
      cells.forEach((cell, c) => {
        const [source, plain] = contents[(r + c) % columns]!;
        expect(cellText(state, cell)).toBe(source);
        expect(state.doc.sliceString(cell.contentFrom, cell.contentTo)).toBe(source);
        expect(plainCellText(state, cell)).toBe(plain);
      });
    });
  });

  test("runs carry the typography classes", () => {
    const doc = "| **b** [[N|al]] #t |\n|---|";
    const state = stateOf(doc);
    const cell = tableAt(state, 0)!.header[0]!;
    const runs = cellRuns(state, cell).filter((r) => r.kind === "text");
    expect(runs.map((r) => [r.text, r.classes.join(" ")])).toEqual([
      ["b", "cm-bc-strong"],
      [" ", ""],
      ["al", "cm-bc-wikilink"],
      [" ", ""],
      ["#t", "cm-bc-tag"],
    ]);
    // Positions point into the document (⌘-click finds the link there).
    const alias = runs.find((r) => r.text === "al")!;
    expect(doc.slice(alias.from, alias.from + 2)).toBe("al");
  });
});
