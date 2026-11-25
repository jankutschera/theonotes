// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, type EditorState, StateEffect, type TransactionSpec } from "@codemirror/state";
import { currentSettings, settingsTransaction } from "../src/editor/features/settings";
import { resizeSpec } from "../src/editor/features/attachments";
import { toggleTodoAt } from "../src/editor/features/todos";
import { typewriterScroll } from "../src/editor/features/typewriter";
import { loadedState } from "../src/editor/setup";

const doc = "line one\nline two\nline three";

/** What a keyboard-driven transaction looks like: it asks for the caret to be scrolled into view. */
const keyed = (spec: TransactionSpec): TransactionSpec => ({ scrollIntoView: true, ...spec });

function stateWith(typewriterMode: boolean): EditorState {
  const state = loadedState({ text: doc, readOnly: false, selection: { anchor: 0, head: 0 } });
  return typewriterMode ? state.update(settingsTransaction(state, { typewriterMode })!).state : state;
}

/** CodeMirror does not export the scroll effect type; its value is a ScrollTarget with `range` and `y`. */
type Target = { range: { head: number }; y: string };
const isScroll = (e: StateEffect<unknown>) => (e.value as Partial<Target> | undefined)?.range !== undefined;

/** The scroll effects a transaction carries once the state's extenders have run. */
const scrollEffects = (state: EditorState, spec: TransactionSpec) => state.update(spec).effects.filter(isScroll);

describe("typewriter mode", () => {
  test("off by default: nothing scrolls", () => {
    const state = stateWith(false);
    expect(currentSettings(state).typewriterMode).toBe(false);
    expect(typewriterScroll(state.update(keyed({ changes: { from: 0, insert: "x" }, userEvent: "input.type" })))).toBeNull();
    expect(scrollEffects(state, keyed({ changes: { from: 0, insert: "x" }, userEvent: "input.type" }))).toHaveLength(0);
  });

  test("typing adds a centre scroll effect", () => {
    const state = stateWith(true);
    const tr = state.update(keyed({ changes: { from: 0, insert: "x" }, selection: { anchor: 1 }, userEvent: "input.type" }));
    const effect = typewriterScroll(tr);
    expect(effect).not.toBeNull();
    expect(isScroll(effect!)).toBe(true);
    // The extender puts the same effect on the transaction itself, aimed at the new caret.
    const [onTransaction] = tr.effects.filter(isScroll);
    expect(onTransaction).toBeDefined();
    const target = onTransaction!.value as Target;
    expect(target.range.head).toBe(1);
    expect(target.y).toBe("center");
  });

  test("deleting, moving the caret and keyboard selection scroll; pointer selection does not", () => {
    const state = stateWith(true);
    for (const userEvent of ["delete.backward", "delete.line", "move.line", "select", "select.extend", "input.paste"]) {
      const spec = userEvent.startsWith("delete")
        ? { changes: { from: 0, to: 1 }, userEvent }
        : userEvent.startsWith("input") || userEvent.startsWith("move")
          ? { changes: { from: 0, insert: "y" }, userEvent }
          : { selection: EditorSelection.single(5), userEvent };
      expect(scrollEffects(state, keyed(spec)), userEvent).toHaveLength(1);
    }
    expect(scrollEffects(state, keyed({ selection: EditorSelection.single(5), userEvent: "select.pointer" }))).toHaveLength(0);
  });

  test("nothing while composing", () => {
    const state = stateWith(true);
    const tr = state.update(keyed({ changes: { from: 0, insert: "あ" }, userEvent: "input.type.compose" }));
    expect(typewriterScroll(tr)).toBeNull();
    expect(tr.effects.filter(isScroll)).toHaveLength(0);
  });

  test("the host's changes and plain dispatches do not scroll (a note opening is no transaction)", () => {
    const state = stateWith(true);
    expect(scrollEffects(state, { changes: { from: 0, insert: "ext" } })).toHaveLength(0);
    expect(scrollEffects(state, { selection: { anchor: 3 } })).toHaveLength(0);
  });

  test("the setting is read from the state before the transaction: switching it off stops at once", () => {
    let state = stateWith(true);
    state = state.update(settingsTransaction(state, { typewriterMode: false })!).state;
    expect(scrollEffects(state, keyed({ changes: { from: 0, insert: "x" }, userEvent: "input.type" }))).toHaveLength(0);
  });

  test("undo and redo centre the caret too", () => {
    const state = stateWith(true);
    for (const userEvent of ["undo", "redo"]) {
      expect(scrollEffects(state, keyed({ changes: { from: 0, insert: "z" }, userEvent })), userEvent).toHaveLength(1);
    }
  });

  test("a transaction that does not ask for the scroll does not centre, whatever its user event", () => {
    const state = stateWith(true);
    expect(scrollEffects(state, { changes: { from: 0, insert: "x" }, userEvent: "input.type" })).toHaveLength(0);
    expect(scrollEffects(state, { selection: EditorSelection.single(5), userEvent: "select" })).toHaveLength(0);
  });

  test("a todo checkbox click does not centre", () => {
    let state = loadedState({ text: "intro\n- [ ] one\n- [ ] two", readOnly: false, selection: { anchor: 25, head: 25 } });
    state = state.update(settingsTransaction(state, { typewriterMode: true })!).state;
    const spec = toggleTodoAt(state, 8)!;
    expect(spec).not.toBeNull();
    const tr = state.update(spec);
    expect(tr.isUserEvent("input")).toBe(true);
    expect(tr.effects.filter(isScroll)).toHaveLength(0);
  });

  test("an image resize does not centre", () => {
    let state = loadedState({ text: "![](a.png)\ntext", readOnly: false, selection: { anchor: 15, head: 15 } });
    state = state.update(settingsTransaction(state, { typewriterMode: true })!).state;
    const spec = resizeSpec(state, { from: 0, to: 10 } as never, 120);
    const tr = state.update(spec);
    expect(tr.isUserEvent("input.attachment")).toBe(true);
    expect(tr.effects.filter(isScroll)).toHaveLength(0);
  });

  test("the scroll is marked as ours, so Find Next and the search highlight (default margin) are not", () => {
    const state = stateWith(true);
    const [ours] = state.update(keyed({ selection: EditorSelection.single(5), userEvent: "select" })).effects.filter(isScroll);
    expect((ours!.value as { yMargin: number }).yMargin).not.toBe(5);
  });
});
