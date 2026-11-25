// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { type Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";

// Theme tokens as CSS variables on `.cm-editor` (spec §4.7: a theme is a set of tokens shared
// with the native shell). Default: "Theo Red", our own light palette with red accents.
// Other themes override these variables; typography.ts consumes them.
// The values mirror `theme-baerchen-red.json` (pinned by test/themes.test.ts); the token names
// are the schema in `Fixtures/themes/theme-schema.json`.
export const bearchenRed = {
  "--bc-color-text": "#2b2b2b",
  "--bc-color-secondary": "#6a6a6a",
  "--bc-color-accent": "#c22c28",
  "--bc-color-bg": "#ffffff",
  "--bc-color-code-bg": "#f4f1ec",
  // Syntax highlighting in code blocks (codeblocks.ts token classes).
  "--bc-color-code-keyword": "#b0347f",
  "--bc-color-code-string": "#3d7b31",
  "--bc-color-code-number": "#2a63b8",
  "--bc-color-code-comment": "#6e6e6e",
  "--bc-color-code-type": "#9a5a1c",
  "--bc-color-code-function": "#6a43b0",
  "--bc-color-code-property": "#1f6f7a",
  "--bc-color-code-tag": "#b0347f",
  "--bc-color-code-meta": "#866a39",
  "--bc-color-rule": "#e2ded7",
  "--bc-color-quote": "#555555",
  "--bc-color-quote-bar": "#e4c9c6",
  "--bc-color-link": "#c22c28",
  "--bc-color-tag": "#c22c28",
  "--bc-color-tag-bg": "#c22c281c",
  "--bc-highlight": "#ffeaa0",
  "--bc-highlight-green": "#d5f2c8",
  "--bc-highlight-red": "#ffddda",
  "--bc-highlight-blue": "#d5e6ff",
  "--bc-highlight-yellow": "#fff0a3",
  "--bc-highlight-purple": "#efdff9",
  "--bc-highlight-dot-green": "#4fa740",
  "--bc-highlight-dot-red": "#e5534b",
  "--bc-highlight-dot-blue": "#4a8ef0",
  "--bc-highlight-dot-yellow": "#b88e15",
  "--bc-highlight-dot-purple": "#a666d6",
  // Selection, find / note-list search matches, the autocomplete popup and shadows.
  "--bc-color-selection": "#e5e3f5",
  "--bc-color-search-match": "#ffd60a59",
  "--bc-color-search-match-current": "#ff9f0a51",
  "--bc-color-popup-bg": "#f5f5f5",
  "--bc-color-popup-text": "#2b2b2b",
  "--bc-color-popup-selected-bg": "#1177cc",
  "--bc-color-popup-selected-text": "#ffffff",
  "--bc-color-shadow": "#0000002e",
  // Rich blocks (M6): callouts, tables, math errors.
  "--bc-color-callout-note-bg": "#eaf2ff",
  "--bc-color-callout-note-border": "#a9c4ef",
  "--bc-color-callout-note-icon": "#1f5fbf",
  "--bc-color-callout-note-title": "#1f5fbf",
  "--bc-color-callout-tip-bg": "#eef8ee",
  "--bc-color-callout-tip-border": "#a6d3a6",
  "--bc-color-callout-tip-icon": "#2d7a2d",
  "--bc-color-callout-tip-title": "#2d7a2d",
  "--bc-color-callout-important-bg": "#f5eefb",
  "--bc-color-callout-important-border": "#cfb3e6",
  "--bc-color-callout-important-icon": "#7b3fb8",
  "--bc-color-callout-important-title": "#7b3fb8",
  "--bc-color-callout-warning-bg": "#fff6e5",
  "--bc-color-callout-warning-border": "#e8c680",
  "--bc-color-callout-warning-icon": "#8a5200",
  "--bc-color-callout-warning-title": "#8a5200",
  "--bc-color-callout-caution-bg": "#fdeeee",
  "--bc-color-callout-caution-border": "#eba8a4",
  "--bc-color-callout-caution-icon": "#b3261e",
  "--bc-color-callout-caution-title": "#b3261e",
  "--bc-color-table-header-bg": "#f4f1ec",
  "--bc-color-table-border": "#e2ded7",
  "--bc-color-math-error": "#b3261e",
  "--bc-color-math-error-bg": "#fdeeee",
  "--bc-color-error": "#b3261e",
} as const;

const base = EditorView.theme({
  "&": {
    ...bearchenRed,
    height: "100%",
    color: "var(--bc-color-text)",
    backgroundColor: "var(--bc-color-bg)",
  },
  "&.cm-focused": { outline: "none" },
  ".cm-content": { caretColor: "var(--bc-color-accent)" },
  // The editor keeps the native selection (no drawSelection, M7-R3); only its colour is the theme's.
  ".cm-content ::selection, .cm-content::selection": { backgroundColor: "var(--bc-color-selection)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--bc-color-accent)" },
  "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground": {
    background: "var(--bc-color-selection)",
  },
});

export const theme: Extension = [base];
