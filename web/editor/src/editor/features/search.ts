// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// In-note Find / Find and Replace (Edit ▸ Find ▸ Find… ⌘F, Find and Replace… ⌥⌘F, Find Next ⌘G,
// Find Previous ⇧⌘G: native menu → `applyCommand` find / findAndReplace / findNext / findPrevious).
// CodeMirror's search state and commands behind our own panel, styled like the app.
//
// Ruling R32: while the panel is open, Find Next / Previous select the match (Mac convention, and
// what Replace acts on); while it is closed they move the note-list search highlight's current
// marker without touching the selection (search-highlight.ts, M4 Task 3). Same command names.
//
// Read-only notes (Trash, Archive, read-only): find works, the replace row is hidden and replacing
// is refused (CodeMirror's replace commands check `state.readOnly`).
//
// Matching is literal and case-insensitive. Text that stays in the DOM is searched as typed, so a
// link's title, a hidden URL and an attachment link's file name all match; a match inside hidden
// markup is revealed when it is selected (the caret is then inside the element, ruling R10).

import { type EditorState, type Extension, Prec, StateEffect, StateField } from "@codemirror/state";
import { EditorView, keymap, type Panel, runScopeHandlers, type ViewUpdate } from "@codemirror/view";
import {
  closeSearchPanel,
  findNext as cmFindNext,
  findPrevious as cmFindPrevious,
  getSearchQuery,
  openSearchPanel,
  replaceAll,
  replaceNext,
  search,
  SearchQuery,
  searchPanelOpen,
  setSearchQuery,
} from "@codemirror/search";
import type { CommandTarget } from "./commands";
import type { CommandArgs } from "../../bridge/protocol";
import { isSearchHighlightActive, searchHighlightTransaction, stepCommand } from "./search-highlight";

export type FindMode = "find" | "replace";

const setFindMode = StateEffect.define<FindMode>();

/** Whether the panel shows the replace row (Find and Replace…) or not (Find…). */
const findMode = StateField.define<FindMode>({
  create: () => "find",
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setFindMode)) value = effect.value;
    return value;
  },
});

export function findPanelOpen(state: EditorState): boolean {
  return searchPanelOpen(state);
}

export function currentFindMode(state: EditorState): FindMode {
  return state.field(findMode, false) ?? "find";
}

/** Matches counted for "3 of 12"; above this the count shows "1000+". */
const COUNT_LIMIT = 1000;
/** Recount after document changes this long after the last one (huge notes). */
const RECOUNT_DELAY_MS = 120;

type Match = { from: number; to: number };

function countMatches(state: EditorState, query: SearchQuery): Match[] {
  if (!query.valid) return [];
  const out: Match[] = [];
  const cursor = query.getCursor(state);
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    out.push({ from: next.value.from, to: next.value.to });
    if (out.length > COUNT_LIMIT) break;
  }
  return out;
}

/** "3 of 12", "12 matches", "No matches", "" (empty query). */
export function countLabel(matches: readonly Match[], selection: { from: number; to: number }, empty: boolean): string {
  if (empty) return "";
  if (matches.length === 0) return "No matches";
  const total = matches.length > COUNT_LIMIT ? `${COUNT_LIMIT}+` : String(matches.length);
  const index = matches.findIndex((m) => m.from === selection.from && m.to === selection.to);
  return index === -1 ? `${total} ${matches.length === 1 ? "match" : "matches"}` : `${index + 1} of ${total}`;
}

function button(name: string, label: string, text: string, onClick: () => void): HTMLButtonElement {
  const el = document.createElement("button");
  el.type = "button";
  el.name = name;
  el.className = `cm-bc-find-button cm-bc-find-button-${name}`;
  el.textContent = text;
  el.setAttribute("aria-label", label);
  el.title = label;
  // Keep the focus in the field.
  el.addEventListener("mousedown", (e) => e.preventDefault());
  el.addEventListener("click", onClick);
  return el;
}

function field(cls: string, placeholder: string): HTMLInputElement {
  const el = document.createElement("input");
  el.className = `cm-bc-find-field ${cls}`;
  el.placeholder = placeholder;
  el.setAttribute("aria-label", placeholder);
  el.spellcheck = false;
  el.setAttribute("autocomplete", "off");
  el.setAttribute("autocorrect", "off");
  el.setAttribute("autocapitalize", "off");
  return el;
}

class FindPanel implements Panel {
  readonly dom: HTMLElement;
  readonly top = true;
  private readonly searchField: HTMLInputElement;
  private readonly replaceField: HTMLInputElement;
  private readonly replaceRow: HTMLElement;
  private readonly count: HTMLElement;
  private query: SearchQuery;
  private matches: Match[] = [];
  private recountTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly view: EditorView) {
    this.query = getSearchQuery(view.state);
    this.dom = document.createElement("div");
    this.dom.className = "cm-bc-find";
    this.dom.setAttribute("role", "search");
    this.dom.addEventListener("keydown", (e) => this.keydown(e));

    this.searchField = field("cm-bc-find-search", "Find");
    this.searchField.setAttribute("main-field", "true");
    this.searchField.value = this.query.search;
    this.searchField.addEventListener("input", () => this.commit());
    this.replaceField = field("cm-bc-find-replace", "Replace");
    this.replaceField.value = this.query.replace;
    this.replaceField.addEventListener("input", () => this.commit());

    this.count = document.createElement("span");
    this.count.className = "cm-bc-find-count";
    this.count.setAttribute("aria-live", "polite");

    const findRow = document.createElement("div");
    findRow.className = "cm-bc-find-row";
    findRow.append(
      this.searchField,
      this.count,
      button("prev", "Previous match", "‹", () => void cmFindPrevious(view)),
      button("next", "Next match", "›", () => void cmFindNext(view)),
      button("done", "Done", "Done", () => void closeSearchPanel(view)),
    );
    this.replaceRow = document.createElement("div");
    this.replaceRow.className = "cm-bc-find-row cm-bc-replace-row";
    this.replaceRow.append(
      this.replaceField,
      button("replace", "Replace", "Replace", () => void replaceNext(view)),
      button("replaceAll", "Replace All", "All", () => void replaceAll(view)),
    );
    this.dom.append(findRow, this.replaceRow);
    this.showMode(view.state);
    this.recount(view.state);
  }

  mount() {
    this.searchField.focus();
    this.searchField.select();
  }

  destroy() {
    if (this.recountTimer !== null) clearTimeout(this.recountTimer);
  }

  update(update: ViewUpdate) {
    for (const tr of update.transactions) {
      for (const effect of tr.effects) {
        if (effect.is(setSearchQuery) && !effect.value.eq(this.query)) this.setQuery(effect.value);
      }
    }
    if (
      update.state.field(findMode, false) !== update.startState.field(findMode, false) ||
      update.state.readOnly !== update.startState.readOnly
    ) {
      this.showMode(update.state);
    }
    if (update.docChanged) this.scheduleRecount();
    else if (update.selectionSet) this.showCount(update.state);
  }

  private setQuery(query: SearchQuery) {
    this.query = query;
    this.searchField.value = query.search;
    this.replaceField.value = query.replace;
    this.recount(this.view.state);
  }

  private commit() {
    const query = new SearchQuery({ search: this.searchField.value, replace: this.replaceField.value, literal: true });
    if (query.eq(this.query)) return;
    this.query = query;
    this.view.dispatch({ effects: setSearchQuery.of(query) });
    this.recount(this.view.state);
  }

  private showMode(state: EditorState) {
    const replace = currentFindMode(state) === "replace" && !state.readOnly;
    this.replaceRow.hidden = !replace;
    this.dom.classList.toggle("cm-bc-find-replacing", replace);
  }

  private scheduleRecount() {
    if (this.recountTimer !== null) clearTimeout(this.recountTimer);
    this.recountTimer = setTimeout(() => {
      this.recountTimer = null;
      this.recount(this.view.state);
    }, RECOUNT_DELAY_MS);
  }

  private recount(state: EditorState) {
    this.matches = countMatches(state, this.query);
    this.showCount(state);
  }

  private showCount(state: EditorState) {
    const label = countLabel(this.matches, state.selection.main, this.query.search === "");
    this.count.textContent = label;
    this.dom.classList.toggle("cm-bc-find-nomatch", label === "No matches");
  }

  private keydown(event: KeyboardEvent) {
    // ⌘G / ⇧⌘G / ⌘F in the panel: the native menu (or, without one, the editor keymap's search-panel scope).
    if (runScopeHandlers(this.view, event, "search-panel")) {
      event.preventDefault();
      return;
    }
    if (event.isComposing) return;
    if (event.key === "Escape") {
      event.preventDefault();
      closeSearchPanel(this.view);
    } else if (event.key === "Enter" && event.target === this.searchField) {
      event.preventDefault();
      (event.shiftKey ? cmFindPrevious : cmFindNext)(this.view);
    } else if (event.key === "Enter" && event.target === this.replaceField) {
      event.preventDefault();
      (event.metaKey ? replaceAll : replaceNext)(this.view);
    }
  }
}

const isView = (target: CommandTarget): target is EditorView => target instanceof EditorView;

/**
 * Find… / Find and Replace…: opens the panel in that mode (read-only notes: Find only) with the
 * selection as the query (when there is one), or focuses and selects the query of the open panel.
 * The note-list search highlight gives way to the panel's matches.
 */
export function openFind(mode: FindMode) {
  return (target: CommandTarget, args?: CommandArgs): boolean => {
    // No note (locked placeholder, halted bridge): nothing to find in.
    if (!isView(target) || !target.state.facet(EditorView.editable)) return false;
    const view = target;
    const effects: StateEffect<unknown>[] = [setFindMode.of(view.state.readOnly ? "find" : mode)];
    if (isSearchHighlightActive(view.state)) {
      const clear = searchHighlightTransaction(view.state, []).effects;
      effects.push(...(Array.isArray(clear) ? clear : clear ? [clear] : []));
    }
    view.dispatch({ effects });
    openSearchPanel(view);
    if (typeof args?.query === "string") {
      view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: args.query, caseSensitive: false, literal: true })) });
    }
    return true;
  };
}

/** Find Next / Previous (R32): the panel's match (selected) while it is open, else the highlight marker. */
export function findStep(direction: 1 | -1) {
  const marker = stepCommand(direction);
  return (target: CommandTarget): boolean => {
    if (isView(target) && searchPanelOpen(target.state)) return (direction === 1 ? cmFindNext : cmFindPrevious)(target);
    return marker(target);
  };
}

/** Escape in the text closes an open panel (the search highlight stays until the next search). */
const escapeKeymap = Prec.high(keymap.of([{ key: "Escape", run: closeSearchPanel }]));

const findTheme = EditorView.theme({
  ".cm-panels": { backgroundColor: "var(--bc-color-bg)", color: "var(--bc-color-text)" },
  ".cm-panels.cm-panels-top": { borderBottom: "1px solid var(--bc-color-rule)" },
  ".cm-bc-find": {
    display: "flex",
    flexDirection: "column",
    gap: "6px",
    padding: "8px 12px",
    font: "13px -apple-system, system-ui, sans-serif",
  },
  ".cm-bc-find-row": { display: "flex", alignItems: "center", gap: "6px" },
  ".cm-bc-find-row[hidden]": { display: "none" },
  ".cm-bc-find-field": {
    flex: "1",
    minWidth: "0",
    font: "inherit",
    padding: "3px 8px",
    color: "var(--bc-color-text)",
    backgroundColor: "var(--bc-color-bg)",
    border: "1px solid var(--bc-color-rule)",
    borderRadius: "6px",
    outline: "none",
  },
  ".cm-bc-find-field:focus": { borderColor: "var(--bc-color-accent)", boxShadow: "0 0 0 2px var(--bc-color-tag-bg)" },
  ".cm-bc-find-nomatch .cm-bc-find-search": { borderColor: "var(--bc-color-accent)" },
  ".cm-bc-find-count": { color: "var(--bc-color-secondary)", minWidth: "6em", textAlign: "right", fontVariantNumeric: "tabular-nums" },
  ".cm-bc-find-button": {
    font: "inherit",
    padding: "2px 10px",
    color: "var(--bc-color-text)",
    backgroundColor: "var(--bc-color-code-bg)",
    border: "1px solid var(--bc-color-rule)",
    borderRadius: "6px",
    cursor: "default",
  },
  ".cm-bc-find-button:active": { backgroundColor: "var(--bc-color-rule)" },
  ".cm-bc-find-button-prev, .cm-bc-find-button-next": { padding: "2px 8px" },
  // Matches: like the note-list search highlight (search-highlight.ts); the selected one stronger.
  ".cm-searchMatch": { backgroundColor: "var(--bc-color-search-match)", borderRadius: "2px" },
  // M7-R10: plus a ring in the accent, so the selected match differs by more than its tint.
  ".cm-searchMatch.cm-searchMatch-selected": {
    backgroundColor: "var(--bc-color-search-match-current)",
    boxShadow: "inset 0 0 0 1.5px var(--bc-color-accent)",
  },
});

export const findAndReplace: Extension = [
  findMode,
  search({ top: true, literal: true, createPanel: (view) => new FindPanel(view) }),
  escapeKeymap,
  findTheme,
];
