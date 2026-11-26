// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The table model (M6 Task 4): rows and cells of a Bear table, read from the Lezer `Table*` nodes
// (dialect-blocks.ts), so `\|`, code spans, wiki links and the other masked pipes
// follow the parser. Pure: the grid widget, the aligned source mode and the AX mirror
// (tables.ts) all read it.

import type { EditorState } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import type { SyntaxNode, Tree } from "@lezer/common";
import { codePointAt } from "../dialect-grammar";
import { highlightColors } from "../dialect";
import { isAttachmentLinkAt } from "./hiding";

/**
 * A cell between two pipes. `from`: right after the opening pipe; `to`: the position of the
 * closing pipe. `contentFrom`…`contentTo`: the trimmed content (the `TableCell` node); an empty
 * cell has an empty content range after its first blank.
 */
export type CellRef = { from: number; to: number; contentFrom: number; contentTo: number };
export type Align = "left" | "center" | "right" | null;
export type TableModel = {
  from: number;
  to: number;
  header: CellRef[];
  align: Align[];
  delimiter: { from: number; to: number; cells: CellRef[] };
  rows: CellRef[][];
  /** The table's lines: header, delimiter, then the body rows. */
  lines: { from: number; to: number }[];
};

const CONTAINERS = new Set(["Document", "Blockquote", "BulletList", "OrderedList", "ListItem"]);

/**
 * The table whose lines hold `pos` (the line edges and container markers included), or null.
 * `tree`: a tree from `ensureSyntaxTree` (the state's own tree may end before a long note's end).
 */
export function tableAt(state: EditorState, pos: number, tree: Tree = syntaxTree(state)): TableModel | null {
  const found = tableNodeAt(state, pos, tree);
  return found ? tableModel(state, found) : null;
}

/**
 * The rows (header and body; the delimiter not counted) of the table at `pos`, without building
 * its model, or null when there is no table there. O(nesting depth + log lines).
 */
export function tableRowsAt(state: EditorState, pos: number, tree: Tree = syntaxTree(state)): number | null {
  const node = tableNodeAt(state, pos, tree);
  return node ? state.doc.lineAt(node.to).number - state.doc.lineAt(node.from).number : null;
}

function tableNodeAt(state: EditorState, pos: number, tree: Tree): SyntaxNode | null {
  const line = state.doc.lineAt(pos);
  let found: SyntaxNode | null = null;
  tree.iterate({
    from: line.from,
    to: line.to,
    enter(node) {
      if (found) return false;
      if (node.name === "Table") {
        if (state.doc.lineAt(node.from).from <= pos && pos <= state.doc.lineAt(node.to).to) found = node.node;
        return false;
      }
      return CONTAINERS.has(node.name);
    },
  });
  return found;
}

/** The number of tables that start in [from, to) (the same container walk as `tableAt`). */
export function tablesBetween(state: EditorState, from: number, to: number, tree: Tree = syntaxTree(state)): number {
  let count = 0;
  if (to <= from) return 0;
  tree.iterate({
    from,
    to,
    enter(node) {
      if (node.from >= to) return false;
      if (node.name === "Table") {
        if (node.from >= from) count++;
        return false;
      }
      return CONTAINERS.has(node.name);
    },
  });
  return count;
}

/** The model of a `Table` node. */
export function tableModel(state: EditorState, table: SyntaxNode): TableModel {
  const doc = state.doc;
  const line = (pos: number) => {
    const l = doc.lineAt(pos);
    return { from: l.from, to: l.to };
  };
  let header: CellRef[] = [];
  let delimiter: TableModel["delimiter"] = { from: table.from, to: table.from, cells: [] };
  const rows: CellRef[][] = [];
  const lines: { from: number; to: number }[] = [];
  for (let child = table.firstChild; child; child = child.nextSibling) {
    if (child.name === "TableHeader") {
      header = rowCells(state, child);
      lines.push(line(child.from));
    } else if (child.name === "TableDelimiter") {
      delimiter = { from: child.from, to: child.to, cells: delimiterCells(state, child.from, child.to) };
      lines.push(line(child.from));
    } else if (child.name === "TableRow") {
      rows.push(rowCells(state, child));
      lines.push(line(child.from));
    }
  }
  const align = delimiter.cells.map((cell): Align => {
    const text = doc.sliceString(cell.contentFrom, cell.contentTo);
    const left = text.startsWith(":");
    const right = text.endsWith(":");
    return left && right ? "center" : right ? "right" : left ? "left" : null;
  });
  return { from: line(table.from).from, to: line(table.to).to, header, align, delimiter, rows, lines };
}

/** An empty cell's caret spot: after its first blank (`| |` → before the closing pipe). */
function emptyCell(state: EditorState, from: number, to: number): CellRef {
  const at = to > from && /[ \t]/.test(state.doc.sliceString(from, from + 1)) ? from + 1 : from;
  return { from, to, contentFrom: at, contentTo: at };
}

/** The cells of a header or body row: between its `TableDelimiter` pipes. */
function rowCells(state: EditorState, row: SyntaxNode): CellRef[] {
  const pipes: number[] = [];
  const contents: SyntaxNode[] = [];
  for (let child = row.firstChild; child; child = child.nextSibling) {
    if (child.name === "TableDelimiter") pipes.push(child.from);
    else if (child.name === "TableCell") contents.push(child);
  }
  const cells: CellRef[] = [];
  for (let k = 0; k + 1 < pipes.length; k++) {
    const from = pipes[k]! + 1;
    const to = pipes[k + 1]!;
    const content = contents.find((n) => n.from >= from && n.to <= to);
    cells.push(content ? { from, to, contentFrom: content.from, contentTo: content.to } : emptyCell(state, from, to));
  }
  return cells;
}

/** The cells of the delimiter row (`|---|:-:|`: only pipes, dashes, colons and blanks). */
function delimiterCells(state: EditorState, from: number, to: number): CellRef[] {
  const text = state.doc.sliceString(from, to);
  const cells: CellRef[] = [];
  let open = text.indexOf("|");
  for (let next = text.indexOf("|", open + 1); open >= 0 && next > open; open = next, next = text.indexOf("|", next + 1)) {
    const inner = text.slice(open + 1, next);
    const start = inner.length - inner.trimStart().length;
    const end = inner.trimEnd().length;
    cells.push({ from: from + open + 1, to: from + next, contentFrom: from + open + 1 + start, contentTo: from + open + 1 + end });
  }
  return cells;
}

/** The cell at `pos`: row 0 is the header, body rows count from 1; null on the delimiter row. */
export function cellAt(model: TableModel, pos: number): { row: number; column: number } | null {
  const index = model.lines.findIndex((l) => l.from <= pos && pos <= l.to);
  if (index < 0 || index === 1) return null;
  const cells = index === 0 ? model.header : model.rows[index - 2];
  if (!cells || cells.length === 0) return null;
  let column = cells.findIndex((c) => c.from <= pos && pos <= c.to);
  if (column < 0) column = pos < cells[0]!.from ? 0 : cells.length - 1;
  return { row: index === 0 ? 0 : index - 1, column };
}

/** The cells of row `row` (0: header). */
export const rowOf = (model: TableModel, row: number): CellRef[] | undefined => (row === 0 ? model.header : model.rows[row - 1]);

/** The exact source of the cell's content. */
export function cellText(state: EditorState, cell: CellRef): string {
  return state.doc.sliceString(cell.contentFrom, cell.contentTo);
}

/** A piece of a cell as shown: visible text with the typography classes of its inline elements. */
export type CellRun =
  | { kind: "text"; text: string; from: number; classes: readonly string[] }
  | { kind: "br"; from: number };

/** Mark node → the element it belongs to (hidden, as with Hide Markdown on and the caret elsewhere). */
const MARKS: Record<string, string> = {
  EmphasisMark: "Emphasis|StrongEmphasis",
  StrikethroughMark: "Strikethrough",
  CodeMark: "InlineCode",
  HighlightMark: "Highlight",
  UnderlineMark: "Underline",
  WikiLinkMark: "WikiLink",
};

/** Inline element → typography.ts class (the same classes the source text gets). */
const CLASSES: Record<string, string> = {
  StrongEmphasis: "cm-bc-strong",
  Emphasis: "cm-bc-em",
  Strikethrough: "cm-bc-strike",
  Underline: "cm-bc-underline",
  InlineCode: "cm-bc-code",
  Tag: "cm-bc-tag",
  WikiLink: "cm-bc-wikilink",
  Autolink: "cm-bc-link",
};

const BR = /<br\s*\/?>/gi;

type Span = { from: number; to: number };
type Marked = Span & { cls: string };

/**
 * The cell as the grid shows it: the markup hidden as Hide Markdown hides it (caret elsewhere), the
 * remaining text in runs carrying the classes of the elements around them, and `<br>` outside
 * code as a line break.
 */
export function cellRuns(state: EditorState, cell: CellRef, tree: Tree = syntaxTree(state)): CellRun[] {
  const { contentFrom: from, contentTo: to } = cell;
  if (to <= from) return [];
  const hidden: Span[] = [];
  const marks: Marked[] = [];
  const code: Span[] = [];
  tree.iterate({
    from,
    to,
    enter(node) {
      if (node.to <= from || node.from >= to) return;
      const name = node.name;
      const parent = node.node.parent;
      const markOf = MARKS[name];
      if (markOf) {
        if (parent && markOf.split("|").includes(parent.name)) hidden.push({ from: node.from, to: node.to });
        return;
      }
      switch (name) {
        case "Escape":
          hidden.push({ from: node.from, to: node.from + 1 });
          return;
        case "HighlightColor":
          hidden.push({ from: node.from, to: node.to });
          return;
        case "Highlight": {
          const color = node.node.getChild("HighlightColor");
          const named = color && highlightColors[codePointAt(state.doc.sliceString(color.from, color.to), 0)];
          marks.push({ from: node.from, to: node.to, cls: named ? `cm-bc-highlight cm-bc-highlight-${named}` : "cm-bc-highlight" });
          return;
        }
        case "WikiLink": {
          marks.push({ from: node.from, to: node.to, cls: "cm-bc-wikilink" });
          const alias = node.node.getChild("WikiAlias");
          if (alias) hidden.push({ from: node.from, to: alias.from }, { from: alias.to, to: node.to });
          return;
        }
        case "Link": {
          const link = node.node;
          const url = link.getChild("URL");
          const [open, close] = link.getChildren("LinkMark");
          if (!url || !open || !close || isAttachmentLinkAt(state, link.from)) return false;
          marks.push({ from: open.to, to: close.from, cls: "cm-bc-link" });
          hidden.push({ from: open.from, to: open.to }, { from: close.from, to: link.to });
          return;
        }
        case "URL": {
          const p = parent?.name;
          if (p !== "Link" && p !== "Image" && p !== "Autolink") marks.push({ from: node.from, to: node.to, cls: "cm-bc-link" });
          return;
        }
        case "InlineCode":
        case "InlineMath":
        case "Comment":
          code.push({ from: node.from, to: node.to });
          break;
      }
      const cls = CLASSES[name];
      if (cls) marks.push({ from: node.from, to: node.to, cls });
    },
  });

  // Every boundary of a hidden range or mark splits the content into pieces.
  const cuts = new Set<number>([from, to]);
  for (const r of [...hidden, ...marks]) {
    if (r.from > from && r.from < to) cuts.add(r.from);
    if (r.to > from && r.to < to) cuts.add(r.to);
  }
  const points = [...cuts].sort((a, b) => a - b);
  const runs: CellRun[] = [];
  const inside = (list: readonly Span[], a: number, b: number) => list.some((r) => r.from <= a && r.to >= b);
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i]!;
    const b = points[i + 1]!;
    if (inside(hidden, a, b)) continue;
    const classes = marks.filter((m) => m.from <= a && m.to >= b).map((m) => m.cls);
    const text = state.doc.sliceString(a, b);
    if (!inside(code, a, b)) {
      let at = 0;
      for (const m of text.matchAll(BR)) {
        if (m.index > at) push(runs, { kind: "text", text: text.slice(at, m.index), from: a + at, classes });
        runs.push({ kind: "br", from: a + m.index });
        at = m.index + m[0].length;
      }
      if (at < text.length) push(runs, { kind: "text", text: text.slice(at), from: a + at, classes });
      continue;
    }
    push(runs, { kind: "text", text, from: a, classes });
  }
  return runs;
}

const sameClasses = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((c, i) => c === b[i]);

function push(runs: CellRun[], run: CellRun & { kind: "text" }) {
  const last = runs.at(-1);
  if (last?.kind === "text" && sameClasses(last.classes, run.classes) && last.from + last.text.length === run.from) {
    runs[runs.length - 1] = { ...last, text: last.text + run.text };
  } else {
    runs.push(run);
  }
}

/** The cell's visible text: markup stripped as Hide Markdown strips it, `<br>` → `"\n"`. */
export function plainCellText(state: EditorState, cell: CellRef, tree?: Tree): string {
  return cellRuns(state, cell, tree)
    .map((r) => (r.kind === "br" ? "\n" : r.text))
    .join("");
}
