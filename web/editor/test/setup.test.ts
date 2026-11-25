// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorView } from "@codemirror/view";
import { baseKeymap, loadedState } from "../src/editor/setup";
import { codeBlockHandlers } from "../src/editor/features/codeblocks";

describe("baseKeymap", () => {
  test("leaves ⌘[ / ⌘] to the host's Go Back / Go Forward (WebKit lets the page see them first)", () => {
    const keys = baseKeymap.flatMap((b) => [b.key, b.mac]).filter(Boolean);
    expect(keys).not.toContain("Mod-[");
    expect(keys).not.toContain("Mod-]");
    // The rest of CodeMirror's default keymap stays, e.g. select line.
    expect(keys).toContain("Alt-l");
  });
});

describe("loadedState", () => {
  test("applies the loadNote selection (F1: reloads keep the caret)", () => {
    const state = loadedState({ text: "hello world", readOnly: false, selection: { anchor: 2, head: 7 } });
    expect(state.doc.toString()).toBe("hello world");
    expect(state.selection.main.anchor).toBe(2);
    expect(state.selection.main.head).toBe(7);
  });

  test("keeps the Copy Code handler across loads (loadDocument passes it on)", () => {
    const code = { copyText: (_text: string) => {} };
    const state = loadedState({ text: "x", readOnly: false }, { code });
    expect(state.facet(codeBlockHandlers)).toBe(code);
  });

  test("clamps a selection past the end and defaults to the start", () => {
    const clamped = loadedState({ text: "abc", readOnly: false, selection: { anchor: 9, head: 1 } });
    expect([clamped.selection.main.anchor, clamped.selection.main.head]).toEqual([3, 1]);
    const none = loadedState({ text: "abc", readOnly: true });
    expect([none.selection.main.anchor, none.selection.main.head]).toEqual([0, 0]);
    expect(none.readOnly).toBe(true);
    // Line breaks are normalised as in EditorState: "a\r\nb" is 3 units long.
    const crlf = loadedState({ text: "a\r\nb", readOnly: false, selection: { anchor: 4, head: 4 } });
    expect(crlf.doc.toString()).toBe("a\nb");
    expect(crlf.selection.main.head).toBe(3);
  });
});

describe("read-only and locked documents refuse every user change", () => {
  test("a user change is dropped, the host's external change passes", async () => {
    const { externalChange } = await import("../src/bridge/client");
    const ro = loadedState({ text: "abc", readOnly: true });
    expect(ro.update({ changes: { from: 0, insert: "\t" }, userEvent: "input.indent" }).state.doc.toString()).toBe("abc");
    expect(ro.update({ changes: { from: 2, to: 3 }, userEvent: "delete.backward" }).state.doc.toString()).toBe("abc");
    expect(ro.update({ selection: { anchor: 1 } }).state.selection.main.head).toBe(1);
    const ext = ro.update({ changes: { from: 3, insert: "!" }, annotations: externalChange.of(true) });
    expect(ext.state.doc.toString()).toBe("abc!");
    const editable = loadedState({ text: "abc", readOnly: false });
    expect(editable.update({ changes: { from: 0, insert: "x" } }).state.doc.toString()).toBe("xabc");
  });

  test("the host's placeholder (locked) is not editable at all", () => {
    const locked = loadedState({ text: "", readOnly: true, locked: true });
    expect(locked.facet(EditorView.editable)).toBe(false);
    expect(locked.update({ changes: { from: 0, insert: "x" } }).state.doc.toString()).toBe("");
    expect(loadedState({ text: "", readOnly: true }).facet(EditorView.editable)).toBe(true);
  });
});
