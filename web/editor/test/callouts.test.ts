// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undoDepth } from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import { calloutAt, calloutLayout } from "../src/editor/features/callouts";
import { runCommand } from "../src/editor/features/commands";
import { menuTargetEffect, menuTargets } from "../src/editor/features/menu-targets";

/** `‸` marks the caret (default: the end); `«…»` a selection. */
function stateOf(marked: string, extensions: Extension[] = []): EditorState {
  let doc = marked;
  let anchor: number;
  let head: number;
  if (doc.includes("«")) {
    anchor = doc.indexOf("«");
    doc = doc.replace("«", "");
    head = doc.indexOf("»");
    doc = doc.replace("»", "");
  } else {
    const at = doc.indexOf("‸");
    doc = doc.replace("‸", "");
    anchor = head = at < 0 ? doc.length : at;
  }
  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(anchor, head),
    extensions: [markdown({ base: bearMarkdown }), history(), menuTargets, ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function run(state: EditorState, name: "callout" | "setCalloutType", args?: Record<string, unknown>) {
  const trs: Transaction[] = [];
  const handled = runCommand({ state, dispatch: (tr) => trs.push(tr) }, name, args);
  return { handled, state: trs.at(-1)?.state ?? state, trs };
}

/** Line number → its callout classes. */
function classes(state: EditorState): Record<number, string> {
  const out: Record<number, string> = {};
  for (const [from, cls] of calloutLayout(state).lines) out[state.doc.lineAt(from).number] = cls;
  return out;
}

const hiddenText = (state: EditorState) => calloutLayout(state).hidden.map((r) => state.doc.sliceString(r.from, r.to));

describe("callouts", () => {
  test("five types, any case", () => {
    for (const [marker, type] of [
      ["NOTE", "note"],
      ["tip", "tip"],
      ["Important", "important"],
      ["WARNING", "warning"],
      ["cAuTiOn", "caution"],
    ] as const) {
      const state = stateOf(`‸\n> [!${marker}]\n> body`);
      expect(calloutAt(state, 1)).toMatchObject({ type, known: true, markerFrom: 3, markerTo: 6 + marker.length, custom: false });
      expect(classes(state)[2]).toBe(`cm-bc-callout cm-bc-callout-${type} cm-bc-callout-depth-1 cm-bc-callout-first`);
      expect(classes(state)[3]).toBe(`cm-bc-callout cm-bc-callout-${type} cm-bc-callout-depth-1 cm-bc-callout-last`);
    }
    // Not a callout: no marker, a marker later on the line, or not in a quote.
    expect(calloutAt(stateOf("‸\n> plain"), 1)).toBeNull();
    expect(calloutAt(stateOf("‸\n> x [!NOTE]"), 1)).toBeNull();
    expect(calloutLayout(stateOf("[!NOTE] text")).lines.size).toBe(0);
  });

  test("unknown type renders as NOTE", () => {
    const state = stateOf("‸\n> [!question] Why?");
    expect(calloutAt(state, 1)).toMatchObject({ type: "note", known: false, title: "Why?", custom: true });
    expect(classes(state)[2]).toContain("cm-bc-callout-note");
    expect(calloutAt(stateOf("‸\n> [!QUESTION]"), 1)).toMatchObject({ title: "Note", custom: false });
  });

  test("custom title replaces the default", () => {
    const custom = stateOf("‸\n> [!TIP] Use the shortcut\n> body");
    expect(calloutAt(custom, 1)).toMatchObject({ title: "Use the shortcut", custom: true });
    // The marker and its space are hidden; no default title.
    expect(hiddenText(custom)).toEqual(["[!TIP] "]);
    expect(calloutLayout(custom).titles).toEqual([]);
    const plain = stateOf("‸\n> [!WARNING]\n> body");
    expect(calloutAt(plain, 1)).toMatchObject({ title: "Warning", custom: false });
    expect(calloutLayout(plain).titles).toEqual([{ pos: plain.doc.line(2).to, title: "Warning" }]);
  });

  test("title-only callout", () => {
    const state = stateOf("‸\n> [!IMPORTANT] Read me");
    expect(classes(state)[2]).toBe("cm-bc-callout cm-bc-callout-important cm-bc-callout-depth-1 cm-bc-callout-first cm-bc-callout-last");
    expect(calloutLayout(state).icons).toEqual([{ pos: 3, type: "important", quoteFrom: 1 }]);
  });

  test("nested callouts get their own box", () => {
    // `> after` right after `> > deep` would continue the inner paragraph (lazy line): `>` ends it.
    const state = stateOf("‸\n> [!NOTE] Outer\n> text\n> > [!WARNING] Inner\n> > deep\n>\n> after");
    const c = classes(state);
    expect(c[2]).toContain("cm-bc-callout-note cm-bc-callout-depth-1 cm-bc-callout-first");
    expect(c[3]).toContain("cm-bc-callout-note cm-bc-callout-depth-1");
    expect(c[4]).toBe("cm-bc-callout cm-bc-callout-warning cm-bc-callout-depth-2 cm-bc-callout-in-note cm-bc-callout-first");
    expect(c[5]).toBe("cm-bc-callout cm-bc-callout-warning cm-bc-callout-depth-2 cm-bc-callout-in-note cm-bc-callout-last");
    expect(c[7]).toBe("cm-bc-callout cm-bc-callout-note cm-bc-callout-depth-1 cm-bc-callout-last");
    expect(calloutLayout(state).icons.map((i) => i.type)).toEqual(["note", "warning"]);
    // A nested plain quote stays part of the outer box.
    expect(classes(stateOf("‸\n> [!TIP]\n> > quoted"))[3]).toContain("cm-bc-callout-tip cm-bc-callout-depth-1");
  });

  test("marker revealed on the caret line", () => {
    const doc = "intro\n> [!NOTE]\n> body";
    expect(hiddenText(stateOf("‸" + doc))).toEqual(["[!NOTE]"]);
    const onLine = stateOf(doc.replace("[!NOTE]", "[!NO‸TE]"));
    expect(hiddenText(onLine)).toEqual([]);
    expect(calloutLayout(onLine).titles).toEqual([]);
    // On the body line the marker stays hidden.
    expect(hiddenText(stateOf(doc.replace("body", "bo‸dy")))).toEqual(["[!NOTE]"]);
    // A caret at the start of a custom title is on the line: nothing hidden next to it, so
    // Backspace there deletes visible text, never the marker.
    const titled = "intro\n> [!TIP] Title";
    expect(hiddenText(stateOf(titled.replace(" Title", " ‸Title")))).toEqual([]);
  });
});

describe("commands", () => {
  test("setCalloutType rewrites only the marker", () => {
    const doc = "> [!note] Title\n> body‸";
    const { handled, state } = run(stateOf(doc), "setCalloutType", { type: "warning" });
    expect(handled).toBe(true);
    expect(state.doc.toString()).toBe("> [!WARNING] Title\n> body");
    // Through a menu target (the callout's first line), from elsewhere in the note.
    let start = stateOf("‸x\n> [!TIP]\n> > [!NOTE] inner");
    start = start.update({ effects: menuTargetEffect.of({ id: "m1", pos: start.doc.line(3).from }) }).state;
    expect(run(start, "setCalloutType", { type: "caution", menuId: "m1" }).state.doc.toString()).toBe("x\n> [!TIP]\n> > [!CAUTION] inner");
    // A dead target, an unknown type or no callout: nothing.
    expect(run(start, "setCalloutType", { type: "tip", menuId: "gone" }).handled).toBe(false);
    expect(run(stateOf(doc), "setCalloutType", { type: "question" }).handled).toBe(false);
    expect(run(stateOf("plain‸"), "setCalloutType", { type: "tip" }).handled).toBe(false);
  });

  test("callout command on an empty line and on a selection", () => {
    const empty = run(stateOf("a\n‸\nb"), "callout");
    expect(empty.state.doc.toString()).toBe("a\n> [!NOTE] \nb");
    expect(empty.state.selection.main.head).toBe("a\n> [!NOTE] ".length);
    expect(undoDepth(empty.state)).toBe(1);

    const selected = run(stateOf("«one\n\ntwo»\nrest"), "callout", { type: "tip" });
    expect(selected.state.doc.toString()).toBe("> [!TIP]\n> one\n>\n> two\nrest");
    expect(undoDepth(selected.state)).toBe(1);
    // A caret on a line with text: that line.
    expect(run(stateOf("te‸xt"), "callout").state.doc.toString()).toBe("> [!NOTE]\n> text");
    // Not in code.
    expect(run(stateOf("```\nco‸de\n```"), "callout").handled).toBe(false);
    // Disjoint cursors: one callout per run of lines.
    let multi = stateOf("one\nmiddle\ntwo", [EditorState.allowMultipleSelections.of(true)]);
    multi = multi.update({ selection: EditorSelection.create([EditorSelection.cursor(1), EditorSelection.cursor(12)]) }).state;
    expect(run(multi, "callout").state.doc.toString()).toBe("> [!NOTE]\n> one\nmiddle\n> [!NOTE]\n> two");
  });

  test("read-only refuses", () => {
    const ro = [EditorState.readOnly.of(true)];
    expect(run(stateOf("‸", ro), "callout").handled).toBe(false);
    expect(run(stateOf("> [!NOTE]‸", ro), "setCalloutType", { type: "tip" }).handled).toBe(false);
  });
});
