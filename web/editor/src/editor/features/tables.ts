// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { rememberMenuTarget } from "./menu-targets";
// Tables (M6 Task 4): a Bear table renders as a grid (the block widget layer, blocks.ts), and in
// source mode its pipes line up.
//
// - Grid: CSS grid in the widget's shadow root (M6-R18), the top row bold (Bear: "Top row always
//   bold"), alignment from the delimiter row, ragged rows padded with empty cells. Cell content
//   uses typography.ts's classes and rules (INLINE_MARKUP_CSS). The widget keeps no document
//   positions: it is reused by source key, so it finds its block in `renderedBlocks` when it draws
//   and marks link runs with their offset from the block start.
// - AX: the grid is aria-hidden (no `label`, R18 provisional) and the source stays in
//   `.cm-content`, collapsed. An off-screen mirror outside `.cm-content` holds one
//   `<table aria-label="Table N">` per rendered table, so VoiceOver can navigate tables while the
//   content text still equals the document (finding F8).
// - Source mode: the header line is bold and the pipes are dimmed (typography.ts). The table
//   holding the caret gets aria-hidden spacer widgets before its closing pipes; their widths are
//   measured from the DOM (`requestMeasure`), mapped and never re-measured while composing.

import { EditorState, type Extension, Prec, type Range as DecoRange, StateEffect } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import type { SyntaxNodeRef } from "@lezer/common";
import type { CaretRect } from "../../bridge/protocol";
import { bearMarkdown } from "../dialect";
import { type BlockRenderer, type BlockSpec, blockMode, blockRenderers, renderedBlocks } from "./blocks";
import { completionBridge, TAGCON_CSS, tagconElement, tagIconPositions, tagIconsChanged } from "./autocomplete";
import { hideMarkdown } from "./hiding";
import { linkHandlers, linkTargetAt } from "./links";
import { tableEnter, tableTab } from "./table-commands";
import { type CellRef, cellRuns, plainCellText, rowOf, type TableModel, tableAt, tableRowsAt, tablesBetween } from "./table-model";
import { INLINE_MARKUP_CSS } from "./typography";

export const AX_TABLES_CLASS = "cm-bc-ax-tables";
/** The cell ⋯ button asks for the native table menu (main.ts posts `tableMenu`). */
export const TABLE_MENU_EVENT = "baerchen-table-menu";
export type TableMenuDetail = { pos: number; row: number; column: number; rows: number; columns: number; rect: CaretRect };
const SPACER_CLASS = "cm-bc-table-spacer";
/**
 * Tables with more rows (header and body) than this always show their plain source: no grid, no
 * aligned pipes (M6-R82). A pasted sheet of thousands of rows otherwise cost frames per keystroke
 * above it. Jan's largest table has 41 rows.
 */
export const MAX_GRID_ROWS = 1000;

/** The block has more than MAX_GRID_ROWS rows (its lines less the delimiter row). */
function overRowCap(key: string): boolean {
  if (key.length < MAX_GRID_ROWS * 3) return false;
  let rows = 0;
  for (let at = key.indexOf("\n"); at >= 0; at = key.indexOf("\n", at + 1)) if (++rows > MAX_GRID_ROWS) return true;
  return false;
}
const MENU_BUTTON_CLASS = "bc-cell-menu";
const LINK_RUN = new Set(["cm-bc-link", "cm-bc-wikilink", "cm-bc-tag"]);

// ---------------------------------------------------------------------------------------------
// Grid

/** The table of a rendered block: from the live state (the widget keeps no positions). */
function modelOf(state: EditorState, key: string): { model: TableModel; state: EditorState; from: number } {
  const block = state.field(renderedBlocks, false)?.blocks.find((b) => b.kind === "table" && b.key === key);
  const model = block && tableAt(state, block.from);
  if (block && model && model.from === block.from && model.to === block.to) return { model, state, from: block.from };
  // Not in the field (should not happen): the source on its own.
  const own = EditorState.create({ doc: key, extensions: markdown({ base: bearMarkdown }) });
  ensureSyntaxTree(own, own.doc.length, 200);
  return { model: tableAt(own, 0) ?? emptyModel, state: own, from: 0 };
}

const emptyModel: TableModel = { from: 0, to: 0, header: [], align: [], delimiter: { from: 0, to: 0, cells: [] }, rows: [], lines: [] };

const columnCount = (model: TableModel) => Math.max(model.header.length, ...model.rows.map((r) => r.length), 1);

/** One cell's content: runs as spans with typography classes, `<br>` as a line break, TagCons. */
function fillCell(el: HTMLElement, state: EditorState, cell: CellRef, base: number, icons: ReadonlyMap<number, string>) {
  for (const run of cellRuns(state, cell)) {
    if (run.kind === "br") {
      el.append(document.createElement("br"));
      continue;
    }
    const icon = icons.get(run.from);
    if (icon) el.append(tagconElement(icon));
    if (run.classes.length === 0) {
      el.append(run.text);
      continue;
    }
    const span = document.createElement("span");
    span.className = run.classes.join(" ");
    // Offset from the block start (not a position): ⌘-click finds the link in the source.
    if (run.classes.some((c) => LINK_RUN.has(c))) span.dataset.o = String(run.from - base);
    span.textContent = run.text;
    el.append(span);
  }
}

function drawGrid(root: HTMLElement, view: EditorView, key: string) {
  const { model, state, from } = modelOf(view.state, key);
  const columns = columnCount(model);
  const icons = new Map(
    tagIconPositions(state, state.facet(completionBridge).tagIcons(), [{ from: model.from, to: model.to }]).map((t) => [t.pos, t.symbol]),
  );
  const grid = document.createElement("div");
  grid.className = "bc-table";
  grid.style.setProperty("--bc-table-columns", String(columns));
  const rows = [model.header, ...model.rows];
  rows.forEach((cells, row) => {
    for (let column = 0; column < columns; column++) {
      const el = document.createElement("div");
      const cell = cells[column];
      el.className = `bc-cell${row === 0 ? " bc-head" : ""}${cell ? "" : " bc-pad"}${column === columns - 1 ? " bc-last" : ""}`;
      el.dataset.row = String(row);
      el.dataset.column = String(column);
      const align = model.align[column];
      if (align) el.style.textAlign = align;
      if (cell) fillCell(el, state, cell, from, icons);
      el.append(menuButton());
      grid.append(el);
    }
  });
  root.replaceChildren(grid);
}

/**
 * The cell's ⋯ button: shown on hover, `aria-hidden`, and not focusable (widget DOM holds no
 * focusable element, M6-R18). Its mousedown is the renderer's `click` (blocks.ts). The dots are a
 * pseudo-element, so the cell's text stays the cell's text.
 */
function menuButton(): HTMLElement {
  const button = document.createElement("span");
  button.className = MENU_BUTTON_CLASS;
  button.setAttribute("aria-hidden", "true");
  return button;
}

/** The drawn grids, redrawn when the TagCon map changes (their key is unchanged). */
const liveGrids = new Set<HTMLElement>();

class TableWidget extends WidgetType {
  constructor(readonly key: string) {
    super();
  }

  override eq(other: TableWidget): boolean {
    return other.key === this.key;
  }

  toDOM(view: EditorView): HTMLElement {
    const wrap = document.createElement("div");
    wrap.className = "bc-table-wrap";
    wrap.dataset.key = this.key;
    drawGrid(wrap, view, this.key);
    liveGrids.add(wrap);
    return wrap;
  }

  override destroy(dom: HTMLElement): void {
    liveGrids.delete(dom);
  }

  override get estimatedHeight(): number {
    // Header + body rows (the delimiter row is not drawn), one text line each plus padding. The
    // layer prefers the measured height and subtracts the collapsed lines' estimate (blocks.ts).
    return Math.max(1, this.key.split("\n").length - 1) * 32;
  }
}

/** The cell (row, column) a pointer event hit inside the grid, the link run if any, and the ⋯ button. */
function hit(event: MouseEvent): { row: number; column: number; offset: number | null; menu: HTMLElement | null } | null {
  let offset: number | null = null;
  let menu: HTMLElement | null = null;
  for (const target of event.composedPath()) {
    if (!(target instanceof HTMLElement)) continue;
    if (menu === null && target.classList.contains(MENU_BUTTON_CLASS)) menu = target;
    if (offset === null && target.dataset.o !== undefined) offset = Number(target.dataset.o);
    if (target.dataset.row !== undefined && target.dataset.column !== undefined) {
      return { row: Number(target.dataset.row), column: Number(target.dataset.column), offset, menu };
    }
  }
  return null;
}

function matchTable(state: EditorState, node: SyntaxNodeRef): BlockSpec | null {
  if (node.name !== "Table") return null;
  const from = state.doc.lineAt(node.from).from;
  const to = state.doc.lineAt(node.to).to;
  return { kind: "table", from, to, key: state.doc.sliceString(from, to) };
}

const GRID_CSS = `
/* The text column's left edge: CodeMirror pads lines by 6px / 2px. */
.bc-table-wrap { overflow-x: auto; padding: 0 2px var(--bc-paragraph-spacing, 0.4em) 6px; }
.bc-table {
  display: grid;
  text-indent: 0;
  grid-template-columns: repeat(var(--bc-table-columns), auto);
  width: max-content;
  max-width: 100%;
  border-top: 1px solid var(--bc-color-table-border);
  border-left: 1px solid var(--bc-color-table-border);
}
.bc-cell {
  position: relative;
  padding: 3px 10px;
  min-width: 2em;
  overflow-wrap: break-word;
  border-right: 1px solid var(--bc-color-table-border);
  border-bottom: 1px solid var(--bc-color-table-border);
  cursor: text;
}
.bc-cell-menu { position:absolute;top:0;right:0;width:24px;height:26px;border:0;background:transparent;color:inherit;cursor:pointer;opacity:0; }
.bc-cell-menu::after { content:"⋯"; }
.bc-cell:hover .bc-cell-menu,.bc-cell-menu:focus { opacity:1; }
@media (pointer:coarse) { .bc-cell-menu { opacity:1;width:32px;height:40px; } .bc-cell { min-height:44px;padding-right:36px; } }
.bc-head { font-weight: 700; background-color: var(--bc-color-table-header-bg); }
.bc-cell-menu {
  position: absolute;
  top: 1px;
  right: 1px;
  display: none;
  box-sizing: border-box;
  min-width: 1.4em;
  height: 1.4em;
  line-height: 1.2em;
  text-align: center;
  font-weight: 700;
  text-indent: 0;
  border-radius: 4px;
  cursor: default;
  user-select: none;
  color: var(--bc-color-secondary);
  background-color: var(--bc-color-table-header-bg);
}
.bc-cell-menu::before { content: "⋯"; }
.bc-cell:hover > .bc-cell-menu { display: block; }
.bc-cell-menu:hover { color: var(--bc-color-text); }
`;

export const tableRenderer: BlockRenderer = {
  kind: "table",
  match: matchTable,
  rendered: (block) => new TableWidget(block.key),
  entry(state, block, from) {
    const model = tableAt(state, block.from);
    const row = from === "above" ? model?.header : model?.rows.at(-1) ?? model?.header;
    return row?.[0]?.contentFrom ?? (from === "above" ? block.from : block.to);
  },
  click(view, block, event) {
    const at = hit(event);
    if (!at) return null;
    if (event.metaKey && at.offset !== null) {
      const link = linkTargetAt(view.state, block.from + at.offset, true);
      if (link) {
        view.state.facet(linkHandlers).openLink?.({ ...link, newWindow: event.altKey });
        return "handled";
      }
    }
    const model = tableAt(view.state, block.from);
    const cells = model && rowOf(model, at.row);
    if (!cells || cells.length === 0) return null;
    if (at.menu) {
      // The ⋯ button: the native menu for this cell. Not a caret move, so the grid stays rendered.
      const r = at.menu.getBoundingClientRect();
      const detail: TableMenuDetail = {
        pos: (cells[at.column] ?? cells[cells.length - 1]!).contentFrom,
        row: at.row,
        column: at.column,
        rows: model.rows.length + 1,
        columns: columnCount(model),
        rect: { x: r.left, y: r.top, width: Math.max(1, r.width), height: r.height },
      };
      view.dom.dispatchEvent(new CustomEvent(TABLE_MENU_EVENT, { bubbles: true, detail }));
      return "handled";
    }
    // A padding cell of a ragged row: the end of the row's last cell.
    return (cells[at.column] ?? cells[cells.length - 1]!).contentTo;
  },
  styles: `${INLINE_MARKUP_CSS}\n${TAGCON_CSS}\n${GRID_CSS}`,
  sourceOnly: (block) => overRowCap(block.key),
};

/** Redraws the live grids when the TagCon map changes. */
const gridIcons = ViewPlugin.define((view) => ({
  update(update: ViewUpdate) {
    if (!update.transactions.some((tr) => tr.effects.some((e) => e.is(tagIconsChanged)))) return;
    for (const wrap of liveGrids) {
      const host = (wrap.getRootNode() as ShadowRoot).host;
      if (host && view.contentDOM.contains(host) && wrap.dataset.key !== undefined) drawGrid(wrap, view, wrap.dataset.key);
    }
  },
}));

// ---------------------------------------------------------------------------------------------
// AX mirror

function mirrorTable(state: EditorState, block: BlockSpec): HTMLTableElement {
  const table = document.createElement("table");
  const model = tableAt(state, block.from) ?? emptyModel;
  const columns = columnCount(model);
  const row = (cells: readonly CellRef[], tag: "th" | "td") => {
    const tr = document.createElement("tr");
    for (let c = 0; c < columns; c++) {
      const el = document.createElement(tag);
      const cell = cells[c];
      if (cell) el.textContent = plainCellText(state, cell);
      tr.append(el);
    }
    return tr;
  };
  const head = table.createTHead();
  head.append(row(model.header, "th"));
  const body = table.createTBody();
  for (const cells of model.rows) body.append(row(cells, "td"));
  return table;
}

/** The rendered tables' keys in document order (the visible ones: what the layer scanned). */
function renderedTables(state: EditorState): BlockSpec[] {
  return (state.field(renderedBlocks, false)?.blocks ?? []).filter((b) => b.kind === "table" && blockMode(state, b) === "rendered");
}

class AxMirror {
  readonly dom: HTMLElement;
  private keys: readonly string[] = [];
  private tables = new Map<string, HTMLTableElement>();
  /** The mirrored tables' numbers, as last labelled. */
  private numbers: readonly number[] = [];
  /** The last mirrored table's end: an edit before it can change the numbers. */
  private lastTo = -1;

  constructor(view: EditorView) {
    this.dom = document.createElement("div");
    this.dom.className = AX_TABLES_CLASS;
    view.dom.append(this.dom);
    this.sync(view.state);
  }

  update(update: ViewUpdate) {
    if (update.state.field(renderedBlocks, false) === update.startState.field(renderedBlocks, false)) return;
    const before = this.lastTo >= 0 && update.docChanged && update.changes.touchesRange(0, this.lastTo) !== false;
    this.sync(update.state, before);
  }

  /**
   * Mirrors the rendered tables. "Table N" is the table's position among all tables of the note
   * (M6-R24), counted again when the mirrored list changes or an edit lands before its end. The
   * DOM is rebuilt only when a key or a number changed (typing above the tables changes neither).
   */
  sync(state: EditorState, renumber = false) {
    const blocks = renderedTables(state);
    const keys = blocks.map((b) => b.key);
    this.lastTo = blocks.at(-1)?.to ?? -1;
    const same = keys.length === this.keys.length && keys.every((k, i) => k === this.keys[i]);
    if (same && !renumber) return;
    let number = 0;
    let counted = 0;
    const numbers = blocks.map((block) => {
      number += tablesBetween(state, counted, block.from) + 1;
      counted = block.to;
      return number;
    });
    if (same && numbers.every((n, i) => n === this.numbers[i])) return;
    const next = new Map<string, HTMLTableElement>();
    const children = blocks.map((block, i) => {
      const table = next.get(block.key) ? mirrorTable(state, block) : (this.tables.get(block.key) ?? mirrorTable(state, block));
      next.set(block.key, table);
      table.setAttribute("aria-label", `Table ${numbers[i]}`);
      return table;
    });
    this.dom.replaceChildren(...children);
    this.tables = next;
    this.keys = keys;
    this.numbers = numbers;
  }

  destroy() {
    this.dom.remove();
  }
}

const axMirror = ViewPlugin.fromClass(AxMirror);

// ---------------------------------------------------------------------------------------------
// Aligned source

class SpacerWidget extends WidgetType {
  constructor(readonly width: number) {
    super();
  }

  override eq(other: SpacerWidget): boolean {
    return other.width === this.width;
  }

  toDOM(): HTMLElement {
    const el = document.createElement("span");
    el.className = SPACER_CLASS;
    el.setAttribute("aria-hidden", "true");
    el.style.width = `${this.width}px`;
    return el;
  }

  // A click on the gap places the caret like a click on text.
  override ignoreEvent(): boolean {
    return false;
  }
}

/** Never touch the DOM around an IME composition: spacers are mapped, measured afterwards. */
export function spacerPlan(u: { composing: boolean; changed: boolean }): "map" | "measure" | "keep" {
  if (u.composing) return "map";
  return u.changed ? "measure" : "keep";
}

const setSpacers = StateEffect.define<{ doc: EditorState["doc"]; spacers: DecorationSet }>();

/** A row measured without spacers: content start x, content widths, the pipe gaps after them. */
type RowMeasure = { start: number; widths: number[]; gaps: number[] };

/** Rows of a table in line order: header, delimiter, body. */
const rowsOf = (model: TableModel): CellRef[][] => [model.header, model.delimiter.cells, ...model.rows];

/**
 * Spacer widths that line up every column's closing pipe, from rows measured without spacers
 * (null rows are not aligned). Pure.
 */
export function spacerWidths(rows: readonly (RowMeasure | null)[]): (number[] | null)[] {
  const x = rows.map((r) => r?.start ?? 0);
  const out = rows.map((r) => (r ? r.widths.map(() => 0) : null));
  const columns = Math.max(0, ...rows.map((r) => r?.widths.length ?? 0));
  for (let k = 0; k < columns; k++) {
    let end = -Infinity;
    rows.forEach((r, i) => {
      if (r && k < r.widths.length) end = Math.max(end, x[i]! + r.widths[k]!);
    });
    rows.forEach((r, i) => {
      if (!r || k >= r.widths.length) return;
      out[i]![k] = Math.round((end - (x[i]! + r.widths[k]!)) * 4) / 4;
      x[i] = end + r.gaps[k]!;
    });
  }
  return out;
}

class TableAlign {
  spacers: DecorationSet = Decoration.none;
  private stale = false;
  private cache = new Map<string, RowMeasure>();
  private metrics = "";
  /** Bumped when the TagCon map changes (TagCons change row widths). */
  private icons = 0;

  constructor(readonly view: EditorView) {
    this.schedule();
  }

  update(update: ViewUpdate) {
    for (const tr of update.transactions) {
      for (const effect of tr.effects) if (effect.is(setSpacers) && effect.value.doc === update.state.doc) this.spacers = effect.value.spacers;
    }
    if (update.docChanged) this.spacers = this.spacers.map(update.changes);
    const iconsChanged = update.transactions.some((tr) => tr.effects.some((e) => e.is(tagIconsChanged)));
    if (iconsChanged) this.icons++;
    const changed =
      iconsChanged ||
      update.docChanged ||
      update.selectionSet ||
      update.viewportChanged ||
      update.geometryChanged ||
      update.startState.facet(hideMarkdown) !== update.state.facet(hideMarkdown) ||
      syntaxTree(update.startState) !== syntaxTree(update.state);
    switch (spacerPlan({ composing: update.view.composing, changed: changed || this.stale })) {
      case "map":
        this.stale ||= changed;
        return;
      case "measure":
        this.stale = false;
        this.schedule();
        return;
      case "keep":
        return;
    }
  }

  /** The table holding the main caret, when it shows its source. */
  private caretTable(state: EditorState): TableModel | null {
    const head = state.selection.main.head;
    // A table over the row cap is plain source: its pipes are not lined up (M6-R82). Counted
    // from its syntax node, so typing in it never builds the model of thousands of rows.
    const rows = tableRowsAt(state, head);
    if (rows === null || rows > MAX_GRID_ROWS) return null;
    const model = tableAt(state, head);
    if (!model) return null;
    const block = { kind: "table" as const, from: model.from, to: model.to, key: "" };
    return blockMode(state, block) === "source" ? model : null;
  }

  private schedule() {
    if (!this.caretTable(this.view.state)) {
      this.spacers = Decoration.none;
      return;
    }
    this.view.requestMeasure({
      key: this,
      read: (view) => this.measure(view),
      write: (result, view) => {
        if (!result) return;
        // Not during the measure cycle: a transaction, once the cycle is done.
        queueMicrotask(() => {
          if (view.state.doc === result.doc && !view.composing) view.dispatch({ effects: setSpacers.of(result) });
        });
      },
    });
  }

  private applied(pos: number): number {
    let width = 0;
    this.spacers.between(pos, pos, (_from, _to, deco) => {
      const widget = deco.spec.widget;
      if (widget instanceof SpacerWidget) width = widget.width;
    });
    return width;
  }

  private measureRow(view: EditorView, cells: readonly CellRef[], left: number): RowMeasure | null {
    if (cells.length === 0) return null;
    const first = view.coordsAtPos(cells[0]!.from, -1);
    if (!first) return null;
    const widths: number[] = [];
    const gaps: number[] = [];
    let previousEnd = 0;
    for (let k = 0; k < cells.length; k++) {
      const cell = cells[k]!;
      const start = view.coordsAtPos(cell.from, -1);
      const end = cell.to > cell.from ? view.coordsAtPos(cell.to, -1) : start;
      if (!start || !end || Math.abs(end.top - first.top) > 2 || Math.abs(start.top - first.top) > 2) return null; // wrapped
      if (k > 0) gaps.push(start.left - previousEnd - this.applied(cells[k - 1]!.to));
      widths.push(end.left - start.left);
      previousEnd = end.left;
    }
    gaps.push(0);
    return { start: first.left - left, widths, gaps };
  }

  private measure(view: EditorView): { doc: EditorState["doc"]; spacers: DecorationSet } | null {
    const state = view.state;
    const model = this.caretTable(state);
    if (!model) return null;
    // Row measurements depend on these too: the reveal state of markup and the TagCon widgets.
    const metrics = `${view.contentDOM.clientWidth}:${view.defaultCharacterWidth}:${view.defaultLineHeight}:${state.facet(hideMarkdown)}:${this.icons}`;
    if (metrics !== this.metrics) {
      this.cache.clear();
      this.metrics = metrics;
    }
    const left = view.contentDOM.getBoundingClientRect().left;
    const sel = state.selection.ranges;
    const rows = rowsOf(model);
    const measured = rows.map((cells, i) => {
      const line = model.lines[i]!;
      const touched = sel.some((r) => r.from <= line.to && r.to >= line.from);
      const key = touched ? null : `${i === 0 ? "H" : i === 1 ? "D" : "R"}${state.doc.sliceString(line.from, line.to)}`;
      const cached = key === null ? undefined : this.cache.get(key);
      if (cached) return cached;
      const row = this.measureRow(view, cells, left);
      if (row && key !== null) this.cache.set(key, row);
      return row;
    });
    if (this.cache.size > 2000) this.cache.clear();
    const widths = spacerWidths(measured);
    const decos: DecoRange<Decoration>[] = [];
    rows.forEach((cells, i) => {
      widths[i]?.forEach((w, k) => {
        if (w >= 0.25) decos.push(Decoration.widget({ widget: new SpacerWidget(w), side: 1 }).range(cells[k]!.to));
      });
    });
    const spacers = Decoration.set(decos, true);
    return sameSpacers(spacers, this.spacers) ? null : { doc: state.doc, spacers };
  }
}

function sameSpacers(a: DecorationSet, b: DecorationSet): boolean {
  if (a.size !== b.size) return false;
  const list = (set: DecorationSet) => {
    const out: string[] = [];
    for (let it = set.iter(); it.value; it.next()) out.push(`${it.from}:${(it.value.spec.widget as SpacerWidget).width}`);
    return out.join(",");
  };
  return list(a) === list(b);
}

const tableAlign = ViewPlugin.fromClass(TableAlign, { decorations: (plugin) => plugin.spacers });

const tableTheme = EditorView.baseTheme({
  [`.${SPACER_CLASS}`]: { display: "inline-block", height: "1px" },
  // Off-screen, still in the accessibility tree (not display/visibility hidden).
  [`.${AX_TABLES_CLASS}`]: {
    position: "absolute",
    width: "1px",
    height: "1px",
    overflow: "hidden",
    clipPath: "inset(50%)",
    whiteSpace: "nowrap",
  },
});

/**
 * Tab / Shift-Tab walk the cells and ↩ adds a line to the cell (M6 Task 5), before the smart
 * lists' keys (Prec.high) so a table in a list item or quote keeps them. Outside a table, in a
 * read-only note and while composing they do not handle the key.
 */
const tableKeys = Prec.highest(
  keymap.of([
    { key: "Tab", run: tableTab(true), shift: tableTab(false) },
    { key: "Enter", run: tableEnter },
  ]),
);

export const tables: Extension = [blockRenderers.of(tableRenderer), gridIcons, axMirror, tableAlign, tableTheme, tableKeys];
