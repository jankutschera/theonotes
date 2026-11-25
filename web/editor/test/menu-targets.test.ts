// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorState, Transaction, type TransactionSpec } from "@codemirror/state";
import { menuTargetEffect, menuTargetPos, menuTargets, rememberMenuTarget, resolveMenuTarget } from "../src/editor/features/menu-targets";

/** The transaction `rememberMenuTarget` dispatches, applied to a bare state. */
function remember(state: EditorState, pos: number, id = `t${pos}`): { id: string; state: EditorState } {
  return { id, state: state.update({ effects: menuTargetEffect.of({ id, pos }) }).state };
}

describe("menu targets", () => {
  test("a remembered target follows edits before it and dies with its text", () => {
    let state = EditorState.create({ doc: "abc\n| a |", extensions: [menuTargets] });
    const { id, state: s1 } = remember(state, 5);
    state = s1.update({ changes: { from: 0, insert: "xx" } }).state;
    expect(menuTargetPos(state, id)).toBe(7);
    state = state.update({ changes: { from: 6, to: 11 } }).state;
    expect(menuTargetPos(state, id)).toBeNull();
  });

  test("a target at the start of a line dies when that line is deleted or replaced from the target on", () => {
    const base = EditorState.create({ doc: "# a\n## b\nrest", extensions: [menuTargets] });
    const { id, state } = remember(base, 4);
    // The whole line, newline included.
    expect(menuTargetPos(state.update({ changes: { from: 4, to: 9 } }).state, id)).toBeNull();
    // The line's text only (the line stays, empty).
    expect(menuTargetPos(state.update({ changes: { from: 4, to: 8 } }).state, id)).toBeNull();
    // Replaced.
    expect(menuTargetPos(state.update({ changes: { from: 4, to: 8, insert: "## c" } }).state, id)).toBeNull();
    // Deleting the line above, or only the end of this line's predecessor, keeps it.
    expect(menuTargetPos(state.update({ changes: { from: 0, to: 4 } }).state, id)).toBe(0);
    expect(menuTargetPos(state.update({ changes: { from: 2, to: 3 } }).state, id)).toBe(3);
    // Deleting after it (the next line) keeps it.
    expect(menuTargetPos(state.update({ changes: { from: 8, to: 13 } }).state, id)).toBe(4);
  });

  test("an edit after the target leaves it where it is", () => {
    const base = EditorState.create({ doc: "# a\nbody", extensions: [menuTargets] });
    const { id, state } = remember(base, 0);
    const after = state.update({ changes: { from: 8, insert: "!" } }).state;
    expect(menuTargetPos(after, id)).toBe(0);
  });

  test("text typed at the target's position pushes the target along (a line start stays on its line)", () => {
    const base = EditorState.create({ doc: "x\n## H", extensions: [menuTargets] });
    const { id, state } = remember(base, 2);
    expect(menuTargetPos(state.update({ changes: { from: 2, insert: "ab" } }).state, id)).toBe(4);
  });

  test("an unknown id and a state without the field answer null", () => {
    const state = EditorState.create({ doc: "abc", extensions: [menuTargets] });
    expect(menuTargetPos(state, "nope")).toBeNull();
    expect(menuTargetPos(EditorState.create({ doc: "abc" }), "nope")).toBeNull();
  });

  test("the last 8 targets are kept", () => {
    let state = EditorState.create({ doc: "0123456789abcdef", extensions: [menuTargets] });
    for (let i = 0; i < 10; i++) state = remember(state, i, `id${i}`).state;
    expect(menuTargetPos(state, "id0")).toBeNull();
    expect(menuTargetPos(state, "id1")).toBeNull();
    expect(menuTargetPos(state, "id2")).toBe(2);
    expect(menuTargetPos(state, "id9")).toBe(9);
  });

  test("replacing the whole document drops every target", () => {
    const base = EditorState.create({ doc: "abc", extensions: [menuTargets] });
    const { id, state } = remember(base, 1);
    expect(menuTargetPos(state.update({ changes: { from: 0, to: 3, insert: "xyz" } }).state, id)).toBeNull();
  });

  /** The slice of an EditorView `rememberMenuTarget` needs (the unit tests run without a DOM). */
  function target(doc: string) {
    const t = {
      state: EditorState.create({ doc, extensions: [menuTargets] }),
      transactions: [] as Transaction[],
      dispatch(spec: TransactionSpec) {
        const tr = t.state.update(spec);
        t.transactions.push(tr);
        t.state = tr.state;
      },
    };
    return t;
  }

  test("remembering a target is not an edit: no document change, no undo step", () => {
    const view = target("abc");
    const id = rememberMenuTarget(view, 2);
    expect(view.transactions).toHaveLength(1);
    expect(view.transactions[0]!.docChanged).toBe(false);
    expect(view.transactions[0]!.annotation(Transaction.addToHistory)).toBe(false);
    expect(menuTargetPos(view.state, id)).toBe(2);
    expect(view.state.doc.toString()).toBe("abc");
  });

  test("resolveMenuTarget: no menuId acts at the selection, a live id at its position, a dead id does nothing", () => {
    const view = target("# a\nbody");
    const id = rememberMenuTarget(view, 4);
    expect(resolveMenuTarget(view.state, undefined)).toEqual({ kind: "selection" });
    expect(resolveMenuTarget(view.state, {})).toEqual({ kind: "selection" });
    expect(resolveMenuTarget(view.state, { level: 2 })).toEqual({ kind: "selection" });
    expect(resolveMenuTarget(view.state, { menuId: id })).toEqual({ kind: "target", pos: 4 });
    view.dispatch({ changes: { from: 0, insert: "xx" } });
    expect(resolveMenuTarget(view.state, { menuId: id })).toEqual({ kind: "target", pos: 6 });
    view.dispatch({ changes: { from: 0, to: view.state.doc.length } });
    expect(resolveMenuTarget(view.state, { menuId: id })).toEqual({ kind: "dead" });
    // Unknown, empty and non-string ids are dead too, never the selection.
    expect(resolveMenuTarget(view.state, { menuId: "menu-nope" })).toEqual({ kind: "dead" });
    expect(resolveMenuTarget(view.state, { menuId: "" })).toEqual({ kind: "dead" });
    expect(resolveMenuTarget(view.state, { menuId: 3 })).toEqual({ kind: "dead" });
    expect(resolveMenuTarget(view.state, { menuId: null })).toEqual({ kind: "dead" });
  });

  test("rememberMenuTarget hands out distinct ids", () => {
    const view = target("abc");
    const a = rememberMenuTarget(view, 1);
    const b = rememberMenuTarget(view, 1);
    expect(a).not.toBe(b);
    expect(a.length).toBeGreaterThan(0);
    expect(menuTargetPos(view.state, a)).toBe(1);
    expect(menuTargetPos(view.state, b)).toBe(1);
  });

  test("a position outside the document is not remembered", () => {
    const view = target("abc");
    const id = rememberMenuTarget(view, 99);
    expect(menuTargetPos(view.state, id)).toBeNull();
  });
});
