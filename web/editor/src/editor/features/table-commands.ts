// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Table editing (M6 Task 5): Format ▸ Table commands, Tab / Shift-Tab between cells, and ↩ in a
// cell. Every command is one transaction and one undo step, writes minimal edits (cells it does
// not target stay byte-identical, spacing included) and finds cells through the parser's model
// (table-model.ts), so `\|`, pipes in code spans and wiki links are never mistaken for cell
// borders. The target cell is the one a native menu was opened on (`menuId`, resolved by
// `resolveMenuTarget`; a dead target does nothing) or else the main selection's head.

import { EditorSelection, type ChangeSet, type ChangeSpec, type EditorState, type Transaction, type TransactionSpec } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { completionStatus } from "@codemirror/autocomplete";
import { isolateHistory } from "@codemirror/commands";
import type { SyntaxNode } from "@lezer/common";
import type { EditorView } from "@codemirror/view";
import type { CommandArgs } from "../../bridge/protocol";
import type { EditorCommand } from "./commands";
import { codeAt, lineInCode, listEditTransaction, parseLinePrefix } from "./lists";
import { resolveMenuTarget } from "./menu-targets";
import { type CellRef, cellAt, type TableModel, tableAt } from "./table-model";

type Target = { state: EditorState; dispatch: (tr: Transaction) => void };
type Span = { from: number; to: number };

const FORMAT_EVENT = "input.format";

function run({ state, dispatch }: Target, spec: TransactionSpec): true {
  dispatch(state.update({ scrollIntoView: true, userEvent: FORMAT_EVENT, ...spec, annotations: isolateHistory.of("full") }));
  return true;
}

/** `|` plus one empty cell (`  |`) per column. */
const newRow = (columns: number) => "|" + "  |".repeat(columns);

/** What stands before a row's first pipe: quote markers and indentation. */
function prefixOf(state: EditorState, line: Span): string {
  const text = state.doc.sliceString(line.from, line.to);
  const at = text.indexOf("|");
  return at < 0 ? "" : text.slice(0, at);
}

const rowCells = (model: TableModel, row: number): CellRef[] | undefined => (row === 0 ? model.header : model.rows[row - 1]);
/** The row's pipe-to-pipe text span. */
const pipeSpan = (cells: readonly CellRef[]): Span => ({ from: cells[0]!.from - 1, to: cells.at(-1)!.to + 1 });
const columnCount = (model: TableModel) => Math.max(model.header.length, model.delimiter.cells.length, ...model.rows.map((r) => r.length), 1);

type Located = { model: TableModel; row: number; column: number; onDelimiter: boolean };

/**
 * The table and cell a command acts on. Null: read-only, a dead menu target, no table there, or
 * the position is not on the table's lines. A caret on the delimiter row counts as the header
 * row (`onDelimiter`). A menu opened on a padding cell of a ragged row targets the row's last real
 * cell and remembers the clicked column: column commands act on that column (final review I2).
 */
function locate(state: EditorState, args: CommandArgs | undefined): Located | null {
  if (state.readOnly) return null;
  const target = resolveMenuTarget(state, args);
  if (target.kind === "dead") return null;
  const pos = target.kind === "target" ? target.pos : state.selection.main.head;
  const model = tableAt(state, pos);
  if (!model) return null;
  const hit = cellAt(model, pos);
  if (hit) {
    // A padding cell's menu (a ragged row's cell past its last real one) names its own column.
    const cells = rowCells(model, hit.row)!;
    const padded = target.kind === "target" && target.column !== undefined && hit.column === cells.length - 1;
    const column = padded && target.column! > hit.column && target.column! < columnCount(model) ? target.column! : hit.column;
    return { model, row: hit.row, column, onDelimiter: false };
  }
  if (!model.lines[1] || pos < model.lines[1].from || pos > model.lines[1].to) return null;
  const cells = model.delimiter.cells;
  let column = cells.findIndex((c) => c.from <= pos && pos <= c.to);
  if (column < 0) column = pos < (cells[0]?.from ?? 0) ? 0 : Math.max(0, cells.length - 1);
  return { model, row: 0, column, onDelimiter: true };
}

/** The main-selection-preserving mapping: `moved` places positions the edit relocates itself. */
function mapSelection(state: EditorState, changes: ChangeSet, assoc: -1 | 1, moved?: (pos: number) => number | undefined) {
  const place = (pos: number) => moved?.(pos) ?? changes.mapPos(pos, assoc);
  return EditorSelection.create(
    state.selection.ranges.map((r) => EditorSelection.range(place(r.anchor), place(r.head))),
    state.selection.mainIndex,
  );
}

const contentStart = (cells: readonly CellRef[], column: number): number | null => {
  const cell = cells[Math.min(column, cells.length - 1)];
  return cell ? cell.contentFrom : null;
};

// ---------------------------------------------------------------------------------------------
// Create

const INLINE_PROTECTED = new Set(["InlineCode", "InlineMath", "Comment"]);

/**
 * Inside inline code, inline math or a comment, the edges included: a caret just before `` `x` ``
 * or right after it counts as inside (`codeAt` is strict), so Create Table refuses there.
 */
function inProtectedSpan(tree: ReturnType<typeof syntaxTree>, pos: number): boolean {
  if (codeAt(tree, pos)) return true;
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(pos, side); n; n = n.parent) {
      if (INLINE_PROTECTED.has(n.name) && n.from <= pos && pos <= n.to) return true;
    }
  }
  return false;
}

const NEW_TABLE_ROWS = ["|  |  |  |", "|---|---|---|", "|  |  |  |", "|  |  |  |"];

/**
 * ⌥⌘T. On a blank line (a quote or list marker may stand before it) the table replaces the line;
 * elsewhere it goes after the current block, with a blank line before it. The caret lands in the
 * first header cell. Never inside code.
 */
export const createTable: EditorCommand = (target, args) => {
  const { state } = target;
  if (state.readOnly) return false;
  const at = resolveMenuTarget(state, args);
  if (at.kind === "dead") return false;
  const pos = at.kind === "target" ? at.pos : state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const tree = ensureSyntaxTree(state, Math.min(state.doc.length, line.to + 2000), 50) ?? syntaxTree(state);
  if (lineInCode(state, line, tree) || inProtectedSpan(tree, pos)) return false;
  const p = parseLinePrefix(line.text);
  const lead = p.list ? line.text.slice(0, p.list.contentFrom) : p.quote;
  if (!/\S/.test(line.text.slice(lead.length)) && !p.list?.box) {
    const follow = p.list ? p.quote + " ".repeat(lead.length - p.quote.length) : lead;
    const from = line.from + lead.length;
    const text = NEW_TABLE_ROWS.map((row, i) => (i === 0 ? "" : "\n" + follow) + row).join("");
    return run(target, { changes: { from, to: line.to, insert: text }, selection: EditorSelection.cursor(from + 2) });
  }
  let blockTo = line.to;
  for (let n = tree.topNode.firstChild; n; n = n.nextSibling) {
    if (n.to < line.from || n.from > line.to) continue;
    const end = n.to > n.from && n.to === state.doc.lineAt(n.to).from ? n.to - 1 : n.to;
    blockTo = Math.max(line.to, state.doc.lineAt(end).to);
    break;
  }
  const next = blockTo < state.doc.length ? state.doc.lineAt(blockTo + 1) : null;
  const insert = "\n\n" + NEW_TABLE_ROWS.join("\n") + (next && /\S/.test(next.text) ? "\n" : "");
  return run(target, { changes: { from: blockTo, insert }, selection: EditorSelection.cursor(blockTo + 2 + 2) });
};

// ---------------------------------------------------------------------------------------------
// Rows

function position(args: CommandArgs | undefined): "before" | "after" | null {
  const value = args?.position;
  return value === undefined ? "after" : value === "before" || value === "after" ? value : null;
}

/** Adds an empty row below the caret row (`position: "before"`: above; not above the header). */
export const tableAddRow: EditorCommand = (target, args) => {
  const where = position(args);
  const at = where && locate(target.state, args);
  if (!at || !where) return false;
  const { state } = target;
  const { model, row } = at;
  const columns = model.delimiter.cells.length || model.header.length;
  if (where === "before") {
    if (row === 0) return false;
    const line = model.lines[row + 1]!;
    const changes = state.changes({ from: line.from, insert: prefixOf(state, line) + newRow(columns) + "\n" });
    return run(target, { changes, selection: mapSelection(state, changes, 1) });
  }
  // Below the header comes the delimiter row; the new row follows it.
  const line = model.lines[row === 0 ? 1 : row + 1]!;
  const changes = state.changes({ from: line.to, insert: "\n" + prefixOf(state, line) + newRow(columns) });
  return run(target, { changes, selection: mapSelection(state, changes, -1) });
};

/**
 * The whole table's lines, with one newline so no blank line is left behind (a blank line on both
 * sides leaves one, not two).
 */
function tableRemoval(state: EditorState, model: TableModel): Span {
  const { doc } = state;
  const before = model.from > 0 ? doc.lineAt(model.from - 1) : null;
  const after = model.to < doc.length ? doc.lineAt(model.to + 1) : null;
  if (!after) return { from: Math.max(0, model.from - 1), to: model.to };
  const lonely = !/\S/.test(after.text) && (!before || !/\S/.test(before.text));
  return { from: model.from, to: lonely ? Math.min(doc.length, after.to + 1) : model.to + 1 };
}

/**
 * Deletes the caret row. Deleting the header promotes the first body row (the delimiter stays;
 * cells are added to the row, or to the delimiter, so the two keep the same count). The only
 * remaining row, the header of a table without body rows, deletes the table.
 */
export const tableDeleteRow: EditorCommand = (target, args) => {
  const at = locate(target.state, args);
  if (!at || at.onDelimiter) return false;
  const { state } = target;
  const { model, row, column } = at;
  if (model.rows.length === 0) {
    const changes = state.changes(tableRemoval(state, model));
    return run(target, { changes, selection: mapSelection(state, changes, 1) });
  }
  if (row === 0) {
    const body = model.rows[0]!;
    const header = pipeSpan(model.header);
    const source = pipeSpan(body);
    const delimiterCount = model.delimiter.cells.length;
    const specs: ChangeSpec[] = [
      { from: header.from, to: header.to, insert: state.doc.sliceString(source.from, source.to) + (body.length < delimiterCount ? "  |".repeat(delimiterCount - body.length) : "") },
      { from: model.lines[2]!.from - 1, to: model.lines[2]!.to },
    ];
    if (body.length > delimiterCount) {
      specs.push({ from: model.delimiter.cells.at(-1)!.to + 1, insert: "---|".repeat(body.length - delimiterCount) });
    }
    const changes = state.changes(specs);
    const removed = model.lines[2]!;
    const selection = mapSelection(state, changes, 1, (pos) => {
      if (pos >= header.from && pos <= header.to) return contentStart(body, column) === null ? undefined : header.from + (contentStart(body, column)! - source.from);
      if (pos >= removed.from && pos <= removed.to) return pos >= source.from && pos <= source.to ? header.from + (pos - source.from) : header.from + 1;
      return undefined;
    });
    return run(target, { changes, selection });
  }
  const line = model.lines[row + 1]!;
  const changes = state.changes({ from: line.from - 1, to: line.to });
  const near = rowCells(model, row + 1) ?? rowCells(model, row - 1)!;
  const dest = contentStart(near, column) ?? line.from - 1;
  const selection = mapSelection(state, changes, 1, (pos) => (pos >= line.from && pos <= line.to ? changes.mapPos(dest, 1) : undefined));
  return run(target, { changes, selection });
};

/** Where text moves when two spans trade places (`first` is the earlier one). */
function swapPlan(state: EditorState, first: Span, second: Span) {
  const a = state.doc.sliceString(first.from, first.to);
  const b = state.doc.sliceString(second.from, second.to);
  const d = b.length - a.length;
  const specs: ChangeSpec[] = [
    { from: first.from, to: first.to, insert: b },
    { from: second.from, to: second.to, insert: a },
  ];
  const place = (pos: number): number | undefined => {
    if (pos >= first.from && pos <= first.to) return pos - first.from + second.from + d;
    if (pos >= second.from && pos <= second.to) return pos - second.from + first.from;
    if (pos > first.to && pos < second.from) return pos + d;
    return undefined;
  };
  return { specs, place };
}

/** Swaps the caret row with its neighbour (`direction`: "up" | "down"); the header never moves. */
export const tableMoveRow: EditorCommand = (target, args) => {
  const direction = args?.direction;
  if (direction !== "up" && direction !== "down") return false;
  const at = locate(target.state, args);
  if (!at || at.onDelimiter || at.row === 0) return false;
  const { state } = target;
  const { model, row } = at;
  const other = direction === "up" ? row - 1 : row + 1;
  const mine = rowCells(model, row);
  const theirs = other >= 1 ? rowCells(model, other) : undefined;
  if (!mine?.length || !theirs?.length) return false;
  const [first, second] = row < other ? [mine, theirs] : [theirs, mine];
  const plan = swapPlan(state, pipeSpan(first), pipeSpan(second));
  const changes = state.changes(plan.specs);
  return run(target, { changes, selection: mapSelection(state, changes, 1, plan.place) });
};

// ---------------------------------------------------------------------------------------------
// Columns

/** Adds an empty column right of the caret column (`position: "before"`: left of it). */
export const tableAddColumn: EditorCommand = (target, args) => {
  const where = position(args);
  const at = where && locate(target.state, args);
  if (!at || !where) return false;
  const { state } = target;
  const { model, column } = at;
  const k = where === "after" ? column + 1 : column;
  const specs: ChangeSpec[] = [];
  // The header and the delimiter always get the column (a caret in a body row's extra cell
  // pads them up to it, so the two keep the same count); a body row that ends before the
  // insertion point is left alone.
  const add = (cells: readonly CellRef[], text: string, pad: boolean) => {
    if (cells.length === 0 || (k > cells.length && !pad)) return;
    specs.push({ from: k < cells.length ? cells[k]!.from : cells.at(-1)!.to + 1, insert: text.repeat(Math.max(1, k - cells.length + 1)) });
  };
  add(model.header, "  |", true);
  add(model.delimiter.cells, "---|", true);
  for (const cells of model.rows) add(cells, "  |", false);
  const changes = state.changes(specs);
  return run(target, { changes, selection: mapSelection(state, changes, 1) });
};

/** Deletes the caret column; the only remaining column deletes the table. */
export const tableDeleteColumn: EditorCommand = (target, args) => {
  const at = locate(target.state, args);
  if (!at) return false;
  const { state } = target;
  const { model, column: c } = at;
  if (columnCount(model) === 1) {
    const changes = state.changes(tableRemoval(state, model));
    return run(target, { changes, selection: mapSelection(state, changes, 1) });
  }
  const specs: ChangeSpec[] = [];
  const gone: { from: number; to: number; dest: number }[] = [];
  const drop = (cells: readonly CellRef[], blank: string) => {
    const cell = cells[c];
    if (!cell) return;
    if (cells.length === 1) {
      // Pipes at both ends make a row: a single cell is emptied instead.
      specs.push({ from: cell.from, to: cell.to, insert: blank });
      return;
    }
    specs.push({ from: cell.from, to: cell.to + 1 });
    const near = cells[c + 1] ?? cells[c - 1]!;
    gone.push({ from: cell.from, to: cell.to + 1, dest: near.contentFrom });
  };
  drop(model.header, "  ");
  drop(model.delimiter.cells, "---");
  for (const cells of model.rows) drop(cells, "  ");
  const changes = state.changes(specs);
  const selection = mapSelection(state, changes, 1, (pos) => {
    const hit = gone.find((g) => pos >= g.from && pos <= g.to);
    return hit ? changes.mapPos(hit.dest, 1) : undefined;
  });
  return run(target, { changes, selection });
};

/** Swaps the caret column with its neighbour (`direction`: "left" | "right"); alignment moves with it. */
export const tableMoveColumn: EditorCommand = (target, args) => {
  const direction = args?.direction;
  if (direction !== "left" && direction !== "right") return false;
  const at = locate(target.state, args);
  if (!at) return false;
  const { state } = target;
  const { model, column } = at;
  const other = direction === "left" ? column - 1 : column + 1;
  if (other < 0 || other >= columnCount(model)) return false;
  const lo = Math.min(column, other);
  const hi = lo + 1;
  const specs: ChangeSpec[] = [];
  const plans: ReturnType<typeof swapPlan>[] = [];
  const padded: { span: Span; shift: number }[] = [];
  const swap = (cells: readonly CellRef[], blank: string) => {
    const a = cells[lo];
    const b = cells[hi];
    if (a && b) {
      const plan = swapPlan(state, { from: a.from, to: a.to }, { from: b.from, to: b.to });
      specs.push(...plan.specs);
      plans.push(plan);
    } else if (a && cells.length === hi) {
      // A short row: its last cell trades places with an empty one beyond its end.
      const text = state.doc.sliceString(a.from, a.to);
      specs.push({ from: a.from, to: a.to + 1, insert: blank + "|" + text + "|" });
      padded.push({ span: { from: a.from, to: a.to }, shift: blank.length + 1 });
    }
  };
  swap(model.header, "  ");
  swap(model.delimiter.cells, "---");
  for (const cells of model.rows) swap(cells, "  ");
  if (specs.length === 0) return false;
  const changes = state.changes(specs);
  const selection = mapSelection(state, changes, 1, (pos) => {
    for (const plan of plans) {
      const to = plan.place(pos);
      if (to !== undefined) return to;
    }
    const pad = padded.find((p) => pos >= p.span.from && pos <= p.span.to);
    return pad ? pos + pad.shift : undefined;
  });
  return run(target, { changes, selection });
};

// ---------------------------------------------------------------------------------------------
// Keys

/**
 * The move Tab (`forward`) or Shift-Tab makes: to the next or previous cell, selecting its
 * content; Tab in the last cell appends a row and enters its first cell. Null: not in a table, or
 * Shift-Tab in the first cell.
 */
export function nextCell(state: EditorState, forward: boolean): TransactionSpec | null {
  const head = state.selection.main.head;
  const model = tableAt(state, head);
  if (!model) return null;
  const rows: CellRef[][] = [model.header, ...model.rows].filter((r) => r.length > 0);
  const hit = cellAt(model, head);
  let cell: CellRef | undefined;
  if (!hit) {
    // The delimiter row: Tab goes to the first body cell, Shift-Tab to the header's last.
    if (forward) cell = model.rows.find((r) => r.length > 0)?.[0];
    else cell = model.header.at(-1);
  } else {
    const own = rowCells(model, hit.row)!;
    const index = rows.indexOf(own);
    if (forward) cell = hit.column + 1 < own.length ? own[hit.column + 1] : rows[index + 1]?.[0];
    else cell = hit.column > 0 ? own[hit.column - 1] : rows[index - 1]?.at(-1);
    if (!cell && !forward) return null;
  }
  if (cell) {
    return { selection: EditorSelection.single(cell.contentFrom, cell.contentTo), scrollIntoView: true, userEvent: "select" };
  }
  if (!forward) return null;
  const last = model.lines.at(-1)!;
  const prefix = prefixOf(state, last);
  const columns = model.delimiter.cells.length || model.header.length;
  return {
    changes: { from: last.to, insert: "\n" + prefix + newRow(columns) },
    selection: EditorSelection.cursor(last.to + 1 + prefix.length + 2),
    scrollIntoView: true,
    userEvent: "input",
    annotations: isolateHistory.of("full"),
  };
}

/**
 * Tab / Shift-Tab in a table. Elsewhere, in read-only notes, while composing and while the
 * completion popup is open (Tab accepts the suggestion): not handled.
 */
export const tableTab = (forward: boolean) => (view: EditorView): boolean => {
  const { state } = view;
  if (state.readOnly || view.composing || state.selection.ranges.length !== 1) return false;
  if (completionStatus(state) === "active") return false;
  if (!tableAt(state, state.selection.main.head)) return false;
  const spec = nextCell(state, forward);
  if (spec) view.dispatch(spec);
  return true;
};

const blank = (state: EditorState, cells: readonly CellRef[]) => cells.every((c) => !/\S/.test(state.doc.sliceString(c.from, c.to)));

/**
 * ↩ at a table's outer edge: after the closing pipe of its last row it opens a line
 * below the table, before the header's first pipe a line above it. The new line keeps the rows'
 * quote markers and indentation. Null anywhere else.
 */
function tableEdgeLine(
  state: EditorState,
  model: TableModel,
  row: number,
  cells: readonly CellRef[],
  pos: number,
): { changes: ChangeSpec; selection: EditorSelection } | null {
  const last = model.lines.at(-1)!;
  const span = pipeSpan(cells);
  if (row >= 1 && row === model.rows.length && last === model.lines[row + 1] && pos >= span.to && pos <= last.to) {
    const insert = "\n" + prefixOf(state, last);
    return { changes: { from: last.to, insert }, selection: EditorSelection.single(last.to + insert.length) };
  }
  const first = model.lines[0]!;
  if (row === 0 && pos >= first.from && pos <= span.from) {
    const prefix = prefixOf(state, first);
    return { changes: { from: first.from, insert: prefix + "\n" }, selection: EditorSelection.single(first.from + prefix.length) };
  }
  return null;
}

/**
 * ↩ in a cell inserts `<br>` (multi-line cells). In a completely empty last body row it deletes
 * the row instead, and the caret stays on the now empty line after the table. At the table's
 * outer edge it opens a line outside (`tableEdgeLine`). Not while the completion popup is open.
 */
export const tableEnter = (view: EditorView): boolean => {
  const { state } = view;
  if (state.readOnly || view.composing || state.selection.ranges.length !== 1) return false;
  // Enter accepts the open completion (a `#tag` typed in a cell).
  if (completionStatus(state) === "active") return false;
  const sel = state.selection.main;
  const model = tableAt(state, sel.head);
  if (!model) return false;
  const hit = cellAt(model, sel.head);
  if (!hit) return false;
  const cells = rowCells(model, hit.row)!;
  const cell = cells[hit.column]!;
  const edge = sel.empty ? tableEdgeLine(state, model, hit.row, cells, sel.head) : null;
  if (edge) {
    // Through the list edit path: a new item above a table in an ordered item renumbers the run.
    view.dispatch(listEditTransaction(state, edge.changes, edge.selection));
    return true;
  }
  if (sel.empty && hit.row >= 1 && hit.row === model.rows.length && blank(state, cells)) {
    const line = model.lines.at(-1)!;
    const from = line.from + prefixOf(state, line).length;
    view.dispatch(
      state.update({
        changes: { from, to: line.to },
        selection: EditorSelection.cursor(from),
        scrollIntoView: true,
        userEvent: "input",
        annotations: isolateHistory.of("full"),
      }),
    );
    return true;
  }
  const inCell = (pos: number) => pos >= cell.from && pos <= cell.to;
  let from = Math.min(sel.anchor, sel.head);
  let to = Math.max(sel.anchor, sel.head);
  if (!sel.empty && !(inCell(from) && inCell(to))) return false;
  if (sel.empty) from = to = from < cell.from ? cell.contentFrom : from > cell.to ? cell.contentTo : from;
  view.dispatch(
    state.update({
      changes: { from, to, insert: "<br>" },
      selection: EditorSelection.cursor(from + 4),
      scrollIntoView: true,
      userEvent: "input",
      annotations: isolateHistory.of("full"),
    }),
  );
  return true;
};
