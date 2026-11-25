// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  type ChangeSet,
  type ChangeSpec,
  EditorSelection,
  type EditorState,
  type Extension,
  Prec,
  type SelectionRange,
  type Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import { type EditorView, keymap, ViewPlugin } from "@codemirror/view";
import type { StateCommand } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { indentLess, indentMore, isolateHistory } from "@codemirror/commands";
import type { CommandArgs, CommandName, FormatStateFields } from "../../bridge/protocol";
import {
  codeAt,
  formatLineNumbers,
  indentListItem,
  lineInCode,
  listKindAt,
  moveListBlockDown,
  moveListBlockUp,
  outdentListItem,
  parseLinePrefix,
  toggleBulletList,
  toggleOrderedList,
} from "./lists";
import { insertTodo, moveCheckedToBottom, toggleTodo } from "./todos";
import { expandOverLinks, footnote, linkCommand, openLinkCommand, setLink, wikiLink } from "./links";
import { pendingInserts, removePendingInsert } from "./attachments";
import { codePaste, fenceAt, fenceLines } from "./codeblocks";
import { findStep, openFind } from "./search";
import { resolveMenuTarget } from "./menu-targets";
import { calloutCommand, setCalloutTypeCommand } from "./callouts";
import { insertMathCommand } from "./math";
import { createTable, tableAddColumn, tableAddRow, tableDeleteColumn, tableDeleteRow, tableMoveColumn, tableMoveRow } from "./table-commands";
import { copyTable } from "./table-copy";
import { foldAllCommand, revealEffects, toggleFoldCommand, unfoldAllCommand } from "./folding";

// The command registry (spec §3.2, §4.4): every formatting action of the native Format menu, run
// through the bridge's `applyCommand`. Shortcuts belong to the native menu (one owner per
// shortcut): in the app the editor lets them pass to AppKit (`menuOwnsShortcuts`); only in mock /
// dev mode (no native menu, e2e) the editor binds them itself (`commandKeymap`). ⌘A stays with the
// editor (code-block aware select all).
//
// Every command that edits is one transaction and one undo step (isolateHistory "full"). Inline
// styles never touch text inside code: in a code block or span they are disabled (formatState
// reports `inCode`), except inline code itself, which toggles off inside a code span.

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];
type Tree = ReturnType<typeof syntaxTree>;
type Range = { from: number; to: number };

export type CommandTarget = { state: EditorState; dispatch: (tr: Transaction) => void };
export type EditorCommand = (target: CommandTarget, args?: CommandArgs) => boolean;

const FORMAT_EVENT = "input.format";

function treeFor(state: EditorState): Tree {
  const end = Math.max(...state.selection.ranges.map((r) => r.to));
  return ensureSyntaxTree(state, Math.min(state.doc.length, end + 2000), 50) ?? syntaxTree(state);
}

function edit(state: EditorState, spec: TransactionSpec, userEvent = FORMAT_EVENT): Transaction {
  return state.update({ scrollIntoView: true, ...spec, userEvent, annotations: isolateHistory.of("full") });
}

// ---------------------------------------------------------------------------------------------
// Code



// ---------------------------------------------------------------------------------------------
// Inline styles

type InlineName = "bold" | "italic" | "underline" | "strike" | "highlight" | "inlineCode";
type Style = { node: string; mark: string; open: string };

const STYLES: Record<InlineName, Style> = {
  bold: { node: "StrongEmphasis", mark: "EmphasisMark", open: "**" },
  // Bear's canonical italic is `_`; intraword it is `*` (an intraword `_` is not emphasis).
  italic: { node: "Emphasis", mark: "EmphasisMark", open: "_" },
  underline: { node: "Underline", mark: "UnderlineMark", open: "~" },
  strike: { node: "Strikethrough", mark: "StrikethroughMark", open: "~~" },
  highlight: { node: "Highlight", mark: "HighlightMark", open: "==" },
  inlineCode: { node: "InlineCode", mark: "CodeMark", open: "`" },
};

const INLINE_NAMES = Object.keys(STYLES) as InlineName[];

/** Highlight colors (exactly five). */
export const HIGHLIGHT_COLORS: Record<string, string> = {
  green: "🟢",
  red: "🔴",
  blue: "🔵",
  yellow: "🟡",
  purple: "🟣",
};

type Element = {
  from: number;
  to: number;
  /** The opening mark (with a highlight's color emoji) and the closing mark. */
  open: Range;
  close: Range;
  color: Range | null;
};

function elementOf(node: SyntaxNode, style: Style): Element | null {
  const marks = node.getChildren(style.mark);
  const open = marks[0];
  const close = marks.at(-1);
  if (!open || !close || marks.length < 2 || open.from !== node.from || close.to !== node.to) return null;
  const colorNode = style.node === "Highlight" ? node.getChild("HighlightColor") : null;
  const color = colorNode && colorNode.from === open.to ? { from: colorNode.from, to: colorNode.to } : null;
  return { from: node.from, to: node.to, open: { from: open.from, to: color?.to ?? open.to }, close: { from: close.from, to: close.to }, color };
}

/** The style's elements touching [from, to]. */
function elementsAround(tree: Tree, style: Style, from: number, to: number): Element[] {
  const out: Element[] = [];
  tree.iterate({
    from: Math.max(0, from - 1),
    to: to + 1,
    enter(ref) {
      if (ref.name !== style.node || ref.to < from || ref.from > to) return;
      const el = elementOf(ref.node, style);
      if (el) out.push(el);
    },
  });
  return out;
}

/** The innermost element whose text holds the caret (between its marks, edges included). */
function elementAtCaret(tree: Tree, style: Style, pos: number): Element | null {
  const els = elementsAround(tree, style, pos, pos).filter((e) => e.open.to <= pos && pos <= e.close.from);
  return els.sort((a, b) => a.to - a.from - (b.to - b.from))[0] ?? null;
}

const isBlank = (c: string | undefined) => c === " " || c === "\t";
const HEADING_MARKS = /^#{1,6}[ \t]+/;

/**
 * The parts of a range a style applies to: per line, the text after the quote prefix, the list
 * marker (and todo box) and heading marks, without blanks at either end. Lines of code, math, HTML
 * and comment blocks (their fences too) are left out: a style never touches them.
 */
function segments(state: EditorState, r: SelectionRange): Range[] {
  const out: Range[] = [];
  const { doc } = state;
  const last = r.to > doc.lineAt(r.to).from ? r.to : r.to - 1;
  for (let n = doc.lineAt(r.from).number; n <= doc.lineAt(Math.max(r.from, last)).number; n++) {
    const line = doc.line(n);
    if (lineInCode(state, line)) continue;
    const p = parseLinePrefix(line.text);
    let start = line.from + (p.list ? p.list.contentFrom : p.quote.length + p.indent.length);
    start += HEADING_MARKS.exec(line.text.slice(start - line.from))?.[0].length ?? 0;
    let s = Math.max(r.from, start);
    let e = Math.min(r.to, line.to);
    while (s < e && isBlank(doc.sliceString(s, s + 1))) s++;
    while (e > s && isBlank(doc.sliceString(e - 1, e))) e--;
    if (s < e) out.push({ from: s, to: e });
  }
  return out;
}

/** Whether the elements cover every position of `seg`. */
function covers(els: readonly Element[], seg: Range): boolean {
  let pos = seg.from;
  for (const e of [...els].sort((a, b) => a.from - b.from)) {
    if (e.from > pos) break;
    pos = Math.max(pos, e.to);
  }
  return pos >= seg.to;
}

const WORD = /[\p{L}\p{N}]/u;

function delimiters(state: EditorState, name: InlineName, span: Range, color: string | null): [string, string] {
  if (name === "inlineCode") {
    const text = state.doc.sliceString(span.from, span.to);
    const run = Math.max(0, ...(text.match(/`+/g) ?? []).map((m) => m.length));
    const fence = "`".repeat(run + 1);
    const pad = text.startsWith("`") || text.endsWith("`") ? " " : "";
    return [fence + pad, pad + fence];
  }
  let open = STYLES[name].open;
  if (name === "italic") {
    const before = state.doc.sliceString(span.from - 1, span.from);
    const after = state.doc.sliceString(span.to, span.to + 1);
    if (WORD.test(before) || WORD.test(after)) open = "*";
  }
  return [open + (color ?? ""), open];
}

type RangePlan = {
  changes: ChangeSpec[];
  /** The new range from the mapped old one, or an explicit cursor (in the old document) plus an offset. */
  cursor?: { at: number; offset: number };
};

/** Removes the elements' marks (a highlight's color emoji with its opening mark). */
function removeMarks(els: readonly Element[]): ChangeSpec[] {
  return els.flatMap((e) => [
    { from: e.open.from, to: e.open.to },
    { from: e.close.from, to: e.close.to },
  ]);
}

function colorOf(state: EditorState, e: Element): string | null {
  return e.color ? state.doc.sliceString(e.color.from, e.color.to) : null;
}

/** The change that gives a highlight `color`: replaces its color emoji or adds one. */
const recolorChange = (e: Element, color: string): ChangeSpec =>
  e.color ? { from: e.color.from, to: e.color.to, insert: color } : { from: e.open.to, insert: color };

function planInline(state: EditorState, tree: Tree, name: InlineName, r: SelectionRange, color: string | null): RangePlan | null {
  const style = STYLES[name];
  if (r.empty) {
    const el = elementAtCaret(tree, style, r.head);
    if (el) {
      if (color !== null && colorOf(state, el) !== color) return { changes: [recolorChange(el, color)] };
      return { changes: removeMarks([el]) };
    }
    if (codeAt(tree, r.head)) return null;
    const [open, close] = delimiters(state, name, { from: r.head, to: r.head }, color);
    return { changes: [{ from: r.head, insert: open + close }], cursor: { at: r.head, offset: open.length } };
  }
  if (name === "inlineCode") {
    const around = elementsAround(tree, style, r.from, r.to).find((e) => e.from <= r.from && r.to <= e.to);
    if (around) return { changes: removeMarks([around]) };
  }
  if (codeAt(tree, r.from) || codeAt(tree, r.to)) return null;
  const segs = segments(state, r).map((seg) => expandOverLinks(tree, seg));
  if (segs.length === 0) return null;
  const perSeg = segs.map((seg) => ({
    seg,
    els: name === "inlineCode" ? [] : elementsAround(tree, style, seg.from, seg.to).filter((e) => e.to > seg.from && e.from < seg.to),
  }));
  if (name !== "inlineCode" && perSeg.every(({ seg, els }) => covers(els, seg))) {
    const els = [...new Map(perSeg.flatMap((p) => p.els).map((e) => [e.from, e])).values()];
    if (color !== null && els.some((e) => colorOf(state, e) !== color)) return { changes: els.map((e) => recolorChange(e, color)) };
    return { changes: removeMarks(els) };
  }
  const changes: ChangeSpec[] = [];
  for (const { seg, els } of perSeg) {
    // Same-style elements inside or across the segment merge into one span.
    const span = { from: Math.min(seg.from, ...els.map((e) => e.from)), to: Math.max(seg.to, ...els.map((e) => e.to)) };
    for (const e of els) changes.push({ from: e.open.from, to: e.open.to }, { from: e.close.from, to: e.close.to });
    const [open, close] = delimiters(state, name, span, color);
    changes.push({ from: span.from, insert: open }, { from: span.to, insert: close });
  }
  return { changes };
}

/**
 * Ruling R11: a new `~` / `~~` delimiter must not touch an existing `~` run (`~~~a~~~` loses the
 * underline, opens a tilde fence at a line start and cannot be toggled back).
 */
function touchesTildes(state: EditorState, changes: ChangeSet): boolean {
  const doc = changes.apply(state.doc);
  let touches = false;
  changes.iterChanges((_fromA, _toA, fromB, toB, inserted) => {
    if (!inserted.toString().includes("~")) return;
    if (doc.sliceString(fromB - 1, fromB) === "~" || doc.sliceString(toB, toB + 1) === "~") touches = true;
  });
  return touches;
}

/** Changes in one set must not repeat (two carets in the same element remove its marks once). */
function unique(changes: readonly ChangeSpec[]): ChangeSpec[] {
  const seen = new Map<string, ChangeSpec>();
  for (const c of changes) {
    const { from, to, insert } = c as { from: number; to?: number; insert?: string };
    seen.set(`${from}:${to ?? from}:${insert ?? ""}`, c);
  }
  return [...seen.values()];
}

function inlineCommand(name: InlineName): EditorCommand {
  return ({ state, dispatch }, args) => {
    if (state.readOnly) return false;
    let color: string | null = null;
    if (name === "highlight" && args?.color !== undefined) {
      color = HIGHLIGHT_COLORS[String(args.color)] ?? null;
      if (color === null) return false;
    }
    const tree = treeFor(state);
    const plans = state.selection.ranges.map((r) => planInline(state, tree, name, r, color));
    if (plans.every((p) => p === null)) return false;
    const changes = state.changes(unique(plans.flatMap((p) => p?.changes ?? [])));
    // Refused (R11): handled, nothing changes (the native side may beep).
    if ((name === "underline" || name === "strike") && touchesTildes(state, changes)) return true;
    const ranges = state.selection.ranges.map((r, i) => {
      const cursor = plans[i]?.cursor;
      if (cursor) return EditorSelection.cursor(changes.mapPos(cursor.at, -1) + cursor.offset);
      if (r.empty) return EditorSelection.cursor(changes.mapPos(r.head, 1));
      const forward = r.anchor <= r.head;
      const from = changes.mapPos(r.from, 1);
      const to = Math.max(from, changes.mapPos(r.to, -1));
      return forward ? EditorSelection.range(from, to) : EditorSelection.range(to, from);
    });
    dispatch(edit(state, { changes, selection: EditorSelection.create(ranges, state.selection.mainIndex) }));
    return true;
  };
}

/** The style is on at the caret / on all of the selected text. */
function inlineActive(state: EditorState, tree: Tree, name: InlineName, r: SelectionRange): boolean {
  const style = STYLES[name];
  if (r.empty) return elementAtCaret(tree, style, r.head) !== null;
  if (name === "inlineCode" && elementsAround(tree, style, r.from, r.to).some((e) => e.from <= r.from && r.to <= e.to)) return true;
  const segs = segments(state, r);
  return segs.length > 0 && segs.every((seg) => covers(elementsAround(tree, style, seg.from, seg.to).filter((e) => e.to > seg.from && e.from < seg.to), seg));
}

// ---------------------------------------------------------------------------------------------
// Line commands

/** The selected lines (a range ending at a line start leaves that line out), blank ones too. */
function selectedLines(state: EditorState) {
  const numbers = new Set<number>();
  for (const r of state.selection.ranges) {
    const last = r.empty || r.to > state.doc.lineAt(r.to).from ? r.to : r.to - 1;
    for (let n = state.doc.lineAt(r.from).number; n <= state.doc.lineAt(last).number; n++) numbers.add(n);
  }
  return [...numbers].sort((a, b) => a - b).map((n) => state.doc.line(n));
}

const HEADING = /^(#{1,6})([ \t]+|$)/;

/**
 * ⌘1…⌘6: sets the level; when every line already has it, the heading marks are removed. With a
 * `menuId` (the heading menu) it changes the line the menu was opened on and leaves the selection
 * where it is; a `menuId` that no longer resolves does nothing.
 */
const heading: EditorCommand = ({ state, dispatch }, args) => {
  const level = args?.level;
  if (state.readOnly || typeof level !== "number" || !Number.isInteger(level) || level < 1 || level > 6) return false;
  const target = resolveMenuTarget(state, args);
  if (target.kind === "dead") return false;
  const lines =
    target.kind === "target"
      ? [state.doc.lineAt(target.pos)].filter((line) => !lineInCode(state, line))
      : formatLineNumbers(state).map((n) => state.doc.line(n));
  if (lines.length === 0) return false;
  const info = lines.map((line) => {
    const p = parseLinePrefix(line.text);
    const at = line.from + (p.list ? p.list.contentFrom : p.quote.length + p.indent.length);
    const m = HEADING.exec(state.doc.sliceString(at, line.to));
    return { at, marks: m ? m[1]!.length : 0, end: at + (m ? m[0].length : 0) };
  });
  const all = info.every((i) => i.marks === level);
  const marks = "#".repeat(level) + " ";
  const specs: ChangeSpec[] = [];
  for (const i of info) {
    if (all) specs.push({ from: i.at, to: i.end });
    else if (i.marks !== level) specs.push({ from: i.at, to: i.end, insert: marks });
  }
  const changes = state.changes(specs);
  dispatch(edit(state, { changes, selection: state.selection.map(changes, 1) }));
  return true;
};

const QUOTE = /^[ \t]*>[ \t]?/;

/** ⇧⌘T: quotes the lines (blank lines inside stay in the quote); when all are quoted, one level goes. */
const quote: EditorCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const lines = selectedLines(state);
  const filled = lines.filter((l) => /\S/.test(l.text));
  const all = (filled.length ? filled : lines).every((l) => QUOTE.test(l.text));
  const specs: ChangeSpec[] = all
    ? lines.flatMap((l) => {
        const m = QUOTE.exec(l.text);
        return m ? [{ from: l.from, to: l.from + m[0].length }] : [];
      })
    : lines.map((l) => ({ from: l.from, insert: /\S/.test(l.text) || lines.length === 1 ? "> " : ">" }));
  const changes = state.changes(specs);
  dispatch(edit(state, { changes, selection: state.selection.map(changes, 1) }));
  return true;
};

/** ⌃⌘C: inside a fenced block removes its fences; else wraps the selected lines in a fence. */
const codeBlock: EditorCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const tree = treeFor(state);
  const main = state.selection.main;
  const fence = fenceAt(tree, main.head);
  if (fence) {
    const { open, close } = fenceLines(state, fence);
    const specs: ChangeSpec[] = [];
    if (close && close.number === open.number + 1) specs.push({ from: open.from, to: close.to });
    else {
      specs.push({ from: open.from, to: Math.min(open.to + 1, state.doc.length) });
      if (close) specs.push({ from: close.from - 1, to: close.to });
    }
    const changes = state.changes(specs);
    dispatch(edit(state, { changes, selection: state.selection.map(changes, 1) }));
    return true;
  }
  // Math, front matter, HTML and comment blocks are not wrapped (a code span's line is).
  const code = codeAt(tree, main.head);
  if (code && code.name !== "InlineCode") return false;
  const lines = selectedLines(state);
  const first = lines[0]!;
  const last = lines.at(-1)!;
  const q = parseLinePrefix(first.text).quote;
  if (lines.length === 1 && !/\S/.test(first.text.slice(q.length))) {
    const changes = state.changes({ from: first.from, to: first.to, insert: `${q}\`\`\`\n${q}\n${q}\`\`\`` });
    dispatch(edit(state, { changes, selection: EditorSelection.cursor(first.from + q.length * 2 + 4) }));
    return true;
  }
  const changes = state.changes([
    { from: first.from, insert: `${q}\`\`\`\n` },
    { from: last.to, insert: `\n${q}\`\`\`` },
  ]);
  dispatch(edit(state, { changes, selection: state.selection.map(changes, 1) }));
  return true;
};

/** ⌥⌘S: a `---` line separator on its own line; the caret goes to the line below it. */
const horizontalRule: EditorCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const tree = treeFor(state);
  const head = state.selection.main.head;
  if (codeAt(tree, head)) return false;
  const line = state.doc.lineAt(head);
  const blank = !/\S/.test(line.text);
  const spec = blank
    ? { changes: { from: line.from, to: line.to, insert: "---\n" }, selection: EditorSelection.cursor(line.from + 4) }
    : { changes: { from: line.to, insert: "\n---\n" }, selection: EditorSelection.cursor(line.to + 5) };
  dispatch(edit(state, spec));
  return true;
};

// ---------------------------------------------------------------------------------------------
// Links

function linkAt(tree: Tree, r: SelectionRange): SyntaxNode | null {
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(r.from, side); n; n = n.parent) {
      if (n.name !== "Link") continue;
      if (r.empty ? n.from < r.from && r.from < n.to : n.from <= r.from && r.to <= n.to) return n;
    }
  }
  return null;
}

// ⌘K (the link panel), setLink, ⇧⌘K, ⌘D and ⇧⌘E live in links.ts.

// ---------------------------------------------------------------------------------------------
// Insertions

function insert(state: EditorState, dispatch: (tr: Transaction) => void, text: string): boolean {
  if (state.readOnly) return false;
  dispatch(edit(state, state.replaceSelection(text), "input"));
  return true;
}

/**
 * Inserts `args.text` over the selection, or, with `args.insertId`, over the pending range of a
 * drop or paste (mapped through the edits since; attachments.ts). An unknown id (the note was
 * reloaded, or answered twice) inserts nothing.
 */
const insertText: EditorCommand = ({ state, dispatch }, args) => {
  if (typeof args?.text !== "string") return false;
  const id = args.insertId;
  if (id === undefined) return insert(state, dispatch, args.text);
  const range = typeof id === "string" ? state.field(pendingInserts, false)?.get(id) : undefined;
  if (!range) return false;
  // The host gave up (nothing stored, source refused): only the pending insert goes.
  if (args.text === "") {
    dispatch(state.update({ effects: removePendingInsert.of(id as string) }));
    return true;
  }
  if (state.readOnly) return false;
  dispatch(edit(state, {
    changes: { from: range.from, to: range.to, insert: args.text },
    selection: EditorSelection.cursor(range.from + args.text.length),
    effects: removePendingInsert.of(id as string),
  }, "input"));
  return true;
};

/**
 * Replaces `[from, to)` with `text` if it still reads `expect` (an attachment rename, delete or
 * metadata change from the host's context menu; stale positions do nothing). With
 * `keepSelection: true` (a background edit such as setting the note type) the caret and the
 * scroll position stay where they are: the selection is mapped through the change.
 */
const uint = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

const replaceRange: EditorCommand = ({ state, dispatch }, args) => {
  const { from, to, expect, text, keepSelection } = args ?? {};
  if (state.readOnly || !uint(from) || !uint(to) || from > to || to > state.doc.length) return false;
  if (typeof expect !== "string" || typeof text !== "string" || state.sliceDoc(from, to) !== expect) return false;
  const changes = { from, to, insert: text };
  dispatch(
    keepSelection === true
      ? state.update({ changes, userEvent: "input", annotations: isolateHistory.of("full") })
      : edit(state, { changes, selection: EditorSelection.cursor(from + text.length) }, "input"),
  );
  return true;
};

/** Edit ▸ Paste From ▸ Code: `args.text` (the host's pasteboard) in a fenced block. */
const pasteCode: EditorCommand = ({ state, dispatch }, args) => {
  if (state.readOnly || typeof args?.text !== "string" || args.text === "") return false;
  dispatch(edit(state, codePaste(state, args.text), "input.paste"));
  return true;
};

export type DateStyle = "longTime" | "long" | "short" | "hours";
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");

/** Bear's date inserts (inventory §2.2.1): `11 Jul 2017, 10:43`, `11 Jul 2017`, `11/07/2017`, `10:43`. */
export function formatDate(style: DateStyle, date: Date): string {
  const long = `${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()}`;
  const hours = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  switch (style) {
    case "longTime":
      return `${long}, ${hours}`;
    case "long":
      return long;
    case "short":
      return `${pad(date.getDate())}/${pad(date.getMonth() + 1)}/${date.getFullYear()}`;
    case "hours":
      return hours;
  }
}

const DATE_STYLES = new Set<string>(["longTime", "long", "short", "hours"]);

/** ⇧⌘7 / ⇧⌘8 / ⇧⌘9 / ⌃⇧⌘0. */
const insertDate: EditorCommand = ({ state, dispatch }, args) => {
  const style = args?.style;
  if (typeof style !== "string" || !DATE_STYLES.has(style)) return false;
  return insert(state, dispatch, formatDate(style as DateStyle, new Date()));
};

// ---------------------------------------------------------------------------------------------
// Selection

/** ⌘A: inside a fenced code block its content first; a second ⌘A (or elsewhere) the whole note. */
const selectAll: EditorCommand = ({ state, dispatch }) => {
  const r = state.selection.main;
  const fence = fenceAt(treeFor(state), r.head);
  const content = fence && fenceLines(state, fence).content;
  const target = content && !(r.from === content.from && r.to === content.to) ? content : { from: 0, to: state.doc.length };
  // The folds inside open (M6-R28: ⌘A unfolds every fold it reaches).
  dispatch(state.update({ selection: EditorSelection.single(target.from, target.to), effects: revealEffects(state, target.from, target.to), userEvent: "select" }));
  return true;
};

/** A command from @codemirror/commands as one isolated undo step (one transaction). */
const asStep =
  (command: StateCommand, userEvent: string): EditorCommand =>
  ({ state, dispatch }) =>
    command({
      state,
      dispatch: (tr) => dispatch(edit(state, { changes: tr.changes, selection: tr.selection }, userEvent)),
    });

/** ⌥⌘→ (Format ▸ Indent): the list items with their children, else the lines. */
const indent: EditorCommand = (target) => indentListItem(target) || asStep(indentMore, "input.indent")(target);
/** ⌥⌘← (Format ▸ Outdent). */
const outdent: EditorCommand = (target) => outdentListItem(target) || asStep(indentLess, "delete.dedent")(target);

// ---------------------------------------------------------------------------------------------
// The registry

export const editorCommands: Record<CommandName, EditorCommand> = {
  bold: inlineCommand("bold"),
  italic: inlineCommand("italic"),
  underline: inlineCommand("underline"),
  strike: inlineCommand("strike"),
  highlight: inlineCommand("highlight"),
  inlineCode: inlineCommand("inlineCode"),
  codeBlock,
  heading,
  bulletList: toggleBulletList,
  orderedList: toggleOrderedList,
  todo: insertTodo,
  toggleTodo,
  moveCheckedToBottom,
  quote,
  link: linkCommand,
  setLink,
  horizontalRule,
  insertDate,
  indent,
  outdent,
  moveLineUp: moveListBlockUp,
  moveLineDown: moveListBlockDown,
  // Folding (folding.ts): not an edit, so it also runs in read-only notes.
  toggleFold: toggleFoldCommand,
  selectAll,
  insertText,
  // Edit ▸ Find (search.ts, R32): with the find panel open Find Next / Previous select its match,
  // else they step the note-list search highlight's marker.
  findNext: findStep(1),
  findPrevious: findStep(-1),
  find: openFind("find"),
  findAndReplace: openFind("replace"),
  wikiLink,
  footnote,
  openLink: openLinkCommand,
  // Format ▸ File… (⇧⌘V) opens the host's file panel; the editor has nothing to do.
  insertFile: () => false,
  replaceRange,
  pasteCode,
  // Tables (table-commands.ts); Copy Table As (table-copy.ts) also runs in read-only notes.
  createTable,
  tableAddRow,
  tableAddColumn,
  tableDeleteRow,
  tableDeleteColumn,
  tableMoveRow,
  tableMoveColumn,
  copyTable,
  callout: calloutCommand,
  setCalloutType: setCalloutTypeCommand,
  insertMath: insertMathCommand,
  foldAll: foldAllCommand,
  unfoldAll: unfoldAllCommand,
};

/**
 * Runs a command by name; unknown names do nothing, and nothing runs during an IME composition
 * (the composed text must land intact).
 */
export function runCommand(target: CommandTarget & { composing?: boolean }, name: CommandName, args?: CommandArgs): boolean {
  if (target.composing) return false;
  const command = Object.hasOwn(editorCommands, name) ? editorCommands[name] : undefined;
  return command ? command(target, args) : false;
}

/**
 * A host `applyCommand`. An attachment insert (`insertText` answering a drop or paste: the host
 * has already stored the file) that arrives during a composition runs once it ends instead of
 * being dropped; everything else is `runCommand`.
 */
export function runHostCommand(
  target: CommandTarget & { composing: boolean; contentDOM: EventTarget },
  name: CommandName,
  args?: CommandArgs,
): boolean {
  if (!target.composing || name !== "insertText" || args?.insertId === undefined) return runCommand(target, name, args);
  target.contentDOM.addEventListener("compositionend", () => afterComposition(() => runHostCommand(target, name, args)), { once: true });
  return true;
}

// ---------------------------------------------------------------------------------------------
// Format state

/** Above this many selected lines the format state is not computed (an empty one is sent). */
const FORMAT_STATE_MAX_LINES = 2000;

/** What the Format menu shows for the main selection. Pure. */
export function formatState(state: EditorState): FormatStateFields {
  const r = state.selection.main;
  if (state.doc.lineAt(r.to).number - state.doc.lineAt(r.from).number + 1 > FORMAT_STATE_MAX_LINES) {
    return { active: [], inTodo: false, inCode: false, canIndent: false };
  }
  const tree = treeFor(state);
  const active: CommandName[] = INLINE_NAMES.filter((name) => inlineActive(state, tree, name, r));
  if (linkAt(tree, r)) active.push("link");
  const line = state.doc.lineAt(r.head);
  let headingLevel: number | undefined;
  tree.iterate({
    from: line.from,
    to: line.to,
    enter(ref) {
      const m = /^ATXHeading(\d)$/.exec(ref.name);
      if (m && ref.from >= line.from && ref.to <= line.to) headingLevel = Number(m[1]);
      return headingLevel === undefined;
    },
  });
  if (headingLevel !== undefined) active.push("heading");
  const kind = listKindAt(state, r.head);
  if (kind === "bullet") active.push("bulletList");
  else if (kind === "ordered") active.push("orderedList");
  else if (kind === "todo") active.push("todo");
  if (QUOTE.test(line.text)) active.push("quote");
  if (fenceAt(tree, r.head)) active.push("codeBlock");
  let canIndent = false;
  indentListItem({ state, dispatch: (tr) => (canIndent = tr.docChanged) });
  return {
    active,
    ...(headingLevel !== undefined && { headingLevel }),
    inTodo: kind === "todo",
    inCode: codeAt(tree, r.from) !== null || codeAt(tree, r.to) !== null,
    canIndent,
  };
}

// ---------------------------------------------------------------------------------------------
// Shortcuts

/** The native Format menu's shortcuts (Fixtures/bridge/format-shortcuts.json, inventory §2.17.1). */
export const FORMAT_SHORTCUTS: readonly { key: string; command: CommandName; args?: CommandArgs }[] = [
  { key: "Mod-b", command: "bold" },
  { key: "Mod-i", command: "italic" },
  { key: "Mod-u", command: "underline" },
  { key: "Mod-Shift-u", command: "strike" },
  { key: "Mod-Shift-m", command: "highlight" },
  { key: "Mod-Alt-c", command: "inlineCode" },
  { key: "Mod-k", command: "link" },
  { key: "Mod-Shift-k", command: "openLink" },
  { key: "Mod-Alt-Shift-k", command: "openLink", args: { window: "new" } },
  { key: "Mod-d", command: "wikiLink" },
  { key: "Mod-Shift-e", command: "footnote" },
  ...[1, 2, 3, 4, 5, 6].map((level) => ({ key: `Mod-${level}`, command: "heading" as const, args: { level } })),
  { key: "Mod-l", command: "bulletList" },
  { key: "Mod-Shift-l", command: "orderedList" },
  { key: "Mod-t", command: "todo" },
  { key: "Mod-.", command: "toggleTodo" },
  { key: "Mod-Shift-t", command: "quote" },
  { key: "Ctrl-Mod-c", command: "codeBlock" },
  { key: "Mod-Alt-s", command: "horizontalRule" },
  { key: "Mod-Shift-7", command: "insertDate", args: { style: "longTime" } },
  { key: "Mod-Shift-8", command: "insertDate", args: { style: "long" } },
  { key: "Mod-Shift-9", command: "insertDate", args: { style: "short" } },
  // ⇧⌘0 is Dismiss Workspace (spec §4.2).
  { key: "Ctrl-Mod-Shift-0", command: "insertDate", args: { style: "hours" } },
  { key: "Mod-Alt-ArrowRight", command: "indent" },
  { key: "Mod-Alt-ArrowLeft", command: "outdent" },
  { key: "Mod-Alt-ArrowUp", command: "moveLineUp" },
  { key: "Mod-Alt-ArrowDown", command: "moveLineDown" },
  { key: "Mod-f", command: "find" },
  { key: "Mod-Alt-f", command: "findAndReplace" },
  { key: "Mod-g", command: "findNext" },
  { key: "Mod-Shift-g", command: "findPrevious" },
  { key: "Mod-Shift-v", command: "insertFile" },
  // Tables and folding (M6; bridge v3).
  { key: "Mod-Alt-t", command: "createTable" },
  { key: "Ctrl-Mod-ArrowDown", command: "tableAddRow" },
  { key: "Ctrl-Mod-ArrowRight", command: "tableAddColumn" },
  { key: "Ctrl-Mod-Backspace", command: "tableDeleteRow" },
  { key: "Ctrl-Mod-Shift-Backspace", command: "tableDeleteColumn" },
  { key: "Mod-'", command: "toggleFold" },
];

/** Shortcuts that also work while the find panel's fields have the focus. */
const FIND_COMMANDS: ReadonlySet<CommandName> = new Set(["find", "findAndReplace", "findNext", "findPrevious"]);

type Modifiers = { alt: boolean; ctrl: boolean; meta: boolean; shift: boolean };
const keyName = (m: Modifiers, key: string) =>
  `${m.alt ? "Alt-" : ""}${m.ctrl ? "Ctrl-" : ""}${m.meta ? "Meta-" : ""}${m.shift ? "Shift-" : ""}${key.length === 1 ? key.toLowerCase() : key}`;

/** `Mod-Shift-7` → `Meta-Shift-7` (the editor runs in WebKit on macOS: Mod is ⌘). */
function normalizeKey(spec: string): string {
  const parts = spec.split("-");
  const key = parts.pop()!;
  const m: Modifiers = { alt: false, ctrl: false, meta: false, shift: false };
  for (const p of parts) {
    if (p === "Alt") m.alt = true;
    else if (p === "Ctrl") m.ctrl = true;
    else if (p === "Mod" || p === "Meta" || p === "Cmd") m.meta = true;
    else if (p === "Shift") m.shift = true;
  }
  return keyName(m, key);
}

const SHORTCUT_NAMES = new Set(FORMAT_SHORTCUTS.map((s) => normalizeKey(s.key)));

/** The unshifted key for a key code (US layout), like CodeMirror's fallback for ⌥/⇧ combinations. */
function baseKey(keyCode: number): string | null {
  if (keyCode >= 48 && keyCode <= 57) return String(keyCode - 48);
  if (keyCode >= 65 && keyCode <= 90) return String.fromCharCode(keyCode + 32);
  if (keyCode === 190) return ".";
  return { 37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown" }[keyCode] ?? null;
}

/** Keys matched by their physical position (`KeyboardEvent.code`), whatever the layout types there. */
function physicalKey(code: string | undefined): string | null {
  // ⌘' is the key right of ; (kVK_ANSI_Quote, native keyCode 39), "ä" on German layouts (M6-R5).
  return code === "Quote" ? "'" : null;
}

export type KeyEventLike = {
  key: string;
  keyCode: number;
  /** The physical key (`KeyboardEvent.code`). */
  code?: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
};

/** The key event is one of the native Format menu's shortcuts. */
export function isFormatShortcut(event: KeyEventLike): boolean {
  const m: Modifiers = { alt: event.altKey, ctrl: event.ctrlKey, meta: event.metaKey, shift: event.shiftKey };
  const names = [event.key, baseKey(event.keyCode), physicalKey(event.code)].filter((k): k is string => !!k);
  return names.some((k) => SHORTCUT_NAMES.has(keyName(m, k)));
}

/**
 * In the app the native menu owns the Format shortcuts: CodeMirror never sees them (its ⌘I/⌘U
 * bindings included), and nothing calls preventDefault, so WebKit hands the unhandled key
 * equivalent back to AppKit's menu. A capture listener on the editor root stops the event before
 * it reaches CodeMirror's listeners on the content element (a CodeMirror DOM handler that returns
 * true would preventDefault it).
 */
export const menuOwnsShortcuts: Extension = ViewPlugin.define((view) => {
  const listener = (event: KeyboardEvent) => {
    if (isFormatShortcut(event)) event.stopPropagation();
  };
  view.dom.addEventListener("keydown", listener, true);
  return { destroy: () => view.dom.removeEventListener("keydown", listener, true) };
});

// File insertion belongs to the native iOS picker, including its origin/privacy guards.
// The web command is intentionally a no-op, so consuming its key here would hide the host action.
const IOS_SHORTCUTS = FORMAT_SHORTCUTS.filter(({ command }) => !["indent", "outdent", "tableAddRow", "tableAddColumn", "insertFile"].includes(command)).concat([
  { key: "Ctrl-Mod-Enter", command: "tableAddRow" },
  { key: "Mod-Shift-Enter", command: "tableAddColumn" },
]);

/** Mock / dev and iOS bind formatting; iOS reserves option-command arrows for history. */
const formattingKeymap = (shortcuts: typeof FORMAT_SHORTCUTS): Extension => Prec.high(
  keymap.of(
    shortcuts.map(({ key, command, args }) => ({
      key,
      ...(FIND_COMMANDS.has(command) && { scope: "editor search-panel" }),
      run: (view: EditorView) => {
        runCommand(view, command, args);
        return true;
      },
      preventDefault: true,
    })),
  ),
);
export const commandKeymap = formattingKeymap(FORMAT_SHORTCUTS);
export const iosCommandKeymap = formattingKeymap(IOS_SHORTCUTS);

/** ⌘A stays with the editor in both modes (code-block aware). */
export const selectAllKeymap: Extension = Prec.high(keymap.of([{ key: "Mod-a", run: (view) => runCommand(view, "selectAll") }]));
