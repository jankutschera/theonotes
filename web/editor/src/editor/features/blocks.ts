// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
// Block widget layer (M6 Task 3): tables, block math and Mermaid render as widgets above their
// source lines, which stay in the DOM collapsed to zero height (finding F8: the content text and
// its offsets equal the document). A selection touching a block's lines, or Hide Markdown off,
// shows the source instead.
//
// Where the decorations come from: CodeMirror allows block decorations only from state, so they
// live in `renderedBlocks`. The field maps them through edits and flips a block's mode itself when
// the selection or Hide Markdown changes (so the caret never sits in collapsed lines, and a mode
// never switches after an IME composition has started). Which blocks exist is found by a view
// plugin that scans the visible ranges' syntax tree after edits, parses and scrolls, and
// dispatches `setRenderedBlocks` only when the list differs.

import {
  Annotation,
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  type ChangeDesc,
  Prec,
  type Range as DecoRange,
  type SelectionRange,
  StateEffect,
  StateField,
  Transaction,
} from "@codemirror/state";
import {
  type Command,
  Decoration,
  type DecorationSet,
  EditorView,
  keymap,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";
import { foldedRanges, syntaxTree } from "@codemirror/language";
import { cursorPageDown, cursorPageUp, selectPageDown, selectPageUp } from "@codemirror/commands";
import type { SyntaxNodeRef } from "@lezer/common";
import { hiddenMark, hideMarkdown, lineEdgePastHidden } from "./hiding";
import { typewriterModeSetting } from "./settings";

export type BlockKind = "table" | "mathBlock" | "mermaid";
/** `from` = first line start, `to` = last line end, `key` = the source text (`from`…`to`). */
export type BlockSpec = { kind: BlockKind; from: number; to: number; key: string };

export interface BlockRenderer {
  kind: BlockKind;
  /** The block at this tree node, or null. Called only for nodes in the scanned (visible) ranges. */
  match(state: EditorState, node: SyntaxNodeRef): BlockSpec | null;
  /** Shown above the collapsed lines. */
  rendered(block: BlockSpec): WidgetType;
  /** Shown below the source in source mode. */
  preview?(block: BlockSpec): WidgetType | null;
  /** Caret target when arrowing in from the line above or below. */
  entry(state: EditorState, block: BlockSpec, from: "above" | "below"): number;
  /**
   * Caret target for a primary-button mousedown on the rendered widget (tables: the clicked
   * cell); `event.composedPath()` reaches into the widget. Null: `entry(…, "above")`.
   * `"handled"`: the renderer acted on the click itself (⌘-click on a link); the selection, and
   * so the block's mode, stay as they are.
   */
  click?(view: EditorView, block: BlockSpec, event: MouseEvent): number | null | "handled";
  /**
   * The rendered widget's accessible name (`role="img"`, `aria-label`). Without one the widget is
   * `aria-hidden` (a renderer that duplicates the source text exposes it some other way).
   */
  label?(block: BlockSpec): string;
  /**
   * The block always shows its source (never collapsed), with the preview below: for blocks too
   * large to collapse (a huge diagram), whose many zero-height lines CodeMirror's viewport cannot
   * settle around.
   */
  sourceOnly?(block: BlockSpec): boolean;
  /**
   * CSS for the widget's DOM. Widgets live in a shadow root (their text must not be part of the
   * content text), so editor themes do not reach them; `--bc-color-*` tokens do (they inherit).
   */
  styles?: string;
}

/** The renderers (Tasks 4, 11, 12 add theirs; none: the layer does nothing). */
export const blockRenderers = Facet.define<BlockRenderer>();

/**
 * Ranges that must be visible although no selection is there: the current search match of the
 * note-list highlight and ⌘G (M6-R78). A rendered block holding one shows its source, the way a
 * fold holding it opens.
 */
export const blockRevealers = Facet.define<(state: EditorState) => { from: number; to: number } | null>();

const revealed = (state: EditorState) => {
  const out: { from: number; to: number }[] = [];
  for (const reveal of state.facet(blockRevealers)) {
    const range = reveal(state);
    if (range) out.push(range);
  }
  return out;
};

const revealsDiffer = (before: EditorState, after: EditorState) => {
  const a = revealed(before);
  const b = revealed(after);
  return a.length !== b.length || a.some((r, i) => r.from !== b[i]!.from || r.to !== b[i]!.to);
};

export const COLLAPSED_LINE_CLASS = "cm-bc-block-collapsed";
const BLOCK_CLASS = "cm-bc-block";

/** A selection range touches the block's lines (their edges included). */
const touches = (ranges: readonly SelectionRange[], block: BlockSpec) =>
  ranges.some((r) => r.from <= block.to && r.to >= block.from);

/**
 * `end` of a mouse selection lies on the block's lines. An end exactly at `block.from` whose other
 * end is above the block is outside: a triple-click on the line above selects up to the block's
 * first position (the line break), not into the block.
 */
const endOn = (end: number, other: number, block: BlockSpec) =>
  end >= block.from && end <= block.to && !(end === block.from && other < block.from);

/** A selection range ends (anchor or head) on the block's lines. */
const endsIn = (ranges: readonly SelectionRange[], block: BlockSpec) =>
  ranges.some((r) => endOn(r.head, r.anchor, block) || endOn(r.anchor, r.head, block));

/** A layer transaction that puts the caret into a block on purpose (arrows, clicks, Backspace). */
const blockEntry = Annotation.define<boolean>();

/**
 * Whether the selection was made with the mouse (a click or drag, not one of the layer's entries)
 * and nothing else changed it since. Such a selection may span a rendered block without showing
 * its source, so a drag across a table does not flip it (and move the text under the pointer).
 */
const pointerSelection = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    if (tr.annotation(blockEntry)) return false;
    if (tr.selection) return tr.isUserEvent("select.pointer");
    return tr.docChanged ? false : value;
  },
});

/**
 * `"source"` when a selection range touches the block's lines, a revealed range (the current
 * search match, `blockRevealers`) lies on them, or Hide Markdown is off, else `"rendered"`. A
 * mouse selection (`pointerSelection`) only counts with an end on the block's lines. An IME
 * composition inside a block always has the caret there, so it is source too.
 */
export function blockMode(state: EditorState, block: BlockSpec): "rendered" | "source" {
  if (!state.facet(hideMarkdown)) return "source";
  if (rendererFor(state, block.kind)?.sourceOnly?.(block)) return "source";
  const ranges = state.selection.ranges;
  const shown = state.field(pointerSelection, false) ? endsIn(ranges, block) : touches(ranges, block);
  if (shown) return "source";
  return revealed(state).some((r) => r.from <= block.to && r.to >= block.from) ? "source" : "rendered";
}

/** Never touch the DOM around an active IME composition; rescan once it ends. */
export function blockUpdatePlan(u: { composing: boolean; changed: boolean }): "map" | "rescan" | "keep" {
  if (u.composing) return "map";
  return u.changed ? "rescan" : "keep";
}

/** The blocks of the scanned ranges; positions are in the transaction's new document. */
export const setRenderedBlocks = StateEffect.define<readonly BlockSpec[]>();

type Mode = "rendered" | "source";

/** The editor's last measured text metrics (for the height estimates below). */
const layout = { width: 0, lineHeight: 0, charWidth: 0 };
/** Measured widget heights by kind, source key and content width (bounded). */
const heights = new Map<string, number>();
const MAX_HEIGHTS = 500;
/** Measured heights hold for one content width and line height (the font size setting). */
const heightKey = (kind: BlockKind, key: string, width: number, lineHeight: number) =>
  `${kind}\u0000${Math.round(width)}\u0000${Math.round(lineHeight * 10)}\u0000${key}`;

/** Records a drawn widget's height (and the editor's metrics); exported for tests. */
export function recordBlockHeight(
  kind: BlockKind,
  key: string,
  height: number,
  metrics: { width: number; lineHeight: number; charWidth: number },
): void {
  Object.assign(layout, metrics);
  if (height <= 0) return;
  if (heights.size >= MAX_HEIGHTS) heights.delete(heights.keys().next().value!);
  heights.set(heightKey(kind, key, metrics.width, metrics.lineHeight), height);
}

/**
 * What CodeMirror's height oracle assumes for the block's source lines until it has measured them
 * (as collapsed, 0): one line height per wrapped row, a long row several (its line-wrapping guess).
 */
export function collapsedLinesEstimate(key: string): number {
  if (layout.lineHeight <= 0) return 0;
  const lineLength = layout.width > 0 && layout.charWidth > 0 ? Math.max(5, layout.width / layout.charWidth) : Infinity;
  let rows = 0;
  for (const line of key.split("\n")) {
    rows += 1 + (lineLength === Infinity ? 0 : Math.max(0, Math.ceil((line.length - lineLength) / Math.max(1, lineLength - 5))));
  }
  return rows * layout.lineHeight;
}

/**
 * Drawn rendered widgets report their height here once laid out. A ResizeObserver, not a
 * `requestMeasure` from `toDOM`: a measure request per drawn widget added iterations to
 * CodeMirror's measure loop ("Viewport failed to stabilize" 3 → 11-18 times while scrolling
 * through 20 wide tables, measured 2026-10-23).
 */
const watched = new WeakMap<Element, { kind: BlockKind; key: string; view: EditorView; height?: number }>();
let observer: ResizeObserver | null | undefined;

function heightObserver(): ResizeObserver | null {
  if (observer === undefined) {
    observer =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) => {
            for (const entry of entries) {
              const info = watched.get(entry.target);
              if (!info || !entry.target.isConnected) continue;
              const { view } = info;
              const metrics = { width: view.contentDOM.clientWidth, lineHeight: view.defaultLineHeight, charWidth: view.defaultCharacterWidth };
              const height = entry.borderBoxSize[0]?.blockSize ?? entry.contentRect.height;
              recordBlockHeight(info.kind, info.key, height, metrics);
              // A render that finished after the widget was laid out (math, Mermaid) changed its
              // height: CodeMirror re-measures (its height map would be stale otherwise).
              if (info.height !== undefined && Math.abs(info.height - height) > 0.5) view.requestMeasure();
              info.height = height;
            }
          });
  }
  return observer;
}

/**
 * A rendered widget's height estimate: its last measured height at this content width, else the
 * renderer's guess; less what CodeMirror still estimates for the collapsed lines, so the
 * document does not shrink (and the viewport is not recomputed several times) when they are
 * first measured.
 */
export function blockHeightEstimate(kind: BlockKind, key: string, guess: number): number {
  const measured = heights.get(heightKey(kind, key, layout.width, layout.lineHeight));
  const raw = measured ?? guess;
  if (raw < 0) return raw;
  return Math.max(1, raw - collapsedLinesEstimate(key));
}

/**
 * The layer's widget around a renderer's: a non-editable host whose shadow root holds the
 * renderer's DOM, so its text is not part of `.cm-content`'s text (innerText, the AX text).
 */
class BlockWidget extends WidgetType {
  constructor(
    readonly role: Mode,
    readonly kind: BlockKind,
    readonly key: string,
    readonly inner: WidgetType,
    readonly label: string | null,
    readonly styles: string | undefined,
  ) {
    super();
  }

  override eq(other: BlockWidget): boolean {
    return (
      other.role === this.role &&
      other.kind === this.kind &&
      other.key === this.key &&
      other.label === this.label &&
      (other.inner === this.inner || other.inner.eq(this.inner))
    );
  }

  toDOM(view: EditorView): HTMLElement {
    const host = document.createElement("div");
    host.className = `${BLOCK_CLASS} ${BLOCK_CLASS}-${this.role} ${BLOCK_CLASS}-${this.kind}`;
    host.contentEditable = "false";
    if (this.role === "rendered" && this.label) {
      host.setAttribute("role", "img");
      host.setAttribute("aria-label", this.label);
    } else {
      host.setAttribute("aria-hidden", "true");
    }
    const root = host.attachShadow({ mode: "open" });
    const sheet = this.styles ? styleSheet(this.styles) : null;
    if (sheet) root.adoptedStyleSheets = [sheet];
    const dom = this.inner.toDOM(view);
    innerDOM.set(host, dom);
    root.append(dom);
    if (this.role === "rendered") {
      watched.set(host, { kind: this.kind, key: this.key, view });
      heightObserver()?.observe(host);
    }
    return host;
  }

  override get estimatedHeight(): number {
    const guess = this.inner.estimatedHeight;
    return this.role === "rendered" ? blockHeightEstimate(this.kind, this.key, guess) : guess;
  }

  override ignoreEvent(event: Event): boolean {
    // The layer's mousedown handler places the caret (domEventHandlers only see events of
    // widgets that do not ignore them).
    if (this.role === "rendered" && event.type === "mousedown") return false;
    return this.inner.ignoreEvent(event);
  }

  override destroy(dom: HTMLElement): void {
    watched.delete(dom);
    observer?.unobserve(dom);
    const inner = innerDOM.get(dom);
    if (inner) this.inner.destroy(inner);
  }
}

const innerDOM = new WeakMap<HTMLElement, HTMLElement>();
const sheets = new Map<string, CSSStyleSheet | null>();

/** One constructable sheet per renderer's CSS (not subject to the CSP's style-src). */
function styleSheet(css: string): CSSStyleSheet | null {
  let sheet = sheets.get(css);
  if (sheet === undefined) {
    try {
      sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
    } catch {
      sheet = null;
    }
    sheets.set(css, sheet);
  }
  return sheet;
}

const collapsedLine = Decoration.line({ class: COLLAPSED_LINE_CLASS });

const widgetKey = (role: Mode, kind: BlockKind, key: string) => `${role}\u0000${kind}\u0000${key}`;

/** The widgets of `decorations`, so a rebuild reuses those whose block did not change. */
function widgetsOf(decorations: DecorationSet): Map<string, BlockWidget> {
  const out = new Map<string, BlockWidget>();
  for (let iter = decorations.iter(); iter.value; iter.next()) {
    const widget = iter.value.spec.widget;
    if (widget instanceof BlockWidget) out.set(widgetKey(widget.role, widget.kind, widget.key), widget);
  }
  return out;
}

type RenderedBlocks = { blocks: readonly BlockSpec[]; decorations: DecorationSet };

function rendererFor(state: EditorState, kind: BlockKind): BlockRenderer | undefined {
  return state.facet(blockRenderers).find((r) => r.kind === kind);
}

function build(state: EditorState, blocks: readonly BlockSpec[], previous: DecorationSet): RenderedBlocks {
  const reuse = widgetsOf(previous);
  const decos: DecoRange<Decoration>[] = [];
  const kept: BlockSpec[] = [];
  for (const block of blocks) {
    const renderer = rendererFor(state, block.kind);
    if (!renderer || block.from < 0 || block.to > state.doc.length || block.to <= block.from) continue;
    kept.push(block);
    const mode = blockMode(state, block);
    const cached = reuse.get(widgetKey(mode, block.kind, block.key));
    if (mode === "rendered") {
      const widget =
        cached ??
        new BlockWidget("rendered", block.kind, block.key, renderer.rendered(block), renderer.label?.(block) ?? null, renderer.styles);
      decos.push(Decoration.widget({ widget, block: true, side: -1 }).range(block.from));
      for (let pos = block.from; pos <= block.to; ) {
        const line = state.doc.lineAt(pos);
        decos.push(collapsedLine.range(line.from));
        if (line.to > line.from) decos.push(hiddenMark.range(line.from, line.to));
        pos = line.to + 1;
      }
    } else {
      const inner = cached ? null : renderer.preview?.(block);
      const widget = cached ?? (inner ? new BlockWidget("source", block.kind, block.key, inner, null, renderer.styles) : null);
      if (widget) decos.push(Decoration.widget({ widget, block: true, side: 1 }).range(block.to));
    }
  }
  return { blocks: kept, decorations: Decoration.set(decos, true) };
}

/** Maps blocks through a change; a block whose text is gone is dropped. */
function mapBlocks(blocks: readonly BlockSpec[], changes: ChangeDesc): BlockSpec[] {
  const out: BlockSpec[] = [];
  for (const b of blocks) {
    const from = changes.mapPos(b.from, 1);
    const to = changes.mapPos(b.to, -1);
    if (to > from) out.push(from === b.from && to === b.to ? b : { ...b, from, to });
  }
  return out;
}

const modesDiffer = (before: EditorState, old: readonly BlockSpec[], after: EditorState, next: readonly BlockSpec[]) =>
  old.some((b, i) => blockMode(before, b) !== blockMode(after, next[i]!));

export const renderedBlocks = StateField.define<RenderedBlocks>({
  create: () => ({ blocks: [], decorations: Decoration.none }),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setRenderedBlocks)) {
        return build(tr.state, effect.value, tr.docChanged ? value.decorations.map(tr.changes) : value.decorations);
      }
    }
    if (value.blocks.length === 0) return value;
    const blocks = tr.docChanged ? mapBlocks(value.blocks, tr.changes) : value.blocks;
    const decorations = tr.docChanged ? value.decorations.map(tr.changes) : value.decorations;
    const settingsChanged =
      tr.startState.facet(hideMarkdown) !== tr.state.facet(hideMarkdown) ||
      tr.startState.facet(blockRenderers) !== tr.state.facet(blockRenderers);
    if (settingsChanged || blocks.length !== value.blocks.length) return build(tr.state, blocks, decorations);
    const revealing = !tr.selection && !tr.docChanged && tr.effects.length > 0 && revealsDiffer(tr.startState, tr.state);
    if ((tr.selection || tr.docChanged || revealing) && modesDiffer(tr.startState, value.blocks, tr.state, blocks)) {
      return build(tr.state, blocks, decorations);
    }
    return blocks === value.blocks && decorations === value.decorations ? value : { blocks, decorations };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
});

/** Containers whose children can hold blocks (tables sit in quotes and list items, M6-R1). */
const containers = new Set(["Document", "Blockquote", "BulletList", "OrderedList", "ListItem"]);

export type Range = { from: number; to: number };

/** The blocks in `ranges` (sorted, disjoint): each renderer's `match` on the block-level nodes. */
export function scanBlocks(state: EditorState, ranges: readonly Range[]): BlockSpec[] {
  const renderers = state.facet(blockRenderers);
  if (renderers.length === 0) return [];
  const tree = syntaxTree(state);
  const out: BlockSpec[] = [];
  let end = -1;
  for (const { from, to } of ranges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        if (node.to <= end) return false;
        for (const renderer of renderers) {
          const block = renderer.match(state, node);
          if (!block) continue;
          if (block.from > end) {
            out.push(block);
            end = block.to;
          }
          return false;
        }
        return containers.has(node.name);
      },
    });
  }
  return out;
}

const sameBlock = (state: EditorState, a: BlockSpec, b: BlockSpec) =>
  a.kind === b.kind && a.from === b.from && a.to === b.to && a.key === b.key && blockMode(state, a) === blockMode(state, b);

/**
 * The blocks of `ranges` when they differ from the field's (kind, from, to, key, mode), else
 * null: what the scanner dispatches.
 */
export function syncBlocks(state: EditorState, ranges: readonly Range[]): readonly BlockSpec[] | null {
  const current = state.field(renderedBlocks, false);
  if (!current) return null;
  const scanned = scanBlocks(state, ranges);
  if (scanned.length === current.blocks.length && scanned.every((b, i) => sameBlock(state, b, current.blocks[i]!))) {
    return null;
  }
  return scanned;
}

/** The visible ranges, one screen of margin added on both sides, within the viewport. */
function scanRanges(view: EditorView): Range[] {
  const margin = view.scrollDOM.clientHeight;
  const { viewport } = view;
  const out: Range[] = [];
  for (const r of view.visibleRanges) {
    const top = Math.max(0, view.lineBlockAt(r.from).top - margin);
    const bottom = view.lineBlockAt(r.to).bottom + margin;
    const from = Math.max(viewport.from, view.lineBlockAtHeight(top).from);
    const to = Math.min(viewport.to, view.lineBlockAtHeight(bottom).to);
    const last = out.at(-1);
    if (last && from <= last.to) last.to = Math.max(last.to, to);
    else if (to >= from) out.push({ from, to });
  }
  return out;
}

const blockScanner = ViewPlugin.fromClass(
  class {
    stale = false;
    scheduled = false;
    destroyed = false;

    constructor(readonly view: EditorView) {
      // Cold start: estimates from the view's metrics before any widget was measured.
      if (layout.lineHeight <= 0) {
        Object.assign(layout, { width: view.contentDOM.clientWidth, lineHeight: view.defaultLineHeight, charWidth: view.defaultCharacterWidth });
      }
      this.schedule();
    }

    update(update: ViewUpdate) {
      const changed =
        update.docChanged ||
        update.viewportChanged ||
        syntaxTree(update.startState) !== syntaxTree(update.state) ||
        update.startState.facet(blockRenderers) !== update.state.facet(blockRenderers) ||
        update.startState.facet(hideMarkdown) !== update.state.facet(hideMarkdown);
      switch (blockUpdatePlan({ composing: update.view.composing, changed: changed || this.stale })) {
        case "map":
          this.stale ||= changed;
          return;
        case "rescan":
          this.stale = false;
          this.schedule();
          return;
        case "keep":
          return;
      }
    }

    /** Scans after the update (a plugin may not dispatch during one), before the next paint. */
    schedule() {
      if (this.scheduled || this.view.state.facet(blockRenderers).length === 0) return;
      this.scheduled = true;
      queueMicrotask(() => {
        this.scheduled = false;
        if (this.destroyed) return;
        if (this.view.composing) {
          this.stale = true;
          return;
        }
        const next = syncBlocks(this.view.state, scanRanges(this.view));
        if (next) this.view.dispatch({ effects: setRenderedBlocks.of(next), annotations: Transaction.addToHistory.of(false) });
      });
    }

    destroy() {
      this.destroyed = true;
    }
  },
  {
    eventHandlers: {
      compositionend() {
        // A composition can end without a following transaction: catch up on what was skipped.
        afterComposition(() => {
          if (this.stale && !this.view.composing) {
            this.stale = false;
            this.schedule();
          }
        });
      },
    },
  },
);

const renderedList = (state: EditorState) =>
  (state.field(renderedBlocks, false)?.blocks ?? []).filter((b) => blockMode(state, b) === "rendered");

/**
 * The rendered block a vertical move from `head` to `next` enters: one that starts on the line
 * right below `head`'s line (forward) or ends on the line right above it (backward), when the move
 * leaves `head`'s line towards it. Blocks inside a folded range are never entered (a move over a
 * fold must not unfold it), and adjacency keeps a move that jumps over hidden lines from landing
 * in a block further away.
 */
export function enteredBlock(state: EditorState, head: number, next: number, forward: boolean): BlockSpec | null {
  const line = state.doc.lineAt(head).number;
  const folded = foldedRanges(state);
  const isFolded = (b: BlockSpec) => {
    let inside = false;
    folded.between(b.from, b.to, (from, to) => {
      if (from <= b.from && to >= b.from) inside = true;
      if (inside) return false;
    });
    return inside;
  };
  for (const block of renderedList(state)) {
    const adjacent = forward
      ? state.doc.lineAt(block.from).number === line + 1 && next >= block.from
      : state.doc.lineAt(block.to).number === line - 1 && next <= block.to;
    if (adjacent && !isFolded(block)) return block;
  }
  return null;
}

/**
 * ArrowDown/ArrowUp (Shift: extend) whose vertical move would enter a rendered block: the caret
 * goes to the renderer's entry point instead of into the zero-height lines. While an IME
 * composition has started such a move does nothing (no mode switch mid-composition; CodeMirror
 * itself ignores keys once the composition has changed the text).
 */
const moveAcross = (forward: boolean, extend: boolean) => (view: EditorView): boolean => {
  const { state } = view;
  if (renderedList(state).length === 0) return false;
  let crossed = false;
  const ranges = state.selection.ranges.map((range) => {
    const next = view.moveVertically(range, forward);
    const block = enteredBlock(state, range.head, next.head, forward);
    const renderer = block && rendererFor(state, block.kind);
    if (!block || !renderer) return extend ? EditorSelection.range(range.anchor, next.head, next.goalColumn) : next;
    crossed = true;
    const pos = renderer.entry(state, block, forward ? "above" : "below");
    return extend ? EditorSelection.range(range.anchor, pos) : EditorSelection.cursor(pos);
  });
  if (!crossed) return false;
  if (view.composing || view.compositionStarted) return true;
  view.dispatch({
    selection: EditorSelection.create(ranges, state.selection.mainIndex),
    scrollIntoView: true,
    userEvent: "select",
    annotations: blockEntry.of(true),
  });
  return true;
};

/**
 * Backspace at the (visual) start of the line below a rendered block, Delete at the end of the
 * line above one: the first press only puts the caret into the block (its source shows), instead
 * of joining the line onto hidden text. An empty line next to a block is removed as usual.
 */
const enterInsteadOfJoin = (forward: boolean): Command => (view) => {
  const { state } = view;
  const { main } = state.selection;
  if (state.selection.ranges.length > 1 || !main.empty) return false;
  const line = state.doc.lineAt(main.head);
  if (line.length === 0 || lineEdgePastHidden(state, main.head, forward) !== (forward ? line.to : line.from)) return false;
  const block = renderedList(state).find((b) => (forward ? b.from === line.to + 1 : b.to === line.from - 1));
  if (!block) return false;
  if (view.composing || view.compositionStarted) return true;
  view.dispatch({
    selection: EditorSelection.cursor(forward ? block.from : block.to),
    scrollIntoView: true,
    userEvent: "select",
    annotations: blockEntry.of(true),
  });
  return true;
};

/** Set while a page motion runs: `true` = down. */
let paging: boolean | null = null;

/**
 * PageDown/PageUp on macOS: scroll one page, the selection stays (NSTextView `scrollPageDown:`,
 * Bear), so a tall rendered table is shown page by page. In typewriter mode the caret line stays
 * centred (M6-R19), so the keys move the caret a page instead, past a rendered block (M6-R25).
 */
const scrollPage = (forward: boolean): Command => (view) => {
  if (view.state.facet(typewriterModeSetting)) return page(forward ? cursorPageDown : cursorPageUp, forward)(view);
  const scroller = view.scrollDOM;
  const distance = Math.max(view.defaultLineHeight, scroller.clientHeight - view.defaultLineHeight);
  scroller.scrollTop += forward ? distance : -distance;
  return true;
};

const page = (command: Command, forward: boolean): Command => (view) => {
  paging = forward;
  try {
    return command(view);
  } finally {
    paging = null;
  }
};

/**
 * PageDown/PageUp (and Ctrl-V/Alt-V, Ctrl-ArrowDown/Up) move by a pixel distance and can land in a
 * rendered block's zero-height lines, which would flip it to source mid-page. Such a head goes
 * past the block in the motion's direction instead (the block stays rendered).
 */
const pageFilter = EditorState.transactionFilter.of((tr) => {
  const forward = paging;
  if (forward === null || tr.docChanged || !tr.selection) return tr;
  const list = renderedList(tr.startState);
  if (list.length === 0) return tr;
  const length = tr.startState.doc.length;
  const sel = tr.selection;
  const ranges = sel.ranges.map((r) => {
    const block = list.find((b) => r.head >= b.from && r.head <= b.to);
    if (!block) return r;
    const head = forward ? (block.to < length ? block.to + 1 : block.to) : block.from > 0 ? block.from - 1 : block.from;
    return r.empty ? EditorSelection.cursor(head) : EditorSelection.range(r.anchor, head);
  });
  if (ranges.every((r, i) => r === sel.ranges[i])) return tr;
  return {
    selection: EditorSelection.create(ranges, sel.mainIndex),
    effects: tr.effects,
    scrollIntoView: tr.scrollIntoView,
    userEvent: tr.annotation(Transaction.userEvent) ?? "select",
  };
});

/**
 * A mouse selection whose head lands on a rendered block's lines (dragging over the widget) takes
 * the whole block: the head goes past it, away from the anchor. With `pointerSelection` the block
 * then stays rendered while it is spanned.
 */
const pointerFilter = EditorState.transactionFilter.of((tr) => {
  if (!tr.selection || tr.docChanged || tr.annotation(blockEntry) || !tr.isUserEvent("select.pointer")) return tr;
  const list = renderedList(tr.startState);
  if (list.length === 0) return tr;
  const length = tr.startState.doc.length;
  const sel = tr.selection;
  const ranges = sel.ranges.map((r) => {
    if (r.empty) return r;
    const block = list.find((b) => endOn(r.head, r.anchor, b) && (r.anchor < b.from || r.anchor > b.to));
    if (!block) return r;
    const head = r.anchor < block.from ? (block.to < length ? block.to + 1 : block.to) : block.from > 0 ? block.from - 1 : block.from;
    return EditorSelection.range(r.anchor, head);
  });
  if (ranges.every((r, i) => r === sel.ranges[i])) return tr;
  return [tr, { selection: EditorSelection.create(ranges, sel.mainIndex), userEvent: "select.pointer", sequential: true }];
});

const blockKeymap = Prec.high(
  keymap.of([
    { key: "ArrowDown", run: moveAcross(true, false), shift: moveAcross(true, true) },
    { key: "ArrowUp", run: moveAcross(false, false), shift: moveAcross(false, true) },
    // Emacs-style line motions (macOS): the same entry points.
    { mac: "Ctrl-n", run: moveAcross(true, false), shift: moveAcross(true, true) },
    { mac: "Ctrl-p", run: moveAcross(false, false), shift: moveAcross(false, true) },
    { mac: "PageDown", run: scrollPage(true), shift: page(selectPageDown, true) },
    { mac: "PageUp", run: scrollPage(false), shift: page(selectPageUp, false) },
    { key: "PageDown", run: page(cursorPageDown, true), shift: page(selectPageDown, true) },
    { key: "PageUp", run: page(cursorPageUp, false), shift: page(selectPageUp, false) },
    { mac: "Ctrl-ArrowDown", run: page(cursorPageDown, true), shift: page(selectPageDown, true) },
    { mac: "Ctrl-ArrowUp", run: page(cursorPageUp, false), shift: page(selectPageUp, false) },
    { mac: "Ctrl-v", run: page(cursorPageDown, true) },
    { mac: "Alt-v", run: page(cursorPageUp, false) },
  ]),
);

// Before hiding's and lists' Backspace/Delete (both Prec.high, registered earlier).
const joinKeymap = Prec.highest(
  keymap.of([
    { key: "Backspace", run: enterInsteadOfJoin(false) },
    { key: "Delete", run: enterInsteadOfJoin(true) },
  ]),
);

/**
 * A primary-button mousedown on a rendered widget puts the caret at the renderer's position
 * (Shift: extends the main selection to it). `"handled"` from `click`: the renderer acted itself
 * (⌘-click on a link) and the block stays rendered. Nothing happens in a locked editor or while
 * an IME composition has started.
 */
const blockPointer = EditorView.domEventHandlers({
  mousedown(event, view) {
    if (event.button !== 0) return false;
    const target = event.target;
    const host = target instanceof Element ? target.closest(`.${BLOCK_CLASS}-rendered`) : null;
    if (!host || !view.contentDOM.contains(host)) return false;
    event.preventDefault();
    if (!view.state.facet(EditorView.editable) || view.composing || view.compositionStarted) return true;
    const at = view.posAtDOM(host);
    const block = renderedList(view.state).find((b) => b.from === at);
    const renderer = block && rendererFor(view.state, block.kind);
    if (!block || !renderer) return true;
    const clicked = renderer.click?.(view, block, event);
    if (clicked === "handled") return true;
    const pos = clicked ?? renderer.entry(view.state, block, "above");
    const main = view.state.selection.main;
    view.focus();
    view.dispatch({
      selection: event.shiftKey ? EditorSelection.range(main.anchor, pos) : EditorSelection.cursor(pos),
      userEvent: "select.pointer",
      annotations: blockEntry.of(true),
    });
    return true;
  },
});

const blockTheme = EditorView.baseTheme({
  // Zero height whatever other line rules add (paragraph spacing, M7 text indents): !important,
  // as line classes come from several features. Not overflow:hidden: WebKit's text iterator (so
  // innerText and the AX text) skips text in a zero-size box that clips its overflow; clip-path
  // hides any overflow (inline widgets of other features) without that.
  [`.cm-content .cm-line.${COLLAPSED_LINE_CLASS}`]: {
    height: "0 !important",
    minHeight: "0 !important",
    padding: "0 !important",
    margin: "0 !important",
    borderTopWidth: "0 !important",
    borderBottomWidth: "0 !important",
    overflow: "visible !important",
    clipPath: "inset(50%)",
  },
  [`.${BLOCK_CLASS}`]: { display: "block", cursor: "default" },
  [`.${BLOCK_CLASS}-rendered`]: { borderRadius: "4px" },
  [`.cm-content:focus .${BLOCK_CLASS}-rendered:hover`]: { outline: "1px solid var(--bc-color-rule)" },
});

export const blocks: Extension = [
  pointerSelection,
  renderedBlocks,
  blockScanner,
  blockKeymap,
  joinKeymap,
  pageFilter,
  pointerFilter,
  blockPointer,
  blockTheme,
];
