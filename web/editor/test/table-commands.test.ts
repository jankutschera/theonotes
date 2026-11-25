// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, Transaction, type TransactionSpec } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undo } from "@codemirror/commands";
import type { EditorView } from "@codemirror/view";
import { bearMarkdown } from "../src/editor/dialect";
import type { CommandArgs, CommandName } from "../src/bridge/protocol";
import { runCommand } from "../src/editor/features/commands";
import { menuTargetEffect, menuTargets } from "../src/editor/features/menu-targets";
import { cellAt, cellText, tableAt } from "../src/editor/features/table-model";
import { nextCell, tableEnter, tableTab } from "../src/editor/features/table-commands";

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

/** `‸` marks the caret, `«`…`»` a selection. */
function make(marked: string, extra: Extension[] = []): EditorState {
  let doc = "";
  let anchor = -1;
  let head = -1;
  for (const ch of marked) {
    if (ch === "‸") anchor = head = doc.length;
    else if (ch === "«") anchor = doc.length;
    else if (ch === "»") head = doc.length;
    else doc += ch;
  }
  if (anchor < 0) anchor = head = doc.length;
  return parsed(
    EditorState.create({
      doc,
      selection: EditorSelection.single(anchor, head),
      extensions: [markdown({ base: bearMarkdown }), history(), menuTargets, ...extra],
    }),
  );
}

/** Runs `fn` against a fake view and returns the resulting state (and what `fn` returned). */
function drive<T>(state: EditorState, fn: (view: EditorView) => T, composing = false): { state: EditorState; result: T } {
  let current = state;
  const view = {
    get state() {
      return current;
    },
    composing,
    dispatch(arg: Transaction | TransactionSpec) {
      current = arg instanceof Transaction ? arg.state : parsed(current.update(arg).state);
    },
  } as unknown as EditorView;
  const result = fn(view);
  return { state: current.update({}).state, result };
}

function command(state: EditorState, name: CommandName, args?: CommandArgs): { state: EditorState; ran: boolean } {
  const { state: next, result } = drive(state, (view) =>
    runCommand({ state: view.state, dispatch: (tr) => view.dispatch(tr) }, name, args),
  );
  return { state: parsed(next), ran: result };
}

const text = (state: EditorState) => state.doc.toString();
const head = (state: EditorState) => state.selection.main.head;
const at = (state: EditorState) => {
  const model = tableAt(state, head(state))!;
  return cellAt(model, head(state));
};

// Irregular spacing: every cell outside the touched row or column must come out byte-identical.
const IRREGULAR = ["|a|  b  |c|", "|:-|--:|---|", "| 1 |‸2|  3  |", "|x|y   |z|"].join("\n");

describe("row commands", () => {
  test("add a row below and above the caret row; other lines stay byte-identical", () => {
    const below = command(make(IRREGULAR), "tableAddRow");
    expect(text(below.state)).toBe(["|a|  b  |c|", "|:-|--:|---|", "| 1 |2|  3  |", "|  |  |  |", "|x|y   |z|"].join("\n"));
    expect(cellText(below.state, tableAt(below.state, 0)!.rows[0]![1]!)).toBe("2");
    const above = command(make(IRREGULAR), "tableAddRow", { position: "before" });
    expect(text(above.state)).toBe(["|a|  b  |c|", "|:-|--:|---|", "|  |  |  |", "| 1 |2|  3  |", "|x|y   |z|"].join("\n"));
    // The caret stays on its own cell.
    expect(cellText(above.state, tableAt(above.state, 0)!.rows[1]![1]!)).toBe("2");
    expect(above.state.doc.sliceString(head(above.state), head(above.state) + 1)).toBe("2");
  });

  test("add a row below the header goes after the delimiter row; above the header is refused", () => {
    const header = command(make("|a‸|b|\n|---|---|\n|1|2|"), "tableAddRow");
    expect(text(header.state)).toBe("|a|b|\n|---|---|\n|  |  |\n|1|2|");
    expect(command(make("|a‸|b|\n|---|---|\n|1|2|"), "tableAddRow", { position: "before" }).ran).toBe(false);
  });

  test("a table in a quote gets quoted rows", () => {
    const r = command(make("> |a‸|\n> |---|\n> |1|"), "tableAddRow");
    expect(text(r.state)).toBe("> |a|\n> |---|\n> |  |\n> |1|");
  });

  test("delete a row removes its line only", () => {
    const r = command(make(IRREGULAR), "tableDeleteRow");
    expect(text(r.state)).toBe(["|a|  b  |c|", "|:-|--:|---|", "|x|y   |z|"].join("\n"));
    // The caret moved to the same column of the row that took its place.
    expect(cellText(r.state, tableAt(r.state, 0)!.rows[0]![1]!)).toBe("y");
    expect(at(r.state)).toEqual({ row: 1, column: 1 });
  });

  test("delete header promotes the first body row; the delimiter stays", () => {
    const r = command(make("| h1‸ | h2 |\n|---|:-:|\n| a | b |\n| c | d |"), "tableDeleteRow");
    expect(text(r.state)).toBe("| a | b |\n|---|:-:|\n| c | d |");
    expect(at(r.state)).toEqual({ row: 0, column: 0 });
  });

  test("promoting a short row pads it; promoting a long row widens the delimiter", () => {
    const short = command(make("| h1‸ | h2 |\n|---|---|\n| a |\n| c | d |"), "tableDeleteRow");
    expect(text(short.state)).toBe("| a |  |\n|---|---|\n| c | d |");
    const long = command(make("| h1‸ |\n|---|\n| a | b | c |"), "tableDeleteRow");
    expect(text(long.state)).toBe("| a | b | c |\n|---|---|---|");
  });

  test("delete the last row deletes the table", () => {
    const r = command(make("Intro\n\n| a‸ |\n|---|\n\nafter"), "tableDeleteRow");
    expect(text(r.state)).toBe("Intro\n\nafter");
    expect(tableAt(r.state, 0)).toBeNull();
    const end = command(make("Intro\n| a‸ |\n|---|"), "tableDeleteRow");
    expect(text(end.state)).toBe("Intro");
  });

  test("the delimiter row cannot be deleted or moved", () => {
    expect(command(make("|a|\n|--‸-|\n|1|\n|2|"), "tableDeleteRow").ran).toBe(false);
    expect(command(make("|a|\n|--‸-|\n|1|\n|2|"), "tableMoveRow", { direction: "down" }).ran).toBe(false);
  });

  test("move a row up and down; the caret follows it; the header never moves", () => {
    const down = command(make(IRREGULAR), "tableMoveRow", { direction: "down" });
    expect(text(down.state)).toBe(["|a|  b  |c|", "|:-|--:|---|", "|x|y   |z|", "| 1 |2|  3  |"].join("\n"));
    expect(at(down.state)).toEqual({ row: 2, column: 1 });
    expect(down.state.doc.sliceString(head(down.state), head(down.state) + 1)).toBe("2");
    const up = command(make(["|a|b|", "|---|---|", "|x|y|", "|1|‸2|"].join("\n")), "tableMoveRow", { direction: "up" });
    expect(text(up.state)).toBe(["|a|b|", "|---|---|", "|1|2|", "|x|y|"].join("\n"));
    expect(at(up.state)).toEqual({ row: 1, column: 1 });
    expect(command(make(IRREGULAR), "tableMoveRow", { direction: "up" }).ran).toBe(false);
    expect(command(make("|a‸|\n|---|\n|1|"), "tableMoveRow", { direction: "down" }).ran).toBe(false);
    expect(command(make(IRREGULAR), "tableMoveRow", { direction: "sideways" }).ran).toBe(false);
  });
});

describe("column commands", () => {
  test("add a column right and left of the caret column; other cells stay byte-identical", () => {
    const right = command(make(IRREGULAR), "tableAddColumn");
    expect(text(right.state)).toBe(["|a|  b  |  |c|", "|:-|--:|---|---|", "| 1 |2|  |  3  |", "|x|y   |  |z|"].join("\n"));
    const left = command(make(IRREGULAR), "tableAddColumn", { position: "before" });
    expect(text(left.state)).toBe(["|a|  |  b  |c|", "|:-|---|--:|---|", "| 1 |  |2|  3  |", "|x|  |y   |z|"].join("\n"));
    expect(left.state.doc.sliceString(head(left.state), head(left.state) + 1)).toBe("2");
  });

  test("add a column at the end appends after the closing pipe; a short row is left alone", () => {
    const r = command(make("|a|b‸|\n|---|---|\n|1|\n|x|y|"), "tableAddColumn");
    expect(text(r.state)).toBe("|a|b|  |\n|---|---|---|\n|1|\n|x|y|  |");
  });

  test("a ragged body row's extra column extends the header and the delimiter too", () => {
    const after = command(make("|h1|h2|\n|---|---|\n|a|b|c‸|"), "tableAddColumn");
    expect(text(after.state)).toBe("|h1|h2|  |  |\n|---|---|---|---|\n|a|b|c|  |");
    const before = command(make("|h1|h2|\n|---|---|\n|a|b|‸c|"), "tableAddColumn", { position: "before" });
    expect(text(before.state)).toBe("|h1|h2|  |\n|---|---|---|\n|a|b|  |c|");
    // A shorter body row stays as it is.
    const short = command(make("|h1|h2|\n|---|---|\n|a|b|c‸|\n|x|"), "tableAddColumn");
    expect(text(short.state)).toBe("|h1|h2|  |  |\n|---|---|---|---|\n|a|b|c|  |\n|x|");
    expect(tableAt(short.state, 0)!.header).toHaveLength(tableAt(short.state, 0)!.delimiter.cells.length);
  });

  test("delete a column", () => {
    const r = command(make(IRREGULAR), "tableDeleteColumn");
    expect(text(r.state)).toBe(["|a|c|", "|:-|---|", "| 1 |  3  |", "|x|z|"].join("\n"));
    expect(at(r.state)).toEqual({ row: 1, column: 1 });
    const last = command(make("|a|b‸|\n|---|---|\n|1|2|"), "tableDeleteColumn");
    expect(text(last.state)).toBe("|a|\n|---|\n|1|");
    expect(at(last.state)).toEqual({ row: 0, column: 0 });
  });

  test("deleting the only column deletes the table", () => {
    const r = command(make("a\n\n|x‸|\n|---|\n|1|\n\nb"), "tableDeleteColumn");
    expect(text(r.state)).toBe("a\n\nb");
  });

  test("move keeps the alignment of a moved column", () => {
    const right = command(make(IRREGULAR), "tableMoveColumn", { direction: "right" });
    expect(text(right.state)).toBe(["|a|c|  b  |", "|:-|---|--:|", "| 1 |  3  |2|", "|x|z|y   |"].join("\n"));
    expect(tableAt(right.state, 0)!.align).toEqual(["left", null, "right"]);
    expect(at(right.state)).toEqual({ row: 1, column: 2 });
    expect(right.state.doc.sliceString(head(right.state), head(right.state) + 1)).toBe("2");
    const left = command(make(IRREGULAR), "tableMoveColumn", { direction: "left" });
    expect(text(left.state)).toBe(["|  b  |a|c|", "|--:|:-|---|", "|2| 1 |  3  |", "|y   |x|z|"].join("\n"));
    expect(tableAt(left.state, 0)!.align).toEqual(["right", "left", null]);
  });

  test("move at the table's edge does nothing; a short row is padded", () => {
    expect(command(make("|a‸|b|\n|---|---|\n|1|2|"), "tableMoveColumn", { direction: "left" }).ran).toBe(false);
    expect(command(make("|a|b‸|\n|---|---|\n|1|2|"), "tableMoveColumn", { direction: "right" }).ran).toBe(false);
    const r = command(make("|a‸|b|\n|---|---|\n| 1 |\n|x|y|"), "tableMoveColumn", { direction: "right" });
    expect(text(r.state)).toBe("|b|a|\n|---|---|\n|  | 1 |\n|y|x|");
  });

  test("escaped pipes and pipes in code do not count as cell borders", () => {
    const r = command(make("|a ‸\\| b|`x|y`|\n|---|---|\n|1|2|"), "tableAddColumn");
    expect(text(r.state)).toBe("|a \\| b|  |`x|y`|\n|---|---|---|\n|1|  |2|");
  });
});

describe("every command", () => {
  const calls: [CommandName, CommandArgs?][] = [
    ["tableAddRow"],
    ["tableAddRow", { position: "before" }],
    ["tableAddColumn"],
    ["tableAddColumn", { position: "before" }],
    ["tableDeleteRow"],
    ["tableDeleteColumn"],
    ["tableMoveRow", { direction: "down" }],
    ["tableMoveColumn", { direction: "right" }],
    ["createTable"],
  ];
  const doc = "|a|b|\n|---|---|\n|1‸|2|\n|3|4|";

  test("is one undo step", () => {
    for (const [name, args] of calls) {
      const state = name === "createTable" ? make("para‸") : make(doc);
      const r = command(state, name, args);
      expect(r.ran, name).toBe(true);
      expect(text(r.state), name).not.toBe(text(state));
      let undone: EditorState | null = null;
      undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
      expect((undone as EditorState | null)?.doc.toString(), name).toBe(text(state));
    }
  });

  test("refuses in read-only notes", () => {
    for (const [name, args] of calls) {
      const state = make(name === "createTable" ? "para‸" : doc, [EditorState.readOnly.of(true)]);
      const r = command(state, name, args);
      expect(r.ran, name).toBe(false);
      expect(text(r.state), name).toBe(text(state));
    }
  });

  test("does nothing while composing", () => {
    for (const [name, args] of calls) {
      let dispatched = 0;
      const state = make(doc);
      expect(runCommand({ state, dispatch: () => dispatched++, composing: true }, name, args), name).toBe(false);
      expect(dispatched, name).toBe(0);
    }
  });

  test("does nothing outside a table (createTable excepted)", () => {
    for (const [name, args] of calls.filter(([n]) => n !== "createTable")) {
      expect(command(make("plain ‸text"), name, args).ran, name).toBe(false);
    }
  });

  test("refuses inside code", () => {
    for (const [name, args] of calls) {
      const r = command(make("```\n|a|\n|---|\n‸x\n```"), name, args);
      expect(r.ran, name).toBe(false);
    }
    expect(command(make("```\nco‸de\n```"), "createTable").ran).toBe(false);
    expect(command(make("some `co‸de` here"), "createTable").ran).toBe(false);
    // The edges of an inline code span, inline math or a comment count as inside.
    for (const marked of [
      "some ‸`code` here", "some `code`‸ here", "some ‸$x+1$ here", "some $x+1$‸ here", "some ‸<!-- c --> here", "some <!-- c -->‸ here",
    ]) {
      const r = command(make(marked), "createTable");
      expect(r.ran, marked).toBe(false);
      expect(text(r.state), marked).toBe(text(make(marked)));
    }
    // A space away from the span is outside it.
    expect(command(make("some‸ `code` here"), "createTable").ran).toBe(true);
  });
});

describe("menu targets", () => {
  const doc = "intro\n\n|a|b|\n|---|---|\n|1|2|\n|3|4|";

  function withTarget(caret: number, pos: number): { state: EditorState; id: string } {
    const state = make(doc).update({ selection: EditorSelection.cursor(caret) }).state;
    return { id: "m1", state: state.update({ effects: menuTargetEffect.of({ id: "m1", pos }) }).state };
  }

  test("a command with a menuId acts on that cell and leaves the caret alone", () => {
    const row2 = doc.indexOf("|3|4|") + 3;
    const { state, id } = withTarget(0, row2);
    const r = command(state, "tableAddRow", { menuId: id });
    expect(text(r.state)).toBe("intro\n\n|a|b|\n|---|---|\n|1|2|\n|3|4|\n|  |  |");
    expect(head(r.state)).toBe(0);
    const del = command(state, "tableDeleteColumn", { menuId: id });
    expect(text(del.state)).toBe("intro\n\n|a|\n|---|\n|1|\n|3|");
    const move = command(state, "tableMoveRow", { menuId: id, direction: "up" });
    expect(text(move.state)).toBe("intro\n\n|a|b|\n|---|---|\n|3|4|\n|1|2|");
  });

  test("a padding cell's menu acts on the clicked column, not the row's last cell (final review I2)", () => {
    const ragged = "| h1 | h2 | h3 | h4 |\n|---|---|---|---|\n| a | b | c | d |\n| short1 | short2 |";
    const base = make(ragged, []).update({ selection: EditorSelection.cursor(0) }).state;
    // The grid's ⋯ on row 2, column 3 (index 2) targets the row's last real cell, with the column.
    const pos = ragged.indexOf("short2");
    const state = base.update({ effects: menuTargetEffect.of({ id: "m1", pos, column: 2 }) }).state;
    const del = command(state, "tableDeleteColumn", { menuId: "m1" });
    expect(del.ran).toBe(true);
    expect(text(del.state)).toBe("| h1 | h2 | h4 |\n|---|---|---|\n| a | b | d |\n| short1 | short2 |");
    const right = command(state, "tableMoveColumn", { menuId: "m1", direction: "right" });
    expect(text(right.state)).toBe("| h1 | h2 | h4 | h3 |\n|---|---|---|---|\n| a | b | d | c |\n| short1 | short2 |");
    const add = command(state, "tableAddColumn", { menuId: "m1" });
    expect(text(add.state)).toBe("| h1 | h2 | h3 |  | h4 |\n|---|---|---|---|---|\n| a | b | c |  | d |\n| short1 | short2 |");
    // Row commands still act on the clicked row.
    expect(text(command(state, "tableDeleteRow", { menuId: "m1" }).state)).toBe("| h1 | h2 | h3 | h4 |\n|---|---|---|---|\n| a | b | c | d |");
    // A target on a real cell keeps that cell's column whatever the remembered one says.
    const real = base.update({ effects: menuTargetEffect.of({ id: "m2", pos: ragged.indexOf("short1"), column: 3 }) }).state;
    expect(text(command(real, "tableDeleteColumn", { menuId: "m2" }).state)).toBe(
      "| h2 | h3 | h4 |\n|---|---|---|\n| b | c | d |\n| short2 |",
    );
  });

  test("a dead menuId does nothing and never falls back to the selection", () => {
    const { state } = withTarget(doc.indexOf("|1|2|") + 1, doc.indexOf("|3|4|") + 1);
    for (const menuId of ["unknown", 5, ""]) {
      const r = command(state, "tableDeleteRow", { menuId });
      expect(r.ran).toBe(false);
      expect(text(r.state)).toBe(doc);
    }
    // The target's text is gone.
    const row2 = doc.indexOf("|3|4|");
    const gone = state.update({ changes: { from: row2 - 1, to: doc.length } }).state;
    const r = command(parsed(gone), "tableDeleteRow", { menuId: "m1" });
    expect(r.ran).toBe(false);
  });
});

describe("createTable", () => {
  const NEW = "|  |  |  |\n|---|---|---|\n|  |  |  |\n|  |  |  |";

  test("replaces a blank line and puts the caret in the first header cell", () => {
    const r = command(make("a\n\n   ‸\n\nb"), "createTable");
    expect(text(r.state)).toBe(`a\n\n${NEW}\n\nb`);
    expect(at(r.state)).toEqual({ row: 0, column: 0 });
    expect(head(r.state)).toBe("a\n\n".length + 2);
    expect(text(command(make("‸"), "createTable").state)).toBe(NEW);
  });

  test("goes after the current block with a blank line before it", () => {
    const r = command(make("Intro ‸text\nmore\n\nafter"), "createTable");
    expect(text(r.state)).toBe(`Intro text\nmore\n\n${NEW}\n\nafter`);
    expect(at(r.state)).toEqual({ row: 0, column: 0 });
    expect(head(r.state)).toBe("Intro text\nmore\n\n".length + 2);
    // A block directly followed by text gets a blank line after the table too.
    expect(text(command(make("# h‸\npara"), "createTable").state)).toBe(`# h\n\n${NEW}\n\npara`);
    // A whole list is one block.
    expect(text(command(make("- a‸\n  - b\n- c"), "createTable").state)).toBe(`- a\n  - b\n- c\n\n${NEW}`);
  });

  test("on a blank quote line or list item the rows keep the container", () => {
    expect(text(command(make("> ‸"), "createTable").state)).toBe(NEW.split("\n").map((l) => `> ${l}`).join("\n"));
    const item = command(make("- ‸"), "createTable");
    expect(text(item.state)).toBe(NEW.split("\n").map((l, i) => (i === 0 ? "- " : "  ") + l).join("\n"));
    expect(tableAt(item.state, 3)).not.toBeNull();
  });
});

describe("Tab navigation", () => {
  const doc = "| a | b |\n|---|---|\n| c | d |";
  const selected = (state: EditorState) => state.doc.sliceString(state.selection.main.from, state.selection.main.to);

  test("Tab selects the next cell's content, row by row", () => {
    let state = make("| ‸a | b |\n|---|---|\n| c | d |");
    for (const expected of ["b", "c", "d"]) {
      const r = drive(state, tableTab(true));
      expect(r.result).toBe(true);
      expect(selected(r.state)).toBe(expected);
      state = r.state;
    }
  });

  test("Tab in the last cell appends a row and enters its first cell; it is one undo step", () => {
    const state = make("| a | b |\n|---|---|\n| c | ‸d |");
    const r = drive(state, tableTab(true));
    expect(text(r.state)).toBe(`${doc}\n|  |  |`);
    expect(at(r.state)).toEqual({ row: 2, column: 0 });
    expect(head(r.state)).toBe(r.state.doc.length - "  |  |".length + 1);
    let undone: EditorState | null = null;
    undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
    expect((undone as EditorState | null)?.doc.toString()).toBe(doc);
  });

  test("Tab appends quoted rows in a quote; ragged rows are walked as they are", () => {
    const quote = drive(make("> | a |\n> |---|\n> | ‸b |"), tableTab(true));
    expect(text(quote.state)).toBe("> | a |\n> |---|\n> | b |\n> |  |");
    const ragged = drive(make("| a | b |\n|---|---|\n| ‸c |\n| d | e |"), tableTab(true));
    expect(selected(ragged.state)).toBe("d");
  });

  test("Shift-Tab selects the previous cell; in the first cell it changes nothing but is consumed", () => {
    const r = drive(make("| a | b |\n|---|---|\n| ‸c | d |"), tableTab(false));
    expect(selected(r.state)).toBe("b");
    const first = make("| ‸a | b |\n|---|---|\n| c | d |");
    const stay = drive(first, tableTab(false));
    expect(stay.result).toBe(true);
    expect(text(stay.state)).toBe(text(first));
    expect(head(stay.state)).toBe(head(first));
  });

  test("on the delimiter row", () => {
    expect(selected(drive(make("| a | b |\n|-‸--|---|\n| c | d |"), tableTab(true)).state)).toBe("c");
    expect(selected(drive(make("| a | b |\n|-‸--|---|\n| c | d |"), tableTab(false)).state)).toBe("b");
  });

  test("nextCell returns a spec; null outside a table and at the first cell", () => {
    expect(nextCell(make("no ‸table"), true)).toBeNull();
    expect(nextCell(make("| ‸a |\n|---|"), false)).toBeNull();
    expect(nextCell(make("| ‸a | b |\n|---|---|"), true)).not.toBeNull();
  });

  test("not handled outside a table, in a read-only note, or while composing", () => {
    const plain = make("- item‸");
    expect(drive(plain, tableTab(true)).result).toBe(false);
    expect(drive(plain, tableTab(false)).result).toBe(false);
    const ro = make("| ‸a | b |\n|---|---|", [EditorState.readOnly.of(true)]);
    expect(drive(ro, tableTab(true)).result).toBe(false);
    expect(drive(make("| ‸a | b |\n|---|---|"), tableTab(true), true).result).toBe(false);
  });
});

describe("Enter in a cell", () => {
  test("inserts <br> and keeps the caret after it", () => {
    const r = drive(make("| a | b‸ |\n|---|---|\n| c | d |"), tableEnter);
    expect(r.result).toBe(true);
    expect(text(r.state)).toBe("| a | b<br> |\n|---|---|\n| c | d |");
    expect(r.state.doc.sliceString(head(r.state) - 4, head(r.state))).toBe("<br>");
    // Text after the caret stays in the same cell.
    const mid = drive(make("| a | x‸y |\n|---|---|"), tableEnter);
    expect(text(mid.state)).toBe("| a | x<br>y |\n|---|---|");
    expect(tableAt(mid.state, 0)!.header).toHaveLength(2);
  });

  test("a caret past the closing pipe, and a selection inside one cell", () => {
    const end = drive(make("| a | b |‸\n|---|---|"), tableEnter);
    expect(text(end.state)).toBe("| a | b<br> |\n|---|---|");
    const sel = drive(make("| a | «bc» |\n|---|---|"), tableEnter);
    expect(text(sel.state)).toBe("| a | <br> |\n|---|---|");
    const across = make("| a «| b |\n|---|---|\n| c» | d |");
    expect(drive(across, tableEnter).result).toBe(false);
  });

  test("after the last row's closing pipe it opens a line below the table (M6-R77)", () => {
    const end = drive(make("| a | b |\n|---|---|\n| c | d |‸"), tableEnter);
    expect(end.result).toBe(true);
    expect(text(end.state)).toBe("| a | b |\n|---|---|\n| c | d |\n");
    expect(head(end.state)).toBe(text(end.state).length);
    // Text after the table moves down a line; trailing spaces after the pipe count as outside.
    const after = drive(make("| a |\n|---|\n| c |  ‸\nnext"), tableEnter);
    expect(text(after.state)).toBe("| a |\n|---|\n| c |  \n\nnext");
    expect(head(after.state)).toBe("| a |\n|---|\n| c |  \n".length);
    // In a quote the new line keeps the quote.
    const quote = drive(make("> | a |\n> |---|\n> | c |‸"), tableEnter);
    expect(text(quote.state)).toBe("> | a |\n> |---|\n> | c |\n> ");
    expect(head(quote.state)).toBe(text(quote.state).length);
    // Before the last row's closing pipe it is still a line in the cell.
    expect(text(drive(make("| a |\n|---|\n| c ‸|"), tableEnter).state)).toBe("| a |\n|---|\n| c <br>|");
  });

  test("before the header's first pipe it opens a line above the table (M6-R77)", () => {
    const start = drive(make("‸| a | b |\n|---|---|\n| c | d |"), tableEnter);
    expect(start.result).toBe(true);
    expect(text(start.state)).toBe("\n| a | b |\n|---|---|\n| c | d |");
    expect(head(start.state)).toBe(0);
    const quote = drive(make("> ‸| a |\n> |---|"), tableEnter);
    expect(text(quote.state)).toBe("> \n> | a |\n> |---|");
    expect(head(quote.state)).toBe(2);
    // In an ordered list item the new item renumbers the run, in one undo step (residual round).
    const ordered = "1. | h | x |\n   |---|---|\n   | a | b |\n2. next";
    const list = drive(make(ordered.replace("1. |", "1. ‸|")), tableEnter);
    expect(list.result).toBe(true);
    expect(text(list.state)).toBe("1. \n2. | h | x |\n   |---|---|\n   | a | b |\n3. next");
    expect(head(list.state)).toBe(3);
    expect(text(drive(list.state, (view) => undo(view)).state)).toBe(ordered);
    // A body row's line start still moves into its first cell (M6-R37).
    expect(text(drive(make("| a |\n|---|\n‸| c |"), tableEnter).state)).toBe("| a |\n|---|\n| <br>c |");
  });

  test("on the delimiter row and outside tables it is not handled", () => {
    expect(drive(make("| a |\n|-‸--|"), tableEnter).result).toBe(false);
    expect(drive(make("para‸"), tableEnter).result).toBe(false);
  });

  test("an empty last body row is deleted and the caret ends on a new line after the table", () => {
    const r = drive(make("| a |\n|---|\n| c |\n| ‸ |\nafter"), tableEnter);
    expect(text(r.state)).toBe("| a |\n|---|\n| c |\n\nafter");
    expect(head(r.state)).toBe("| a |\n|---|\n| c |\n".length);
    expect(tableAt(r.state, 0)!.rows).toHaveLength(1);
    const quote = drive(make("> | a |\n> |---|\n> |  ‸|"), tableEnter);
    expect(text(quote.state)).toBe("> | a |\n> |---|\n> ");
    expect(head(quote.state)).toBe(text(quote.state).length);
  });

  test("an empty row that is not the last, or a header, gets <br>", () => {
    const middle = drive(make("| a |\n|---|\n| ‸ |\n| c |"), tableEnter);
    expect(text(middle.state).split("\n")[2]).toBe("| <br> |");
    expect(tableAt(middle.state, 0)!.rows).toHaveLength(2);
    expect(text(drive(make("| ‸ |\n|---|"), tableEnter).state)).toContain("<br>");
  });

  test("not handled in a read-only note or while composing", () => {
    expect(drive(make("| a‸ |\n|---|", [EditorState.readOnly.of(true)]), tableEnter).result).toBe(false);
    expect(drive(make("| a‸ |\n|---|"), tableEnter, true).result).toBe(false);
  });
});
