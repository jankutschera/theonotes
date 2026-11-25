// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { type EditorView, keymap, runScopeHandlers } from "@codemirror/view";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { FORMAT_SHORTCUTS, iosCommandKeymap } from "../src/editor/features/commands";

function target(extensions: Extension[], text = "hello") {
  let state = EditorState.create({ doc: text, selection: EditorSelection.single(0, text.length),
    extensions: [markdown({ base: bearMarkdown }), ...extensions] });
  return { get state() { return state; }, dispatch(transaction: Transaction) { state = transaction.state; } } as EditorView;
}
function event(key: string, meta: boolean, extra: Partial<KeyboardEvent> = {}): KeyboardEvent {
  return { key, keyCode: key.toUpperCase().charCodeAt(0), code: `Key${key.toUpperCase()}`,
    metaKey: meta, ctrlKey: !meta, altKey: false, shiftKey: false, stopPropagation() {}, ...extra } as KeyboardEvent;
}
// Resolve Mod through CodeMirror itself: Node uses Control, whereas iOS uses Meta.
const probe = target([keymap.of([{ key: "Mod-x", run: () => true }])]);
const meta = runScopeHandlers(probe, event("x", true), "editor");

describe("iOS web/native shortcut ownership", () => {
  test("Cmd-Shift-V passes through to the native guarded Files action without modifying the note", () => {
    const view = target([iosCommandKeymap]);
    expect(runScopeHandlers(view, event("V", meta, { shiftKey: true }), "editor")).toBe(false);
    expect(view.state.doc.toString()).toBe("hello");
    expect(view.state.selection.main.from).toBe(0);
    expect(view.state.selection.main.to).toBe(5);
  });
  test("editor bold and heading shortcuts still consume their keys and change Markdown", () => {
    const bold = target([iosCommandKeymap]);
    expect(runScopeHandlers(bold, event("b", meta), "editor")).toBe(true);
    expect(bold.state.doc.toString()).toBe("**hello**");
    const heading = target([iosCommandKeymap]);
    expect(runScopeHandlers(heading, event("1", meta, { keyCode: 49, code: "Digit1" }), "editor")).toBe(true);
    expect(heading.state.doc.toString()).toBe("# hello");
  });
  test("the shared desktop Format inventory retains its File shortcut", () => {
    expect(FORMAT_SHORTCUTS).toContainEqual({ key: "Mod-Shift-v", command: "insertFile" });
  });
});
