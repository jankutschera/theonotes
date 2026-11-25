// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Footnotes (M6 Task 13): `[^label]` references and `[^label]:` definitions at a line start,
// outside code, math and comments. References render as superscript labels (their `[^` and `]`
// are hidden by hiding.ts unless the caret is inside); definitions get a dimmed label. A click on
// a rendered label moves the caret to its counterpart. Renaming a label in one edit renames its
// single counterpart in the same transaction (one undo step, M6-R41).

import { EditorSelection, EditorState, type Extension, type Line, type Range as Ranged } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { hidingUpdatePlan } from "./hiding";
import { codeAt, lineInCode } from "./lists";

type Range = { from: number; to: number };

export type Footnote = {
  kind: "ref" | "def";
  label: string;
  /** The whole `[^label]` (a definition's colon is not part of it). */
  from: number;
  to: number;
  labelFrom: number;
  labelTo: number;
};

const FOOTNOTE = /\[\^([^\]\s]+)\]/g;
/**
 * Link markup a `[^label]` can be part of (`[^1](url)`, `[[^1]]`). lezer parses a bare `[^1]` as a
 * reference-style `Link` of exactly its own extent: that one is the footnote.
 */
const LINKS = new Set(["Link", "Image", "WikiLink"]);

type Tree = ReturnType<typeof syntaxTree>;

function footnotesOnLine(state: EditorState, tree: Tree, line: Line, out: Footnote[]): void {
  if (!line.text.includes("[^") || lineInCode(state, line, tree)) return;
  for (const m of line.text.matchAll(FOOTNOTE)) {
    const from = line.from + m.index;
    const to = from + m[0].length;
    if (codeAt(tree, from + 1)) continue;
    let inLink = false;
    for (let n: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(from + 1, 1); n; n = n.parent) {
      if (LINKS.has(n.name) && (n.name === "WikiLink" || n.from < from || n.to > to)) inLink = true;
    }
    if (inLink) continue;
    const label = m[1]!;
    const kind = m.index === 0 && line.text[m[0].length] === ":" ? "def" : "ref";
    out.push({ kind, label, from, to, labelFrom: from + 2, labelTo: to - 1 });
  }
}

/**
 * The footnotes on the lines of `within` (default: the whole document), in document order. `tree`:
 * a tree the caller parsed far enough (default: the state's current one).
 */
export function footnotesIn(state: EditorState, within?: readonly Range[], tree: Tree = syntaxTree(state)): Footnote[] {
  const { doc } = state;
  const out: Footnote[] = [];
  let next = 1;
  for (const span of within ?? [{ from: 0, to: doc.length }]) {
    const first = Math.max(next, doc.lineAt(span.from).number);
    const last = doc.lineAt(span.to).number;
    for (let n = first; n <= last; n++) footnotesOnLine(state, tree, doc.line(n), out);
    next = Math.max(next, last + 1);
  }
  return out;
}

const at = (notes: readonly Footnote[], pos: number) => notes.find((f) => f.from <= pos && pos <= f.to) ?? null;

/**
 * Where a click on the footnote at `pos` goes: a reference to its definition's text, a definition
 * to just after its first reference. Null when `pos` is on no footnote or it has no counterpart.
 */
export function footnoteTarget(state: EditorState, pos: number): number | null {
  const notes = footnotesIn(state);
  const note = at(notes, pos);
  if (!note) return null;
  if (note.kind === "ref") {
    const def = notes.find((f) => f.kind === "def" && f.label === note.label);
    if (!def) return null;
    const textFrom = def.to + 1;
    return state.doc.sliceString(textFrom, textFrom + 1) === " " ? textFrom + 1 : textFrom;
  }
  return notes.find((f) => f.kind === "ref" && f.label === note.label)?.to ?? null;
}

// ---------------------------------------------------------------------------------------------
// Label rename

/**
 * A user edit confined to one footnote's label carries over to the label's only other use (the
 * old label occurs exactly twice, a reference and a definition) when the new label is unused.
 * Anything else (several labels, a shared footnote, a taken label, read-only, undo/redo, host
 * changes) leaves the transaction alone.
 */
const renameCounterpart = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || tr.startState.readOnly || !(tr.isUserEvent("input") || tr.isUserEvent("delete"))) return tr;
  const start = tr.startState;
  // Cheap gate: every change sits on one line with a `[^`.
  let line: Line | null = null;
  let oneLine = true;
  tr.changes.iterChangedRanges((fromA, toA) => {
    const l = start.doc.lineAt(fromA);
    if (toA > l.to || (line && line.number !== l.number)) oneLine = false;
    line = l;
  });
  if (!oneLine || !line || !(line as Line).text.includes("[^")) return tr;

  const onLine = footnotesIn(start, [line as Line]);
  let edited: Footnote | null = null;
  let confined = true;
  tr.changes.iterChangedRanges((fromA, toA) => {
    const f = onLine.find((n) => n.labelFrom <= fromA && toA <= n.labelTo) ?? null;
    if (!f || (edited && edited !== f)) confined = false;
    edited = f;
  });
  const old = edited as Footnote | null;
  if (!confined || !old) return tr;
  // Only now the whole note: who else uses the label.
  const uses = footnotesIn(start).filter((f) => f.label === old.label);
  const counterpart = uses.find((f) => f.from !== old.from);
  if (uses.length !== 2 || !counterpart || counterpart.kind === old.kind) return tr;

  const after = footnotesIn(tr.state, [{ from: tr.changes.mapPos(old.from, -1), to: tr.changes.mapPos(old.to, 1) }]);
  const renamed = after.find((f) => f.from === tr.changes.mapPos(old.from, -1) && f.kind === old.kind);
  if (!renamed || renamed.label === old.label) return tr;
  if (footnotesIn(tr.state).some((f) => f.label === renamed.label && f.from !== renamed.from)) return tr;
  const from = tr.changes.mapPos(counterpart.labelFrom);
  const to = tr.changes.mapPos(counterpart.labelTo);
  return [tr, { changes: { from, to, insert: renamed.label }, sequential: true }];
});

// ---------------------------------------------------------------------------------------------
// Presentation and clicks

const refMark = Decoration.mark({ class: "cm-bc-footnote-ref" });
const defMark = Decoration.mark({ class: "cm-bc-footnote-def" });

function footnoteDecorations(view: EditorView): DecorationSet {
  const ranges: Ranged<Decoration>[] = [];
  for (const f of footnotesIn(view.state, view.visibleRanges)) {
    ranges.push(f.kind === "ref" ? refMark.range(f.labelFrom, f.labelTo) : defMark.range(f.from, f.to));
  }
  return Decoration.set(ranges, true);
}

const footnoteMarks = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    stale = false;
    constructor(view: EditorView) {
      this.decorations = footnoteDecorations(view);
    }
    update(update: ViewUpdate) {
      const changed = update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state);
      // Never rebuilt while composing (global constraint): kept aligned, rebuilt afterwards.
      const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
      if (plan === "rebuild") {
        this.decorations = footnoteDecorations(update.view);
        this.stale = false;
        return;
      }
      if (update.docChanged) this.decorations = this.decorations.map(update.changes);
      if (plan === "map") this.stale ||= changed;
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

/**
 * A plain click on a rendered label jumps to its counterpart. A label the selection touches is
 * revealed markup (hiding.ts, inclusive ends, every range): a click there places the caret.
 * Not in a locked editor, nor during a composition.
 */
const footnoteClick = EditorView.domEventHandlers({
  mousedown(event, view) {
    if (event.button !== 0 || event.shiftKey || event.metaKey || event.altKey || event.ctrlKey) return false;
    if (!view.state.facet(EditorView.editable) || view.composing || view.compositionStarted) return false;
    const el = (event.target as Element | null)?.closest?.(".cm-bc-footnote-ref, .cm-bc-footnote-def");
    if (!el) return false;
    const pos = view.posAtDOM(el);
    const note = at(footnotesIn(view.state, [{ from: pos, to: pos }]), pos);
    if (!note) return false;
    if (view.state.selection.ranges.some((r) => r.from <= note.to && r.to >= note.from)) return false;
    const target = footnoteTarget(view.state, pos);
    if (target === null) return false;
    event.preventDefault();
    view.dispatch({
      selection: EditorSelection.cursor(target),
      effects: EditorView.scrollIntoView(target, { y: "center" }),
      userEvent: "select.footnote",
    });
    view.focus();
    return true;
  },
});

const footnoteTheme = EditorView.baseTheme({
  ".cm-bc-footnote-ref": {
    verticalAlign: "super",
    fontSize: "0.75em",
    lineHeight: "1",
    color: "var(--bc-color-accent)",
    cursor: "pointer",
  },
  ".cm-bc-footnote-def": { color: "var(--bc-color-secondary)", cursor: "pointer" },
});

export const footnotes: Extension = [renameCounterpart, footnoteMarks, footnoteClick, footnoteTheme];
