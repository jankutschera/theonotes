// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  type ChangeDesc,
  type ChangeSpec,
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  type Range as Ranged,
  StateEffect,
  type TransactionSpec,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { ensureSyntaxTree, HighlightStyle, LanguageDescription, syntaxTree } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import type { Completion, CompletionContext, CompletionResult } from "@codemirror/autocomplete";
import { type ChangedRange, type SyntaxNode, type Tree, TreeFragment } from "@lezer/common";
import { highlightTree, tags as t } from "@lezer/highlight";
import { hiddenMark, hidingUpdatePlan, type Range } from "./hiding";
import { parseLinePrefix } from "./lists";

// Fenced code blocks (spec §4.4, inventory §2.2.1): the fence lines collapse when the selection is
// outside the block (their text stays in the DOM, hidden like all markup, finding F8) and the
// opening row shows the language; the rows keep their height, so nothing moves when the caret
// enters. Code is highlighted with the language from the info string, loaded lazily
// from the bundle (@codemirror/language-data; unknown languages stay plain). The block's code is
// parsed on its own, not mounted into the Markdown tree, so the hiding/typography walks and the
// incremental Markdown parse never see code-language nodes; each block keeps its last tree for an
// incremental re-parse (HighlightCache), and only the visible lines are highlighted. Copy Code (top
// right, including on touch) sends the code to the host's pasteboard; spellcheck/autocorrect are off on code
// lines and spans.

// ---------------------------------------------------------------------------------------------
// Blocks

/** The fenced code block around `pos` (its fence lines included). */
export function fenceAt(tree: Tree, pos: number): SyntaxNode | null {
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(pos, side); n; n = n.parent) {
      if (n.name === "FencedCode" && n.from <= pos && n.to >= pos) return n;
    }
  }
  return null;
}

/** Lines of a fenced block: the opening line and, when it has one, the closing fence line. */
export function fenceLines(state: EditorState, fence: SyntaxNode) {
  const open = state.doc.lineAt(fence.from);
  const marks = fence.getChildren("CodeMark");
  const last = marks.at(-1);
  const close = marks.length >= 2 && last && state.doc.lineAt(last.from).number > open.number ? state.doc.lineAt(last.from) : null;
  const content = { from: open.to + 1, to: close ? close.from - 1 : fence.to };
  return { open, close, content: content.from <= content.to && content.from <= state.doc.length ? content : null };
}

/** The first word of the block's info string (`swift` for ```` ```swift title ````), or "". */
export function fenceLanguage(state: EditorState, fence: SyntaxNode): string {
  const info = fence.getChild("CodeInfo");
  return info ? (/^\S*/.exec(state.sliceDoc(info.from, info.to))?.[0] ?? "") : "";
}

type CodeLine = { from: number; text: string };

/**
 * The code of each content line: the line without container markup (quote markers, list
 * indentation), from the block's CodeText nodes. A line without code is empty.
 */
function codeLines(state: EditorState, fence: SyntaxNode): CodeLine[] {
  const { open, close } = fenceLines(state, fence);
  const last = close ? close.number - 1 : state.doc.lineAt(fence.to).number;
  const pieces = fence.getChildren("CodeText");
  const out: CodeLine[] = [];
  let i = 0;
  for (let n = open.number + 1; n <= last; n++) {
    const line = state.doc.line(n);
    while (i < pieces.length && pieces[i]!.to <= line.from) i++;
    let from = -1;
    let to = -1;
    for (let j = i; j < pieces.length && pieces[j]!.from < line.to; j++) {
      const p = pieces[j]!;
      if (p.to <= line.from) continue;
      if (from < 0) from = Math.max(p.from, line.from);
      to = Math.min(p.to, line.to);
    }
    out.push(from < 0 ? { from: line.to, text: "" } : { from, text: state.sliceDoc(from, to) });
  }
  return out;
}

/** What Copy Code copies: the code lines joined with `\n`, without fences. */
export function codeBlockText(state: EditorState, fence: SyntaxNode): string {
  return codeLines(state, fence)
    .map((l) => l.text)
    .join("\n");
}

// ---------------------------------------------------------------------------------------------
// Languages and highlighting

/** Info strings that name a file extension of another language but mean plain text. */
const PLAIN = new Set(["text", "txt", "plain", "plaintext"]);

/** The language an info string names: a language name or alias, else a file extension (`py`). */
export function languageFor(name: string): LanguageDescription | null {
  const lower = name.toLowerCase();
  if (!lower || PLAIN.has(lower)) return null;
  return (
    LanguageDescription.matchLanguageName(languages, lower, false) ??
    languages.find((d) => d.extensions.includes(lower)) ??
    null
  );
}

/** Theme-token classes (colors in the theme's `--bc-color-code-*` variables). */
export const codeHighlightStyle = HighlightStyle.define([
  { tag: t.keyword, class: "cm-bc-tok-keyword" },
  { tag: [t.string, t.special(t.string), t.regexp, t.character], class: "cm-bc-tok-string" },
  { tag: [t.number, t.bool, t.null, t.atom], class: "cm-bc-tok-number" },
  { tag: t.comment, class: "cm-bc-tok-comment" },
  { tag: [t.typeName, t.className, t.namespace], class: "cm-bc-tok-type" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], class: "cm-bc-tok-function" },
  { tag: [t.propertyName, t.attributeName], class: "cm-bc-tok-property" },
  { tag: t.tagName, class: "cm-bc-tok-tag" },
  { tag: [t.meta, t.annotation, t.processingInstruction], class: "cm-bc-tok-meta" },
]);

/** Above this many characters (fences included) a block stays plain. */
export const MAX_HIGHLIGHT_CHARS = 30_000;
/** At most this much code text (and its trees) is kept by a HighlightCache. */
export const HIGHLIGHT_CACHE_CHARS = 200_000;

type Token = { from: number; to: number; cls: string };
type CacheEntry = { desc: LanguageDescription; text: string; tree: Tree; generation: number };

/** The single edit that turns `a` into `b` (common prefix and suffix). */
function textChange(a: string, b: string): ChangedRange {
  const max = Math.min(a.length, b.length);
  let start = 0;
  while (start < max && a.charCodeAt(start) === b.charCodeAt(start)) start++;
  let end = 0;
  while (end < max - start && a.charCodeAt(a.length - 1 - end) === b.charCodeAt(b.length - 1 - end)) end++;
  return { fromA: start, toA: a.length - end, fromB: start, toB: b.length - end };
}

/**
 * The last parse of each highlighted block, keyed by the block's start (mapped through every
 * change), so an edit re-parses incrementally from the previous tree. Holds only the blocks of the
 * last build and at most HIGHLIGHT_CACHE_CHARS of code. One per editor view.
 */
export class HighlightCache {
  private entries = new Map<number, CacheEntry>();
  private generation = 0;

  get size(): number {
    return this.entries.size;
  }

  /** Characters of code held. */
  get chars(): number {
    let n = 0;
    for (const e of this.entries.values()) n += e.text.length;
    return n;
  }

  /** Follows a document change (keys are block starts). */
  map(changes: ChangeDesc): void {
    if (changes.empty) return;
    const next = new Map<number, CacheEntry>();
    for (const [from, entry] of this.entries) next.set(changes.mapPos(from, 1), entry);
    this.entries = next;
  }

  /** Starts a build: entries not used by it are dropped at `end()`. */
  begin(): void {
    this.generation++;
  }

  end(): void {
    let chars = 0;
    for (const [from, entry] of this.entries) {
      if (entry.generation !== this.generation) this.entries.delete(from);
      else chars += entry.text.length;
    }
    // Oldest first (insertion order) until within the bound.
    for (const [from, entry] of this.entries) {
      if (chars <= HIGHLIGHT_CACHE_CHARS) break;
      this.entries.delete(from);
      chars -= entry.text.length;
    }
  }

  /** The tree of the block at `from`, re-using the previous parse of that block. */
  tree(from: number, desc: LanguageDescription, text: string): Tree {
    const old = this.entries.get(from);
    let tree: Tree;
    if (old && old.desc === desc && old.text === text) tree = old.tree;
    else if (old && old.desc === desc) {
      const fragments = TreeFragment.applyChanges(TreeFragment.addTree(old.tree), [textChange(old.text, text)]);
      tree = desc.support!.language.parser.parse(text, fragments);
    } else tree = desc.support!.language.parser.parse(text);
    this.entries.delete(from);
    this.entries.set(from, { desc, text, tree, generation: this.generation });
    return tree;
  }
}

/** Highlight tokens of `tree` within each text range. */
function tokensIn(tree: Tree, ranges: readonly Range[]): Token[] {
  const out: Token[] = [];
  for (const r of ranges) highlightTree(tree, codeHighlightStyle, (from, to, cls) => out.push({ from, to, cls }), r.from, r.to);
  return out;
}

// ---------------------------------------------------------------------------------------------
// Decorations

/** The language shown in a collapsed opening fence row (drawn by CSS: no text in the DOM). */
export class LanguageLabel extends WidgetType {
  constructor(readonly language: string) {
    super();
  }

  override eq(other: LanguageLabel) {
    return other.language === this.language;
  }

  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-bc-code-lang";
    el.dataset.language = this.language;
    el.setAttribute("aria-hidden", "true");
    return el;
  }
}

/**
 * Where Copy Code and Copy Table As send their text (the bridge client: `copyText`); `html` is the
 * rich flavour of a table copy.
 */
export type CodeBlockHandlers = { copyText?: (text: string, html?: string) => void };

export const codeBlockHandlers = Facet.define<CodeBlockHandlers, CodeBlockHandlers>({
  combine: (values) => values[0] ?? {},
});

const COPIED_MS = 1200;

/** Copies the code of the block at `pos` through the handler; false without block or handler. */
export function copyCodeAt(view: EditorView, pos: number): boolean {
  const handler = view.state.facet(codeBlockHandlers).copyText;
  const fence = fenceAt(syntaxTree(view.state), pos);
  if (!handler || !fence) return false;
  handler(codeBlockText(view.state, fence));
  return true;
}

/**
 * Copy Code is a native button for touch, keyboard and assistive technology. Pointer presses
 * preserve the editor selection; keyboard activation uses the button's native Enter/Space behavior.
 */
export class CopyCodeButton extends WidgetType {
  override eq(other: CopyCodeButton) {
    return other instanceof CopyCodeButton;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("button");
    el.type = "button";
    el.contentEditable = "false";
    el.className = "cm-bc-copy";
    el.setAttribute("aria-label", "Copy Code");
    el.title = "Copy Code";
    let timer: ReturnType<typeof setTimeout> | null = null;
    el.addEventListener("mousedown", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
    el.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (!copyCodeAt(view, view.posAtDOM(el))) return;
      el.dataset.copied = "true";
      el.setAttribute("aria-label", "Copy Code, copied");
      if (timer !== null) clearTimeout(timer);
      timer = setTimeout(() => {
        delete el.dataset.copied;
        el.setAttribute("aria-label", "Copy Code");
      }, COPIED_MS);
    });
    return el;
  }

  override ignoreEvent() {
    return true;
  }
}

/** Off in code: no spelling marks, autocorrection, capitalization or Writing Tools suggestions. */
const CODE_ATTRIBUTES = { spellcheck: "false", autocorrect: "off", autocapitalize: "off", writingsuggestions: "false" };

const codeLineDeco = Decoration.line({ class: "cm-bc-code-line", attributes: CODE_ATTRIBUTES });
const inlineCodeDeco = Decoration.mark({ attributes: CODE_ATTRIBUTES });
const openDeco = Decoration.line({ class: "cm-bc-fence-open" });
const openCollapsedDeco = Decoration.line({ class: "cm-bc-fence-open cm-bc-fence-collapsed" });
const closeDeco = Decoration.line({ class: "cm-bc-fence-close" });
const closeCollapsedDeco = Decoration.line({ class: "cm-bc-fence-close cm-bc-fence-collapsed" });
const copyDeco = Decoration.widget({ widget: new CopyCodeButton(), side: 1 });
const labelDecos = new Map<string, Decoration>();
const labelDeco = (language: string) => {
  let deco = labelDecos.get(language);
  if (!deco) labelDecos.set(language, (deco = Decoration.widget({ widget: new LanguageLabel(language), side: 1 })));
  return deco;
};
const tokenDecos = new Map<string, Decoration>();
const tokenDeco = (cls: string) => {
  let deco = tokenDecos.get(cls);
  if (!deco) tokenDecos.set(cls, (deco = Decoration.mark({ class: cls })));
  return deco;
};

export type CodeBlockSets = {
  /** Line classes and attributes, attribute marks on inline code. */
  outer: DecorationSet;
  /** Collapsed fences, language labels and copy buttons. */
  inner: DecorationSet;
  /** Languages the visible blocks need that are not loaded yet. */
  pending: LanguageDescription[];
};

/** Calls `block` once for every fenced block and `inline` for every code span in `spans`. */
function codeIn(
  state: EditorState,
  spans: readonly Range[],
  block: (fence: SyntaxNode) => void,
  inline?: (from: number, to: number) => void,
): void {
  const seen = new Set<number>();
  const tree = syntaxTree(state);
  for (const span of spans) {
    tree.iterate({
      from: span.from,
      to: span.to,
      enter(ref) {
        if (ref.name !== "FencedCode" && ref.name !== "InlineCode") return;
        if (seen.has(ref.from)) return false;
        seen.add(ref.from);
        if (ref.name === "FencedCode") block(ref.node);
        else inline?.(ref.from, ref.to);
        return false;
      },
    });
  }
}

/** The known language a block's info string names, if any (loaded or not). */
function blockLanguage(state: EditorState, fence: SyntaxNode): LanguageDescription | null {
  const language = fenceLanguage(state, fence);
  return language ? languageFor(language) : null;
}

/**
 * Highlight tokens of the blocks in `within` (default: the whole document), only on the visible
 * lines. Blocks whose language is not loaded, and blocks over MAX_HIGHLIGHT_CHARS, stay plain.
 * Pure but for `cache` (the plugin's), which keeps each block's last parse for incremental
 * re-parsing; without it every block is parsed from scratch.
 */
export function codeBlockTokens(state: EditorState, within?: readonly Range[], cache?: HighlightCache): DecorationSet {
  const spans = within ?? [{ from: 0, to: state.doc.length }];
  const visible = (from: number, to: number) => spans.some((s) => s.from <= to && s.to >= from);
  const out: Ranged<Decoration>[] = [];
  cache?.begin();
  codeIn(state, spans, (fence) => {
    const desc = blockLanguage(state, fence);
    if (!desc?.support || fence.to - fence.from > MAX_HIGHLIGHT_CHARS) return;
    const lines = codeLines(state, fence);
    const ranges = visibleTextRanges(lines, spans);
    if (!ranges.length) return;
    const text = lines.map((l) => l.text).join("\n");
    const code = cache ? cache.tree(fence.from, desc, text) : desc.support.language.parser.parse(text);
    highlightInto(out, lines, tokensIn(code, ranges), visible);
  });
  cache?.end();
  return Decoration.set(out, true);
}

/**
 * Code block decorations for `within` (default: the whole document; the plugin passes the
 * visible ranges), without the highlight tokens (codeBlockTokens). Pure. A block's fences
 * collapse unless a selection range touches one of its lines.
 */
export function codeBlockDecorations(state: EditorState, within?: readonly Range[]): CodeBlockSets {
  const doc = state.doc;
  const sel = state.selection.ranges;
  const spans = within ?? [{ from: 0, to: doc.length }];
  const outer: Ranged<Decoration>[] = [];
  const inner: Ranged<Decoration>[] = [];
  const pending = new Set<LanguageDescription>();
  const visible = (from: number, to: number) => spans.some((s) => s.from <= to && s.to >= from);

  const block = (fence: SyntaxNode) => {
    const { open, close } = fenceLines(state, fence);
    const last = close ?? doc.lineAt(fence.to);
    const collapsed = !sel.some((r) => r.from <= last.to && r.to >= open.from);
    let lastLine = 0;
    for (const s of spans) {
      const from = Math.max(open.from, s.from);
      const to = Math.min(last.to, s.to);
      if (from > to) continue;
      for (let n = Math.max(doc.lineAt(from).number, lastLine + 1); n <= doc.lineAt(to).number; n++) {
        const line = doc.line(n);
        outer.push(codeLineDeco.range(line.from));
        if (n === open.number) outer.push((collapsed ? openCollapsedDeco : openDeco).range(line.from));
        else if (close && n === close.number) outer.push((collapsed ? closeCollapsedDeco : closeDeco).range(line.from));
        lastLine = n;
      }
    }

    const marks = fence.getChildren("CodeMark");
    const language = fenceLanguage(state, fence);
    if (visible(open.from, open.to)) {
      if (collapsed && marks[0]) {
        if (language) inner.push(labelDeco(language).range(marks[0].from));
        inner.push(hiddenMark.range(marks[0].from, open.to));
      }
      if (fence.getChild("CodeText")) inner.push(copyDeco.range(open.to));
    }
    const closeMark = close ? marks.at(-1) : null;
    if (collapsed && close && closeMark && visible(close.from, close.to)) {
      inner.push(hiddenMark.range(closeMark.from, close.to));
    }

    const desc = blockLanguage(state, fence);
    if (desc && !desc.support) pending.add(desc);
  };

  codeIn(state, spans, block, (from, to) => outer.push(inlineCodeDeco.range(from, to)));
  return { outer: Decoration.set(outer, true), inner: Decoration.set(inner, true), pending: [...pending] };
}

/** The ranges of the joined code text whose lines intersect `spans`. */
function visibleTextRanges(lines: readonly CodeLine[], spans: readonly Range[]): Range[] {
  const out: Range[] = [];
  let offset = 0;
  let current: Range | null = null;
  for (const { from, text } of lines) {
    const end = offset + text.length;
    if (spans.some((s) => s.from <= from + text.length && s.to >= from)) {
      if (current && current.to + 1 >= offset) current.to = end;
      else out.push((current = { from: offset, to: end }));
    }
    offset = end + 1;
  }
  return out;
}

/** Maps tokens of the joined code text onto the document lines (a token may span lines). */
function highlightInto(
  out: Ranged<Decoration>[],
  lines: readonly CodeLine[],
  tokens: readonly Token[],
  visible: (from: number, to: number) => boolean,
): void {
  let line = 0;
  let lineStart = 0; // offset of `lines[line]` in the joined text
  for (const token of tokens) {
    while (line < lines.length - 1 && lineStart + lines[line]!.text.length < token.from) {
      lineStart += lines[line]!.text.length + 1;
      line++;
    }
    let l = line;
    let start = lineStart;
    while (l < lines.length && start < token.to) {
      const { from, text } = lines[l]!;
      const a = Math.max(token.from, start) - start;
      const b = Math.min(token.to, start + text.length) - start;
      if (b > a && visible(from + a, from + b)) out.push(tokenDeco(token.cls).range(from + a, from + b));
      start += text.length + 1;
      l++;
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Plugin

const languageLoaded = StateEffect.define<null>();
const loads = new Map<LanguageDescription, Promise<unknown>>();

function loadLanguage(desc: LanguageDescription): Promise<unknown> {
  let promise = loads.get(desc);
  if (!promise) {
    promise = desc.load();
    loads.set(desc, promise);
  }
  return promise;
}

/** Re-highlighting waits this long after the last edit (off the keystroke path). */
export const HIGHLIGHT_DELAY_MS = 120;
const highlightNow = StateEffect.define<null>();

const codeBlockPlugin = ViewPlugin.fromClass(
  class {
    sets: CodeBlockSets;
    tokens: DecorationSet;
    stale = false;
    /** The tokens are mapped, not recomputed, since an edit; a timer recomputes them. */
    tokensStale = false;
    destroyed = false;
    timer: ReturnType<typeof setTimeout> | null = null;
    private readonly waiting = new Set<LanguageDescription>();
    /** Each visible block's last parse (incremental re-parse on edits). */
    private readonly cache = new HighlightCache();
    /** The copy button shown for the block under the pointer. */
    private shown: HTMLElement | null = null;

    constructor(readonly view: EditorView) {
      this.sets = this.build();
      this.tokens = codeBlockTokens(view.state, view.visibleRanges, this.cache);
    }

    build(): CodeBlockSets {
      const sets = codeBlockDecorations(this.view.state, this.view.visibleRanges);
      for (const desc of sets.pending) this.wait(desc);
      return sets;
    }

    /** Edits keep the mapped tokens; the blocks are re-highlighted once typing pauses. */
    scheduleHighlight() {
      this.tokensStale = true;
      if (this.timer !== null) clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        this.timer = null;
        if (this.destroyed || !this.tokensStale) return;
        // During an IME composition compositionend asks for it.
        if (!this.view.composing) this.view.dispatch({ effects: highlightNow.of(null) });
      }, HIGHLIGHT_DELAY_MS);
    }

    /** Loads a language from the bundle and redecorates once it is there. */
    wait(desc: LanguageDescription) {
      if (this.waiting.has(desc)) return;
      this.waiting.add(desc);
      loadLanguage(desc).then(
        () => this.languageArrived(),
        (err: unknown) => {
          // Stays plain; the bundle is local, so this only happens for a broken build.
          if (import.meta.env.DEV) console.warn(`[baerchen] could not load ${desc.name}`, err);
        },
      );
    }

    languageArrived() {
      if (this.destroyed) return;
      // Never touch the DOM around an IME composition; compositionend catches up.
      if (this.view.composing) this.stale = this.tokensStale = true;
      else this.view.dispatch({ effects: languageLoaded.of(null) });
    }

    update(update: ViewUpdate) {
      const effect = (type: typeof languageLoaded) => update.transactions.some((tr) => tr.effects.some((e) => e.is(type)));
      const loaded = effect(languageLoaded);
      const now = effect(highlightNow);
      const treeChanged = syntaxTree(update.startState) !== syntaxTree(update.state);
      const changed = update.docChanged || update.selectionSet || update.viewportChanged || treeChanged || loaded || now;
      // Also while composing: the cached block starts and the tokens follow every change.
      if (update.docChanged) {
        this.cache.map(update.changes);
        this.tokens = this.tokens.map(update.changes);
        this.scheduleHighlight();
      }
      switch (hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale })) {
        case "map":
          this.sets = { ...this.sets, outer: this.sets.outer.map(update.changes), inner: this.sets.inner.map(update.changes) };
          this.stale ||= changed;
          return;
        case "rebuild":
          this.sets = this.build();
          this.stale = false;
          // Typing never parses code; a pause, a new viewport, a loaded language or the background
          // parse reaching more blocks (no edit waiting for its pause) does.
          const parseAdvanced = treeChanged && this.timer === null;
          if (!update.docChanged && (now || loaded || update.viewportChanged || parseAdvanced)) {
            this.tokens = codeBlockTokens(update.view.state, update.view.visibleRanges, this.cache);
            this.tokensStale = false;
          }
          return;
        case "keep":
          return;
      }
    }

    /** Shows the copy button of the block under the pointer (direct DOM: no transaction). */
    hover(target: EventTarget | null) {
      let line = target instanceof Element ? target.closest(".cm-line") : null;
      while (line && !line.classList.contains("cm-bc-fence-open")) {
        const prev: Element | null = line.classList.contains("cm-bc-code-line") ? line.previousElementSibling : null;
        line = prev?.classList.contains("cm-bc-code-line") ? prev : null;
      }
      const button = line?.querySelector<HTMLElement>(".cm-bc-copy") ?? null;
      if (button === this.shown) return;
      this.shown?.classList.remove("cm-bc-copy-shown");
      button?.classList.add("cm-bc-copy-shown");
      this.shown = button;
    }

    destroy() {
      this.destroyed = true;
      if (this.timer !== null) clearTimeout(this.timer);
    }
  },
  {
    eventHandlers: {
      compositionend(_event, view) {
        afterComposition(() => {
          if (view.composing || (!this.stale && !this.tokensStale)) return;
          view.dispatch(this.tokensStale && this.timer === null ? { effects: highlightNow.of(null) } : {});
        });
      },
      mousemove(event) {
        this.hover(event.target);
      },
      mouseleave() {
        this.hover(null);
      },
    },
  },
);

// ---------------------------------------------------------------------------------------------
// Paste as Code

const longestRun = (text: string) => Math.max(0, ...Array.from(text.matchAll(/`+/g), (m) => m[0].length));

/** What a new line inside the container of `lineText` starts with: quote markers, indentation, list content offset. */
function containerPrefix(lineText: string): string {
  const p = parseLinePrefix(lineText);
  const at = p.quote.length + p.indent.length;
  return p.quote + p.indent + (p.list ? " ".repeat(p.list.textFrom - at) : "");
}

/** The length of the `ch` fence run starting `line` (after up to three spaces), else 0. */
function fenceRun(line: string, ch: string): number {
  const m = /^ {0,3}(`+|~+)/.exec(line);
  return m && m[1]![0] === ch ? m[1]!.length : 0;
}

const pasteSpec = (state: EditorState, changes: ChangeSpec[], end: (set: ReturnType<EditorState["changes"]>) => number): TransactionSpec => {
  const set = state.changes(changes);
  return { changes: set, selection: EditorSelection.cursor(end(set)), scrollIntoView: true, userEvent: "input.paste" };
};

/**
 * `lines` as code of `fence`, replacing [from, to): every line but a first one that continues
 * the caret's line gets the block's container prefix. A pasted line that starts with a fence run
 * as long as the block's fence would close the block, so both fences grow past it instead.
 */
function intoBlock(
  state: EditorState,
  fence: SyntaxNode,
  range: { from: number; to: number; lead: string },
  lines: readonly string[],
  firstStartsLine: boolean,
  prefix: string,
): TransactionSpec {
  const marks = fence.getChildren("CodeMark");
  const opener = marks[0]!;
  const closer = fenceLines(state, fence).close ? marks.at(-1)! : null;
  const ch = state.sliceDoc(opener.from, opener.from + 1);
  const longest = Math.max(0, ...lines.map((l, i) => (i === 0 && !firstStartsLine ? 0 : fenceRun(l, ch))));
  const insert = range.lead + lines.map((l, i) => (i === 0 && !range.lead ? l : prefix + l)).join("\n");
  const changes: ChangeSpec[] = [{ from: range.from, to: range.to, insert }];
  if (longest >= opener.to - opener.from) {
    const run = ch.repeat(longest + 1);
    changes.push({ from: opener.from, to: opener.to, insert: run });
    if (closer) changes.push({ from: closer.from, to: closer.to, insert: run });
  }
  return pasteSpec(state, changes, (set) => set.mapPos(range.to, 1));
}

/** `body` as a new fenced block, each line with `prefix`; the fence outlasts any backtick run. */
const fencedLines = (body: string, prefix: string) => {
  const ticks = "`".repeat(Math.max(3, longestRun(body) + 1));
  return [ticks, ...body.split("\n"), ticks].map((l) => prefix + l);
};

/**
 * Edit ▸ Paste From ▸ Code: `raw` in a fenced block on lines of its own over the selection, inside
 * the line's container (quote, list item). In a block: on the opening fence line the text becomes
 * the block's first lines, on the closing one a new block follows; in its code the text goes in
 * as is, with the container prefix on every new line.
 */
export function codePaste(state: EditorState, raw: string): TransactionSpec {
  const text = raw.replace(/\r\n?/g, "\n");
  const body = text.replace(/\n$/, "");
  const main = state.selection.main;
  const doc = state.doc;
  const tree = ensureSyntaxTree(state, main.to, 50) ?? syntaxTree(state);
  const fence = fenceAt(tree, main.from);
  if (fence && fenceAt(tree, main.to)?.from === fence.from) {
    const { open, close, content } = fenceLines(state, fence);
    const prefix = containerPrefix(open.text);
    if (main.to <= open.to) {
      return intoBlock(state, fence, { from: open.to, to: open.to, lead: "\n" }, body.split("\n"), true, prefix);
    }
    if (close && main.from >= close.from) {
      const insert = fencedLines(body, prefix).map((l) => `\n${l}`).join("");
      return pasteSpec(state, [{ from: close.to, insert }], (set) => set.mapPos(close.to, 1));
    }
    if (content && main.from >= content.from && main.to <= content.to) {
      const before = state.sliceDoc(doc.lineAt(main.from).from, main.from);
      return intoBlock(state, fence, { from: main.from, to: main.to, lead: "" }, text.split("\n"), /^[ \t>]*$/.test(before), prefix);
    }
  }
  const line = doc.lineAt(main.from);
  const prefix = containerPrefix(line.text);
  const blank = /^[ \t>]*$/.test(state.sliceDoc(line.from, main.from));
  const endLine = doc.lineAt(main.to);
  const trail = main.to < endLine.to ? `\n${containerPrefix(endLine.text)}` : "";
  const [first, ...rest] = fencedLines(body, prefix);
  const insert = (blank ? first!.slice(prefix.length) : `\n${first}`) + rest.map((l) => `\n${l}`).join("") + trail;
  return pasteSpec(state, [{ from: main.from, to: main.to, insert }], () => main.from + insert.length - trail.length);
}

// ---------------------------------------------------------------------------------------------
// Language autocomplete

/** An opening fence up to the caret: container prefix (quotes, a list marker), fence, word. */
const FENCE_PREFIX = /^((?:[ \t]*>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?)(`{3,}|~{3,})((?:[A-Za-z][\w#+.-]*)?)$/;
const LANGUAGE_WORD = /^[\w#+.-]+$/;

let options: Completion[] | null = null;

/** Every language name and alias (lowercase, one word), with the language's name as detail. */
function languageOptions(): Completion[] {
  if (options) return options;
  const seen = new Set<string>();
  options = [];
  for (const desc of languages) {
    for (const label of desc.alias) {
      if (!LANGUAGE_WORD.test(label) || seen.has(label)) continue;
      seen.add(label);
      options.push({ label, detail: desc.name, type: "type" });
    }
  }
  return options;
}

/**
 * The language after an opening fence (```` ```sw ```` → `swift`). An empty word only on an
 * explicit request, so Enter right after ```` ``` ```` still starts the block's first line.
 */
export function languageCompletionSource(context: CompletionContext): CompletionResult | null {
  if (context.view?.composing) return null;
  const { state, pos } = context;
  const line = state.doc.lineAt(pos);
  const match = FENCE_PREFIX.exec(state.sliceDoc(line.from, pos));
  if (!match) return null;
  const word = match[3]!;
  if (!word && !context.explicit) return null;
  const fenceFrom = line.from + match[1]!.length;
  const tree = ensureSyntaxTree(state, line.to, 50) ?? syntaxTree(state);
  if (fenceAt(tree, fenceFrom)?.from !== fenceFrom) return null; // a closing fence or code
  return { from: pos - word.length, options: languageOptions(), validFor: /^[\w#+.-]*$/ };
}

// ---------------------------------------------------------------------------------------------
// Theme and extension

const codeBlockTheme = EditorView.theme({
  ".cm-bc-fence-open": { position: "relative" },
  ".cm-bc-code-lang": {
    display: "inline-block",
    fontFamily: "var(--bc-font-text)",
    fontSize: "0.85em",
    fontWeight: "500",
    letterSpacing: "0.02em",
    color: "var(--bc-color-secondary)",
    userSelect: "none",
    pointerEvents: "none",
  },
  ".cm-bc-code-lang::before": { content: "attr(data-language)" },
  ".cm-bc-copy": {
    position: "absolute",
    top: "6px",
    right: "8px",
    padding: "2px 7px",
    borderRadius: "4px",
    border: "1px solid var(--bc-color-rule)",
    backgroundColor: "var(--bc-color-bg)",
    color: "var(--bc-color-secondary)",
    fontFamily: "var(--bc-font-text)",
    fontSize: "11px",
    lineHeight: "16px",
    cursor: "pointer",
    userSelect: "none",
    opacity: "0",
    transition: "opacity 120ms",
  },
  ".cm-bc-copy::before": { content: '"Copy"' },
  ".cm-bc-copy[data-copied]::before": { content: '"Copied"' },
  ".cm-bc-copy.cm-bc-copy-shown, .cm-bc-copy:hover, .cm-bc-copy[data-copied], .cm-bc-copy:focus-visible": { opacity: "1" },
  // Touch (iOS, ios-iphone-ipad ac43d5a): no hover, so the button is always shown, with a 44 pt
  // target on a row tall enough to hold it. The desktop keeps Bear's hover-revealed button.
  "@media (pointer: coarse)": {
    ".cm-bc-fence-open": { minHeight: "44px", paddingRight: "72px" },
    ".cm-bc-copy": { top: "0", minWidth: "44px", minHeight: "44px", boxSizing: "border-box", opacity: "1" },
  },
  ".cm-bc-copy:hover": { color: "var(--bc-color-accent)" },
  ".cm-bc-copy:focus-visible": { outline: "2px solid var(--bc-color-accent)", outlineOffset: "2px" },

  ".cm-bc-tok-keyword": { color: "var(--bc-color-code-keyword)" },
  ".cm-bc-tok-string": { color: "var(--bc-color-code-string)" },
  ".cm-bc-tok-number": { color: "var(--bc-color-code-number)" },
  ".cm-bc-tok-comment": { color: "var(--bc-color-code-comment)", fontStyle: "italic" },
  ".cm-bc-tok-type": { color: "var(--bc-color-code-type)" },
  ".cm-bc-tok-function": { color: "var(--bc-color-code-function)" },
  ".cm-bc-tok-property": { color: "var(--bc-color-code-property)" },
  ".cm-bc-tok-tag": { color: "var(--bc-color-code-tag)" },
  ".cm-bc-tok-meta": { color: "var(--bc-color-code-meta)" },
});

export const codeBlocks: Extension = [
  codeBlockPlugin,
  EditorView.outerDecorations.of((view) => view.plugin(codeBlockPlugin)?.sets.outer ?? Decoration.none),
  EditorView.decorations.of((view) => view.plugin(codeBlockPlugin)?.sets.inner ?? Decoration.none),
  EditorView.decorations.of((view) => view.plugin(codeBlockPlugin)?.tokens ?? Decoration.none),
  codeBlockTheme,
];
