// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  acceptCompletion,
  autocompletion,
  type Completion,
  type CompletionContext,
  type CompletionResult,
  closeCompletion,
  completionStatus,
  moveCompletionSelection,
  startCompletion,
} from "@codemirror/autocomplete";
import { EditorSelection, type EditorState, type Extension, Facet, type Line, Prec, RangeSetBuilder, StateEffect, type TransactionSpec } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, type KeyBinding, keymap, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import type { CompletionItem, CompletionKind } from "../../bridge/protocol";
import { canonicalKey, codePointAt, collapse, endsSingleWord, isSpace, opensTag, parseWikiLink, scanInline, tagName } from "../dialect-grammar";
import { hidingUpdatePlan } from "./hiding";
import { cssText } from "./typography";
import { codeAt, lineInCode } from "./lists";
import { languageCompletionSource } from "./codeblocks";

// Autocomplete (spec §4.4, inventory §2.2.2): `#` after a tag opener lists tags, `[[` note titles
// (a `/` after the title that note's headings, `[[/` this note's), `:` + two letters emoji. The
// host ranks everything (bridge `requestCompletions` → `completionResults`); the editor only
// finds the query, shows the list and inserts the choice. Nothing completes in code, math,
// comments or front matter, in read-only notes, with the `autocomplete` setting off, or while an
// IME composition is in progress (no popup, no accept). TagCons: tag completions and tag pills
// show the tag's icon (bridge `tagIcons`), an aria-hidden widget beside the text.

/** What the host answers completions with; the bridge client in the app and in mock mode. */
export interface CompletionBridge {
  /** The ranked items, or null when the answer is stale (a newer request), late or missing. */
  request(kind: CompletionKind, query: string, noteTitle?: string): Promise<readonly CompletionItem[] | null>;
  /** The `autocomplete` setting. */
  enabled(): boolean;
  /** Tag path key (canonicalKey) → TagCon symbol. */
  tagIcons(): ReadonlyMap<string, string>;
}

const NO_BRIDGE: CompletionBridge = {
  request: () => Promise.resolve(null),
  enabled: () => false,
  tagIcons: () => new Map(),
};

export const completionBridge = Facet.define<CompletionBridge, CompletionBridge>({
  combine: (values) => values[0] ?? NO_BRIDGE,
});

/** The tag icon map changed (dispatched by the bridge client): the icons are redrawn. */
export const tagIconsChanged = StateEffect.define<null>();

/**
 * A completion in progress: `query` is what the host matches, `from`…`to` what the choice replaces
 * (`#` / `:` included for tags and emoji; after `[[` or `[[Title/` for notes and headings).
 * `noteTitle` (headings): the link target, empty for `[[/`.
 */
export type CompletionQuery = { kind: CompletionKind; query: string; noteTitle?: string; from: number; to: number };

/** Code, math, a comment or front matter (the tree is parsed up to `pos` for at most 5 ms). */
function inCode(state: EditorState, pos: number, line: Line): boolean {
  const tree = ensureSyntaxTree(state, pos, 5) ?? syntaxTree(state);
  return lineInCode(state, line) || codeAt(tree, pos) !== null;
}

/** The completion the caret at `pos` is in, if any. */
export function completionQueryAt(state: EditorState, pos: number): CompletionQuery | null {
  if (state.readOnly) return null;
  const line = state.doc.lineAt(pos);
  const col = pos - line.from;
  if (inCode(state, pos, line)) return null;
  const before = line.text.slice(0, col);
  const mask = scanInline(before).mask;
  return wikiQuery(line, before, col, mask) ?? tagQuery(line, before, col, mask) ?? emojiQuery(line, before, col, mask);
}

/** The first `/` of a wiki link body that is not written `\/`, or -1. */
function headingSlash(body: string): number {
  for (let i = 0; i < body.length; i++) {
    if (body[i] === "\\" && body[i + 1] === "/") i++;
    else if (body[i] === "/") return i;
  }
  return -1;
}

const unescapeSlashes = (s: string) => s.replace(/\\\//g, "/");

/** Inside `[[…` before any `|`, `[` or `]`: note titles, or headings after the title's `/`. */
function wikiQuery(line: Line, before: string, col: number, mask: Uint8Array): CompletionQuery | null {
  const open = before.lastIndexOf("[[");
  if (open < 0 || mask[open]) return null;
  const body = before.slice(open + 2);
  if (/[[\]|]/.test(body)) return null;
  const slash = headingSlash(body);
  // A link closed on this line: the rest of the part being typed is replaced too.
  const closed = parseWikiLink(line.text, open) !== null;
  const stop = slash < 0 ? /[/|[\]]/ : /[|[\]]/;
  let end = col;
  if (closed) while (end < line.text.length && !stop.test(line.text[end]!)) end++;
  const to = line.from + end;
  if (slash < 0) return { kind: "note", query: unescapeSlashes(body), from: line.from + open + 2, to };
  return {
    kind: "heading",
    query: unescapeSlashes(body.slice(slash + 1)),
    noteTitle: collapse(unescapeSlashes(body.slice(0, slash))),
    from: line.from + open + 3 + slash,
    to,
  };
}

/** A character a single-word tag may contain (`/` separates nested tags). */
function inTagWord(s: string, i: number): boolean {
  const c = codePointAt(s, i);
  return c === 47 || !endsSingleWord(c);
}

/** The code point before `i` (surrogate pairs whole). */
function before16(s: string, i: number): number {
  const low = s.charCodeAt(i - 1);
  return low >= 0xdc00 && low <= 0xdfff && i >= 2 && s.charCodeAt(i - 2) >= 0xd800 && s.charCodeAt(i - 2) <= 0xdbff ? 2 : 1;
}

/** `#` + at least one character of a single-word tag, after a tag opener (TagScanner rules). */
function tagQuery(line: Line, before: string, col: number, mask: Uint8Array): CompletionQuery | null {
  let p = col;
  while (p > 0) {
    const width = before16(before, p);
    if (!inTagWord(before, p - width)) break;
    p -= width;
  }
  const hash = p - 1;
  if (hash < 0 || before[hash] !== "#" || p === col || !opensTag(before, mask, hash)) return null;
  for (let i = hash; i < col; i++) if (mask[i]) return null;
  let end = col;
  while (end < line.text.length && inTagWord(line.text, end)) end += codePointAt(line.text, end) > 0xffff ? 2 : 1;
  return { kind: "tag", query: before.slice(p), from: line.from + hash, to: line.from + end };
}

const EMOJI_WORD = /[\p{L}\p{N}_+-]/u;

/** `:` + two or more name characters (a letter first), at a line start or after a blank or `(`. */
function emojiQuery(line: Line, before: string, col: number, mask: Uint8Array): CompletionQuery | null {
  let p = col;
  while (p > 0) {
    const width = before16(before, p);
    if (!EMOJI_WORD.test(before.slice(p - width, p))) break;
    p -= width;
  }
  const colon = p - 1;
  const query = before.slice(p);
  if (colon < 0 || before[colon] !== ":" || mask[colon] || [...query].length < 2 || !/^\p{L}/u.test(query)) return null;
  if (colon > 0 && !(isSpace(before.charCodeAt(colon - 1)) || before[colon - 1] === "(")) return null;
  let end = col;
  while (end < line.text.length && EMOJI_WORD.test(line.text[end]!)) end++;
  return { kind: "emoji", query, from: line.from + colon, to: line.from + end };
}

// ---------------------------------------------------------------------------------------------
// Inserting a choice

const edit = (changes: { from: number; to: number; insert: string }, caret: number): TransactionSpec => ({
  changes,
  selection: EditorSelection.cursor(caret),
  userEvent: "input.complete",
  scrollIntoView: true,
});

/**
 * The edit for accepting `item` at `q`: tags reuse a following blank for the item's trailing
 * space; notes and headings get the closing `]]` when it is missing and leave the caret after the
 * link.
 */
export function completionEdit(state: EditorState, q: CompletionQuery, item: CompletionItem): TransactionSpec {
  const { doc } = state;
  if (q.kind === "tag" || q.kind === "emoji") {
    let insert = item.insert;
    const next = doc.sliceString(q.to, q.to + 1);
    if (insert.endsWith(" ") && (next === " " || next === "\t")) {
      insert = insert.slice(0, -1);
      return edit({ from: q.from, to: q.to, insert }, q.from + insert.length + 1);
    }
    return edit({ from: q.from, to: q.to, insert }, q.from + insert.length);
  }
  const line = doc.lineAt(q.from);
  const open = line.text.lastIndexOf("[[", q.from - line.from);
  const link = open >= 0 ? parseWikiLink(line.text, open) : null;
  const delta = item.insert.length - (q.to - q.from);
  if (link) return edit({ from: q.from, to: q.to, insert: item.insert }, line.from + link.end + delta);
  const insert = item.insert + "]]";
  return edit({ from: q.from, to: q.to, insert }, q.from + insert.length);
}

// ---------------------------------------------------------------------------------------------
// The source

type BearCompletion = Completion & { item: CompletionItem; kind: CompletionKind };

function applyItem(view: EditorView, completion: BearCompletion, from: number, to: number): void {
  const q = completionQueryAt(view.state, view.state.selection.main.head);
  const spec = q && q.kind === completion.kind
    ? completionEdit(view.state, q, completion.item)
    : edit({ from, to, insert: completion.item.insert }, from + completion.item.insert.length);
  view.dispatch(spec);
}

/** Asks the host for the completions at the caret; null while composing or with the setting off. */
export async function bearCompletionSource(context: CompletionContext): Promise<CompletionResult | null> {
  const bridge = context.state.facet(completionBridge);
  if (!bridge.enabled() || context.view?.composing) return null;
  const q = completionQueryAt(context.state, context.pos);
  if (!q) return null;
  const items = await bridge.request(q.kind, q.query, q.noteTitle);
  if (!items || items.length === 0 || context.aborted || context.view?.composing) return null;
  const options = items.map((item): BearCompletion => ({
    label: item.label,
    ...(item.detail !== undefined && { detail: item.detail }),
    item,
    kind: q.kind,
    apply: (view, completion, from, to) => applyItem(view, completion as BearCompletion, from, to),
  }));
  return { from: q.from, to: q.to, options, filter: false };
}

const notComposing = (run: (view: EditorView) => boolean) => (view: EditorView) => !view.composing && run(view);

/**
 * The popup's keys; none acts while an IME composition is in progress. Only Enter and Tab accept
 * (ruling R28, as in Bear): `/` and `|` are typed text, so `[[Title/` opens that title's headings.
 */
export const guardedCompletionKeymap: readonly KeyBinding[] = [
  { key: "ArrowDown", run: notComposing(moveCompletionSelection(true)) },
  { key: "ArrowUp", run: notComposing(moveCompletionSelection(false)) },
  { key: "PageDown", run: notComposing(moveCompletionSelection(true, "page")) },
  { key: "PageUp", run: notComposing(moveCompletionSelection(false, "page")) },
  { key: "Enter", run: notComposing(acceptCompletion) },
  { key: "Tab", run: notComposing(acceptCompletion) },
  { key: "Escape", run: notComposing(closeCompletion) },
];

/** The popup closes when a composition starts and the query is looked at again once it ends. */
const composition = EditorView.domEventHandlers({
  compositionstart(_event, view) {
    if (completionStatus(view.state) !== null) closeCompletion(view);
    return false;
  },
  compositionend(_event, view) {
    afterComposition(() => {
      if (view.composing || !view.state.facet(completionBridge).enabled()) return;
      if (completionQueryAt(view.state, view.state.selection.main.head)) startCompletion(view);
    }, 20);
    return false;
  },
});

// ---------------------------------------------------------------------------------------------
// TagCons

const SYMBOL = /^[a-z0-9]+(?:\.[a-z0-9]+)*$/;

/**
 * The TagCon image (an SF Symbol rendered by the host as a template PNG), or null for a bad name.
 * The `v2` segment versions the image size (96 px, sharp up to editor zoom 2.0); the host answers
 * only versioned paths.
 */
export function tagconURL(symbol: string): string | null {
  return SYMBOL.test(symbol) ? `baerchen-asset://tagcon/v2/${symbol}.png` : null;
}

/** An aria-hidden TagCon element (tag pills, completions, table cells). */
export function tagconElement(symbol: string): HTMLElement {
  const el = document.createElement("span");
  el.className = "cm-bc-tagcon";
  el.setAttribute("aria-hidden", "true");
  const url = tagconURL(symbol);
  if (url) el.style.setProperty("--bc-tagcon", `url("${url}")`);
  return el;
}

/** Tag starts (in `ranges`, default the whole document) whose path has an icon in `icons`. */
export function tagIconPositions(
  state: EditorState,
  icons: ReadonlyMap<string, string>,
  ranges: readonly { from: number; to: number }[] = [{ from: 0, to: state.doc.length }],
): { pos: number; symbol: string }[] {
  const found: { pos: number; symbol: string }[] = [];
  if (icons.size === 0) return found;
  const tree = syntaxTree(state);
  let last = -1;
  for (const { from, to } of ranges) {
    tree.iterate({
      from,
      to,
      enter(ref) {
        if (ref.name !== "Tag") return;
        const symbol = icons.get(canonicalKey(tagName(state.doc.sliceString(ref.from, ref.to))));
        if (symbol && tagconURL(symbol) && ref.from > last) {
          found.push({ pos: ref.from, symbol });
          last = ref.from;
        }
        return false;
      },
    });
  }
  return found;
}

export class TagConWidget extends WidgetType {
  constructor(readonly symbol: string) {
    super();
  }

  override eq(other: TagConWidget) {
    return other.symbol === this.symbol;
  }

  toDOM() {
    return tagconElement(this.symbol);
  }
}

/** What the TagCon plugin reads of the view (a fake in tests). */
export type TagIconsViewLike = { state: EditorState; visibleRanges: readonly { from: number; to: number }[]; composing: boolean };
export type TagIconsUpdateLike = Pick<ViewUpdate, "state" | "startState" | "changes" | "docChanged" | "viewportChanged" | "transactions"> & {
  view: TagIconsViewLike;
};

function tagIconDecorations(view: TagIconsViewLike): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  for (const { pos, symbol } of tagIconPositions(view.state, view.state.facet(completionBridge).tagIcons(), view.visibleRanges)) {
    builder.add(pos, pos, Decoration.widget({ widget: new TagConWidget(symbol), side: 1 }));
  }
  return builder.finish();
}

/** The TagCon widgets of the visible tags; never rebuilt while composing (only mapped). */
export class TagIconsState {
  decorations: DecorationSet;
  stale = false;

  constructor(view: TagIconsViewLike) {
    this.decorations = tagIconDecorations(view);
  }

  update(update: TagIconsUpdateLike) {
    const iconsChanged = update.transactions.some((tr) => tr.effects.some((e) => e.is(tagIconsChanged)));
    const changed =
      iconsChanged || update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state);
    // Never rebuilt while composing (global constraint): mapped, rebuilt once it ends.
    const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
    if (plan === "rebuild") {
      this.decorations = tagIconDecorations(update.view);
      this.stale = false;
      return;
    }
    if (update.docChanged) this.decorations = this.decorations.map(update.changes);
    if (plan === "map") this.stale ||= changed;
  }
}

const tagIconPlugin = ViewPlugin.fromClass(
  class extends TagIconsState {
    constructor(view: EditorView) {
      super(view);
    }

    override update(update: ViewUpdate) {
      super.update(update);
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
    eventHandlers: {
      compositionend(_event, view) {
        afterComposition(() => {
          if (this.stale && !view.composing) view.dispatch({});
        });
      },
    },
  },
);

/** The TagCon in front of a tag completion's label. */
const optionIcon = {
  render(completion: Completion): Node | null {
    const icon = (completion as Partial<BearCompletion>).item?.icon;
    return icon && tagconURL(icon) ? tagconElement(icon) : null;
  },
  position: 20,
};

const tagconStyle = {
  display: "inline-block",
  width: "0.85em",
  height: "0.85em",
  marginRight: "0.2em",
  verticalAlign: "-0.08em",
  backgroundColor: "var(--bc-color-tag, currentColor)",
  maskImage: "var(--bc-tagcon)",
  maskSize: "contain",
  maskRepeat: "no-repeat",
  maskPosition: "center",
  WebkitMaskImage: "var(--bc-tagcon)",
  WebkitMaskSize: "contain",
  WebkitMaskRepeat: "no-repeat",
  WebkitMaskPosition: "center",
};

/** The TagCon rule as CSS text, for widget shadow roots (table cells, M6-R18). */
export const TAGCON_CSS = cssText({ ".cm-bc-tagcon": tagconStyle });

const autocompleteTheme = EditorView.baseTheme({
  ".cm-bc-tagcon": tagconStyle,
  ".cm-tooltip.cm-tooltip-autocomplete.cm-bc-completions": {
    borderRadius: "8px",
    overflow: "hidden",
    boxShadow: "0 6px 24px var(--bc-color-shadow)",
    backgroundColor: "var(--bc-color-popup-bg)",
    color: "var(--bc-color-popup-text)",
    "& > ul": {
      fontFamily: "-apple-system, system-ui, sans-serif",
      fontSize: "13px",
      maxHeight: "16em",
      minWidth: "200px",
      padding: "4px",
    },
    "& > ul > li": { padding: "3px 8px", borderRadius: "5px", lineHeight: "1.4" },
    "& > ul > li[aria-selected]": {
      backgroundColor: "var(--bc-color-popup-selected-bg)",
      color: "var(--bc-color-popup-selected-text)",
    },
    "& .cm-completionDetail": { float: "right", marginLeft: "1.5em", fontStyle: "normal", opacity: "0.55" },
    "& .cm-bc-tagcon": { backgroundColor: "currentColor" },
  },
});

/** The fence language source (codeblocks.ts), off with the `autocomplete` setting like the rest. */
export function fenceLanguageSource(context: CompletionContext): CompletionResult | null {
  return context.state.facet(completionBridge).enabled() ? languageCompletionSource(context) : null;
}

/** The one completion config: Bear's sources (tags, notes, headings, emoji) and fence languages. */
export const autocomplete: Extension = [
  autocompletion({
    // Enter and Tab are explicit acceptance keys; a visible result accepts immediately.
    interactionDelay: 0,
    override: [bearCompletionSource, fenceLanguageSource],
    defaultKeymap: false,
    icons: false,
    closeOnBlur: true,
    addToOptions: [optionIcon],
    tooltipClass: () => "cm-bc-completions",
  }),
  Prec.highest(keymap.of(guardedCompletionKeymap)),
  composition,
  tagIconPlugin,
  autocompleteTheme,
];
