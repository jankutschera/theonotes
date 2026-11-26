// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Mermaid diagrams (M6 Task 12): a ```mermaid fence renders through the block layer.
// Caret outside: the code is collapsed and the diagram shows; caret inside: the code block as
// usual with a live preview below (re-rendered once typing rests 300 ms). The diagram is an
// `<img>` of Mermaid's SVG (a data URL) in the layer's shadow root, never live SVG DOM, so labels
// from the note cannot run anything; errors show in its place. The theme follows the editor's
// appearance (neutral / dark, ruling X3).

import { EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../dialect";
import { EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import type { SyntaxNodeRef } from "@lezer/common";
import { type BlockRenderer, type BlockSpec, blockRenderers } from "./blocks";
import { codeBlockText, fenceLanguage } from "./codeblocks";
import { cachedMermaid, MAX_MERMAID_SOURCE, type MermaidResult, type MermaidTheme, renderMermaid } from "./mermaid-render";
import { currentSettings } from "./settings";

/** How long the source must rest before the preview re-renders. */
export const MERMAID_DEBOUNCE_MS = 300;

const idle = (run: () => void) =>
  typeof requestIdleCallback === "function" ? requestIdleCallback(() => run(), { timeout: 500 }) : setTimeout(run, 0);

/**
 * Pending renders by widget: a widget that is replaced (each edit of the source makes a new one)
 * cancels its render, so a run of edits renders once, `delay` after the last one, when idle.
 */
export class RenderQueue {
  /** Per widget: the debounce timer, then the idle callback; either phase can be cancelled. */
  private pendingRuns = new Map<object, { timer?: ReturnType<typeof setTimeout>; idle?: number | ReturnType<typeof setTimeout> }>();

  schedule(token: object, delay: number, run: () => void): void {
    this.cancel(token);
    const handles: { timer?: ReturnType<typeof setTimeout>; idle?: number | ReturnType<typeof setTimeout> } = {};
    handles.timer = setTimeout(() => {
      handles.timer = undefined;
      handles.idle = idle(() => {
        this.pendingRuns.delete(token);
        run();
      });
    }, delay);
    this.pendingRuns.set(token, handles);
  }

  cancel(token: object): void {
    const handles = this.pendingRuns.get(token);
    if (!handles) return;
    if (handles.timer !== undefined) clearTimeout(handles.timer);
    if (handles.idle !== undefined) {
      if (typeof cancelIdleCallback === "function" && typeof handles.idle === "number") cancelIdleCallback(handles.idle);
      else clearTimeout(handles.idle as ReturnType<typeof setTimeout>);
    }
    this.pendingRuns.delete(token);
  }

  get pending(): number {
    return this.pendingRuns.size;
  }
}

const queue = new RenderQueue();

const themeOf = (state: EditorState): MermaidTheme => (currentSettings(state).appearance === "dark" ? "dark" : "neutral");

/** The diagram source of recent block keys (a lookup cache; `sourceOf` re-derives a missing one). */
const sources = new Map<string, string>();

/** The fence's code: the key (the block's lines, container prefixes included) parsed on its own. */
function sourceOf(key: string): string {
  const known = sources.get(key);
  if (known !== undefined) return known;
  const state = EditorState.create({ doc: key, extensions: markdown({ base: bearMarkdown }) });
  const tree = ensureSyntaxTree(state, state.doc.length, 200) ?? syntaxTree(state);
  let source = "";
  tree.iterate({
    enter(node) {
      if (node.name !== "FencedCode") return;
      source = codeBlockText(state, node.node);
      return false;
    },
  });
  remember(key, source);
  return source;
}

function remember(key: string, source: string): void {
  sources.set(key, source);
  if (sources.size > 200) sources.delete(sources.keys().next().value!);
}

function matchMermaid(state: EditorState, node: SyntaxNodeRef): BlockSpec | null {
  if (node.name !== "FencedCode" || fenceLanguage(state, node.node).toLowerCase() !== "mermaid") return null;
  const first = state.doc.lineAt(node.from);
  const last = state.doc.lineAt(node.to);
  const key = state.doc.sliceString(first.from, last.to);
  if (!sources.has(key)) remember(key, codeBlockText(state, node.node));
  return { kind: "mermaid", from: first.from, to: last.to, key };
}

/** The `<img>` size of an SVG string: its viewBox (an `<img>` of a 100%-wide SVG has none). */
function viewBoxSize(svg: string): { width: number; height: number } | null {
  const m = /viewBox="\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)\s*"/.exec(svg);
  const width = m ? Number(m[1]) : NaN;
  const height = m ? Number(m[2]) : NaN;
  return width > 0 && height > 0 ? { width, height } : null;
}

function draw(box: HTMLElement, result: MermaidResult): void {
  if ("error" in result) {
    const error = document.createElement("div");
    error.className = "error";
    error.textContent = result.error;
    box.replaceChildren(error);
    return;
  }
  const img = document.createElement("img");
  img.alt = "";
  img.decoding = "async";
  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(result.svg)}`;
  const size = viewBoxSize(result.svg);
  if (size) {
    img.style.width = `min(100%, ${size.width}px)`;
    img.style.aspectRatio = `${size.width} / ${size.height}`;
  }
  box.replaceChildren(img);
}

type Live = { box: HTMLElement; source: string; view: EditorView; theme: MermaidTheme };
/** Drawn diagrams, so a theme change redraws them in place. */
const live = new Set<Live>();
const liveOf = new WeakMap<HTMLElement, Live>();

function render(entry: Live, delay: number): void {
  const cached = cachedMermaid(entry.source, entry.theme);
  if (cached) {
    draw(entry.box, cached);
    return;
  }
  if (!entry.box.firstChild) {
    const wait = document.createElement("div");
    wait.className = "pending";
    entry.box.replaceChildren(wait);
  }
  queue.schedule(entry, delay, () => {
    if (!live.has(entry)) return;
    const theme = entry.theme;
    void renderMermaid(entry.source, theme).then((result) => {
      if (!live.has(entry) || entry.theme !== theme) return;
      draw(entry.box, result);
    });
  });
}

class MermaidWidget extends WidgetType {
  constructor(
    readonly source: string,
    readonly role: "rendered" | "preview",
  ) {
    super();
  }

  override eq(other: MermaidWidget) {
    return other.source === this.source && other.role === this.role;
  }

  override toDOM(view: EditorView): HTMLElement {
    const box = document.createElement("div");
    box.className = `mermaid mermaid-${this.role}`;
    const entry: Live = { box, source: this.source, view, theme: themeOf(view.state) };
    live.add(entry);
    liveOf.set(box, entry);
    // A cached diagram draws at once (no height jump); the preview waits for typing to rest.
    render(entry, this.role === "preview" ? MERMAID_DEBOUNCE_MS : 0);
    return box;
  }

  override get estimatedHeight(): number {
    return 160;
  }

  override destroy(dom: HTMLElement): void {
    const entry = liveOf.get(dom);
    if (!entry) return;
    queue.cancel(entry);
    live.delete(entry);
  }
}

const MERMAID_CSS = `
  .mermaid { display: block; text-align: center; padding: 0.5em 0; min-height: 2em; }
  .mermaid img { display: inline-block; max-width: 100%; height: auto; }
  .pending { min-height: 6em; }
  .error {
    color: var(--bc-color-math-error, var(--bc-color-secondary));
    font-family: -apple-system, system-ui, sans-serif;
    font-size: 0.85em;
    text-align: left;
    white-space: pre-wrap;
  }
`;

export const mermaidRenderer: BlockRenderer = {
  kind: "mermaid",
  match: matchMermaid,
  rendered: (block) => new MermaidWidget(sourceOf(block.key), "rendered"),
  preview: (block) => new MermaidWidget(sourceOf(block.key), "preview"),
  entry(state, block, from) {
    // The first or last code line: between the opening fence and the closing one, if any.
    const first = state.doc.lineAt(block.from);
    const last = state.doc.lineAt(block.to);
    const closed = last.number > first.number && /^[\s>]*(`{3,}|~{3,})\s*$/.test(last.text);
    const lastCode = closed ? last.number - 1 : last.number;
    if (lastCode <= first.number) return first.to;
    return from === "above" ? state.doc.line(first.number + 1).from : state.doc.line(lastCode).to;
  },
  styles: MERMAID_CSS,
  // Too large to render: the code stays a code block, "Diagram too large" below it.
  sourceOnly: (block) => block.key.length > MAX_MERMAID_SOURCE,
};

/** Redraws the live diagrams of this editor when its appearance changes (neutral ↔ dark). */
const themeFollower = ViewPlugin.define((view) => ({
  update(update: ViewUpdate) {
    const theme = themeOf(update.state);
    if (theme === themeOf(update.startState)) return;
    for (const entry of live) {
      if (entry.view !== view || entry.theme === theme) continue;
      entry.theme = theme;
      render(entry, 0);
    }
  },
}));

export const mermaid: Extension = [blockRenderers.of(mermaidRenderer), themeFollower];
