// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, type EditorState } from "@codemirror/state";
import { undoDepth } from "@codemirror/commands";
import { EditorView } from "@codemirror/view";
import type { EditorSettings } from "../src/bridge/protocol";
import { loadedState } from "../src/editor/setup";
import { currentSettings, DEFAULT_SETTINGS, settingsTransaction, settingsStyle } from "../src/editor/features/settings";
import { autoSortTodos } from "../src/editor/features/todos";
import { computeHiddenRanges, hideMarkdown } from "../src/editor/features/hiding";
import { headingBadgeMarkers, showHeadingLevels, typographyDecorations } from "../src/editor/features/typography";

function typed(state: EditorState, text: string, at: number): EditorState {
  return state.update({ changes: { from: at, insert: text }, userEvent: "input.type" }).state;
}

describe("setSettings", () => {
  test("the defaults: markup hidden, no auto-sort, default typography and theme", () => {
    const state = loadedState({ text: "a", readOnly: false });
    expect(currentSettings(state)).toEqual(DEFAULT_SETTINGS);
    expect(state.facet(hideMarkdown)).toBe(true);
    expect(state.facet(autoSortTodos)).toBe(false);
    expect(state.facet(showHeadingLevels)).toBe(true);
  });

  test("toggles keep the document, the selection and the undo history", () => {
    let state = loadedState({ text: "some **bold** text", readOnly: false, selection: { anchor: 2, head: 4 } });
    state = typed(state, "x", 0);
    state = state.update({ selection: EditorSelection.single(3, 5) }).state;
    const before = { doc: state.doc.toString(), sel: state.selection.main, undo: undoDepth(state) };
    const patches: EditorSettings[] = [
      { hideMarkdown: false },
      { autoSortTodos: true },
      { showHeadingLevels: false },
      { showHeadingLevels: true },
      { typography: { fontSize: 20, lineWidth: 600 } },
      { theme: { "--bc-color-bg": "#000000" } },
      { hideMarkdown: true, autoSortTodos: false, typography: {}, theme: {} },
    ];
    for (const patch of patches) {
      const spec = settingsTransaction(state, patch);
      expect(spec, JSON.stringify(patch)).not.toBeNull();
      const tr = state.update(spec!);
      expect(tr.docChanged).toBe(false);
      state = tr.state;
      expect(state.doc.toString()).toBe(before.doc);
      expect(state.selection.main.eq(before.sel)).toBe(true);
      expect(undoDepth(state)).toBe(before.undo);
    }
  });

  test("each field reconfigures its compartment", () => {
    let state = loadedState({ text: "**b** x", readOnly: false, selection: { anchor: 7, head: 7 } });
    expect(computeHiddenRanges(state).length).toBeGreaterThan(0);
    state = state.update(settingsTransaction(state, { hideMarkdown: false, autoSortTodos: true })!).state;
    expect(state.facet(hideMarkdown)).toBe(false);
    expect(state.facet(autoSortTodos)).toBe(true);
    expect(computeHiddenRanges(state)).toEqual([]);
    state = state.update(settingsTransaction(state, { typography: { fontSize: 18, lineHeight: 1.5 } })!).state;
    expect(currentSettings(state).typography).toEqual({ fontSize: 18, lineHeight: 1.5 });
    expect(settingsStyle(state)).toContain("--bc-size: 18px");
    expect(settingsStyle(state)).toContain("--bc-line-height: 1.5");
    state = state.update(settingsTransaction(state, { theme: { "--bc-color-text": "#eeeeee" } })!).state;
    expect(settingsStyle(state)).toContain("--bc-color-text: #eee");
    // A present typography object replaces the previous one as a whole.
    state = state.update(settingsTransaction(state, { typography: { lineWidth: 500 } })!).state;
    expect(currentSettings(state).typography).toEqual({ lineWidth: 500 });
    expect(settingsStyle(state)).not.toContain("--bc-size");
  });

  test("showHeadingLevels hides and shows the heading badges, the doc and selection stay", () => {
    const doc = "# One\ntext\n## Two";
    let state = loadedState({ text: doc, readOnly: false, selection: { anchor: 8, head: 11 } });
    const badges = () => headingBadgeMarkers(state, typographyDecorations(state).headings);
    const levels = () => {
      const found: number[] = [];
      for (const it = badges().iter(); it.value; it.next()) found.push(it.value.level);
      return found;
    };
    expect(levels()).toEqual([1, 2]);
    state = state.update(settingsTransaction(state, { showHeadingLevels: false })!).state;
    expect(currentSettings(state).showHeadingLevels).toBe(false);
    expect(levels()).toEqual([]);
    expect(state.doc.toString()).toBe(doc);
    expect(state.selection.main.anchor).toBe(8);
    expect(state.selection.main.head).toBe(11);
    // The heading lines themselves are decorated as before (only the badges go).
    expect(typographyDecorations(state).outer.size).toBeGreaterThan(0);
    state = state.update(settingsTransaction(state, { showHeadingLevels: true })!).state;
    expect(levels()).toEqual([1, 2]);
    expect(state.selection.main.head).toBe(11);
  });

  test("unchanged or empty settings are no transaction; autocomplete is not this module's", () => {
    const state = loadedState({ text: "a", readOnly: false });
    expect(settingsTransaction(state, {})).toBeNull();
    expect(settingsTransaction(state, { hideMarkdown: true, autoSortTodos: false, showHeadingLevels: true })).toBeNull();
    expect(settingsTransaction(state, { autocomplete: false })).toBeNull();
    expect(settingsTransaction(state, { typography: {}, theme: {} })).toBeNull();
  });

  test("typewriterMode is a stored setting: off by default, kept across loads (behaviour: typewriter.test.ts)", () => {
    let state = loadedState({ text: "a", readOnly: false });
    expect(currentSettings(state).typewriterMode).toBe(false);
    expect(DEFAULT_SETTINGS.typewriterMode).toBe(false);
    state = state.update(settingsTransaction(state, { typewriterMode: true })!).state;
    expect(currentSettings(state).typewriterMode).toBe(true);
    expect(settingsTransaction(state, { typewriterMode: true })).toBeNull();
    const next = loadedState({ text: "other", readOnly: false }, { settings: currentSettings(state) });
    expect(currentSettings(next).typewriterMode).toBe(true);
    state = state.update(settingsTransaction(state, { typewriterMode: false })!).state;
    expect(currentSettings(state).typewriterMode).toBe(false);
  });

  test("a loaded note keeps the settings (loadNote replaces the state)", () => {
    let state = loadedState({ text: "a", readOnly: false });
    state = state.update(settingsTransaction(state, { hideMarkdown: false, theme: { "--bc-color-bg": "#111111" } })!).state;
    const next = loadedState({ text: "other", readOnly: false }, { settings: currentSettings(state) });
    expect(next.facet(hideMarkdown)).toBe(false);
    expect(currentSettings(next)).toEqual(currentSettings(state));
  });

  test("appearance dark sets darkTheme and color-scheme, keeps doc/selection/history", () => {
    let s = loadedState({ text: "a **b**", readOnly: false, selection: { anchor: 2, head: 4 } });
    s = typed(s, "x", 0);
    const before = { doc: s.doc.toString(), sel: s.selection.main, undo: undoDepth(s) };
    expect(s.facet(EditorView.darkTheme)).toBe(false);
    expect(settingsStyle(s)).toContain("color-scheme: light");
    const tr = s.update(settingsTransaction(s, { appearance: "dark" })!);
    expect(tr.docChanged).toBe(false);
    s = tr.state;
    expect(s.facet(EditorView.darkTheme)).toBe(true);
    expect(settingsStyle(s)).toContain("color-scheme: dark");
    expect(settingsStyle(s)).not.toContain("color-scheme: light");
    expect(currentSettings(s).appearance).toBe("dark");
    expect(s.doc.toString()).toBe(before.doc);
    expect(s.selection.main.eq(before.sel)).toBe(true);
    expect(undoDepth(s)).toBe(before.undo);
    expect(settingsTransaction(s, { appearance: "dark" })).toBeNull();
    s = s.update(settingsTransaction(s, { appearance: "light" })!).state;
    expect(s.facet(EditorView.darkTheme)).toBe(false);
  });

  test("a loaded note keeps appearance and reduceMotion", () => {
    let s = loadedState({ text: "a", readOnly: false });
    s = s.update(settingsTransaction(s, { appearance: "dark", reduceMotion: true })!).state;
    const next = loadedState({ text: "other", readOnly: false }, { settings: currentSettings(s) });
    expect(next.facet(EditorView.darkTheme)).toBe(true);
    expect(currentSettings(next).reduceMotion).toBe(true);
  });

  const withSettings = (typography: EditorSettings["typography"]) => {
    const s = loadedState({ text: "a", readOnly: false });
    return s.update(settingsTransaction(s, { typography })!).state;
  };

  test("a font family keeps the fallback stack", () => {
    const s = withSettings({ fontText: "Iowan Old Style" });
    expect(settingsStyle(s)).toContain('--bc-font-text: "Iowan Old Style", -apple-system');
    // Headings follow the text font when they have none of their own, and keep their own fallback stack.
    expect(settingsStyle(s)).toContain('--bc-font-heading: "Iowan Old Style", -apple-system, "SF Pro Display"');
    expect(settingsStyle(s)).not.toContain("--bc-font-code");
  });

  test("a heading font beats the text font; code has its own", () => {
    const s = withSettings({ fontText: "Iowan Old Style", fontHeading: "Avenir Next", fontCode: "Menlo" });
    expect(settingsStyle(s)).toContain('--bc-font-heading: "Avenir Next", -apple-system');
    expect(settingsStyle(s)).not.toContain('--bc-font-heading: "Iowan Old Style"');
    expect(settingsStyle(s)).toContain('--bc-font-code: "Menlo", ui-monospace');
    // Only a heading font: the text font stays the default.
    const heading = withSettings({ fontHeading: "Avenir Next" });
    expect(settingsStyle(heading)).toContain('--bc-font-heading: "Avenir Next"');
    expect(settingsStyle(heading)).not.toContain("--bc-font-text");
  });

  test("paragraphIndent and reduceMotion reconfigure in place", () => {
    let s = loadedState({ text: "a", readOnly: false, selection: { anchor: 1, head: 1 } });
    s = typed(s, "x", 0);
    const undo = undoDepth(s);
    const classes = (state: EditorState) =>
      state
        .facet(EditorView.editorAttributes)
        .map((a) => (typeof a === "function" ? null : a?.class))
        .filter(Boolean)
        .join(" ");
    expect(classes(s)).not.toContain("cm-bc-reduce-motion");
    const tr = s.update(settingsTransaction(s, { typography: { paragraphIndent: 2 }, reduceMotion: true })!);
    expect(tr.docChanged).toBe(false);
    s = tr.state;
    expect(settingsStyle(s)).toContain("--bc-paragraph-indent: 2em");
    expect(classes(s)).toContain("cm-bc-reduce-motion");
    expect(currentSettings(s).reduceMotion).toBe(true);
    expect(undoDepth(s)).toBe(undo);
    expect(settingsTransaction(s, { reduceMotion: true })).toBeNull();
    s = s.update(settingsTransaction(s, { reduceMotion: false })!).state;
    expect(classes(s)).not.toContain("cm-bc-reduce-motion");
  });

  test("the style lands on the editor element", () => {
    let state = loadedState({ text: "a", readOnly: false });
    state = state.update(settingsTransaction(state, { typography: { fontSize: 18 } })!).state;
    const attrs = state.facet(EditorView.editorAttributes).map((a) => (typeof a === "function" ? null : a?.style));
    expect(attrs.join(";")).toContain("--bc-size: 18px");
  });
});
