// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undo, undoDepth } from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import { footnotes, footnotesIn, footnoteTarget } from "../src/editor/features/footnotes";
import { computeHiddenRanges, computeMarkup, hideMarkdown } from "../src/editor/features/hiding";

function stateOf(doc: string, caret = doc.length, extensions: Extension[] = []): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(caret),
    extensions: [markdown({ base: bearMarkdown }), history(), footnotes, ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

const brief = (state: EditorState) => footnotesIn(state).map((f) => `${f.kind}:${f.label}@${f.from}`);

/** Types `text` over [from, to) as the user would (one input transaction). */
function type(state: EditorState, from: number, to: number, text: string) {
  return state.update({ changes: { from, to, insert: text }, userEvent: "input.type" }).state;
}

describe("footnotesIn", () => {
  test("refs and defs outside code and math", () => {
    const doc = [
      "text[^1] and [^note] `[^code]` $[^m]$ <!-- [^c] -->",
      "```",
      "[^fenced]",
      "```",
      "[^x](https://a.b) [[^w]]",
      "",
      "[^1]: one",
      "[^note]: named",
      "- [^2]: not a definition",
    ].join("\n");
    const state = stateOf(doc);
    expect(brief(state)).toEqual([
      "ref:1@4",
      "ref:note@13",
      `def:1@${doc.indexOf("[^1]: one")}`,
      `def:note@${doc.indexOf("[^note]: named")}`,
      `ref:2@${doc.indexOf("[^2]")}`,
    ]);
    const [first] = footnotesIn(state);
    expect(first).toEqual({ kind: "ref", label: "1", from: 4, to: 8, labelFrom: 6, labelTo: 7 });
    // `within` limits the scan to the lines it touches.
    const last = state.doc.line(state.doc.lines);
    expect(footnotesIn(state, [{ from: last.from, to: last.to }]).map((f) => f.label)).toEqual(["2"]);
  });

  test("a reference's brackets are hidden unless the caret is inside", () => {
    const doc = "see[^1] end\n\n[^1]: one";
    const hidden = computeHiddenRanges(stateOf(doc)).map((r) => doc.slice(r.from, r.to));
    expect(hidden).toEqual(["[^", "]"]);
    expect(computeHiddenRanges(stateOf(doc, 5))).toEqual([]);
  });
});

describe("fix round 1", () => {
  test("with Hide Markdown off nothing is hidden; the brackets are dimmed markup", () => {
    const doc = "see[^1] end";
    const markup = computeMarkup(stateOf(doc, 0, [hideMarkdown.of(false)]));
    expect(markup.hidden).toEqual([]);
    expect(markup.dim.map((r) => doc.slice(r.from, r.to))).toEqual(["[^", "]"]);
  });

  test("a passed tree decides what is code (⇧⌘E ensures one; the state's may lag)", () => {
    const doc = "```\n[^1]\n```\nref[^2]";
    const parsed = stateOf(doc);
    const tree = syntaxTree(parsed);
    // A state whose own tree is empty (not parsed yet) still excludes the fence with the given tree.
    const unparsed = EditorState.create({ doc, extensions: [markdown({ base: bearMarkdown })] });
    expect(footnotesIn(unparsed, undefined, tree).map((f) => f.label)).toEqual(["2"]);
  });

  test("deleting or pasting inside a label renames too", () => {
    const doc = "a[^12] b\n\n[^12]: one";
    const deleted = stateOf(doc).update({ changes: { from: 4, to: 5 }, userEvent: "delete.backward" }).state;
    expect(deleted.doc.toString()).toBe("a[^1] b\n\n[^1]: one");
    const pasted = stateOf(doc).update({ changes: { from: 3, to: 5, insert: "src" }, userEvent: "input.paste" }).state;
    expect(pasted.doc.toString()).toBe("a[^src] b\n\n[^src]: one");
  });
});

describe("footnoteTarget", () => {
  test("click target both ways", () => {
    const doc = "a[^1] b[^1]\n\n[^1]: one\n[^2]: orphan";
    const state = stateOf(doc);
    // Reference → the definition's text; definition → just after the first reference.
    expect(footnoteTarget(state, 2)).toBe(doc.indexOf("one"));
    expect(footnoteTarget(state, 8)).toBe(doc.indexOf("one"));
    expect(footnoteTarget(state, doc.indexOf("[^1]:") + 1)).toBe(5);
    expect(footnoteTarget(state, doc.indexOf("[^2]:") + 1)).toBeNull();
    expect(footnoteTarget(state, doc.indexOf(" b") + 1)).toBeNull();
  });
});

describe("label rename (M6-R41)", () => {
  const doc = "a[^1] b\n\n[^1]: one";
  const refLabel = 3;
  const defLabel = doc.indexOf("[^1]:") + 2;

  test("renaming a ref label renames its definition in one undo step", () => {
    let state = stateOf(doc);
    state = type(state, refLabel, refLabel + 1, "note");
    expect(state.doc.toString()).toBe("a[^note] b\n\n[^note]: one");
    expect(undoDepth(state)).toBe(1);
    let undone = state;
    undo({ state, dispatch: (tr) => (undone = tr.state) });
    expect(undone.doc.toString()).toBe(doc);
    // Typing into a label, character by character, keeps the pair in step.
    let typed = stateOf(doc);
    typed = type(typed, refLabel + 1, refLabel + 1, "a");
    typed = type(typed, refLabel + 2, refLabel + 2, "b");
    expect(typed.doc.toString()).toBe("a[^1ab] b\n\n[^1ab]: one");
    // And from the definition side.
    const fromDef = type(stateOf(doc), defLabel, defLabel + 1, "x");
    expect(fromDef.doc.toString()).toBe("a[^x] b\n\n[^x]: one");
  });

  test("no propagation when the new label exists or there are two counterparts", () => {
    const taken = "a[^1] b[^2]\n\n[^1]: one\n[^2]: two";
    expect(type(stateOf(taken), 3, 4, "2").doc.toString()).toBe("a[^2] b[^2]\n\n[^1]: one\n[^2]: two");
    const shared = "a[^1] b[^1]\n\n[^1]: one";
    expect(type(stateOf(shared), 3, 4, "x").doc.toString()).toBe("a[^x] b[^1]\n\n[^1]: one");
    const twoDefs = "a[^1]\n\n[^1]: one\n[^1]: again";
    expect(type(stateOf(twoDefs), 3, 4, "x").doc.toString()).toBe("a[^x]\n\n[^1]: one\n[^1]: again");
    // An edit beyond the label, or of two labels, is not a rename.
    expect(type(stateOf(doc), 1, 4, "Z[^x").doc.toString()).toBe("aZ[^x] b\n\n[^1]: one");
    // Undo/redo and host changes never propagate.
    const host = stateOf(doc).update({ changes: { from: refLabel, to: refLabel + 1, insert: "h" } }).state;
    expect(host.doc.toString()).toBe("a[^h] b\n\n[^1]: one");
  });

  test("read-only: no rename", () => {
    const state = stateOf(doc, doc.length, [EditorState.readOnly.of(true)]);
    expect(type(state, refLabel, refLabel + 1, "x").doc.toString()).toBe("a[^x] b\n\n[^1]: one");
  });
});
