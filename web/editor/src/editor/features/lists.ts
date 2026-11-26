// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import {
  type ChangeDesc,
  ChangeSet,
  type ChangeSpec,
  EditorSelection,
  EditorState,
  type Extension,
  type Line,
  Prec,
  type SelectionRange,
  type StateCommand,
  type Text,
  Transaction,
  type TransactionSpec,
  Annotation,
} from "@codemirror/state";
import { type Command, EditorView, keymap } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { indentLess, insertTab, isolateHistory } from "@codemirror/commands";

// Smart lists and line editing (inventory §2.2.1 lists, ordered lists, todos, indent/outdent,
// end a list, reorder lines; §2.2.2 auto-wrap selection, arrows).
//
// The editing commands are line based: a line is a list item when, after its quote
// prefix and indentation, it starts with `-`, `*`, `+` or a number with `.`/`)` followed by a
// blank (a bare `1.` is text), it is not a thematic break (`- - -`) or a date (`12. March`), and
// it is not inside code. They replace @codemirror/lang-markdown's Enter/Backspace entirely (that
// keymap follows CommonMark, where a bare `1.` is an empty item and the tree decides).
//
// Every command is one transaction and one undo step (isolateHistory "full"); ordered lists the
// command touches are renumbered in the same transaction.

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

// ---------------------------------------------------------------------------------------------
// The line model

export type ListMarker = {
  kind: "bullet" | "ordered";
  /** `-`, `*`, `+`, `12.` or `3)`. */
  marker: string;
  number: number | null;
  delim: "." | ")" | null;
  /** The blanks after the marker (at least one). */
  spacing: string;
  /** `[ ]`/`[x]`/`[X]` and the blanks after it (bullets only), else "". */
  box: string;
  /** Offsets in the line. */
  markerFrom: number;
  /** After the marker and its blanks. */
  textFrom: number;
  /** After the box and its blanks (= textFrom without a box). */
  contentFrom: number;
};

export type LinePrefix = {
  /** Quote marks, each with at most one blank after it (`> > `). */
  quote: string;
  /** The blanks after the quote prefix. */
  indent: string;
  list: ListMarker | null;
};

const PREFIX = /^((?:[ \t]*>[ \t]?)*)([ \t]*)/;
const MARKER = /^(?:([-*+])|(\d{1,9})([.)]))([ \t]+)/;
const BOX = /^\[[ xX]\](?:[ \t]+|$)/;
const RULE = /^([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const WORD = /^\p{Lu}\p{L}*/u;

// A line that opens like a date is not a list. A day number (1–31) with a dot,
// then a capitalized English or German month name that ends the line or is followed by a year
// or punctuation (`12. March`, `3. Mai,`, `1. Jan 2026`); an abbreviation needs a dot or a
// number after it (`1. Okt. 2025`). A month word followed by more text is a list item:
// `1. Jan to send invoice`, `1. May I…`, `2. March on…`.
const MONTHS = new Set(
  (
    "January February March April May June July August September October November December " +
    "Januar Jänner Februar Feber März Mai Juni Juli Oktober Dezember"
  ).split(" "),
);
const MONTH_ABBREVIATIONS = new Set("Jan Feb Mar Apr Jun Jul Aug Sep Sept Oct Nov Dec Mär Okt Dez".split(" "));
const AFTER_MONTH = /^(?:[ \t]*$|[ \t]*\d|[.,;:!?)])/;
const AFTER_ABBREVIATION = /^(?:\.|[ \t]*\d)/;

function isDate(m: ListMarker, text: string): boolean {
  if (m.delim !== "." || m.number === null || m.number < 1 || m.number > 31) return false;
  const word = WORD.exec(text.slice(m.textFrom))?.[0];
  if (!word) return false;
  const rest = text.slice(m.textFrom + word.length);
  if (MONTHS.has(word)) return AFTER_MONTH.test(rest);
  return MONTH_ABBREVIATIONS.has(word) && AFTER_ABBREVIATION.test(rest);
}

export function parseLinePrefix(text: string): LinePrefix {
  const prefix = PREFIX.exec(text)!;
  const quote = prefix[1]!;
  const indent = prefix[2]!;
  const at = prefix[0].length;
  const rest = text.slice(at);
  const m = MARKER.exec(rest);
  if (!m || RULE.test(rest)) return { quote, indent, list: null };
  const ordered = m[2] !== undefined;
  const marker = ordered ? m[2]! + m[3]! : m[1]!;
  const textFrom = at + m[0].length;
  const box = ordered ? "" : (BOX.exec(text.slice(textFrom))?.[0] ?? "");
  const list: ListMarker = {
    kind: ordered ? "ordered" : "bullet",
    marker,
    number: ordered ? Number(m[2]) : null,
    delim: ordered ? (m[3] as "." | ")") : null,
    spacing: m[4]!,
    box,
    markerFrom: at,
    textFrom,
    contentFrom: textFrom + box.length,
  };
  return { quote, indent, list: isDate(list, text) ? null : list };
}

const isBlank = (c: string | undefined) => c === " " || c === "\t";
const blankText = (s: string) => !/\S/.test(s);

/** Indentation width in columns (tab = 4). */
function columns(indent: string): number {
  let col = 0;
  for (const c of indent) col = c === "\t" ? col + 4 - (col % 4) : col + 1;
  return col;
}

/** The quote prefix as written on continued lines: with a blank after the last `>`. */
const quoteForNewLine = (quote: string) => (quote && !isBlank(quote.at(-1)) ? quote + " " : quote);
const quoteKey = (quote: string) => quote.replace(/[ \t]/g, "");
/** The quote prefix without its innermost level. */
const dropQuoteLevel = (quote: string) => quoteForNewLine(quote.replace(/[ \t]*>[ \t]?$/, ""));

// ---------------------------------------------------------------------------------------------
// Code

const CODE = new Set([
  "FencedCode",
  "CodeBlock",
  "InlineCode",
  "MathBlock",
  "InlineMath",
  "FrontMatter",
  "HTMLBlock",
  "CommentBlock",
  "Comment",
]);

/**
 * The code node `pos` is strictly inside (a span, a block, math, a comment, front matter), if
 * any. The one code check for lists, commands, links and autocomplete (with `lineInCode`).
 */
export function codeAt(tree: ReturnType<typeof syntaxTree>, pos: number): SyntaxNode | null {
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(pos, side); n; n = n.parent) {
      if (CODE.has(n.name) && n.from < pos && n.to > pos) return n;
    }
  }
  return null;
}

/** `pos` is strictly inside code (a span, a block, math, a comment). */
function insideCode(state: EditorState, pos: number): boolean {
  return codeAt(syntaxTree(state), pos) !== null;
}

/**
 * The line `line` is a line of a code block (or the inline code of a code span around `pos`).
 * `tree`: one the caller made sure is parsed far enough (`ensureSyntaxTree`).
 */
export function lineInCode(state: EditorState, line: Line, tree: ReturnType<typeof syntaxTree> = syntaxTree(state)): boolean {
  const p = PREFIX.exec(line.text)![0].length;
  const pos = line.from + p;
  for (let n: SyntaxNode | null = tree.resolveInner(pos, 1); n; n = n.parent) {
    if (CODE.has(n.name) && n.name !== "InlineCode" && n.name !== "InlineMath" && n.name !== "Comment") {
      // The opening line of a block is the block too.
      if (n.from <= pos && n.to > pos) return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// Presentation layout (shared with typography.ts and the caret steering below)

export type ListLayout = {
  /** The item's first line (with the marker), else a continuation line inside the item. */
  first: boolean;
  kind: "bullet" | "ordered" | "todo";
  /** 1 for a top-level list. */
  level: number;
  /** After the quote prefix: where the (hidden) indentation starts. */
  indentFrom: number;
  /** The marker (first line) or the first character (continuation line). */
  textFrom: number;
  /** End of the marker characters (first line), else textFrom. */
  markerTo: number;
  /** Where the item text starts. */
  contentFrom: number;
  /** The marker as written (`-`, `12.`); "" on continuation lines without one. */
  marker: string;
};

function listDepth(item: SyntaxNode): number {
  let depth = 0;
  for (let n: SyntaxNode | null = item.parent; n; n = n.parent) {
    if (n.name === "BulletList" || n.name === "OrderedList") depth++;
  }
  return depth;
}

function itemKind(item: SyntaxNode, prefix: LinePrefix): ListLayout["kind"] {
  if (item.parent?.name === "OrderedList") return "ordered";
  return item.getChild("Task") && prefix.list?.box ? "todo" : "bullet";
}

/**
 * How a list line is laid out, or null for any other line. A first line needs both: the line
 * model and the syntax tree (a ListMark there, so not code). A continuation line
 * is an indented, non-blank line inside a list item (not code).
 */
export function listLayout(state: EditorState, line: { from: number; to: number; text: string; number: number }): ListLayout | null {
  const p = parseLinePrefix(line.text);
  const tree = syntaxTree(state);
  const indentFrom = line.from + p.quote.length;
  if (p.list) {
    const m = line.from + p.list.markerFrom;
    const mark = tree.resolveInner(m, 1);
    const item = mark.parent;
    if (mark.name !== "ListMark" || mark.from !== m || !item || item.name !== "ListItem") return null;
    const kind = itemKind(item, p);
    return {
      first: true,
      kind,
      level: listDepth(item),
      indentFrom,
      textFrom: m,
      markerTo: m + p.list.marker.length,
      contentFrom: line.from + (kind === "todo" ? p.list.contentFrom : p.list.textFrom),
      marker: p.list.marker,
    };
  }
  if (!p.indent) return null;
  const textFrom = indentFrom + p.indent.length;
  if (textFrom >= line.to) return null;
  for (let n: SyntaxNode | null = tree.resolveInner(textFrom, 1); n; n = n.parent) {
    if (CODE.has(n.name)) return null;
    if (n.name !== "ListItem") continue;
    const first = state.doc.lineAt(n.from);
    if (first.number === line.number) return null;
    const fp = parseLinePrefix(first.text);
    if (!fp.list) return null;
    return { first: false, kind: itemKind(n, fp), level: listDepth(n), indentFrom, textFrom, markerTo: textFrom, contentFrom: textFrom, marker: fp.list.marker };
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Ordered list runs and renumbering

type ParsedLine = { line: Line; p: LinePrefix; col: number; blank: boolean };

const SCAN_LIMIT = 2000;

function parsed(doc: Text, n: number): ParsedLine {
  const line = doc.line(n);
  const p = parseLinePrefix(line.text);
  return { line, p, col: columns(p.indent), blank: blankText(line.text.slice(p.quote.length)) };
}

type Run = { first: number; items: number[] };

/** Parsed lines of one document, each parsed once; `inCode` memoized too. */
class Lines {
  private readonly cache = new Map<number, ParsedLine>();
  private readonly code = new Map<number, boolean>();
  constructor(
    readonly doc: Text,
    private readonly codeTest: (n: number) => boolean,
  ) {}

  get(n: number): ParsedLine {
    let l = this.cache.get(n);
    if (!l) this.cache.set(n, (l = parsed(this.doc, n)));
    return l;
  }

  inCode(n: number): boolean {
    let c = this.code.get(n);
    if (c === undefined) this.code.set(n, (c = this.codeTest(n)));
    return c;
  }
}

/**
 * The ordered list run around line `n` (an ordered item): the items at the same indentation,
 * quote level and delimiter, with their children, continuation lines and blank lines between
 * them. Anything else at that indentation or less (a paragraph, a bullet, a heading, a fence)
 * ends the run, and so does an item numbered 1 after a blank line (a new list). Code lines are
 * never items.
 */
function orderedRun(lines: Lines, n: number): Run | null {
  const at = lines.get(n);
  if (at.p.list?.kind !== "ordered" || lines.inCode(n)) return null;
  const key = quoteKey(at.p.quote);
  const delim = at.p.list.delim;
  const member = (ln: number): "item" | "inside" | "blank" | "stop" => {
    const l = lines.get(ln);
    if (quoteKey(l.p.quote) !== key) return "stop";
    if (l.blank) return "blank";
    if (l.col > at.col) return "inside";
    if (l.col === at.col && l.p.list?.kind === "ordered" && l.p.list.delim === delim && !lines.inCode(ln)) return "item";
    return "stop";
  };
  const number = (ln: number) => lines.get(ln).p.list!.number;
  let first = n;
  let blankSince = false;
  for (let i = n - 1; i >= Math.max(1, n - SCAN_LIMIT); i--) {
    const m = member(i);
    if (m === "stop") break;
    if (m === "blank") blankSince = true;
    if (m !== "item") continue;
    if (blankSince && number(first) === 1) break;
    first = i;
    blankSince = false;
  }
  const items = [first];
  blankSince = false;
  for (let i = first + 1; i <= Math.min(lines.doc.lines, first + SCAN_LIMIT); i++) {
    const m = member(i);
    if (m === "stop") break;
    if (m === "blank") {
      blankSince = true;
      continue;
    }
    if (m === "item") {
      if (blankSince && number(i) === 1) break;
      items.push(i);
      blankSince = false;
    }
  }
  return { first, items };
}

/**
 * Renumbering changes (in `lines.doc`) for the ordered runs containing the given lines: the
 * first item keeps its number (or takes `starts.get(firstLine)`), every following item counts
 * up. Each run is walked once, however many of the lines fall into it.
 */
function renumber(lines: Lines, anchors: Iterable<number>, starts?: ReadonlyMap<number, number>): ChangeSpec[] {
  const sorted = [...new Set(anchors)].filter((n) => n >= 1 && n <= lines.doc.lines).sort((a, b) => a - b);
  const out: ChangeSpec[] = [];
  // Items of the runs already renumbered (nested runs inside them are separate runs).
  const done = new Set<number>();
  for (const n of sorted) {
    if (done.has(n)) continue;
    const run = orderedRun(lines, n);
    if (!run) continue;
    for (const ln of run.items) done.add(ln);
    let expected = starts?.get(run.first) ?? null;
    for (const ln of run.items) {
      const { line, p } = lines.get(ln);
      const list = p.list!;
      if (expected !== null && list.number !== expected) {
        const from = line.from + list.markerFrom;
        out.push({ from, to: from + list.marker.length - 1, insert: String(expected) });
      }
      expected = (expected ?? list.number!) + 1;
    }
  }
  return out;
}

/**
 * Code lines of a document derived from `state.doc` by `changes`, judged by `state`'s tree.
 * When no change adds or removes a line break, line n is still line n.
 */
function codeLinesAfter(state: EditorState, doc: Text, changes: ChangeDesc): (n: number) => boolean {
  let sameLines = true;
  changes.iterChangedRanges((fromA, toA, fromB, toB) => {
    if (sameLines && (state.doc.lineAt(fromA).number !== state.doc.lineAt(toA).number || doc.lineAt(fromB).number !== doc.lineAt(toB).number)) {
      sameLines = false;
    }
  });
  if (sameLines) return (n) => lineInCode(state, state.doc.line(n));
  const back = changes.invertedDesc;
  return (n) => lineInCode(state, state.doc.lineAt(back.mapPos(doc.line(n).from, 1)));
}

/** One list edit: one transaction, one undo step, ordered runs around `anchors` renumbered. */
const listEdit = Annotation.define<boolean>();

type Edit = { changes: ChangeSet; selection: EditorSelection };

function finish(
  state: EditorState,
  edit: Edit,
  anchors: (doc: Text) => Iterable<number>,
  userEvent: string,
  starts?: (doc: Text) => ReadonlyMap<number, number>,
): Transaction {
  const doc = edit.changes.apply(state.doc);
  const lines = new Lines(doc, codeLinesAfter(state, doc, edit.changes));
  const fix = ChangeSet.of(renumber(lines, anchors(doc), starts?.(doc)), doc.length);
  return state.update({
    changes: edit.changes.compose(fix),
    selection: edit.selection.map(fix),
    scrollIntoView: true,
    userEvent,
    annotations: [isolateHistory.of("full"), listEdit.of(true)],
  });
}

/** Lines around the selection heads (and the line after), in `doc`. */
const aroundHeads = (selection: EditorSelection) => (doc: Text) =>
  selection.ranges.flatMap((r) => {
    const n = doc.lineAt(Math.min(r.head, doc.length)).number;
    return [n - 1, n, n + 1];
  });

// ---------------------------------------------------------------------------------------------
// Blocks: an item with its children

/** The last line of the item on line `n` with everything nested in it. */
function blockEnd(doc: Text, n: number): number {
  const at = parsed(doc, n);
  const key = quoteKey(at.p.quote);
  let end = n;
  for (let i = n + 1; i <= Math.min(doc.lines, n + SCAN_LIMIT); i++) {
    const l = parsed(doc, i);
    if (quoteKey(l.p.quote) !== key) break;
    if (l.blank) continue;
    if (l.col <= at.col) break;
    end = i;
  }
  return end;
}

/** The next item at the same indentation and quote level after line `n`'s block, if any. */
function nextSibling(doc: Text, n: number): ParsedLine | null {
  const at = parsed(doc, n);
  for (let i = blockEnd(doc, n) + 1; i <= Math.min(doc.lines, n + SCAN_LIMIT); i++) {
    const l = parsed(doc, i);
    if (quoteKey(l.p.quote) !== quoteKey(at.p.quote)) return null;
    if (l.blank) continue;
    return l.col === at.col && l.p.list ? l : null;
  }
  return null;
}

/** The previous line at the same or a smaller indentation (skipping blank and deeper lines). */
function previousAtOrAbove(doc: Text, n: number): ParsedLine | null {
  const at = parsed(doc, n);
  for (let i = n - 1; i >= Math.max(1, n - SCAN_LIMIT); i--) {
    const l = parsed(doc, i);
    if (quoteKey(l.p.quote) !== quoteKey(at.p.quote)) return null;
    if (l.blank || l.col > at.col) continue;
    return l;
  }
  return null;
}

/** The selected lines (a range ending at a line start leaves that line out). */
function selectedLineNumbers(state: EditorState): number[] {
  const set = new Set<number>();
  for (const r of state.selection.ranges) {
    const last = r.empty || r.to > state.doc.lineAt(r.to).from ? r.to : r.to - 1;
    for (let n = state.doc.lineAt(r.from).number; n <= state.doc.lineAt(last).number; n++) set.add(n);
  }
  return [...set].sort((a, b) => a - b);
}

type Root = { n: number; end: number; at: ParsedLine };

/**
 * The list items among `lines` that are not inside another one's block, with their blocks. An
 * item that cannot move (`movable` false: no item above to nest under, already at the top
 * level) is left out and does not take its selected children along: they move on their own.
 */
function blockRoots(state: EditorState, lines: readonly number[], movable: (root: Root) => boolean = () => true): Root[] {
  const roots: Root[] = [];
  let coveredTo = 0;
  for (const n of lines) {
    if (n <= coveredTo) continue;
    const at = parsed(state.doc, n);
    if (!at.p.list || lineInCode(state, at.line)) continue;
    const root = { n, end: blockEnd(state.doc, n), at };
    if (!movable(root)) continue;
    roots.push(root);
    coveredTo = root.end;
  }
  return roots;
}

/** Inserts `add` (columns of spaces) or removes `remove` columns of indentation on lines `from`…`to`. */
function shiftLines(doc: Text, from: number, to: number, add: number, remove: number, out: ChangeSpec[]) {
  for (let i = from; i <= to; i++) {
    const l = parsed(doc, i);
    if (l.blank) continue;
    const start = l.line.from + l.p.quote.length;
    if (add > 0) {
      out.push({ from: start, insert: " ".repeat(add) });
      continue;
    }
    let cut = 0;
    let col = 0;
    while (cut < l.p.indent.length && col < remove) {
      col = l.p.indent[cut] === "\t" ? col + 4 - (col % 4) : col + 1;
      cut++;
    }
    if (cut > 0) out.push({ from: start, to: start + cut });
  }
}

/** Marker width of an item: what its children are indented by (CommonMark content column). */
const markerWidth = (m: ListMarker) => m.marker.length + Math.min(m.spacing.length, 4);

type ListKind = { kind: "bullet" | "ordered"; marker: string; delim: "." | ")" | null };

/** The marker change that gives the item on `at` the list kind `target` (todos keep their box). */
function convertMarker(at: ParsedLine, target: ListKind, out: ChangeSpec[]): void {
  const own = at.p.list!;
  const from = at.line.from + own.markerFrom;
  const textFrom = at.line.from + own.textFrom;
  if (target.kind === "bullet" && own.kind === "ordered") out.push({ from, to: textFrom, insert: `${target.marker} ` });
  // The number is fixed by renumbering (the item joins an ordered run).
  else if (target.kind === "ordered" && own.kind === "bullet" && !own.box) out.push({ from, to: textFrom, insert: `1${target.delim} ` });
  else if (target.kind === "bullet" && own.kind === "bullet" && target.marker !== own.marker) out.push({ from, to: from + 1, insert: target.marker });
  // `1.` joining a `1)` list takes its delimiter, so it joins its run.
  else if (target.kind === "ordered" && own.kind === "ordered" && target.delim && own.delim !== target.delim) {
    const delimAt = from + own.marker.length - 1;
    out.push({ from: delimAt, to: delimAt + 1, insert: target.delim });
  }
}

/**
 * Tab: each root goes under the item above it at its indentation, by that item's marker width.
 * Selected siblings in a row all go by the same width and stay siblings. A root that joins an
 * existing nested list takes that list's kind (`-`/`*`/`+` or numbered; todos keep their box),
 * and so do the selected siblings after it; a run of selected siblings that starts a new nested
 * list takes the first one's kind. An ordered root that starts a new nested list is numbered 1
 * (`nestedFirst`). `markers` are the marker changes, separate from the indentation (`changes`)
 * so a selection at a line start stays before the marker.
 */
function indentRoots(state: EditorState, roots: readonly Root[]): { changes: ChangeSpec[]; markers: ChangeSpec[]; nestedFirst: number[] } {
  const { doc } = state;
  const changes: ChangeSpec[] = [];
  const markers: ChangeSpec[] = [];
  const nestedFirst: number[] = [];
  const widths = new Map<number, number>();
  // Root line → the list kind it ends up in.
  const kinds = new Map<number, ListKind>();
  for (const root of roots) {
    const prev = previousAtOrAbove(doc, root.n);
    // The first item of a list has nothing to nest under.
    if (!prev || prev.col !== root.at.col || !prev.p.list) continue;
    const own = root.at.p.list!;
    const prevWidth = widths.get(prev.line.number);
    const width = prevWidth ?? markerWidth(prev.p.list);
    widths.set(root.n, width);
    shiftLines(doc, root.n, root.end, width, 0, changes);
    // The item above moves along: they stay siblings, in the same list kind.
    const carried = kinds.get(prev.line.number);
    if (prevWidth !== undefined && carried) {
      convertMarker(root.at, carried, markers);
      kinds.set(root.n, carried);
      continue;
    }
    // The last child of the item above at the new indentation, if any.
    const col = root.at.col + width;
    let child: ParsedLine | null = null;
    for (let i = root.n - 1; i > prev.line.number; i--) {
      const l = parsed(doc, i);
      if (l.blank || l.col > col) continue;
      if (l.col === col && l.p.list) child = l;
      break;
    }
    const target = child?.p.list ?? own;
    kinds.set(root.n, { kind: target.kind, marker: target.marker, delim: target.delim });
    if (child) convertMarker(root.at, kinds.get(root.n)!, markers);
    else if (own.kind === "ordered") nestedFirst.push(root.n);
  }
  return { changes, markers, nestedFirst };
}

function outdentRoots(state: EditorState, roots: readonly Root[]): ChangeSpec[] {
  const changes: ChangeSpec[] = [];
  // Root line → its target column; a sibling root above has the same parent.
  const targets = new Map<number, number>();
  for (const root of roots) {
    if (root.at.col === 0) continue;
    // The parent: the nearest item above with a smaller indentation.
    let target = 0;
    for (let i = root.n - 1; i >= Math.max(1, root.n - SCAN_LIMIT); i--) {
      const sibling = targets.get(i);
      const l = parsed(state.doc, i);
      if (quoteKey(l.p.quote) !== quoteKey(root.at.p.quote)) break;
      if (sibling !== undefined && l.col === root.at.col) {
        target = sibling;
        break;
      }
      if (l.blank || l.col >= root.at.col) continue;
      if (l.p.list) target = l.col;
      break;
    }
    targets.set(root.n, target);
    shiftLines(state.doc, root.n, root.end, 0, root.at.col - target, changes);
  }
  return changes;
}

/** Tab/Shift-Tab result: all roots' lines and the line after each block, for renumbering. */
function rootAnchors(roots: readonly Root[]): number[] {
  return roots.flatMap((r) => [r.n - 1, r.n, r.end + 1]);
}

// ---------------------------------------------------------------------------------------------
// Commands

/** Enter: continue the list / quote, or end it on an empty item (outdent first when nested). */
export const insertNewlineContinueList: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const { doc } = state;
  let handled = false;
  const outdents: Root[] = [];
  const result = state.changeByRange((range) => {
    const line = doc.lineAt(range.from);
    const end = doc.lineAt(range.to);
    const p = parseLinePrefix(line.text);
    const plain = { changes: { from: range.from, to: range.to, insert: "\n" }, range: EditorSelection.cursor(range.from + 1) };
    if ((!p.list && !p.quote) || lineInCode(state, line)) return plain;
    let from = range.from - line.from;
    const after = doc.sliceString(range.to, end.to);
    if (p.list) {
      const list = p.list;
      if (from < list.markerFrom) return plain;
      const contentFrom = p.list.contentFrom;
      from = Math.max(from, contentFrom);
      const to = Math.max(range.to, line.from + contentFrom);
      // A caret inside the marker: the marker's own characters are not item text.
      const rest = end.number === line.number ? doc.sliceString(to, end.to) : after;
      if (blankText(line.text.slice(contentFrom, from) + rest)) {
        handled = true;
        if (p.indent) {
          outdents.push({ n: line.number, end: blockEnd(doc, line.number), at: parsed(doc, line.number) });
          return { range: EditorSelection.cursor(end.to) };
        }
        const cut = line.from + p.quote.length;
        return { changes: { from: cut, to: end.to }, range: EditorSelection.cursor(cut) };
      }
      handled = true;
      let s = line.from + from;
      while (s > line.from + contentFrom && isBlank(doc.sliceString(s - 1, s))) s--;
      let e = to;
      while (e < end.to && isBlank(doc.sliceString(e, e + 1))) e++;
      const next = list.kind === "ordered" ? `${list.number! + 1}${list.delim}` : list.marker;
      const insert = `\n${quoteForNewLine(p.quote)}${p.indent}${next}${list.spacing}${list.box ? "[ ] " : ""}`;
      return { changes: { from: s, to: e, insert }, range: EditorSelection.cursor(s + insert.length) };
    }
    // A quote line without a list.
    if (from < p.quote.length) return plain;
    handled = true;
    if (blankText(line.text.slice(p.quote.length, from) + after)) {
      const quote = dropQuoteLevel(p.quote);
      return { changes: { from: line.from, to: end.to, insert: quote }, range: EditorSelection.cursor(line.from + quote.length) };
    }
    let s = range.from;
    while (s > line.from + p.quote.length && isBlank(doc.sliceString(s - 1, s))) s--;
    let e = range.to;
    while (e < end.to && isBlank(doc.sliceString(e, e + 1))) e++;
    const insert = "\n" + quoteForNewLine(p.quote);
    return { changes: { from: s, to: e, insert }, range: EditorSelection.cursor(s + insert.length) };
  });
  if (!handled) return false;
  let changes = state.changes(result.changes);
  let selection = result.selection;
  if (outdents.length) {
    // Empty nested items move one level out (cursor ranges stay at their line ends).
    const out = state.changes(outdentRoots(state, outdents)).map(changes);
    changes = changes.compose(out);
    selection = selection.map(out);
  }
  dispatch(finish(state, { changes, selection }, aroundHeads(selection), "input"));
  return true;
};

/**
 * Enter on a folded list item (folding.ts): a new sibling item (its marker continued as
 * Enter would, an unchecked box for a todo) on a new line inserted at `at`, the end of the item's
 * folded block, so the hidden children stay with their item. Null when line `n` is no list item.
 */
export function newItemAfterBlock(state: EditorState, n: number, at: number): Transaction | null {
  if (state.readOnly) return null;
  const line = state.doc.line(n);
  const p = parseLinePrefix(line.text);
  if (!p.list || lineInCode(state, line)) return null;
  const list = p.list;
  const next = list.kind === "ordered" ? `${list.number! + 1}${list.delim}` : list.marker;
  const insert = `\n${quoteForNewLine(p.quote)}${p.indent}${next}${list.spacing}${list.box ? "[ ] " : ""}`;
  const selection = EditorSelection.single(at + insert.length);
  return finish(state, { changes: state.changes({ from: at, insert }), selection }, aroundHeads(selection), "input");
}

/**
 * A list-aware edit made by another feature (a new line at a table's edge): one
 * transaction and one undo step, the ordered runs around the selection renumbered.
 */
export function listEditTransaction(state: EditorState, changes: ChangeSpec, selection: EditorSelection, userEvent = "input"): Transaction {
  return finish(state, { changes: state.changes(changes), selection }, aroundHeads(selection), userEvent);
}

/**
 * Shift-Enter on a list or quote line: a new line without a list marker (Bear: ends the list);
 * quotes continue. Other lines and code: false (the default Enter, which keeps indentation).
 */
export const insertNewlineWithoutMarker: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  let handled = false;
  const result = state.changeByRange((range) => {
    const line = state.doc.lineAt(range.from);
    const p = parseLinePrefix(line.text);
    const ours = (p.list || p.quote) && !lineInCode(state, line);
    if (ours) handled = true;
    const insert = "\n" + (ours ? quoteForNewLine(p.quote) : "");
    return { changes: { from: range.from, to: range.to, insert }, range: EditorSelection.cursor(range.from + insert.length) };
  });
  if (!handled) return false;
  const changes = state.changes(result.changes);
  dispatch(finish(state, { changes, selection: result.selection }, aroundHeads(result.selection), "input"));
  return true;
};

/**
 * Backspace right after a list marker removes the marker (the item becomes text at the same
 * indentation); right after a quote mark it removes that quote level; right before the marker
 * of a nested item it outdents the item. Anything else: false (the default Backspace).
 */
export const deleteListMarkup: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly || state.selection.ranges.length > 1) return false;
  const range = state.selection.main;
  if (!range.empty) return false;
  const line = state.doc.lineAt(range.head);
  const p = parseLinePrefix(line.text);
  const off = range.head - line.from;
  if ((!p.list && !p.quote) || lineInCode(state, line)) return false;
  let changes: ChangeSet;
  let starts: ((doc: Text) => ReadonlyMap<number, number>) | undefined;
  const extra: number[] = [];
  if (p.list && off === p.list.contentFrom) {
    changes = state.changes({ from: line.from + p.list.markerFrom, to: line.from + p.list.contentFrom });
    // The rest of the ordered list continues with this item's number: the next sibling (after
    // the item's children and continuation lines, skipping blank lines), when it is an item of
    // the same list. Line numbers do not change.
    const sibling = p.list.number !== null ? nextSibling(state.doc, line.number) : null;
    if (sibling && sibling.p.list?.kind === "ordered" && sibling.p.list.delim === p.list.delim) {
      const number = p.list.number!;
      const n = sibling.line.number;
      starts = () => new Map([[n, number]]);
      extra.push(n);
    }
  } else if (p.list && off === p.list.markerFrom && p.indent) {
    const root = { n: line.number, end: blockEnd(state.doc, line.number), at: parsed(state.doc, line.number) };
    changes = state.changes(outdentRoots(state, [root]));
  } else if (!p.list && p.quote && !p.indent && off === p.quote.length) {
    const quote = dropQuoteLevel(p.quote);
    changes = state.changes({ from: line.from, to: line.from + p.quote.length, insert: quote });
  } else {
    return false;
  }
  const selection = state.selection.map(changes, -1);
  const anchors = (doc: Text) => [...aroundHeads(selection)(doc), ...extra];
  dispatch(finish(state, { changes, selection }, anchors, "delete.backward", starts));
  return true;
};

function shiftCommand(indent: boolean): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const lines = selectedLineNumbers(state);
    if (!lines.some((n) => parsed(state.doc, n).p.list && !lineInCode(state, state.doc.line(n)))) return false;
    const roots = blockRoots(state, lines, (root) => {
      if (!indent) return root.at.col > 0;
      const prev = previousAtOrAbove(state.doc, root.n);
      return !!prev && prev.col === root.at.col && !!prev.p.list;
    });
    let specs: ChangeSpec[];
    let markerSpecs: ChangeSpec[] = [];
    let nestedFirst: number[] = [];
    if (indent) ({ changes: specs, markers: markerSpecs, nestedFirst } = indentRoots(state, roots));
    else specs = outdentRoots(state, roots);
    const shifted = state.changes(specs);
    const markers = state.changes(markerSpecs).map(shifted);
    const changes = shifted.compose(markers);
    // After the indentation, before a converted marker.
    const selection = state.selection.map(shifted, 1).map(markers, -1);
    // Line numbers are unchanged (only indentation within lines changes).
    const starts = () => new Map(nestedFirst.map((n) => [n, 1]));
    dispatch(finish(state, { changes, selection }, () => rootAnchors(roots), indent ? "input.indent" : "delete.dedent", starts));
    return true;
  };
}

/** Tab: indent the selected list items with their children (under the item above). */
export const indentListItem: StateCommand = shiftCommand(true);
/** Shift-Tab: outdent the selected list items with their children (to the parent's level). */
export const outdentListItem: StateCommand = shiftCommand(false);

const HEADING = /^#{1,6}(?:[ \t]|$)/;
const BARE_MARKER = /^(?:[-*+]|\d{1,9}[.)])$/;

/**
 * The lines a format command (⌘L, ⇧⌘L, ⌘1…) works on: the selected lines without code; a
 * selection over several lines skips the blank ones (unless all of them are blank).
 */
export function formatLineNumbers(state: EditorState): number[] {
  const lines = selectedLineNumbers(state).filter((n) => !lineInCode(state, state.doc.line(n)));
  const filled = lines.filter((n) => !parsed(state.doc, n).blank);
  return lines.length > 1 && filled.length > 0 ? filled : lines;
}

export type LineKind = "bullet" | "ordered" | "todo" | null;

const lineKind = (p: LinePrefix): LineKind =>
  !p.list ? null : p.list.kind === "ordered" ? "ordered" : p.list.box ? "todo" : "bullet";

/** The list kind of the line at `pos` (Bear's line rules, not inside code). */
export function listKindAt(state: EditorState, pos: number): LineKind {
  const line = state.doc.lineAt(pos);
  return lineInCode(state, line) ? null : lineKind(parseLinePrefix(line.text));
}

/**
 * ⌘L / ⇧⌘L: when every line already is an item of that kind, the markers are removed; else every
 * line becomes one (other markers and todo boxes are replaced, a bare marker too). Heading lines
 * are left alone. Ordered items are renumbered.
 */
function listToggle(target: "bullet" | "ordered"): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const lines = formatLineNumbers(state)
      .map((n) => parsed(state.doc, n))
      .filter((l) => !HEADING.test(l.line.text.slice(l.p.quote.length + l.p.indent.length)));
    if (lines.length === 0) return false;
    const all = lines.every((l) => lineKind(l.p) === target);
    const insert = target === "bullet" ? "- " : "1. ";
    const specs: ChangeSpec[] = [];
    for (const { line, p } of lines) {
      const at = line.from + p.quote.length + p.indent.length;
      if (all) {
        specs.push({ from: line.from + p.list!.markerFrom, to: line.from + p.list!.contentFrom });
      } else if (p.list) {
        if (lineKind(p) !== target) specs.push({ from: line.from + p.list.markerFrom, to: line.from + p.list.contentFrom, insert });
      } else if (BARE_MARKER.test(line.text.slice(at - line.from))) {
        specs.push({ from: at, to: line.to, insert });
      } else {
        specs.push({ from: at, insert });
      }
    }
    if (specs.length === 0) return false;
    const changes = state.changes(specs);
    const selection = state.selection.map(changes, 1);
    const anchors = () => lines.flatMap(({ line }) => [line.number - 1, line.number, line.number + 1]);
    dispatch(finish(state, { changes, selection }, anchors, "input.list"));
    return true;
  };
}

/** ⌘L: bullet list on/off. */
export const toggleBulletList: StateCommand = listToggle("bullet");
/** ⇧⌘L: ordered list on/off. */
export const toggleOrderedList: StateCommand = listToggle("ordered");

/** The first and last line of what moves: the selected lines, list items with their children. */
function movingBlock(state: EditorState): { s: number; e: number; at: ParsedLine } {
  const lines = selectedLineNumbers(state);
  const s = lines[0]!;
  let e = lines.at(-1)!;
  for (const root of blockRoots(state, lines)) e = Math.max(e, root.end);
  return { s, e, at: parsed(state.doc, s) };
}

function moveCommand(up: boolean): StateCommand {
  return ({ state, dispatch }) => {
    if (state.readOnly) return false;
    const { doc } = state;
    const { s, e, at } = movingBlock(state);
    const isItem = !!at.p.list && !lineInCode(state, at.line);
    let uFrom: number;
    let uTo: number;
    if (up) {
      if (s === 1) return consumed(state, dispatch);
      uFrom = uTo = s - 1;
      const prev = isItem ? previousAtOrAbove(doc, s) : null;
      if (prev && !parsed(doc, s - 1).blank && prev.col === at.col && prev.p.list && blockEnd(doc, prev.line.number) === s - 1) {
        uFrom = prev.line.number;
      }
    } else {
      if (e === doc.lines) return consumed(state, dispatch);
      uFrom = uTo = e + 1;
      const next = parsed(doc, e + 1);
      if (isItem && !next.blank && next.col === at.col && next.p.list) uTo = blockEnd(doc, e + 1);
    }
    const block = doc.sliceString(doc.line(s).from, doc.line(e).to);
    const unit = doc.sliceString(doc.line(uFrom).from, doc.line(uTo).to);
    const from = doc.line(Math.min(s, uFrom)).from;
    const to = doc.line(Math.max(e, uTo)).to;
    const shift = up ? -(unit.length + 1) : unit.length + 1;
    const changes = state.changes({ from, to, insert: up ? `${block}\n${unit}` : `${unit}\n${block}` });
    const selection = EditorSelection.create(
      state.selection.ranges.map((r) => EditorSelection.range(r.anchor + shift, r.head + shift)),
      state.selection.mainIndex,
    );
    // The ordered run keeps the number its first line had before the move.
    const first = Math.min(s, uFrom);
    const oldRun = orderedRun(new Lines(doc, (n) => lineInCode(state, doc.line(n))), first);
    const oldStart = oldRun ? parsed(doc, oldRun.first).p.list!.number! : null;
    const starts = () => (oldRun && oldStart !== null ? new Map([[oldRun.first, oldStart]]) : new Map<number, number>());
    const anchors = () => {
      const out: number[] = [];
      for (let n = first - 1; n <= Math.max(e, uTo) + 1; n++) out.push(n);
      return out;
    };
    dispatch(finish(state, { changes, selection }, anchors, "move.line", starts));
    return true;
  };
}

function consumed(state: EditorState, dispatch: (tr: Transaction) => void): boolean {
  dispatch(state.update({ scrollIntoView: true, userEvent: "move.line" }));
  return true;
}

/** ⌥⌘↑: move the line / selected lines / list item with its children up. */
export const moveListBlockUp: StateCommand = moveCommand(true);
/** ⌥⌘↓: move the line / selected lines / list item with its children down. */
export const moveListBlockDown: StateCommand = moveCommand(false);

// ---------------------------------------------------------------------------------------------
// Typing: auto-wrap a selection, arrows

const WRAPPERS: Record<string, string> = { '"': '"', "'": "'", "(": ")", "[": "]", "{": "}", "*": "*", _: "_", "~": "~", "=": "=", "`": "`" };

/** Inside an inline code span being typed: an odd number of backticks before `pos` on its line. */
function afterOpenBacktick(state: EditorState, pos: number): boolean {
  const line = state.doc.lineAt(pos);
  return (line.text.slice(0, pos - line.from).match(/`/g)?.length ?? 0) % 2 === 1;
}

/** In a bare URL or a link target (also while it is being typed). */
function inUrl(state: EditorState, pos: number): boolean {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); n; n = n.parent) {
    if (n.name === "URL" || n.name === "Autolink") return true;
  }
  const line = state.doc.lineAt(pos);
  const before = line.text.slice(0, pos - line.from);
  return /\]\([^)\s]*$/.test(before) || /(?:^|\s)(?:[a-z][\w+.-]*:\/\/|www\.)\S*$/i.test(before);
}

/**
 * Typing `ch` over a selection: wraps every non-empty range (not in code) in `ch` and its
 * closing character and keeps the text selected (typing `*` twice makes `**bold**`).
 */
export function wrapSelectionSpec(state: EditorState, ch: string): TransactionSpec | null {
  const close = WRAPPERS[ch];
  if (close === undefined || state.readOnly) return null;
  const ranges = state.selection.ranges;
  const wraps = (r: SelectionRange) => !r.empty && !insideCode(state, r.from) && !insideCode(state, r.to);
  if (!ranges.some(wraps)) return null;
  const result = state.changeByRange((r) => {
    if (!wraps(r)) return { changes: { from: r.from, to: r.to, insert: ch }, range: EditorSelection.cursor(r.from + 1) };
    const inner = r.anchor <= r.head ? EditorSelection.range(r.from + 1, r.to + 1) : EditorSelection.range(r.to + 1, r.from + 1);
    return { changes: [{ from: r.from, insert: ch }, { from: r.to, insert: close }], range: inner };
  });
  return { ...result, scrollIntoView: true, userEvent: "input.wrap", annotations: isolateHistory.of("full") };
}

/**
 * Typing `ch` at `pos` completes `->` or `<-`: the change that turns the character before `pos`
 * plus the typed one into the arrow (applied after the typed character is in), else null.
 */
export function arrowConversion(state: EditorState, pos: number, ch: string): { from: number; to: number; insert: string } | null {
  const before = state.doc.sliceString(Math.max(0, pos - 2), pos);
  let arrow: string | null = null;
  if (ch === ">" && before.endsWith("-") && before !== "--") arrow = "→";
  else if (ch === "-" && before.endsWith("<")) arrow = "←";
  if (!arrow || insideCode(state, pos) || afterOpenBacktick(state, pos) || inUrl(state, pos)) return null;
  if (lineInCode(state, state.doc.lineAt(pos))) return null;
  return { from: pos - 1, to: pos, insert: arrow };
}

const typingHandler = EditorView.inputHandler.of((view, from, to, text, insert) => {
  const { state } = view;
  if (view.composing || state.readOnly || text.length !== 1) return false;
  const main = state.selection.main;
  if (from !== main.from || to !== main.to) return false;
  const wrap = wrapSelectionSpec(state, text);
  if (wrap) {
    view.dispatch(wrap);
    return true;
  }
  if (state.selection.ranges.length !== 1 || !main.empty) return false;
  const arrow = arrowConversion(state, from, text);
  if (!arrow) return false;
  view.dispatch(insert());
  // A separate step: one undo brings back the typed `->`.
  if (view.state.sliceDoc(arrow.from, arrow.to + 1) === state.sliceDoc(arrow.from, arrow.to) + text) {
    view.dispatch({
      changes: { from: arrow.from, to: arrow.to + 1, insert: arrow.insert },
      selection: EditorSelection.cursor(arrow.from + 1),
      userEvent: "input.arrow",
      annotations: isolateHistory.of("full"),
    });
  }
  return true;
});

// ---------------------------------------------------------------------------------------------
// Renumbering after structural edits by other means (paste, drop, cut, deleting lines)

const STRUCTURAL = /^(input\.paste|input\.drop|delete|move\.drop)($|\.)/;
const ORDERED_LINE = /^[\s>]*\d{1,9}[.)][ \t]/;

const renumberFilter = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.annotation(listEdit)) return tr;
  const event = tr.annotation(Transaction.userEvent);
  if (!event || !STRUCTURAL.test(event)) return tr;
  const old = tr.startState.doc;
  const doc = tr.newDoc;
  const anchors: number[] = [];
  let multiLine = false;
  tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    if (inserted.lines > 1 || old.lineAt(fromA).number !== old.lineAt(toA).number) multiLine = true;
    const a = doc.lineAt(fromB).number;
    const b = doc.lineAt(toB).number;
    anchors.push(a - 1, a, b, b + 1);
  });
  if (!multiLine) return tr;
  const candidates = anchors.filter((n) => n >= 1 && n <= doc.lines && ORDERED_LINE.test(doc.line(n).text));
  if (candidates.length === 0) return tr;
  const fix = renumber(new Lines(doc, codeLinesAfter(tr.startState, doc, tr.changes)), candidates);
  return fix.length ? [tr, { changes: fix, sequential: true }] : tr;
});

// ---------------------------------------------------------------------------------------------
// Caret steering around the hidden indentation of list lines (typography.ts collapses it)

/**
 * A caret in the hidden indentation of a list line goes to the marker. A click there or on the
 * marker (bullet, number, checkbox) goes to the item text, like in Bear.
 */
const indentationSteering = EditorState.transactionFilter.of((tr) => {
  if (tr.docChanged || !tr.selection) return tr;
  const state = tr.startState;
  const pointer = tr.isUserEvent("select.pointer");
  let moved = false;
  const ranges = tr.selection.ranges.map((r) => {
    if (!r.empty) return r;
    const line = state.doc.lineAt(r.head);
    if (!pointer && !isBlank(line.text[r.head - line.from]) && r.head !== line.from) return r;
    const layout = listLayout(state, line);
    const target = layout && (pointer ? layout.contentFrom : layout.textFrom);
    if (!layout || r.head < layout.indentFrom || r.head >= target!) return r;
    moved = true;
    return EditorSelection.cursor(target!);
  });
  if (!moved) return tr;
  return [tr, { selection: EditorSelection.create(ranges, tr.selection.mainIndex), sequential: true }];
});

/** ←/→ across the hidden indentation in one step (the caret never stops inside it). */
function overIndentation(forward: boolean, extend: boolean): StateCommand {
  return ({ state, dispatch }) => {
    if (state.selection.ranges.length !== 1) return false;
    const r = state.selection.main;
    if (!extend && !r.empty) return false;
    const line = state.doc.lineAt(r.head);
    let target: number | null = null;
    if (!forward) {
      const layout = listLayout(state, line);
      if (!layout || layout.textFrom <= layout.indentFrom || r.head !== layout.textFrom) return false;
      target = layout.indentFrom > line.from ? layout.indentFrom : line.number > 1 ? line.from - 1 : r.head;
    } else {
      if (r.head !== line.to || line.number === state.doc.lines) return false;
      const next = state.doc.line(line.number + 1);
      const layout = listLayout(state, next);
      if (!layout || layout.indentFrom !== next.from || layout.textFrom <= layout.indentFrom) return false;
      target = layout.textFrom;
    }
    const selection = extend ? EditorSelection.range(r.anchor, target) : EditorSelection.cursor(target);
    dispatch(state.update({ selection, scrollIntoView: true, userEvent: "select" }));
    return true;
  };
}

/**
 * Home on a list item's line: the start of the item text when the caret is after it, then the
 * marker; else null (the default line-start command runs).
 */
export function listLineStart(state: EditorState, pos: number): number | null {
  const layout = listLayout(state, state.doc.lineAt(pos));
  if (!layout?.first) return null;
  if (pos > layout.contentFrom) return layout.contentFrom;
  return pos > layout.textFrom ? layout.textFrom : null;
}

const toItemStart =
  (extend: boolean): Command =>
  (view) => {
    const { state } = view;
    let moved = false;
    const ranges = state.selection.ranges.map((r) => {
      const start = listLineStart(state, r.head);
      const layout = start !== null ? listLayout(state, state.doc.lineAt(r.head)) : null;
      // On a later row of a wrapped item the row start comes first (the default command).
      const boundary = view.moveToLineBoundary(EditorSelection.cursor(r.head), false, true).head;
      if (start === null || !layout || boundary > layout.contentFrom) return r;
      moved = true;
      return extend ? EditorSelection.range(r.anchor, start) : EditorSelection.cursor(start);
    });
    if (!moved) return false;
    view.dispatch({ selection: EditorSelection.create(ranges, state.selection.mainIndex), scrollIntoView: true, userEvent: "select" });
    return true;
  };

// ---------------------------------------------------------------------------------------------

const run = (...commands: StateCommand[]) => (target: { state: EditorState; dispatch: (tr: Transaction) => void }) =>
  commands.some((c) => c(target));

/**
 * Tab / Shift-Tab. A read-only note does not handle the key, and the binding has no
 * `preventDefault`, so WebKit moves the focus on; `insertTab` would otherwise "succeed" (the
 * change filter drops its edit) and swallow the key.
 */
const tab = (...commands: StateCommand[]) => {
  const editing = run(...commands);
  return (target: { state: EditorState; dispatch: (tr: Transaction) => void }) => !target.state.readOnly && editing(target);
};

// ⌥⌘→ / ⌥⌘← / ⌥⌘↑ / ⌥⌘↓ are Format menu commands (commands.ts).
export const lists: Extension = [
  renumberFilter,
  indentationSteering,
  typingHandler,
  // Before hiding's Home (Prec.high) and todos' (same as this for todo lines).
  Prec.highest(keymap.of([
    { key: "Home", run: toItemStart(false), shift: toItemStart(true) },
    { mac: "Cmd-ArrowLeft", run: toItemStart(false), shift: toItemStart(true) },
  ])),
  Prec.high(keymap.of([
    { key: "Enter", run: insertNewlineContinueList },
    { key: "Shift-Enter", run: insertNewlineWithoutMarker },
    { key: "Backspace", run: deleteListMarkup },
    { key: "Tab", run: tab(indentListItem, insertTab), shift: tab(outdentListItem, indentLess) },
    { key: "ArrowLeft", run: overIndentation(false, false), shift: overIndentation(false, true) },
    { key: "ArrowRight", run: overIndentation(true, false), shift: overIndentation(true, true) },
  ])),
];
