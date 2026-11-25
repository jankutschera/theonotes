// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  findClusterBreak,
  Prec,
  type SelectionRange,
} from "@codemirror/state";
import {
  type Command,
  Decoration,
  type DecorationSet,
  Direction,
  EditorView,
  keymap,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import {
  cursorLineBoundaryBackward,
  cursorLineBoundaryForward,
  cursorLineBoundaryLeft,
  cursorLineBoundaryRight,
  selectLineBoundaryBackward,
  selectLineBoundaryForward,
  selectLineBoundaryLeft,
  selectLineBoundaryRight,
} from "@codemirror/commands";
import { codePointAt, scanInline } from "../dialect-grammar";
import { highlightColors } from "../dialect";
import { footnotesIn } from "./footnotes";
import { hiddenFontBase64 } from "./hidden-font";

export type Range = { from: number; to: number };
/** A hidden range; `color` ranges (highlight color emoji) also get a colored dot widget. */
export type HiddenRange = Range & { color?: string };

/** Mark node → the element(s) it belongs to (hidden unless the caret is inside the element). */
const inlineElements: Record<string, string> = {
  EmphasisMark: "Emphasis|StrongEmphasis",
  StrikethroughMark: "Strikethrough",
  CodeMark: "InlineCode",
  HighlightMark: "Highlight",
  UnderlineMark: "Underline",
  WikiLinkMark: "WikiLink",
};

/** The caret (or a range selection) is inside the element; sitting on its outer edge does not count. */
const intersects = (sel: readonly SelectionRange[], from: number, to: number) =>
  sel.some((r) => r.from < to && r.to > from);

let attachmentLine: { doc: EditorState["doc"]; from: number; starts: Set<number> } | null = null;

/**
 * The link starting at `from` is a file attachment (`[name](relative)` and a `<!-- {…} -->`
 * metadata comment), which attachments.ts draws and collapses as a whole. The one recognizer is
 * dialect-grammar.ts `scanInline` (attachments.ts `attachmentsIn` uses it too).
 */
export function isAttachmentLinkAt(state: EditorState, from: number): boolean {
  const line = state.doc.lineAt(from);
  if (attachmentLine?.doc !== state.doc || attachmentLine.from !== line.from) {
    const starts = new Set(scanInline(line.text).attachments.filter((a) => !a.isImage).map((a) => line.from + a.from));
    attachmentLine = { doc: state.doc, from: line.from, starts };
  }
  return attachmentLine!.starts.has(from);
}

/** Any selection range touches the line(s) of [from, to]. */
function touchesLines(state: EditorState, sel: readonly SelectionRange[], from: number, to: number): boolean {
  const start = state.doc.lineAt(from).from;
  const end = state.doc.lineAt(to).to;
  return sel.some((r) => r.from <= end && r.to >= start);
}

/**
 * The Hide Markdown setting (bridge `setSettings`, settings.ts): on, markup is hidden unless the
 * caret is inside its element; off, all markup shows (dimmed). Block markers that give way to a
 * widget (bullets, quote bars, rules: typography.ts) are not markup in this sense.
 */
export const hideMarkdown = Facet.define<boolean, boolean>({ combine: (values) => values[0] ?? true });

export type Markup = {
  /** Collapsed (zero width, atomic); split per line. */
  hidden: HiddenRange[];
  /**
   * Revealed markup marks (caret inside the element, or Hide Markdown off), shown in the secondary
   * color. Disjoint from `hidden`: a class on a mark that overlapped a hidden range would
   * split the collapsed span (Task 2 concern 2), so these are the marks minus the hidden ranges.
   */
  dim: Range[];
};

/**
 * Markup ranges to hide (ruling R10): ATX heading marks (plus the following space) unless the
 * selection is on the heading's line; emphasis, strikethrough, highlight (its color emoji
 * becomes a dot), underline and inline-code marks, wiki link brackets (and the target when an
 * alias is shown), the backslash of escapes, the brackets + URL of inline links and the `[^` / `]`
 * of footnote references, unless the selection is inside the element. Pure; `within` limits the walk (e.g. to the visible ranges).
 */
export function computeHiddenRanges(state: EditorState, within?: readonly Range[]): HiddenRange[] {
  return computeMarkup(state, within).hidden;
}

/** The hidden and the dimmed (revealed) markup in `within` (default: the whole document). Pure. */
export function computeMarkup(state: EditorState, within?: readonly Range[]): Markup {
  const tree = syntaxTree(state);
  const sel = state.selection.ranges;
  const hide = state.facet(hideMarkdown);
  const out: HiddenRange[] = [];
  const marks: Range[] = [];
  const spans = within ?? [{ from: 0, to: state.doc.length }];
  const mark = (from: number, to: number) => {
    if (to > from) marks.push({ from, to });
  };

  for (const span of spans) {
    tree.iterate({
      from: span.from,
      to: span.to,
      enter(node) {
        const parent = node.node.parent;
        switch (node.name) {
          case "HeaderMark": {
            if (!parent || !/^ATXHeading\d$/.test(parent.name)) return;
            mark(node.from, node.to);
            if (touchesLines(state, sel, parent.from, parent.to)) return;
            const next = state.doc.sliceString(node.to, node.to + 1);
            out.push({ from: node.from, to: node.to + (next === " " || next === "\t" ? 1 : 0) });
            return;
          }
          case "QuoteMark":
            // Collapsed off its line by typography.ts; revealed on the caret's line.
            if (touchesLines(state, sel, node.from, node.to)) mark(node.from, node.to);
            return;
          case "HighlightColor": {
            if (!parent || parent.name !== "Highlight" || intersects(sel, parent.from, parent.to)) return;
            const color = highlightColors[codePointAt(state.doc.sliceString(node.from, node.to), 0)];
            if (color) out.push({ from: node.from, to: node.to, color });
            return;
          }
          case "Escape":
            mark(node.from, node.from + 1);
            if (!intersects(sel, node.from, node.to)) out.push({ from: node.from, to: node.from + 1 });
            return;
          case "InlineMath": {
            // A rendered formula (math.ts) hides its whole source; an empty one stays text with
            // dimmed marks, as does a formula the selection is in.
            const [open, close] = node.node.getChildren("MathMark");
            if (!open || !close) return;
            const rendered = /\S/.test(state.doc.sliceString(open.to, close.from)) && !intersects(sel, node.from, node.to);
            if (rendered) out.push({ from: node.from, to: node.to });
            else {
              mark(open.from, open.to);
              mark(close.from, close.to);
            }
            return false;
          }
          case "TagMark":
            // The closing `#` of a multi-word tag hides like other closing markup; the opening `#` stays.
            if (!parent || parent.name !== "Tag" || node.from === parent.from) return;
            if (!intersects(sel, parent.from, parent.to)) out.push({ from: node.from, to: node.to });
            return;
          case "WikiLink": {
            const alias = node.node.getChild("WikiAlias");
            if (alias && !intersects(sel, node.from, node.to)) {
              out.push({ from: node.from, to: alias.from }, { from: alias.to, to: node.to });
            }
            return;
          }
          case "Link": {
            const link = node.node;
            const url = link.getChild("URL");
            if (!url) return;
            // A file attachment is collapsed as a whole by its widget (attachments.ts).
            if (isAttachmentLinkAt(state, link.from)) return;
            const linkMarks = link.getChildren("LinkMark");
            for (const m of linkMarks) mark(m.from, m.to);
            if (intersects(sel, link.from, link.to)) return;
            const open = linkMarks[0];
            const close = linkMarks[1];
            if (!open || !close) return;
            out.push({ from: open.from, to: open.to }, { from: close.from, to: link.to });
            return;
          }
        }
        const parents = inlineElements[node.name];
        if (!parents) return;
        if (!parent || !parents.split("|").includes(parent.name)) return;
        mark(node.from, node.to);
        if (!intersects(sel, parent.from, parent.to)) out.push({ from: node.from, to: node.to });
      },
    });
  }

  // Footnote references (footnotes.ts): `[^` and `]` around the superscript label.
  for (const f of footnotesIn(state, spans)) {
    if (f.kind !== "ref") continue;
    mark(f.from, f.labelFrom);
    mark(f.labelTo, f.to);
    if (!intersects(sel, f.from, f.to)) out.push({ from: f.from, to: f.labelFrom }, { from: f.labelTo, to: f.to });
  }

  if (!hide) return { hidden: [], dim: sortedUnique(marks) };
  out.sort((a, b) => a.from - b.from || a.to - b.to);
  const merged: HiddenRange[] = [];
  for (const r of out) {
    const last = merged.at(-1);
    if (last && r.from < last.to) {
      last.to = Math.max(last.to, r.to);
      delete last.color;
    } else if (r.to > r.from) merged.push({ ...r });
  }
  // Plugin decorations may not replace line breaks (e.g. multi-line link
  // titles), so split every range into its per-line pieces.
  const hidden = merged.flatMap((r) => {
    const pieces: HiddenRange[] = [];
    let from = r.from;
    for (const line of state.doc.sliceString(r.from, r.to).split("\n")) {
      if (line.length > 0) pieces.push({ ...r, from, to: from + line.length });
      from += line.length + 1;
    }
    return pieces;
  });
  return { hidden, dim: subtract(sortedUnique(marks), merged) };
}

function sortedUnique(ranges: Range[]): Range[] {
  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  return ranges.filter((r, i) => i === 0 || r.from >= ranges[i - 1]!.to);
}

/** `ranges` minus `cut` (both sorted, `cut` disjoint): the pieces outside every cut range. */
function subtract(ranges: readonly Range[], cut: readonly Range[]): Range[] {
  const out: Range[] = [];
  let j = 0;
  for (const r of ranges) {
    while (j < cut.length && cut[j]!.to <= r.from) j++;
    let from = r.from;
    for (let k = j; k < cut.length && cut[k]!.from < r.to; k++) {
      if (cut[k]!.from > from) out.push({ from, to: cut[k]!.from });
      from = Math.max(from, cut[k]!.to);
    }
    if (from < r.to) out.push({ from, to: r.to });
  }
  return out;
}

/**
 * Backspace/Delete next to hidden markup removes the nearest visible character instead of the
 * hidden mark (Review Focus 1): `**bold**|` + Backspace → `**bol**`. Null when the default
 * command should run (range selections, nothing hidden next to the caret, line edges).
 */
export function visibleCharDeletion(state: EditorState, forward: boolean): Range | null {
  if (state.selection.ranges.length > 1 || !state.selection.main.empty) return null;
  const head = state.selection.main.head;
  const line = state.doc.lineAt(head);
  const hidden = computeHiddenRanges(state, [{ from: line.from, to: line.to }]);
  const pos = skipHidden(hidden, head, forward);
  if (pos === head || pos === (forward ? line.to : line.from)) return null;
  const other = findClusterBreak(line.text, pos - line.from, forward) + line.from;
  return forward ? { from: pos, to: other } : { from: other, to: pos };
}

/** Steps from `pos` over adjacent hidden ranges (forward: those starting there). */
function skipHidden(hidden: readonly HiddenRange[], pos: number, forward: boolean): number {
  for (;;) {
    const r = hidden.find((h) => (forward ? h.from === pos : h.to === pos));
    if (!r) return pos;
    pos = forward ? r.to : r.from;
  }
}

/**
 * End/Home: when only hidden markup separates the visual line boundary from the end (start)
 * of the line, go to the real line end (start), so `**bold**` + End + typing appends after
 * the closing `**` instead of inside the bold text.
 */
export function lineEdgePastHidden(state: EditorState, pos: number, forward: boolean): number {
  const line = state.doc.lineAt(pos);
  const hidden = computeHiddenRanges(state, [{ from: line.from, to: line.to }]);
  const skipped = skipHidden(hidden, pos, forward);
  return skipped === (forward ? line.to : line.from) ? skipped : pos;
}

/** Set while a CodeMirror line-boundary command runs: `true` = towards the line end. */
let lineEdgeForward: boolean | null = null;

/**
 * Runs CodeMirror's own line-boundary command (smart Home, wrapped lines, second press), then
 * `lineEdgeFilter` only moves a head that stopped right before (after) hidden markup that
 * reaches the line end (start).
 */
const lineEdge =
  (command: Command, direction: "forward" | "backward" | "right" | "left"): Command =>
  (view) => {
    const head = view.state.selection.main.head;
    const ltr = view.textDirectionAt(head) === Direction.LTR;
    lineEdgeForward = direction === "forward" || (direction === "right" ? ltr : direction === "left" ? !ltr : false);
    try {
      return command(view);
    } finally {
      lineEdgeForward = null;
    }
  };

const lineEdgeFilter = EditorState.transactionFilter.of((tr) => {
  const forward = lineEdgeForward;
  if (forward === null || tr.docChanged || !tr.selection) return tr;
  const sel = tr.selection;
  const ranges = sel.ranges.map((r) => {
    const head = lineEdgePastHidden(tr.startState, r.head, forward);
    if (head === r.head) return r;
    return r.empty ? EditorSelection.cursor(head) : EditorSelection.range(r.anchor, head);
  });
  if (ranges.every((r, i) => r === sel.ranges[i])) return tr;
  return { selection: EditorSelection.create(ranges, sel.mainIndex), scrollIntoView: tr.scrollIntoView, userEvent: "select" };
});

const deleteVisible = (forward: boolean) => (view: EditorView) => {
  const range = visibleCharDeletion(view.state, forward);
  if (!range) return false;
  view.dispatch({ changes: range, scrollIntoView: true, userEvent: forward ? "delete.forward" : "delete.backward" });
  return true;
};

class ColorDot extends WidgetType {
  constructor(readonly color: string) {
    super();
  }

  override eq(other: ColorDot) {
    return other.color === this.color;
  }

  toDOM() {
    const dot = document.createElement("span");
    dot.className = `cm-highlight-dot cm-highlight-dot-${this.color}`;
    dot.setAttribute("aria-hidden", "true");
    return dot;
  }
}

/**
 * Hidden markup stays in the DOM as text (finding F8: the accessibility text, and so VoiceOver,
 * dictation and Writing Tools offsets, must equal the document text); the mark only collapses
 * it to zero width. The same ranges are atomic for the caret. Not editable, so WebKit never
 * types or composes (IME) into the invisible text next to it.
 */
export const hiddenMark = Decoration.mark({ class: "cm-bc-hidden", attributes: { contenteditable: "false" } });
const dots = new Map<string, Decoration>();
const dot = (color: string) => {
  let deco = dots.get(color);
  if (!deco) dots.set(color, (deco = Decoration.widget({ widget: new ColorDot(color), side: 1 })));
  return deco;
};

/**
 * Collapsing marks for the hidden ranges; a highlight color emoji keeps its (hidden) text and
 * gets an aria-hidden dot widget right before it.
 */
export function hidingDecorations(hidden: readonly HiddenRange[]): DecorationSet {
  return Decoration.set(
    hidden.flatMap((r) =>
      r.color ? [dot(r.color).range(r.from), hiddenMark.range(r.from, r.to)] : [hiddenMark.range(r.from, r.to)],
    ),
    true,
  );
}

/** Revealed markup in the secondary color (Bear); never atomic, never overlapping hidden text. */
const dimMark = Decoration.mark({ class: "cm-bc-markup" });

export function dimDecorations(dim: readonly Range[]): DecorationSet {
  return Decoration.set(dim.map((r) => dimMark.range(r.from, r.to)));
}

function build(view: EditorView): { decorations: DecorationSet; dim: DecorationSet } {
  const markup = computeMarkup(view.state, view.visibleRanges);
  return { decorations: hidingDecorations(markup.hidden), dim: dimDecorations(markup.dim) };
}

/** Never touch the DOM around an active IME composition; catch up once it ends. */
export function hidingUpdatePlan(u: { changed: boolean; composing: boolean; stale: boolean }): "map" | "rebuild" | "keep" {
  if (u.composing) return "map";
  return u.changed || u.stale ? "rebuild" : "keep";
}

/** The outermost hidden-markup element around `node` (inside `root`), if any. */
function hiddenAncestor(node: Node, root: HTMLElement): HTMLElement | null {
  let found: HTMLElement | null = null;
  for (let n: Node | null = node; n && n !== root; n = n.parentNode) {
    if (n.nodeType === 1 && (n as HTMLElement).classList.contains("cm-bc-hidden")) found = n as HTMLElement;
  }
  return found;
}

type DOMPoint = { node: Node; offset: number };

/**
 * A DOM point just before or after the hidden element `point` is in: a point at the element's
 * start stays before it; any other point (its end, or a point inside it) moves after it, i.e. to
 * the hidden range's end.
 */
function outsideHidden(view: EditorView, point: DOMPoint): DOMPoint | null {
  const hidden = hiddenAncestor(point.node, view.contentDOM);
  const parent = hidden?.parentNode;
  if (!hidden || !parent) return null;
  const index = Array.prototype.indexOf.call(parent.childNodes, hidden) as number;
  const atStart = view.posAtDOM(point.node, point.offset) <= view.posAtDOM(hidden, 0);
  return { node: parent, offset: atStart ? index : index + 1 };
}

/**
 * CodeMirror may put the DOM caret inside a hidden (non-editable) span at its edge, where WebKit
 * would drop typed, dictated or composed text. Move it to the equivalent point outside.
 */
export function steerSelectionOutOfHidden(view: EditorView): boolean {
  if (view.composing || !view.hasFocus) return false;
  const sel = document.getSelection();
  if (!sel?.anchorNode || !sel.focusNode || !view.contentDOM.contains(sel.focusNode)) return false;
  const anchor = { node: sel.anchorNode, offset: sel.anchorOffset };
  const focus = { node: sel.focusNode, offset: sel.focusOffset };
  const a = outsideHidden(view, anchor);
  const f = outsideHidden(view, focus);
  if (!a && !f) return false;
  const na = a ?? anchor;
  const nf = f ?? focus;
  sel.setBaseAndExtent(na.node, na.offset, nf.node, nf.offset);
  return true;
}

const selectionSteering = ViewPlugin.fromClass(
  class {
    private readonly onSelectionChange = () => steerSelectionOutOfHidden(this.view);

    constructor(readonly view: EditorView) {
      document.addEventListener("selectionchange", this.onSelectionChange);
    }

    destroy() {
      document.removeEventListener("selectionchange", this.onSelectionChange);
    }
  },
  {
    eventHandlers: {
      // Before the browser inserts a typed character or starts an IME composition.
      keydown(_event, view) {
        steerSelectionOutOfHidden(view);
        return false;
      },
    },
  },
);

const hidingPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    dim: DecorationSet;
    stale = false;

    constructor(view: EditorView) {
      ({ decorations: this.decorations, dim: this.dim } = build(view));
    }

    update(update: ViewUpdate) {
      const changed =
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        update.startState.facet(hideMarkdown) !== update.state.facet(hideMarkdown) ||
        syntaxTree(update.startState) !== syntaxTree(update.state);
      switch (hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale })) {
        case "map":
          // Keep the previous decorations aligned with the text.
          this.decorations = this.decorations.map(update.changes);
          this.dim = this.dim.map(update.changes);
          this.stale ||= changed;
          return;
        case "rebuild":
          ({ decorations: this.decorations, dim: this.dim } = build(update.view));
          this.stale = false;
          return;
        case "keep":
          return;
      }
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
    eventHandlers: {
      compositionend(_event, view) {
        // A composition can end without a following transaction; flush the
        // recomputation we skipped while it was active.
        afterComposition(() => {
          if (this.stale && !view.composing) view.dispatch({});
        });
      },
    },
  },
);

const dotColors = ["green", "red", "blue", "yellow", "purple"];

/**
 * Registers the zero-advance font from bytes (no fetch, so the CSP's font-src does not apply).
 * Returns whether it is usable; without it hidden text falls back to `font-size: 0`.
 */
function registerHiddenFont(): boolean {
  if (typeof FontFace === "undefined" || typeof document === "undefined" || !document.fonts) return false;
  try {
    const bytes = Uint8Array.from(atob(hiddenFontBase64), (c) => c.charCodeAt(0));
    const face = new FontFace("TheoNotesHidden", bytes);
    document.fonts.add(face);
    // WebKit decodes byte sources synchronously; anything else would lay out hidden text in a
    // fallback font until it loads, so use the font only when it is ready now.
    return face.status === "loaded";
  } catch {
    return false;
  }
}

const hiddenFontReady = registerHiddenFont();
if (!hiddenFontReady && import.meta.env.DEV && typeof document !== "undefined") {
  console.warn(
    "[baerchen] TheoNotesHidden font did not load synchronously; hidden markup falls back to font-size: 0 " +
      "(no caret rects at hidden boundaries)",
  );
}

const dotTheme = EditorView.baseTheme({
  // Zero advance width while the text stays in the DOM and the accessibility tree (finding F8).
  // The font keeps real ascent/descent, so WebKit still reports rects for hidden text (caret
  // coords, posAtCoords); line-height 0 keeps its inline box from growing the line.
  // Also for nested elements (highlighter spans, other marks), which would otherwise bring back
  // their own font; a synthesized bold/italic or a tab stop could give hidden text an advance.
  ".cm-content .cm-bc-hidden, .cm-content .cm-bc-hidden *": {
    ...(hiddenFontReady ? { fontFamily: "TheoNotesHidden" } : { fontSize: "0" }),
    fontWeight: "normal",
    fontStyle: "normal",
    fontSynthesis: "none",
    tabSize: "0",
    lineHeight: "0",
    letterSpacing: "0",
    wordSpacing: "0",
    color: "transparent",
  },
  ".cm-bc-markup": { color: "var(--bc-color-secondary)" },
  ".cm-highlight-dot": {
    display: "inline-block",
    width: "0.5em",
    height: "0.5em",
    borderRadius: "50%",
    margin: "0 0.25em 0 0.1em",
    verticalAlign: "middle",
  },
  ...Object.fromEntries(
    dotColors.map((name) => [`.cm-highlight-dot-${name}`, { backgroundColor: `var(--bc-highlight-dot-${name})` }]),
  ),
});

export const hiding: Extension = [
  hidingPlugin,
  selectionSteering,
  EditorView.atomicRanges.of((view) => view.plugin(hidingPlugin)?.decorations ?? Decoration.none),
  EditorView.decorations.of((view) => view.plugin(hidingPlugin)?.dim ?? Decoration.none),
  Prec.high(keymap.of([
    { key: "Backspace", run: deleteVisible(false) },
    { key: "Delete", run: deleteVisible(true) },
    {
      key: "End",
      run: lineEdge(cursorLineBoundaryForward, "forward"),
      shift: lineEdge(selectLineBoundaryForward, "forward"),
      preventDefault: true,
    },
    {
      key: "Home",
      run: lineEdge(cursorLineBoundaryBackward, "backward"),
      shift: lineEdge(selectLineBoundaryBackward, "backward"),
      preventDefault: true,
    },
    {
      mac: "Cmd-ArrowRight",
      run: lineEdge(cursorLineBoundaryRight, "right"),
      shift: lineEdge(selectLineBoundaryRight, "right"),
      preventDefault: true,
    },
    {
      mac: "Cmd-ArrowLeft",
      run: lineEdge(cursorLineBoundaryLeft, "left"),
      shift: lineEdge(selectLineBoundaryLeft, "left"),
      preventDefault: true,
    },
  ])),
  lineEdgeFilter,
  dotTheme,
];
