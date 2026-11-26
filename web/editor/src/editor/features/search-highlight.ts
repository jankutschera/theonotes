// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
// Note-list search highlight (bridge `searchHighlight`, M4 Task 3): a note opened from the search
// shows every match of the search's terms and scrolls to the first; Edit ▸ Find ▸ Find Next /
// Find Previous (⌘G / ⇧⌘G, native menu → `applyCommand` findNext / findPrevious) step through
// them. Neither moves the selection: the "current" match is a marker of this module, so typing
// after opening a result never replaces a match. The in-note find/replace panel is M3 Task 10's.
//
// Matching is TheoNotesCore `SearchOffsets` (Fixtures/search/fold.json pins both): per character
// (grapheme cluster), folded like Foundation's caseInsensitive + diacriticInsensitive, substring
// anywhere, overlapping matches merged. Editor only: a `#tag` term needs a tag boundary.

import { type EditorState, type Extension, RangeSetBuilder, StateEffect, StateField, type Text, type Transaction, type TransactionSpec } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { blockRevealers } from "./blocks";
import { revealEffects } from "./folding";
import { hidingUpdatePlan } from "./hiding";

export type MatchRange = { from: number; to: number };

// ---------------------------------------------------------------------------------------------
// Folding

const latinGreekCyrillic = /[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}]/u;
const marks = /\p{M}/gu;
const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * One character folded like Foundation `folding(options: [.caseInsensitive, .diacriticInsensitive])`
 * (measured, see Fixtures/search/fold.json): marks are dropped from Latin, Greek and Cyrillic
 * letters only (kana voicing, Hangul, Indic, Arabic, Hebrew, Thai and emoji stay as they are, and
 * nothing is normalized there); case folds fully (`ß` → `ss`, `ﬁ` → `fi`) except dotless `ı`.
 */
export function foldCharacter(ch: string): string {
  const code = ch.charCodeAt(0);
  if (ch.length === 1 && code < 0x80) return code >= 65 && code <= 90 ? String.fromCharCode(code + 32) : ch;
  if (ch === "ı") return ch;
  let s = ch;
  const decomposed = ch.normalize("NFD");
  if (latinGreekCyrillic.test(String.fromCodePoint(decomposed.codePointAt(0)!))) {
    const stripped = decomposed.replace(marks, "");
    if (stripped !== "") s = stripped.normalize("NFC");
  }
  return s.toLowerCase().toUpperCase().toLowerCase();
}

/** `text` folded, with the source range (UTF-16) of the character each folded code unit came from. */
function foldWithOrigins(text: string): { folded: string; from: number[]; to: number[] } | { folded: string; ascii: true } {
  if (!/[^\x00-\x7f]/.test(text)) return { folded: text.toLowerCase(), ascii: true };
  let folded = "";
  const from: number[] = [];
  const to: number[] = [];
  for (const { segment, index } of segmenter.segment(text)) {
    const f = foldCharacter(segment);
    for (let k = 0; k < f.length; k++) {
      from.push(index);
      to.push(index + segment.length);
    }
    folded += f;
  }
  return { folded, from, to };
}

type Needle = { folded: string; tag: boolean };

function needlesFor(terms: readonly string[]): Needle[] {
  const out: Needle[] = [];
  for (const term of terms) {
    const trimmed = term.trim();
    const folded = foldWithOrigins(trimmed).folded;
    if (folded !== "" && !out.some((n) => n.folded === folded)) out.push({ folded, tag: trimmed.startsWith("#") });
  }
  return out;
}

const tagChar = /[\p{L}\p{N}\p{M}_-]/u;

/** Matches in one line (offsets relative to it), merged where they overlap. */
function lineMatches(line: string, needles: readonly Needle[]): MatchRange[] {
  const f = foldWithOrigins(line);
  const ranges: MatchRange[] = [];
  for (const needle of needles) {
    for (let i = f.folded.indexOf(needle.folded); i !== -1; i = f.folded.indexOf(needle.folded, i + 1)) {
      const end = i + needle.folded.length - 1;
      const range = "ascii" in f ? { from: i, to: end + 1 } : { from: f.from[i]!, to: f.to[end]! };
      if (needle.tag) {
        const after = [...line.slice(range.to, range.to + 2)][0];
        const before = [...line.slice(Math.max(0, range.from - 2), range.from)].at(-1);
        if ((after !== undefined && tagChar.test(after)) || (before !== undefined && tagChar.test(before))) continue;
      }
      ranges.push(range);
    }
  }
  ranges.sort((a, b) => a.from - b.from);
  const merged: MatchRange[] = [];
  for (const r of ranges) {
    const last = merged.at(-1);
    if (last && r.from < last.to) last.to = Math.max(last.to, r.to);
    else merged.push({ ...r });
  }
  return merged;
}

function* matchesFrom(doc: Text, needles: readonly Needle[], fromLine: number, toLine: number): Generator<MatchRange> {
  for (let n = fromLine; n <= toLine; n++) {
    const line = doc.line(n);
    for (const r of lineMatches(line.text, needles)) yield { from: line.from + r.from, to: line.from + r.to };
  }
}

/** All matches of `terms` in `doc` within `from..to`, in order. */
export function searchHighlightMatches(doc: Text, terms: readonly string[], from = 0, to = doc.length): MatchRange[] {
  return rangeMatches(doc, needlesFor(terms), from, to);
}

function rangeMatches(doc: Text, needles: readonly Needle[], from: number, to: number): MatchRange[] {
  if (needles.length === 0) return [];
  const out: MatchRange[] = [];
  for (const m of matchesFrom(doc, needles, doc.lineAt(from).number, doc.lineAt(to).number)) {
    if (m.to > from && m.from < to) out.push(m);
  }
  return out;
}

const wordChar = /[\p{L}\p{N}]/u;

/** Where a result opens: the first match that starts a word (`art` in "start art"), else the first. */
function firstMatch(doc: Text, needles: readonly Needle[]): MatchRange | null {
  let first: MatchRange | null = null;
  for (const m of matchesFrom(doc, needles, 1, doc.lines)) {
    first ??= m;
    const before = [...doc.sliceString(Math.max(0, m.from - 2), m.from)].at(-1);
    if (before === undefined || !wordChar.test(before)) return m;
  }
  return first;
}

// ---------------------------------------------------------------------------------------------
// State

type Highlight = { needles: Needle[]; current: MatchRange | null };

const setHighlight = StateEffect.define<Highlight | null>();
const setCurrent = StateEffect.define<MatchRange>();

const highlightField = StateField.define<Highlight | null>({
  create: () => null,
  update(value, tr) {
    if (value?.current && tr.docChanged) {
      const from = tr.changes.mapPos(value.current.from, 1);
      const to = tr.changes.mapPos(value.current.to, -1);
      value = { ...value, current: to > from ? { from, to } : null };
    }
    for (const effect of tr.effects) {
      if (effect.is(setHighlight)) value = effect.value;
      else if (effect.is(setCurrent) && value) value = { ...value, current: effect.value };
    }
    return value;
  },
});

export function isSearchHighlightActive(state: EditorState): boolean {
  return state.field(highlightField, false) != null;
}

export function currentMatch(state: EditorState): MatchRange | null {
  return state.field(highlightField, false)?.current ?? null;
}

/**
 * The host's `searchHighlight`: shows the matches of `terms`, marks the first (word-start) one as
 * current and centers it (unfolding the folds it is in). Empty `terms` clear. Never changes the
 * document or the selection.
 */
export function searchHighlightTransaction(state: EditorState, terms: readonly string[]): TransactionSpec {
  const needles = needlesFor(terms);
  if (needles.length === 0) return { effects: setHighlight.of(null) };
  const first = firstMatch(state.doc, needles);
  return {
    effects: [setHighlight.of({ needles, current: first }), ...(first ? scrollToMatch(state, first) : [])],
  };
}

/** Centers a match; a match inside a fold unfolds it first (a rendered block shows its source, `blockRevealers`). */
const scrollToMatch = (state: EditorState, match: MatchRange) => [
  ...revealEffects(state, match.from, match.to),
  EditorView.scrollIntoView(match.from, { y: "center" }),
];

/** The next (`1`) or previous (`-1`) match from the current one (else from the caret), wrapping. */
export function stepSearchHighlight(state: EditorState, direction: 1 | -1): MatchRange | null {
  const highlight = state.field(highlightField, false);
  if (!highlight) return null;
  const { doc } = state;
  const head = state.selection.main.head;
  const at = highlight.current ?? { from: head, to: head };
  if (direction === 1) {
    for (const m of matchesFrom(doc, highlight.needles, doc.lineAt(at.to).number, doc.lines)) if (m.from >= at.to) return m;
    for (const m of matchesFrom(doc, highlight.needles, 1, doc.lines)) return m;
    return null;
  }
  for (let n = doc.lineAt(at.from).number; n >= 1; n--) {
    const before = [...matchesFrom(doc, highlight.needles, n, n)].filter((m) => m.to <= at.from);
    if (before.length) return before.at(-1)!;
  }
  for (let n = doc.lines; n >= 1; n--) {
    const all = [...matchesFrom(doc, highlight.needles, n, n)];
    if (all.length) return all.at(-1)!;
  }
  return null;
}

/** `findNext` / `findPrevious` (registry commands): move the current match and center it. */
export function stepCommand(direction: 1 | -1) {
  return (target: { state: EditorState; dispatch: (tr: Transaction) => void }): boolean => {
    const next = stepSearchHighlight(target.state, direction);
    if (!next) return false;
    target.dispatch(target.state.update({ effects: [setCurrent.of(next), ...scrollToMatch(target.state, next)] }));
    return true;
  };
}

// ---------------------------------------------------------------------------------------------
// Highlighting

const matchMark = Decoration.mark({ class: "cm-bc-searchMatch" });
const currentMark = Decoration.mark({ class: "cm-bc-searchMatch cm-bc-searchMatch-current" });
const visibleMargin = 250;

export type SearchHighlightViewLike = { state: EditorState; visibleRanges: readonly { from: number; to: number }[]; composing: boolean };
export type SearchHighlightUpdateLike = Pick<ViewUpdate, "state" | "startState" | "changes" | "docChanged" | "viewportChanged"> & {
  view: SearchHighlightViewLike;
};

function highlightDecorations(view: SearchHighlightViewLike): DecorationSet {
  const highlight = view.state.field(highlightField, false);
  if (!highlight) return Decoration.none;
  const { doc } = view.state;
  const builder = new RangeSetBuilder<Decoration>();
  const visible = view.visibleRanges;
  let last = -1;
  for (let i = 0; i < visible.length; i++) {
    const from = Math.max(0, visible[i]!.from - visibleMargin);
    let to = visible[i]!.to;
    while (i + 1 < visible.length && visible[i + 1]!.from - 2 * visibleMargin < to) to = visible[++i]!.to;
    for (const m of rangeMatches(doc, highlight.needles, from, Math.min(doc.length, to + visibleMargin))) {
      if (m.from < last) continue;
      const current = highlight.current?.from === m.from && highlight.current.to === m.to;
      builder.add(m.from, m.to, current ? currentMark : matchMark);
      last = m.to;
    }
  }
  return builder.finish();
}

/** The match marks of the visible text; never rebuilt while composing (only mapped). */
export class SearchHighlightState {
  decorations: DecorationSet;
  stale = false;

  constructor(view: SearchHighlightViewLike) {
    this.decorations = highlightDecorations(view);
  }

  update(update: SearchHighlightUpdateLike) {
    const changed =
      update.docChanged ||
      update.viewportChanged ||
      update.state.field(highlightField, false) !== update.startState.field(highlightField, false);
    // Never rebuilt while composing (global constraint): mapped, rebuilt once it ends.
    const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
    if (plan === "rebuild") {
      this.decorations = highlightDecorations(update.view);
      this.stale = false;
      return;
    }
    if (update.docChanged) this.decorations = this.decorations.map(update.changes);
    if (plan === "map") this.stale ||= changed;
  }
}

const highlighter = ViewPlugin.fromClass(
  class extends SearchHighlightState {
    constructor(view: EditorView) {
      super(view);
    }

    override update(update: ViewUpdate) {
      super.update(update);
    }
  },
  {
    decorations: (v) => v.decorations,
    eventHandlers: {
      compositionend(_event, view) {
        afterComposition(() => {
          if (this.stale && !view.composing) view.dispatch({});
        });
      },
    },
  },
);

const theme = EditorView.baseTheme({
  ".cm-bc-searchMatch": { backgroundColor: "var(--bc-color-search-match)", borderRadius: "2px" },
  // The current match also gets a ring in the accent (a non-colour cue; inset, so no layout shift).
  ".cm-bc-searchMatch-current": {
    backgroundColor: "var(--bc-color-search-match-current)",
    boxShadow: "inset 0 0 0 1.5px var(--bc-color-accent)",
  },
});

// The current match shows a rendered block's source (table grid, `$$` math, Mermaid),.
export const searchHighlight: Extension = [highlightField, highlighter, theme, blockRevealers.of(currentMatch)];
