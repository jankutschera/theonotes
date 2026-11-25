// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Folding (M6 Task 7): headings fold their section, list items their nested list, through
// CodeMirror's fold machinery (`foldEffect`/`unfoldEffect`, the `foldState` field), so everything
// that reads `foldedRanges` (block entry in blocks.ts) sees the folds. `foldRangeAt` is the only
// source of fold ranges: lang-markdown's `headerIndent` service and its `foldNodeProp` blocks are
// never asked (nothing here calls `foldable`).
//
// Folding is not an edit: no document change, no undo step, no revision, and it works in
// read-only notes. Folded ranges leave the DOM, as with a closed disclosure (the one documented
// exception to finding F8, `innerText == document`); a `⋯` button stands in for them.
//
// Side Actions: the fold gutter (left of the heading gutter, inside `--bc-gutter-width`) shows a
// chevron on the hovered line when it can fold, and always on folded lines; chevrons hide while
// typing.

import {
  type ChangeSpec,
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  type Line,
  Prec,
  RangeSet,
  type Range as Ranged,
  StateEffect,
  StateField,
  Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import { EditorView, gutter, GutterMarker, keymap, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { codeFolding, ensureSyntaxTree, foldedRanges, foldEffect, foldState, syntaxTree, unfoldEffect } from "@codemirror/language";
import { completionStatus } from "@codemirror/autocomplete";
import { type FoldEntry, MAX_FOLDS } from "../../bridge/protocol";
import { indexedHeadingText } from "../conformance";
import { newItemAfterBlock, parseLinePrefix } from "./lists";
import { resolveMenuTarget } from "./menu-targets";

type Tree = ReturnType<typeof syntaxTree>;
type FoldRange = { from: number; to: number };

// ---------------------------------------------------------------------------------------------
// Line hashes (persisted fold entries, M6 Task 8)

const encoder = new TextEncoder();

/** FNV-1a 32-bit of the UTF-8 bytes of `text`, as 8 lowercase hex characters. */
export function lineHash(text: string): string {
  let hash = 0x811c9dc5;
  for (const byte of encoder.encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

// ---------------------------------------------------------------------------------------------
// What folds

const HEADING = /^ATXHeading([1-6])$/;
/** Nodes that can hold an indexed heading (a heading in a list item's continuation line). */
const CONTAINERS = new Set(["BulletList", "OrderedList", "ListItem"]);
const blank = (text: string) => !/\S/.test(text);

function treeOf(state: EditorState): Tree {
  return ensureSyntaxTree(state, state.doc.length, 50) ?? syntaxTree(state);
}

type HeadingAt = { line: number; level: number };

/**
 * Calls `visit` with each heading NoteParser indexes (`indexedHeadingText`) that starts at or
 * after `from` (and not after `to`), in document order, until it returns false. Only block
 * containers are entered.
 */
function walkHeadings(state: EditorState, tree: Tree, from: number, visit: (h: HeadingAt) => boolean, to = Infinity): void {
  const { doc } = state;
  const slicer = { slice: (a: number, b: number) => doc.sliceString(a, b) };
  const c = tree.cursor();
  if (!c.childAfter(from)) return;
  for (;;) {
    if (c.from > to) return;
    const m = HEADING.exec(c.name);
    if (m) {
      if (c.from >= from) {
        const line = doc.lineAt(c.from);
        if (indexedHeadingText(slicer, line.from, c.node) !== null && !visit({ line: line.number, level: Number(m[1]) })) return;
      }
    } else if (CONTAINERS.has(c.name) && c.childAfter(from)) {
      continue;
    }
    while (!c.nextSibling()) if (!c.parent()) return;
  }
}

/** The indexed heading on line `n`, if any. */
function headingOn(state: EditorState, tree: Tree, n: number): HeadingAt | null {
  const line = state.doc.line(n);
  let found: HeadingAt | null = null;
  walkHeadings(state, tree, line.from, (h) => {
    if (h.line === n) found = h;
    return false;
  }, line.to);
  return found;
}

/** From the end of line `first` to the end of the last non-blank line up to `last`, or null. */
function foldTo(state: EditorState, first: number, last: number): FoldRange | null {
  const { doc } = state;
  let end = last;
  while (end > first && blank(doc.line(end).text)) end--;
  return end > first ? { from: doc.line(first).to, to: doc.line(end).to } : null;
}

/** The last line of a heading's section, trailing blank lines included. */
function sectionLast(state: EditorState, tree: Tree, heading: HeadingAt): number {
  const { doc } = state;
  let last = doc.lines;
  walkHeadings(state, tree, doc.line(heading.line).to, (h) => {
    if (h.line <= heading.line || h.level > heading.level) return true;
    last = h.line - 1;
    return false;
  });
  return last;
}

function headingRange(state: EditorState, tree: Tree, heading: HeadingAt): FoldRange | null {
  return foldTo(state, heading.line, sectionLast(state, tree, heading));
}

/** The list item whose first line is `line`, when it has a nested list. */
function listRange(state: EditorState, tree: Tree, line: Line): FoldRange | null {
  const p = parseLinePrefix(line.text);
  if (!p.list) return null;
  const at = line.from + p.list.markerFrom;
  const mark = tree.resolveInner(at, 1);
  const item = mark.parent;
  if (mark.name !== "ListMark" || mark.from !== at || !item || item.name !== "ListItem") return null;
  if (!item.getChild("BulletList") && !item.getChild("OrderedList")) return null;
  return foldTo(state, line.number, state.doc.lineAt(item.to).number);
}

/**
 * The range line `line` (1-based) folds, or null:
 * - an indexed ATX heading (not in a quote or after a list marker, with visible text): from the
 *   end of its line to the last non-blank line before the next heading of the same or a higher
 *   level, or the end of the note;
 * - a list item (todos too) with a nested list: from the end of its first line to the end of its
 *   last descendant.
 * Nothing else folds (code blocks, quotes, tables, paragraphs).
 */
export function foldRangeAt(state: EditorState, line: number): FoldRange | null {
  if (!Number.isInteger(line) || line < 1 || line > state.doc.lines) return null;
  const tree = treeOf(state);
  const heading = headingOn(state, tree, line);
  return heading ? headingRange(state, tree, heading) : listRange(state, tree, state.doc.line(line));
}

/** The folds that start on line `n`. */
function foldsOn(state: EditorState, n: number): FoldRange[] {
  const line = state.doc.line(n);
  const out: FoldRange[] = [];
  foldedRanges(state).between(line.from, line.to, (from, to) => {
    if (from >= line.from && from <= line.to) out.push({ from, to });
  });
  return out;
}

/** Whether line `line` (1-based) is folded (a fold starts on it). */
export function isFolded(state: EditorState, line: number): boolean {
  return Number.isInteger(line) && line >= 1 && line <= state.doc.lines && foldsOn(state, line).length > 0;
}

// ---------------------------------------------------------------------------------------------
// Folding and unfolding

const installed = (state: EditorState) => state.field(foldState, false) !== undefined;

/** A caret strictly inside, or a selection overlapping, the range. */
const meets = (r: { from: number; to: number; empty: boolean; head: number }, f: FoldRange) =>
  r.empty ? f.from < r.head && r.head < f.to : f.from < r.to && f.to > r.from;

/** Folding `f` would hide the selection range: a caret on a folded line (its end included) or any overlap. */
const hides = (r: { from: number; to: number; empty: boolean; head: number }, f: FoldRange) =>
  r.empty ? f.from < r.head && r.head <= f.to : f.from < r.to && f.to > r.from;

/**
 * Folds `ranges`. A selection that would end up inside a new fold collapses to the start of the
 * outermost one (the end of the folded line), so the caret stays visible.
 */
function foldSpec(state: EditorState, ranges: readonly FoldRange[]): TransactionSpec | null {
  if (ranges.length === 0) return null;
  let moved = false;
  const selection = state.selection.ranges.map((r) => {
    const hit = ranges.filter((f) => hides(r, f));
    if (hit.length === 0) return r;
    moved = true;
    return EditorSelection.cursor(Math.min(...hit.map((f) => f.from)));
  });
  const effects = ranges.map((range) => foldEffect.of(range));
  return moved ? { effects, selection: EditorSelection.create(selection, state.selection.mainIndex) } : { effects };
}

/** Folds (`folded` true) or unfolds line `n`; null when there is nothing to do. */
function foldLineSpec(state: EditorState, n: number, folded: boolean): TransactionSpec | null {
  if (!installed(state) || !Number.isInteger(n) || n < 1 || n > state.doc.lines) return null;
  const existing = foldsOn(state, n);
  if (!folded) return existing.length ? { effects: existing.map((f) => unfoldEffect.of(f)) } : null;
  if (existing.length) return null;
  const range = foldRangeAt(state, n);
  return range ? foldSpec(state, [range]) : null;
}

/** Folds or unfolds line `line` (1-based) of the view. False when nothing changed. */
export function foldLine(view: EditorView, line: number, folded: boolean): boolean {
  const spec = foldLineSpec(view.state, line, folded);
  if (!spec) return false;
  view.dispatch(spec);
  return true;
}

/** Unfold effects for the folds a range (or caret, `from === to`) reaches into. */
export function revealEffects(state: EditorState, from: number, to: number = from): StateEffect<FoldRange>[] {
  const out: StateEffect<FoldRange>[] = [];
  const r = { from, to, empty: from === to, head: from };
  foldedRanges(state).between(from, to, (a, b) => {
    if (meets(r, { from: a, to: b })) out.push(unfoldEffect.of({ from: a, to: b }));
  });
  return out;
}

const strictlyInside = (pos: number, f: FoldRange) => f.from < pos && pos < f.to;

/**
 * Selections and folds (M6-R28). A selection endpoint (anchor or head) strictly inside a fold
 * unfolds it, whatever moved it there. A pointer drag or a Shift-selection across a fold keeps it
 * closed. Find (`select.search`) unfolds every fold its match reaches; ⌘A, the ToC jump, the
 * bridge `selectRange` and the search highlight add `revealEffects` themselves. The folds are the
 * old ones mapped through the change, exactly as `foldState` maps them, so the unfold effects match.
 */
const revealSelection = EditorState.transactionExtender.of((tr) => {
  if (!tr.selection) return null;
  const old = tr.startState.field(foldState, false);
  if (!old || old.size === 0) return null;
  const folded = tr.docChanged ? old.map(tr.changes) : old;
  const reach = tr.isUserEvent("select.search");
  const effects: StateEffect<FoldRange>[] = [];
  for (const r of tr.selection.ranges) {
    folded.between(r.from, r.to, (from, to) => {
      const f = { from, to };
      const opens = reach ? meets(r, f) : strictlyInside(r.anchor, f) || strictlyInside(r.head, f);
      if (opens && !effects.some((e) => e.value.from === from && e.value.to === to)) effects.push(unfoldEffect.of(f));
    });
  }
  return effects.length ? { effects } : null;
});

/** The start of the outermost fold that ends at `pos` (a caret right after a `⋯`), else null. */
function foldStartEndingAt(state: EditorState, pos: number): number | null {
  let start: number | null = null;
  foldedRanges(state).between(pos, pos, (from, to) => {
    if (to === pos && (start === null || from < start)) start = from;
  });
  return start;
}

/**
 * A caret never rests at a fold's end (M6-R28): an empty cursor that would land exactly there (a
 * click right of the `⋯`, ⌘→, End, ⌃E, ArrowUp/Down, ArrowLeft from the next line, a host
 * selection) goes to the fold's start instead, before the `⋯`. So typing there, dead-key and IME
 * compositions included, always edits the visible line. Shift-extended (non-empty) ranges may
 * span the fold and are left alone; a running composition is never moved. The folds are the old
 * ones mapped through the change.
 */
const caretOffFoldEnd = EditorState.transactionFilter.of((tr) => {
  if (!tr.selection || tr.isUserEvent("input.type.compose")) return tr;
  const old = tr.startState.field(foldState, false);
  if (!old || old.size === 0) return tr;
  const folds = tr.docChanged ? old.map(tr.changes) : old;
  let moved = false;
  const ranges = tr.selection.ranges.map((r) => {
    if (!r.empty) return r;
    let start: number | null = null;
    folds.between(r.head, r.head, (from, to) => {
      if (to === r.head && (start === null || from < start)) start = from;
    });
    if (start === null) return r;
    moved = true;
    return EditorSelection.cursor(start, 1);
  });
  if (!moved) return tr;
  return [tr, { selection: EditorSelection.create(ranges, tr.selection.mainIndex), sequential: true }];
});

/**
 * ArrowRight (and ⌃F) from a fold's start, before the `⋯`, moves to the start of the line after the
 * fold (a caret cannot rest at the fold's end, `caretOffFoldEnd`); at the end of the note it
 * stays. Shift-→ from the fold's start extends over the whole fold to its end, Shift-← from the
 * fold's end back to its start, so a keyboard extension never stops inside hidden text.
 */
const overFold = (forward: boolean, extend: boolean) => (view: EditorView): boolean => {
  const { state } = view;
  const main = state.selection.main;
  if (view.composing || state.selection.ranges.length !== 1 || (!extend && !main.empty)) return false;
  const head = main.head;
  let target: number | null = null;
  foldedRanges(state).between(head, head, (from, to) => {
    if (forward && from === head && (target === null || to > target)) target = to;
    if (!forward && to === head && (target === null || from < target)) target = from;
  });
  if (target === null) return false;
  const at = target as number;
  if (extend) {
    view.dispatch({ selection: { anchor: main.anchor, head: at }, scrollIntoView: true, userEvent: "select" });
    return true;
  }
  if (!forward) return false;
  if (at < state.doc.length) view.dispatch({ selection: { anchor: at + 1 }, scrollIntoView: true, userEvent: "select" });
  return true;
};

/**
 * Typing, pasting or dropping with the caret right after a `⋯` (a fold's end, the end of the last
 * hidden line) would edit hidden text: the insert goes to the end of the visible folded line
 * instead, before the `⋯` (M6-R28). A backstop: `caretOffFoldEnd` keeps the caret off that
 * position, so this catches inserts positioned by other code (paste and drop). An IME
 * composition is left alone (its DOM must not move).
 */
const inputBeforePlaceholder = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.isUserEvent("input.type.compose")) return tr;
  if (!tr.isUserEvent("input.type") && !tr.isUserEvent("input.paste") && !tr.isUserEvent("input.drop")) return tr;
  const { startState } = tr;
  const folds = startState.field(foldState, false);
  if (!folds || folds.size === 0) return tr;
  let moved = false;
  const specs: ChangeSpec[] = [];
  tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
    const start = fromA === toA ? foldStartEndingAt(startState, fromA) : null;
    if (start === null) return void specs.push({ from: fromA, to: toA, insert: inserted });
    moved = true;
    specs.push({ from: start, insert: inserted });
  });
  if (!moved) return tr;
  const changes = startState.changes(specs);
  const ranges = startState.selection.ranges.map((r) => {
    const start = r.empty ? foldStartEndingAt(startState, r.head) : null;
    return start === null ? r.map(changes, 1) : EditorSelection.cursor(changes.mapPos(start, 1));
  });
  return {
    changes,
    selection: EditorSelection.create(ranges, startState.selection.mainIndex),
    effects: tr.effects,
    scrollIntoView: tr.scrollIntoView,
    ...(tr.annotation(Transaction.userEvent) !== undefined && { userEvent: tr.annotation(Transaction.userEvent)! }),
  };
});

/**
 * A deletion key at a fold's edge (Delete, ⌥⌦ or ⌃K before the `⋯`, Backspace or ⌥⌫ at the start
 * of the line after the fold, ⇧⌘K on a folded line) would change hidden text or merge the next
 * line into it: the key unfolds the folds it reaches instead and deletes nothing, so the next
 * press acts on visible text (M6-R76). ⌃K before the `⋯` would delete the whole hidden section
 * (the folded row is one visual line): it unfolds too. Deleting a selection that covers a whole
 * fold (a selection across the `⋯`) goes ahead. Cut is left alone.
 */
const deleteUnfoldsFold = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || !tr.isUserEvent("delete") || tr.isUserEvent("delete.cut")) return tr;
  const folds = tr.startState.field(foldState, false);
  if (!folds || folds.size === 0) return tr;
  const effects: StateEffect<FoldRange>[] = [];
  const selected = (a: number, b: number) => tr.startState.selection.ranges.some((r) => !r.empty && r.from <= a && r.to >= b);
  tr.changes.iterChangedRanges((a, b) => {
    if (a === b) return;
    folds.between(a, b, (from, to) => {
      const covers = a <= from && b >= to;
      const reaches = (a < to && b > from) || (a === to && b > to);
      if (reaches && !(covers && selected(a, b)) && !effects.some((e) => e.value.from === from && e.value.to === to)) {
        effects.push(unfoldEffect.of({ from, to }));
      }
    });
  });
  return effects.length ? { effects, scrollIntoView: true } : tr;
});

/**
 * Enter with the caret at either edge of a folded row (before the `⋯` or right after it): the new
 * line goes after the fold's end, so the hidden lines stay with their heading or item and the fold
 * stays on its line. A folded list item continues the list (a sibling, as Enter would); anything
 * else gets a plain new line (M6-R28).
 */
const enterOnFoldedRow = (view: EditorView): boolean => {
  if (view.composing || completionStatus(view.state) === "active") return false;
  const tr = enterAfterFold(view.state);
  if (!tr) return false;
  view.dispatch(tr);
  return true;
};

/** The Enter transaction for a caret at an edge of a folded row, else null (`enterOnFoldedRow`). */
export function enterAfterFold(state: EditorState): Transaction | null {
  if (state.readOnly || state.selection.ranges.length !== 1 || !state.selection.main.empty) return null;
  const head = state.selection.main.head;
  let fold: FoldRange | null = null;
  foldedRanges(state).between(head, head, (from, to) => {
    if ((from === head || to === head) && (!fold || from < fold.from)) fold = { from, to };
  });
  if (!fold) return null;
  const { from, to } = fold as FoldRange;
  return (
    newItemAfterBlock(state, state.doc.lineAt(from).number, to) ??
    state.update({ changes: { from: to, insert: "\n" }, selection: { anchor: to + 1 }, scrollIntoView: true, userEvent: "input" })
  );
}

type Target = { state: EditorState; dispatch: (tr: ReturnType<EditorState["update"]>) => void };

function run(target: Target, spec: TransactionSpec | null): boolean {
  if (!spec) return false;
  target.dispatch(target.state.update(spec));
  return true;
}

/** The nearest foldable line around line `n`: an enclosing list item, then the section heading. */
function enclosingFoldLine(state: EditorState, n: number): number | null {
  const { doc } = state;
  const tree = treeOf(state);
  const line = doc.line(n);
  const covers = (first: number) => {
    const range = foldRangeAt(state, first);
    return range !== null && range.from < line.from && range.to >= line.to;
  };
  for (let node: ReturnType<Tree["resolveInner"]> | null = tree.resolveInner(line.to, -1); node; node = node.parent) {
    if (node.name !== "ListItem") continue;
    const first = doc.lineAt(node.from).number;
    if (first < n && covers(first)) return first;
  }
  const above: HeadingAt[] = [];
  walkHeadings(state, tree, 0, (h) => {
    if (h.line >= n) return false;
    above.push(h);
    return true;
  }, line.from - 1);
  // The nearest section that holds line `n`, its trailing blank lines included.
  for (let i = above.length - 1; i >= 0; i--) {
    const h = above[i]!;
    if (n <= sectionLast(state, tree, h) && foldRangeAt(state, h.line)) return h.line;
  }
  return null;
}

/**
 * ⌘' (registry `toggleFold`): toggles the caret line, or the heading line of a heading menu
 * (`menuId`). A caret line that cannot fold toggles the nearest enclosing foldable line (the
 * parent list item, then the section heading). Works in read-only notes.
 */
export function toggleFoldCommand(target: Target, args?: Record<string, unknown>): boolean {
  const { state } = target;
  if (!installed(state)) return false;
  const at = resolveMenuTarget(state, args);
  if (at.kind === "dead") return false;
  const n = at.kind === "target" ? state.doc.lineAt(at.pos).number : caretRowLine(state);
  if (isFolded(state, n)) return run(target, foldLineSpec(state, n, false));
  if (at.kind === "target" || foldRangeAt(state, n)) return run(target, foldLineSpec(state, n, true));
  const outer = enclosingFoldLine(state, n);
  return outer !== null && run(target, foldLineSpec(state, outer, !isFolded(state, outer)));
}

/**
 * The line whose row the caret is on: a caret right after a `⋯` (at a fold's end, on the last
 * folded line) is on the row of the folded line.
 */
function caretRowLine(state: EditorState): number {
  const head = state.selection.main.head;
  let from = head;
  foldedRanges(state).between(head, head, (a, b) => {
    if (a < head && head <= b) from = Math.min(from, a);
  });
  return state.doc.lineAt(from).number;
}

/** Every indexed heading line, in order. */
function headingLines(state: EditorState): number[] {
  const lines: number[] = [];
  walkHeadings(state, treeOf(state), 0, (h) => {
    lines.push(h.line);
    return true;
  });
  return lines;
}

/** Fold All (Headings): folds every heading that has a section. */
export function foldAllCommand(target: Target): boolean {
  const { state } = target;
  if (!installed(state)) return false;
  const ranges = headingLines(state)
    .filter((n) => !isFolded(state, n))
    .flatMap((n) => foldRangeAt(state, n) ?? []);
  return run(target, foldSpec(state, ranges));
}

/** Unfold All (Headings): unfolds every heading (folded list items stay folded). */
export function unfoldAllCommand(target: Target): boolean {
  const { state } = target;
  if (!installed(state)) return false;
  const effects = headingLines(state).flatMap((n) => foldsOn(state, n).map((f) => unfoldEffect.of(f)));
  return run(target, effects.length ? { effects } : null);
}

// ---------------------------------------------------------------------------------------------
// Persisted folds (bridge `FoldEntry`, M6 Task 8 posts and restores them)

/** Where the folds go when they change (the bridge client's `foldState`); none in tests and dev. */
export type FoldStateSink = (folds: FoldEntry[]) => void;
export const foldStateSink = Facet.define<FoldStateSink, FoldStateSink | null>({ combine: (values) => values[0] ?? null });

/** The folds the host stored for the loaded note (`loadNote.foldState`): the poster's baseline. */
export const storedFolds = Facet.define<readonly FoldEntry[], readonly FoldEntry[]>({ combine: (values) => values[0] ?? [] });

/** How long the folds must stay unchanged before they are posted. */
export const FOLD_POST_DELAY = 300;

const foldsKey = (folds: readonly FoldEntry[]) => JSON.stringify(folds.map((f) => [f.line, f.hash]));

/**
 * Posts `foldEntries` 300 ms after the folds last changed (a fold, an unfold, a document change
 * that maps them, a folded line's text changing), only when they differ from what the host has:
 * the stored folds the note was loaded with, then the last post. A load with stored folds checks
 * once, so a restore that drops or moves entries (or an unfold right after it) is written back.
 * Loading a note recreates the plugin; a post still pending then is dropped, as the host would
 * ignore it for the note it no longer shows.
 */
const foldStatePoster = ViewPlugin.fromClass(
  class {
    timer: ReturnType<typeof setTimeout> | null = null;
    posted: string;
    constructor(readonly view: EditorView) {
      this.posted = foldsKey(view.state.facet(storedFolds));
      if (this.posted !== "[]") this.schedule();
    }
    update(update: ViewUpdate) {
      if (update.startState.field(foldState, false) === update.state.field(foldState, false)) return;
      if (this.timer === null && foldedRanges(update.state).size === 0 && this.posted === "[]") return;
      this.schedule();
    }
    schedule() {
      if (!this.view.state.facet(foldStateSink)) return;
      if (this.timer !== null) clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        this.timer = null;
        const sink = this.view.state.facet(foldStateSink);
        const folds = foldEntries(this.view.state);
        const key = foldsKey(folds);
        if (!sink || key === this.posted) return;
        this.posted = key;
        sink(folds);
      }, FOLD_POST_DELAY);
    }
    destroy() {
      if (this.timer !== null) clearTimeout(this.timer);
    }
  },
);

/** The folds of `state` as entries (first line and its hash), at most `MAX_FOLDS`. */
export function foldEntries(state: EditorState): FoldEntry[] {
  const starts = new Set<number>();
  // Nested folds come in no particular order.
  foldedRanges(state).between(0, state.doc.length, (from) => {
    starts.add(state.doc.lineAt(from).number);
  });
  return [...starts]
    .sort((a, b) => a - b)
    .slice(0, MAX_FOLDS)
    .map((n) => ({ line: n, hash: lineHash(state.doc.line(n).text) }));
}

/** How far a stored fold may have moved (lines inserted or removed above it while closed). */
const RESTORE_WINDOW = 50;

/**
 * The transaction that folds the lines of `entries`: an entry applies when line `line` still has
 * `hash` and folds; otherwise the nearest line within ±50 lines with that hash that folds; otherwise
 * it is dropped. A fold that would hide the caret is dropped too (the restored selection wins).
 */
export function applyFoldEntries(state: EditorState, entries: FoldEntry[]): TransactionSpec | null {
  if (!installed(state)) return null;
  const { doc } = state;
  const main = state.selection.main;
  const taken = new Set<number>();
  const ranges: FoldRange[] = [];
  // Each line is hashed once, however many entries search the window around it.
  const hashes = new Map<number, string>();
  const hashOf = (n: number) => {
    let hash = hashes.get(n);
    if (hash === undefined) hashes.set(n, (hash = lineHash(doc.line(n).text)));
    return hash;
  };
  const fits = (n: number, hash: string) => {
    if (n < 1 || n > doc.lines || taken.has(n) || hashOf(n) !== hash) return null;
    const range = foldRangeAt(state, n);
    return range && !isFolded(state, n) ? range : null;
  };
  for (const entry of entries.slice(0, MAX_FOLDS)) {
    if (!entry || !Number.isInteger(entry.line) || typeof entry.hash !== "string") continue;
    let found: { n: number; range: FoldRange } | null = null;
    for (let d = 0; d <= RESTORE_WINDOW && !found; d++) {
      for (const n of d === 0 ? [entry.line] : [entry.line - d, entry.line + d]) {
        const range = fits(n, entry.hash);
        if (range) {
          found = { n, range };
          break;
        }
      }
    }
    if (!found || hides(main, found.range)) continue;
    taken.add(found.n);
    ranges.push(found.range);
  }
  return ranges.length ? { effects: ranges.map((range) => foldEffect.of(range)) } : null;
}

// ---------------------------------------------------------------------------------------------
// Placeholder

const foldedLineCount = (state: EditorState, range: FoldRange) =>
  state.doc.lineAt(range.to).number - state.doc.lineAt(range.from).number;

function placeholder(_view: EditorView, onclick: (event: Event) => void, lines: number): HTMLElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "cm-foldPlaceholder cm-bc-fold-placeholder";
  button.tabIndex = -1;
  button.textContent = "⋯";
  button.setAttribute("aria-label", `${lines} folded line${lines === 1 ? "" : "s"}`);
  // Keep the caret and the focus where they are; the click unfolds.
  button.addEventListener("mousedown", (event) => event.preventDefault());
  button.addEventListener("click", onclick);
  return button;
}

// ---------------------------------------------------------------------------------------------
// Side Actions: the fold gutter

/** The line the pointer is over (a chevron shows there when it can fold), else null. */
const setHoverLine = StateEffect.define<number | null>();

const hoverLine = StateField.define<number | null>({
  create: () => null,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setHoverLine)) return e.value;
    return tr.docChanged ? null : value;
  },
});

export class FoldChevron extends GutterMarker {
  constructor(
    readonly folded: boolean,
    /** The heading level of the line (its box lines up like the heading badge), 0 for a list item. */
    readonly level: number,
  ) {
    super();
  }

  override eq(other: FoldChevron) {
    return other.folded === this.folded && other.level === this.level;
  }

  override toDOM() {
    const el = document.createElement("div");
    el.className = `cm-bc-fold-chevron${this.folded ? " cm-bc-folded" : ""}${this.level ? ` cm-bc-fold-heading cm-bc-fold-h${this.level}` : ""}`;
    el.setAttribute("role", "button");
    el.setAttribute("aria-expanded", String(!this.folded));
    el.setAttribute("aria-label", this.folded ? "Unfold" : "Fold");
    return el;
  }
}

const chevrons = new Map<string, FoldChevron>();
const chevron = (folded: boolean, level: number) => {
  const key = `${folded}:${level}`;
  let marker = chevrons.get(key);
  if (!marker) chevrons.set(key, (marker = new FoldChevron(folded, level)));
  return marker;
};

/** The chevrons of the visible lines: folded lines, and the hovered line when it can fold. */
export function chevronMarkers(
  state: EditorState,
  visible: readonly { from: number; to: number }[],
  hover: number | null,
): RangeSet<FoldChevron> {
  const { doc } = state;
  const tree = syntaxTree(state);
  const levelOf = (n: number) => headingOn(state, tree, n)?.level ?? 0;
  const out: Ranged<FoldChevron>[] = [];
  const seen = new Set<number>();
  for (const span of visible) {
    foldedRanges(state).between(span.from, span.to, (from) => {
      if (from < span.from || from > span.to) return;
      const line = doc.lineAt(from);
      if (seen.has(line.number)) return;
      seen.add(line.number);
      out.push(chevron(true, levelOf(line.number)).range(line.from));
    });
  }
  if (hover !== null && hover >= 1 && hover <= doc.lines && !seen.has(hover)) {
    const line = doc.line(hover);
    if (visible.some((s) => line.from >= s.from && line.from <= s.to) && foldRangeAt(state, hover)) {
      out.push(chevron(false, levelOf(hover)).range(line.from));
    }
  }
  return RangeSet.of(out, true);
}

const chevronPlugin = ViewPlugin.fromClass(
  class {
    markers: RangeSet<FoldChevron>;

    constructor(view: EditorView) {
      this.markers = chevronMarkers(view.state, view.visibleRanges, view.state.field(hoverLine));
    }

    update(update: ViewUpdate) {
      const { state, startState } = update;
      const changed =
        update.docChanged ||
        update.viewportChanged ||
        state.field(foldState, false) !== startState.field(foldState, false) ||
        state.field(hoverLine) !== startState.field(hoverLine);
      if (!changed) return;
      // Nothing is rebuilt during an IME composition (the gutter catches up afterwards).
      if (update.view.composing) this.markers = this.markers.map(update.changes);
      else this.markers = chevronMarkers(state, update.view.visibleRanges, state.field(hoverLine));
    }
  },
);

const TYPING_CLASS = "cm-bc-fold-typing";

/** Hover tracking and the typing state (chevrons hide on keydown until the pointer moves). */
const pointerTracking = ViewPlugin.define((view) => {
  const scroller = view.scrollDOM;
  let last: { x: number; y: number } | null = null;
  const move = (event: MouseEvent) => {
    // WebKit sends a mousemove without movement when the page scrolls under a resting pointer
    // (typewriter mode while typing): that is not the pointer coming back.
    if (last && last.x === event.screenX && last.y === event.screenY) return;
    last = { x: event.screenX, y: event.screenY };
    scroller.classList.remove(TYPING_CLASS);
    if (view.composing) return;
    const y = event.clientY - view.documentTop;
    const block = view.lineBlockAtHeight(y);
    // Not over a line: the padding above the first one or the over-scroll below the last.
    const n = y >= block.top && y <= block.bottom ? view.state.doc.lineAt(block.from).number : null;
    if (n !== view.state.field(hoverLine)) view.dispatch({ effects: setHoverLine.of(n) });
  };
  const leave = () => {
    if (view.state.field(hoverLine) !== null && !view.composing) view.dispatch({ effects: setHoverLine.of(null) });
  };
  const keydown = (event: KeyboardEvent) => {
    // Shortcuts (⌘', ⌘G…) are not typing.
    if (!event.metaKey && !event.ctrlKey) scroller.classList.add(TYPING_CLASS);
  };
  scroller.addEventListener("mousemove", move);
  scroller.addEventListener("mouseleave", leave);
  view.dom.addEventListener("keydown", keydown);
  return {
    destroy() {
      scroller.removeEventListener("mousemove", move);
      scroller.removeEventListener("mouseleave", leave);
      view.dom.removeEventListener("keydown", keydown);
    },
  };
});

const chevronAt = (event: Event) =>
  event.target instanceof Element ? event.target.closest<HTMLElement>(".cm-bc-fold-chevron") : null;

/** The fold gutter. typography.ts places it left of the heading gutter. */
export const foldChevronGutter: Extension = [
  chevronPlugin,
  gutter({
    class: "cm-bc-fold-gutter",
    markers: (view) => view.plugin(chevronPlugin)?.markers ?? RangeSet.empty,
    domEventHandlers: {
      // Keep the caret and focus where they are.
      mousedown(_view, _line, event) {
        if (!chevronAt(event)) return false;
        event.preventDefault();
        return true;
      },
      click(view, line, event) {
        const el = chevronAt(event);
        if (!el) return false;
        const n = view.state.doc.lineAt(line.from).number;
        foldLine(view, n, !el.classList.contains("cm-bc-folded"));
        return true;
      },
    },
  }),
];

const foldingTheme = EditorView.theme({
  ".cm-bc-fold-gutter": { width: "var(--bc-fold-gutter-width)", flexShrink: "0" },
  ".cm-bc-fold-chevron": {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    height: "calc(var(--bc-line-height) * 1em)",
    color: "var(--bc-color-secondary)",
    cursor: "pointer",
  },
  // In em of the text size (not the heading's), so the glyph scales with the font size setting.
  ".cm-bc-fold-chevron::before": {
    content: '""',
    fontSize: "var(--bc-size)",
    width: "0.32em",
    height: "0.32em",
    borderRight: "0.095em solid currentColor",
    borderBottom: "0.095em solid currentColor",
    transform: "translateY(-0.12em) rotate(45deg)",
  },
  ".cm-bc-fold-chevron.cm-bc-folded::before": { transform: "rotate(-45deg)" },
  ".cm-bc-fold-chevron:hover": { color: "var(--bc-color-accent)" },
  [`.${TYPING_CLASS} .cm-bc-fold-chevron`]: { visibility: "hidden" },
  ".cm-bc-fold-placeholder": {
    font: "inherit",
    lineHeight: "1",
    margin: "0 0 0 0.3em",
    padding: "0 0.35em",
    border: "none",
    borderRadius: "4px",
    color: "var(--bc-color-secondary)",
    backgroundColor: "var(--bc-color-tag-bg)",
    cursor: "pointer",
  },
  ".cm-bc-fold-placeholder:hover": { color: "var(--bc-color-accent)" },
});

export const folding: Extension = [
  codeFolding({ preparePlaceholder: foldedLineCount, placeholderDOM: placeholder }),
  revealSelection,
  inputBeforePlaceholder,
  deleteUnfoldsFold,
  caretOffFoldEnd,
  // Before the smart-list keys (Prec.high: Enter, ArrowRight over indentation) and the defaults.
  Prec.highest(
    keymap.of([
      { key: "Enter", run: enterOnFoldedRow },
      { key: "ArrowRight", run: overFold(true, false), shift: overFold(true, true) },
      { key: "ArrowLeft", shift: overFold(false, true) },
      { mac: "Ctrl-f", run: overFold(true, false) },
    ]),
  ),
  hoverLine,
  foldChevronGutter,
  pointerTracking,
  foldStatePoster,
  foldingTheme,
];
