// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Math (M6 Task 11): inline `$…$` and `$$` blocks rendered by
// MathJax (math-render.ts). Inline, caret outside: the source is hidden (hiding.ts; it stays in
// the DOM) and a widget shows the rendering; caret inside: the source with dimmed `$` and a live
// preview after it. Blocks render through the block layer (`mathBlockRenderer`), centred; in
// source mode the preview sits below the closing `$$`. Renderings and errors live in shadow roots,
// so their text is not part of the content text (F8). Nothing changes while composing.

import { EditorSelection, EditorState, type Extension, Prec, type Range as Ranged } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { isolateHistory } from "@codemirror/commands";
import type { SyntaxNodeRef } from "@lezer/common";
import type { CommandArgs } from "../../bridge/protocol";
import { type BlockRenderer, type BlockSpec, blockRenderers } from "./blocks";
import { hideMarkdown, hidingUpdatePlan } from "./hiding";
import { lineInCode } from "./lists";
import { MAX_TEX, renderMath } from "./math-render";
import type { CommandTarget } from "./commands";

type Range = { from: number; to: number };

/** An inline formula: its node extent, the TeX between the marks, display for `$$…$$`. */
export type InlineFormula = { from: number; to: number; tex: string; display: boolean };

function formulaOf(state: EditorState, node: SyntaxNodeRef): InlineFormula | null {
  const marks = node.node.getChildren("MathMark");
  const open = marks[0];
  const close = marks[1];
  if (!open || !close) return null;
  return {
    from: node.from,
    to: node.to,
    tex: state.doc.sliceString(open.to, close.from),
    display: open.to - open.from === 2,
  };
}

/** The inline formulas on the lines of `within` (default: the whole document). */
export function inlineFormulas(state: EditorState, within?: readonly Range[]): InlineFormula[] {
  const out: InlineFormula[] = [];
  const tree = syntaxTree(state);
  let seen = -1;
  for (const span of within ?? [{ from: 0, to: state.doc.length }]) {
    tree.iterate({
      from: span.from,
      to: span.to,
      enter(node) {
        if (node.name !== "InlineMath" || node.from <= seen) return;
        seen = node.from;
        const f = formulaOf(state, node);
        if (f) out.push(f);
        return false;
      },
    });
  }
  return out;
}

/** The selection is inside the formula (its outer edges do not count, as for hidden markup). */
const inside = (state: EditorState, f: Range) => state.selection.ranges.some((r) => r.from < f.to && r.to > f.from);

export type MathLayout = {
  /** Formulas shown rendered (their source hidden by hiding.ts). */
  rendered: InlineFormula[];
  /** Formulas being edited: a live preview after the closing mark. */
  previews: InlineFormula[];
};

/** Which inline formulas of `within` render and which show a preview. Pure. */
export function mathLayout(state: EditorState, within?: readonly Range[]): MathLayout {
  const layout: MathLayout = { rendered: [], previews: [] };
  if (!state.facet(hideMarkdown)) return layout;
  for (const f of inlineFormulas(state, within)) {
    if (f.tex.trim() === "") continue;
    (inside(state, f) ? layout.previews : layout.rendered).push(f);
  }
  return layout;
}

// ---------------------------------------------------------------------------------------------
// Widgets

/**
 * A MathJax rendering (or its error) in a shadow root. `role`: "inline" (in the text), "preview"
 * (after a formula being edited) or "block".
 */
class MathWidget extends WidgetType {
  constructor(
    readonly tex: string,
    readonly display: boolean,
    readonly role: "inline" | "preview" | "block",
  ) {
    super();
  }

  override eq(other: MathWidget) {
    return other.tex === this.tex && other.display === this.display && other.role === this.role;
  }

  override toDOM(view: EditorView): HTMLElement {
    const host: HTMLElement = document.createElement(this.role === "block" ? "div" : "span");
    host.className = `cm-bc-math cm-bc-math-${this.role}`;
    host.setAttribute("aria-hidden", "true");
    host.contentEditable = "false";
    // Inline: a shadow root of its own. A block already sits in the block layer's shadow root
    // (its CSS comes through `mathBlockRenderer.styles`).
    const box = document.createElement(this.role === "block" ? "div" : "span");
    box.className = this.role === "block" || this.display ? "display" : "inline";
    if (this.role === "block") host.append(box);
    else {
      const root = host.attachShadow({ mode: "open" });
      const sheet = mathSheet();
      if (sheet) root.adoptedStyleSheets = [sheet];
      root.append(box);
    }
    void renderMath(this.tex, this.display || this.role === "block").then((result) => {
      // Filled even before CodeMirror attached the widget (a cached result settles at once).
      if ("svg" in result) box.replaceChildren(result.svg.cloneNode(true));
      else {
        const error = document.createElement("span");
        error.className = "cm-bc-math-error";
        error.textContent = result.error;
        box.replaceChildren(error);
      }
      // The rendering changes the line's height (a tall fraction, a block).
      if (box.isConnected) view.requestMeasure();
    });
    if (this.role !== "block") {
      // A click on a rendering (or its error) puts the caret in the source.
      host.addEventListener("mousedown", (event) => {
        if (event.button !== 0 || view.composing || view.compositionStarted) return;
        event.preventDefault();
        const pos = view.posAtDOM(host);
        const f = inlineFormulas(view.state, [{ from: pos, to: pos }]).find((x) => x.from <= pos && pos <= x.to);
        if (f) view.dispatch({ selection: EditorSelection.cursor(f.to - (f.display ? 2 : 1)), userEvent: "select.pointer" });
        view.focus();
      });
    }
    return host;
  }

  override get estimatedHeight(): number {
    return this.role === "block" ? 48 : -1;
  }

  override ignoreEvent(): boolean {
    // Its own mousedown listener places the caret.
    return true;
  }
}

const MATH_CSS = `
  :host { display: inline-block; vertical-align: baseline; }
  :host(.cm-bc-math-block) { display: block; }
  :host(.cm-bc-math-preview) { margin-left: 0.4em; opacity: 0.85; }
  .display { display: block; text-align: center; padding: 0.4em 0; overflow-x: auto; }
  .inline { display: inline-block; }
  svg { overflow: visible; }
  .cm-bc-math-error {
    color: var(--bc-color-math-error, var(--bc-color-secondary));
    font-family: -apple-system, system-ui, sans-serif;
    font-size: 0.85em;
    font-style: normal;
  }
`;

let sheet: CSSStyleSheet | null | undefined;
/** One constructable sheet (not subject to the CSP's style-src). */
function mathSheet(): CSSStyleSheet | null {
  if (sheet === undefined) {
    try {
      sheet = new CSSStyleSheet();
      sheet.replaceSync(MATH_CSS);
    } catch {
      sheet = null;
    }
  }
  return sheet;
}

function mathDecorations(view: EditorView): DecorationSet {
  const layout = mathLayout(view.state, view.visibleRanges);
  const ranges: Ranged<Decoration>[] = [];
  // Before the hidden source (side -1), never inside its hidden-font span.
  for (const f of layout.rendered) ranges.push(Decoration.widget({ widget: new MathWidget(f.tex, f.display, "inline"), side: -1 }).range(f.from));
  for (const f of layout.previews) ranges.push(Decoration.widget({ widget: new MathWidget(f.tex, f.display, "preview"), side: 1 }).range(f.to));
  return Decoration.set(ranges, true);
}

const mathPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    stale = false;
    constructor(view: EditorView) {
      this.decorations = mathDecorations(view);
    }
    update(update: ViewUpdate) {
      const changed =
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        update.startState.facet(hideMarkdown) !== update.state.facet(hideMarkdown) ||
        syntaxTree(update.startState) !== syntaxTree(update.state);
      // Never rebuilt while composing (global constraint): kept aligned, rebuilt afterwards.
      const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
      if (plan === "rebuild") {
        this.decorations = mathDecorations(update.view);
        this.stale = false;
        return;
      }
      if (update.docChanged) this.decorations = this.decorations.map(update.changes);
      if (plan === "map") this.stale ||= changed;
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

// ---------------------------------------------------------------------------------------------
// Keyboard: arrows (and Backspace/Delete) next to a rendered formula enter its source

/** The rendered formula whose edge `pos` is (`end`: its end, else its start), if any. */
function renderedAt(state: EditorState, pos: number, end: boolean): InlineFormula | null {
  if (!state.facet(hideMarkdown)) return null;
  const line = state.doc.lineAt(pos);
  return mathLayout(state, [{ from: line.from, to: line.to }]).rendered.find((f) => (end ? f.to === pos : f.from === pos)) ?? null;
}

/**
 * Where an arrow (or Backspace/Delete) at a rendered formula's edge puts the caret: just inside
 * it, which reveals its source. Null when the caret is at no rendered formula's edge.
 */
export function formulaEntry(state: EditorState, forward: boolean): number | null {
  const main = state.selection.main;
  if (state.selection.ranges.length > 1 || !main.empty) return null;
  const f = renderedAt(state, main.head, !forward);
  return f ? (forward ? f.from + 1 : f.to - 1) : null;
}

const enter = (forward: boolean) => (view: Pick<EditorView, "composing" | "compositionStarted" | "state" | "dispatch">) => {
  if (view.composing || view.compositionStarted) return false;
  const at = formulaEntry(view.state, forward);
  if (at === null) return false;
  view.dispatch({ selection: EditorSelection.cursor(at), scrollIntoView: true, userEvent: "select" });
  return true;
};

/** The keymap's command for an arrow key (exported for tests). */
export const enterFormulaCommand = enter;

// Before hiding.ts's Backspace/Delete over hidden markup (it would delete the text before the formula).
const mathKeymap = Prec.highest(
  keymap.of([
    { key: "ArrowRight", run: enter(true) },
    { key: "ArrowLeft", run: enter(false) },
    // Next to a rendered formula Backspace/Delete reveal it instead of deleting text hidden from view.
    { key: "Backspace", run: enter(false) },
    { key: "Delete", run: enter(true) },
  ]),
);

// ---------------------------------------------------------------------------------------------
// Block math

function matchMathBlock(state: EditorState, node: SyntaxNodeRef): BlockSpec | null {
  if (node.name !== "MathBlock") return null;
  const first = state.doc.lineAt(node.from);
  const last = state.doc.lineAt(node.to);
  return { kind: "mathBlock", from: first.from, to: last.to, key: state.doc.sliceString(first.from, last.to) };
}

/** The TeX of a block: between the opening and closing `$$` lines. */
function blockTex(key: string): string {
  const lines = key.split("\n");
  return lines.slice(1, -1).join("\n");
}

/** `blockTex(key).length` without splitting the block (called per block on every edit). */
function blockTexLength(key: string): number {
  const first = key.indexOf("\n");
  const last = key.lastIndexOf("\n");
  return first < 0 || last <= first ? 0 : last - first - 1;
}

export const mathBlockRenderer: BlockRenderer = {
  kind: "mathBlock",
  match: matchMathBlock,
  rendered: (block) => new MathWidget(blockTex(block.key), true, "block"),
  preview: (block) => new MathWidget(blockTex(block.key), true, "block"),
  styles: MATH_CSS,
  // TeX over MAX_TEX never renders (renderMath refuses it): the source stays shown with the error
  // below, instead of an error widget over thousands of collapsed lines.
  sourceOnly: (block) => block.key.length > MAX_TEX && blockTexLength(block.key) > MAX_TEX,
  entry(state, block, from) {
    const first = state.doc.lineAt(block.from);
    const last = state.doc.lineAt(block.to);
    // The first or last TeX line (the fences when there is none).
    if (last.number - first.number < 2) return from === "above" ? first.to : last.from;
    return from === "above" ? state.doc.line(first.number + 1).from : state.doc.line(last.number - 1).to;
  },
};

// ---------------------------------------------------------------------------------------------
// Command

const FORMAT_EVENT = "input.format";

/** Code, math, comments and front matter: no formula goes in or around them. */
const NO_MATH = new Set(["FencedCode", "CodeBlock", "InlineCode", "MathBlock", "InlineMath", "Comment", "CommentBlock", "FrontMatter", "HTMLBlock"]);

/** A code or math node lies inside or across `from`…`to` (or holds the caret strictly). */
function touchesCodeOrMath(state: EditorState, from: number, to: number): boolean {
  let found = false;
  syntaxTree(state).iterate({
    from,
    to,
    enter(node) {
      if (found) return false;
      if (!NO_MATH.has(node.name)) return;
      // A caret on a node's outer edge is outside it; a range must not overlap it.
      found = from === to ? node.from < from && node.to > from : node.from < to && node.to > from;
    },
  });
  return found;
}

/**
 * Format ▸ Math `{display?}`: `$…$` around the selection (the caret between them when empty), or
 * a `$$` block around it on its own lines with the caret inside. One undo step; refused in
 * read-only notes and in code.
 */
export function insertMathCommand({ state, dispatch }: CommandTarget, args?: CommandArgs): boolean {
  if (state.readOnly || state.selection.ranges.length > 1) return false;
  const main = state.selection.main;
  if (lineInCode(state, state.doc.lineAt(main.from)) || touchesCodeOrMath(state, main.from, main.to)) return false;
  const text = state.doc.sliceString(main.from, main.to);
  let insert: string;
  let caret: number;
  if (args?.display === true) {
    const before = main.from > state.doc.lineAt(main.from).from ? "\n" : "";
    const after = main.to < state.doc.lineAt(main.to).to ? "\n" : "";
    insert = `${before}$$\n${text}\n$$${after}`;
    caret = main.from + before.length + 3 + text.length;
  } else {
    insert = `$${text}$`;
    caret = main.from + 1 + text.length;
  }
  dispatch(
    state.update({
      changes: { from: main.from, to: main.to, insert },
      selection: EditorSelection.cursor(caret),
      scrollIntoView: true,
      userEvent: FORMAT_EVENT,
      annotations: isolateHistory.of("full"),
    }),
  );
  return true;
}

export const math: Extension = [mathPlugin, mathKeymap, blockRenderers.of(mathBlockRenderer)];
