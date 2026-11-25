// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, type StateCommand, type Transaction } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { history, redo, undo, undoDepth } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import {
  arrowConversion,
  deleteListMarkup,
  indentListItem,
  insertNewlineContinueList,
  insertNewlineWithoutMarker,
  listLayout,
  listLineStart,
  lists,
  moveListBlockDown,
  moveListBlockUp,
  outdentListItem,
  parseLinePrefix,
  wrapSelectionSpec,
} from "../src/editor/features/lists";

// Notation: `|` is the caret; `‹…›` a range selection (anchor ‹, head ›).
function make(spec: string, extensions: Extension[] = []): EditorState {
  const ranges: { anchor: number; head: number }[] = [];
  let doc = "";
  let anchor: number | null = null;
  let head: number | null = null;
  for (const ch of spec) {
    if (ch === "|") ranges.push({ anchor: doc.length, head: doc.length });
    else if (ch === "‹") anchor = doc.length;
    else if (ch === "›") head = doc.length;
    else doc += ch;
    if (anchor !== null && head !== null) {
      ranges.push({ anchor, head });
      anchor = head = null;
    }
  }
  const selection = ranges.length
    ? EditorSelection.create(ranges.map((r) => EditorSelection.range(r.anchor, r.head)))
    : EditorSelection.single(0);
  const state = EditorState.create({
    doc,
    selection,
    extensions: [markdown({ base: bearMarkdown, addKeymap: false }), EditorState.allowMultipleSelections.of(true), ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function show(state: EditorState): string {
  const marks: { pos: number; text: string }[] = [];
  for (const r of state.selection.ranges) {
    if (r.empty) marks.push({ pos: r.head, text: "|" });
    else marks.push({ pos: r.anchor, text: "‹" }, { pos: r.head, text: "›" });
  }
  marks.sort((a, b) => b.pos - a.pos);
  let doc = state.doc.toString();
  for (const m of marks) doc = doc.slice(0, m.pos) + m.text + doc.slice(m.pos);
  return doc;
}

function apply(cmd: StateCommand, spec: string, extensions: Extension[] = []): { out: string | false; tr: Transaction | null } {
  const state = make(spec, extensions);
  let tr: Transaction | null = null;
  const ok = cmd({ state, dispatch: (t) => (tr = t) });
  if (!ok) return { out: false, tr: null };
  return { out: show(tr!.state), tr };
}
const run = (cmd: StateCommand, spec: string) => apply(cmd, spec).out;

/** Runs `cmd`, then checks that one undo restores `spec` exactly and redo re-applies it. */
function undoable(cmd: StateCommand, spec: string): string {
  const state = make(spec, [history()]);
  let tr: Transaction | null = null;
  expect(cmd({ state, dispatch: (t) => (tr = t) })).toBe(true);
  const after = tr!.state;
  expect(undoDepth(after)).toBe(1);
  let undone: Transaction | null = null;
  expect(undo({ state: after, dispatch: (t) => (undone = t) })).toBe(true);
  expect(show(undone!.state)).toBe(spec);
  let redone: Transaction | null = null;
  redo({ state: undone!.state, dispatch: (t) => (redone = t) });
  expect(redone!.state.doc.toString()).toBe(after.doc.toString());
  return show(after);
}

describe("parseLinePrefix (Bear: a list starts only with marker + space)", () => {
  test.each([
    ["- a", { kind: "bullet", marker: "-", textFrom: 2, contentFrom: 2 }],
    ["* a", { kind: "bullet", marker: "*" }],
    ["+ a", { kind: "bullet", marker: "+" }],
    ["12. a", { kind: "ordered", marker: "12.", number: 12, delim: ".", textFrom: 4 }],
    ["3) a", { kind: "ordered", marker: "3)", number: 3, delim: ")" }],
    ["- [ ] a", { kind: "bullet", box: "[ ] ", contentFrom: 6 }],
    ["- [x]", { kind: "bullet", box: "[x]", contentFrom: 5 }],
    ["- ", { kind: "bullet", textFrom: 2 }],
    ["  - a", { markerFrom: 2 }],
    ["-\ta", { spacing: "\t" }],
  ])("%j is a list item", (text, expected) => {
    expect(parseLinePrefix(text).list).toMatchObject(expected);
  });

  test.each(["1.", "-", "1.a", "-a", "12. March", "3. Mai", "31. Dezember", "1. Jan. 2026", "- - -", "* * *", "text", ""])(
    "%j is not a list item",
    (text) => {
      expect(parseLinePrefix(text).list).toBeNull();
    },
  );

  test.each(["12. March 2026", "3. Mai,", "1. Jan 2026", "12. März.", "1. Okt. 2025", "4. July!", "9. Sept 9"])("%j is a date, not a list", (text) => {
    expect(parseLinePrefix(text).list).toBeNull();
  });

  test.each(["1. Jan to send invoice", "1. Jan Kutschera", "1. May I come in", "2. March on Rome", "3. Mai bis Juni", "4. Dez"])(
    "%j is a list item: a month word followed by more text is not a date",
    (text) => {
      expect(parseLinePrefix(text).list).not.toBeNull();
    },
  );

  test("the date heuristic needs a capitalized month and a day number", () => {
    expect(parseLinePrefix("12. march").list).not.toBeNull();
    expect(parseLinePrefix("40. March").list).not.toBeNull();
    expect(parseLinePrefix("12) March").list).not.toBeNull();
    expect(parseLinePrefix("12. Marching").list).not.toBeNull();
  });

  test("quote prefix and indentation", () => {
    expect(parseLinePrefix("> > - a")).toMatchObject({ quote: "> > ", indent: "", list: { markerFrom: 4 } });
    expect(parseLinePrefix(">   1. a")).toMatchObject({ quote: "> ", indent: "  ", list: { markerFrom: 4 } });
    expect(parseLinePrefix("> 1.")).toMatchObject({ quote: "> ", list: null });
  });
});

describe("Enter continues lists and quotes", () => {
  test.each([
    ["- a|", "- a\n- |"],
    ["* a|", "* a\n* |"],
    ["+ a|", "+ a\n+ |"],
    ["1. a|", "1. a\n2. |"],
    ["9) a|", "9) a\n10) |"],
    ["- [ ] a|", "- [ ] a\n- [ ] |"],
    ["- [x] done|", "- [x] done\n- [ ] |"],
    ["  - a|", "  - a\n  - |"],
    ["> a|", "> a\n> |"],
    [">a|", ">a\n> |"],
    ["> > a|", "> > a\n> > |"],
    ["> - a|", "> - a\n> - |"],
    ["> 1. a|", "> 1. a\n> 2. |"],
    ["- a|b", "- a\n- |b"],
    ["- a |  b", "- a\n- |b"],
    ["- |a", "- \n- |a"],
    ["- ‹a›b", "- \n- |b"],
    ["1. a|\n2. b\n3. c", "1. a\n2. |\n3. b\n4. c"],
    ["5. a|\n6. b", "5. a\n6. |\n7. b"],
  ])("%j → %j", (before, after) => {
    expect(run(insertNewlineContinueList, before)).toBe(after);
  });

  test.each([
    ["- |", "|"],
    ["-   |", "|"],
    ["1. |", "|"],
    ["- [ ] |", "|"],
    ["> - |", "> |"],
    ["> |", "|"],
    ["> > |", "> |"],
    ["- a\n  - |", "- a\n- |"],
    ["- a\n  - [ ] |", "- a\n- [ ] |"],
    ["1. a\n   1. |", "1. a\n2. |"],
  ])("empty item %j → %j (removes the marker, outdents first)", (before, after) => {
    expect(run(insertNewlineContinueList, before)).toBe(after);
  });

  test('↩ keeps the ")" delimiter', () => {
    expect(run(insertNewlineContinueList, "1) a|")).toBe("1) a\n2) |");
    expect(run(insertNewlineContinueList, "> 3) a|\n> 4) b")).toBe("> 3) a\n> 4) |\n> 5) b");
    expect(run(insertNewlineContinueList, "1. a\n   1) x|")).toBe("1. a\n   1) x\n   2) |");
  });

  test("a bare marker is text: plain Enter (fallback) or quote continuation", () => {
    expect(run(insertNewlineContinueList, "1.|")).toBe(false);
    expect(run(insertNewlineContinueList, "-|")).toBe(false);
    expect(run(insertNewlineContinueList, "> 1.|")).toBe("> 1.\n> |");
    // Carried from bug 3a05be4: a bare ordered marker after a list marker stays.
    expect(run(insertNewlineContinueList, "- 1.|")).toBe("- 1.\n- |");
    expect(run(insertNewlineContinueList, "1. 1.|")).toBe("1. 1.\n2. |");
  });

  test("no list: dates, rules, plain text and code fall back to the default Enter", () => {
    expect(run(insertNewlineContinueList, "12. March|")).toBe(false);
    expect(run(insertNewlineContinueList, "* * *|")).toBe(false);
    expect(run(insertNewlineContinueList, "text|")).toBe(false);
    expect(run(insertNewlineContinueList, "```\n- a|\n```")).toBe(false);
    expect(run(insertNewlineContinueList, "```\n> a|\n```")).toBe(false);
  });

  test("an item numbered 1 after a blank line starts a new list: not renumbered", () => {
    expect(run(insertNewlineContinueList, "1. a|\n2. b\n\n1. c\n2. d")).toBe("1. a\n2. |\n3. b\n\n1. c\n2. d");
    // Without the blank line, or with another number, it is the same list.
    expect(run(insertNewlineContinueList, "1. a|\n2. b\n\n3. c")).toBe("1. a\n2. |\n3. b\n\n4. c");
  });

  test("the caret inside the marker of an empty item ends the list; of a full item splits after it", () => {
    expect(run(insertNewlineContinueList, "1|2. ")).toBe("|");
    expect(run(insertNewlineContinueList, "- [| ] ")).toBe("|");
    expect(run(insertNewlineContinueList, "1|2. a")).toBe("12. \n13. |a");
  });

  test("multiple carets", () => {
    expect(run(insertNewlineContinueList, "- a|\n- b|")).toBe("- a\n- |\n- b\n- |");
  });

  test("one undo step", () => {
    expect(undoable(insertNewlineContinueList, "1. a|\n2. b")).toBe("1. a\n2. |\n3. b");
    expect(undoable(insertNewlineContinueList, "- a\n  - |")).toBe("- a\n- |");
    expect(undoable(insertNewlineContinueList, "- |")).toBe("|");
  });

  test("read-only", () => {
    const state = make("- a|", [EditorState.readOnly.of(true)]);
    expect(insertNewlineContinueList({ state, dispatch: () => {} })).toBe(false);
  });
});

describe("Shift-Enter: a new line without a marker", () => {
  test.each([
    ["- a|", "- a\n|"],
    ["1. a|b", "1. a\n|b"],
    ["> - a|", "> - a\n> |"],
    ["> a|", "> a\n> |"],
  ])("%j → %j", (before, after) => {
    expect(run(insertNewlineWithoutMarker, before)).toBe(after);
  });

  test("plain lines and code: not handled (the default Enter keeps the indentation)", () => {
    expect(run(insertNewlineWithoutMarker, "a|")).toBe(false);
    expect(run(insertNewlineWithoutMarker, "‹a›")).toBe(false);
    expect(run(insertNewlineWithoutMarker, "```\n- a|\n```")).toBe(false);
  });

  test("one undo step", () => {
    expect(undoable(insertNewlineWithoutMarker, "- a|")).toBe("- a\n|");
  });
});

describe("Backspace after a list marker", () => {
  test.each([
    ["- |a", "|a"],
    ["- [ ] |a", "|a"],
    ["- [x] |a", "|a"],
    ["1. |a", "|a"],
    ["- a\n  - |b", "- a\n  |b"],
    ["> - |a", "> |a"],
    ["- |", "|"],
    ["> |a", "|a"],
    ["> > |a", "> |a"],
    ["> |", "|"],
  ])("%j → %j (the item becomes text at the same indent)", (before, after) => {
    expect(run(deleteListMarkup, before)).toBe(after);
  });

  test("Backspace before the marker of a nested item outdents it", () => {
    expect(run(deleteListMarkup, "- a\n  |- b\n    - c")).toBe("- a\n|- b\n  - c");
  });

  test("everything else is the default Backspace", () => {
    expect(run(deleteListMarkup, "- a|")).toBe(false);
    expect(run(deleteListMarkup, "-| a")).toBe(false);
    expect(run(deleteListMarkup, "1.|")).toBe(false);
    expect(run(deleteListMarkup, "- 1.|")).toBe(false);
    expect(run(deleteListMarkup, "|- a")).toBe(false);
    expect(run(deleteListMarkup, "- ‹a›")).toBe(false);
    expect(run(deleteListMarkup, "text|")).toBe(false);
    expect(run(deleteListMarkup, "```\n- |a\n```")).toBe(false);
  });

  test("renumbers the rest of an ordered list: the next sibling takes the removed number", () => {
    expect(run(deleteListMarkup, "1. a\n   1. |b\n   2. c")).toBe("1. a\n   |b\n   1. c");
    // Children and continuation lines of the removed item are skipped; the sibling after them counts.
    expect(run(deleteListMarkup, "5. |a\n   1. x\n   2. y\n6. b")).toBe("|a\n   1. x\n   2. y\n5. b");
    expect(run(deleteListMarkup, "5. |a\n   cont\n\n6. b\n7. c")).toBe("|a\n   cont\n\n5. b\n6. c");
    // Not a sibling of the same list: left alone.
    expect(run(deleteListMarkup, "5. |a\n- b")).toBe("|a\n- b");
    expect(run(deleteListMarkup, "5. |a\n6) b")).toBe("|a\n6) b");
    expect(run(deleteListMarkup, "   5. |a\n6. b")).toBe("   |a\n6. b");
  });

  test("one undo step, never joined with the Backspaces before it", () => {
    let state = make("- abc|", [history()]);
    const press = (cmd: StateCommand) => cmd({ state, dispatch: (t) => (state = t.state) });
    // Two plain deletions (as the default Backspace would dispatch them), then the marker.
    state = state.update({ changes: { from: 4, to: 5 }, userEvent: "delete.backward" }).state;
    state = state.update({ changes: { from: 3, to: 4 }, userEvent: "delete.backward" }).state;
    state = state.update({ changes: { from: 2, to: 3 }, userEvent: "delete.backward" }).state;
    expect(show(state)).toBe("- |");
    expect(press(deleteListMarkup)).toBe(true);
    expect(show(state)).toBe("|");
    undo({ state, dispatch: (t) => (state = t.state) });
    expect(state.doc.toString()).toBe("- ");
  });
});

describe("Tab / Shift-Tab", () => {
  test.each([
    ["- a\n- b|", "- a\n  - b|"],
    ["- a\n- [ ] b|", "- a\n  - [ ] b|"],
    ["1. a\n- b|", "1. a\n   - b|"],
    ["10. a\n11. b|", "10. a\n    1. b|"],
    ["1. a\n2. b|", "1. a\n   1. b|"],
    ["1. a\n2. b|\n3. c", "1. a\n   1. b|\n2. c"],
    ["- a\n- b|\n  - c\n- d", "- a\n  - b|\n    - c\n- d"],
    ["- a\n‹- b\n- c›", "- a\n  ‹- b\n  - c›"],
    ["> - a\n> - b|", "> - a\n>   - b|"],
    ["- a\n\n- b|", "- a\n\n  - b|"],
    // Joining an existing nested list takes its kind; a todo keeps its box.
    ["1. a\n   - x\n2. b|", "1. a\n   - x\n   - b|"],
    ["- a\n  1. x\n- b|", "- a\n  1. x\n  2. b|"],
    ["- a\n  * x\n- b|", "- a\n  * x\n  * b|"],
    ["- a\n  1. x\n- [ ] b|", "- a\n  1. x\n  - [ ] b|"],
    ["1. a\n   1. x\n2. b|\n3. c", "1. a\n   1. x\n   2. b|\n2. c"],
    // An ordered item joining an ordered list with the other delimiter takes its delimiter.
    ["1. a\n   1) x\n2. b|", "1. a\n   1) x\n   2) b|"],
    // Selected siblings joining a nested list all take its kind (and numbering).
    ["1. a\n   - x\n‹2. b\n3. c›", "1. a\n   - x\n   ‹- b\n   - c›"],
    ["- a\n  1. x\n‹- b\n- c›", "- a\n  1. x\n  ‹2. b\n  3. c›"],
    ["- a\n  * x\n‹- b\n+ c›", "- a\n  * x\n  ‹* b\n  * c›"],
    // A new nested list: the following siblings take the first one's kind.
    ["- a\n‹1. b\n- c›", "- a\n  ‹1. b\n  2. c›"],
    // Selected siblings in a row stay siblings (same width), whatever their number widths.
    ["9. a\n‹10. b\n11. c›", "9. a\n   ‹1. b\n   2. c›"],
  ])("Tab %j → %j", (before, after) => {
    expect(run(indentListItem, before)).toBe(after);
  });

  test("the first item of a list has no parent: Tab is consumed, nothing changes", () => {
    const { out, tr } = apply(indentListItem, "- a|\n- b");
    expect(out).toBe("- a|\n- b");
    expect(tr!.docChanged).toBe(false);
  });

  test("not a list line: Tab is not handled here", () => {
    expect(run(indentListItem, "text|")).toBe(false);
    expect(run(indentListItem, "```\n- a|\n```")).toBe(false);
  });

  test.each([
    ["- a\n  - b|", "- a\n- b|"],
    ["- a\n  - b|\n    - c", "- a\n- b|\n  - c"],
    ["- a\n  - x\n  - b|", "- a\n  - x\n- b|"],
    ["1. a\n   1. b|\n2. c", "1. a\n2. b|\n3. c"],
    ["   - a|", "- a|"],
    ["- a\n\t- b|", "- a\n- b|"],
    ["- a\n  ‹- b\n  - c›", "- a\n‹- b\n- c›"],
    // A selected item that cannot move does not hold back its selected children.
    ["‹- a\n  - b\n    - c›", "‹- a\n- b\n  - c›"],
  ])("Shift-Tab %j → %j", (before, after) => {
    expect(run(outdentListItem, before)).toBe(after);
  });

  test("Shift-Tab on a top-level item is consumed without a change", () => {
    const { tr } = apply(outdentListItem, "- a|");
    expect(tr!.docChanged).toBe(false);
    expect(run(outdentListItem, "text|")).toBe(false);
  });

  test("one undo step each", () => {
    expect(undoable(indentListItem, "1. a\n2. b|\n3. c")).toBe("1. a\n   1. b|\n2. c");
    expect(undoable(outdentListItem, "1. a\n   1. b|\n2. c")).toBe("1. a\n2. b|\n3. c");
  });
});

describe("move line / list item (⌥⌘↑ / ⌥⌘↓)", () => {
  test.each([
    ["a\nb|", moveListBlockUp, "b|\na"],
    ["a|\nb", moveListBlockDown, "b\na|"],
    ["- a\n- b|\n  - b1", moveListBlockUp, "- b|\n  - b1\n- a"],
    ["- a|\n  - a1\n- b", moveListBlockDown, "- b\n- a|\n  - a1"],
    ["- a\n  - a1\n- b|", moveListBlockUp, "- b|\n- a\n  - a1"],
    ["1. a\n2. b|", moveListBlockUp, "1. b|\n2. a"],
    ["3. a|\n4. b\n5. c", moveListBlockDown, "3. b\n4. a|\n5. c"],
    ["‹x\ny›\nz", moveListBlockDown, "z\n‹x\ny›"],
    ["- a\n\n- b|", moveListBlockUp, "- a\n- b|\n"],
  ])("%j", (before, cmd, after) => {
    expect(run(cmd, before)).toBe(after);
  });

  test("at the document edge: consumed, unchanged", () => {
    expect(apply(moveListBlockUp, "a|\nb").tr!.docChanged).toBe(false);
    expect(apply(moveListBlockDown, "a\nb|").tr!.docChanged).toBe(false);
  });

  test("one undo step", () => {
    expect(undoable(moveListBlockUp, "1. a\n2. b|")).toBe("1. b|\n2. a");
  });
});

describe("renumbering after pastes and deletions inside an ordered list", () => {
  const ext = [lists];
  const update = (spec: string, change: { from: number; to?: number; insert?: string }, userEvent: string) =>
    make(spec, ext).update({ changes: change, userEvent }).state.doc.toString();

  test("deleting a whole item renumbers the rest, in the same transaction", () => {
    const doc = "1. a\n2. b\n3. c\n4. d";
    const from = doc.indexOf("2. b");
    expect(update(doc, { from, to: from + 5 }, "delete.selection")).toBe("1. a\n2. c\n3. d");
    const state = make(doc, [...ext, history()]).update({ changes: { from, to: from + 5 }, userEvent: "delete.cut" }).state;
    expect(undoDepth(state)).toBe(1);
  });

  test("pasting items renumbers the pasted and the following items", () => {
    const doc = "1. a\n2. b";
    expect(update(doc, { from: doc.indexOf("2. b"), insert: "1. x\n1. y\n" }, "input.paste")).toBe("1. a\n2. x\n3. y\n4. b");
  });

  test("typing and single-line edits never renumber", () => {
    expect(update("1. a\n5. b", { from: 4, insert: "x" }, "input.type")).toBe("1. ax\n5. b");
    expect(update("1. a\n12. b", { from: 6, to: 7 }, "delete.backward")).toBe("1. a\n1. b");
  });

  test("not inside code, not across other blocks, not dates", () => {
    const code = "```\n1. a\n2. b\n5. c\n```";
    const at = code.indexOf("5.");
    expect(update(code, { from: code.indexOf("2. b"), to: at }, "delete.selection")).toBe("```\n1. a\n5. c\n```");
    expect(update("1. a\n2. b\n\npara\n\n7. c", { from: 5, to: 10 }, "delete.selection")).toBe("1. a\n\npara\n\n7. c");
    expect(update("1. a\n2. b\n12. March\n13. x", { from: 5, to: 10 }, "delete.selection")).toBe("1. a\n12. March\n13. x");
  });
});

describe("listLayout (presentation and caret steering)", () => {
  const layout = (doc: string, lineNo: number) => {
    const state = make(doc);
    return listLayout(state, state.doc.line(lineNo));
  };

  test("item lines: kind, level, indentation, content start", () => {
    expect(layout("- a", 1)).toMatchObject({ first: true, kind: "bullet", level: 1, indentFrom: 0, textFrom: 0, contentFrom: 2 });
    expect(layout("- a\n  - b", 2)).toMatchObject({ kind: "bullet", level: 2, indentFrom: 4, textFrom: 6, contentFrom: 8 });
    expect(layout("1. a\n   - [ ] b", 2)).toMatchObject({ kind: "todo", level: 2, textFrom: 8, contentFrom: 14 });
    expect(layout("> 1. a", 1)).toMatchObject({ kind: "ordered", indentFrom: 2, textFrom: 2, markerTo: 4, contentFrom: 5 });
  });

  test("continuation lines inside an item", () => {
    expect(layout("- a\n  b", 2)).toMatchObject({ first: false, kind: "bullet", level: 1, indentFrom: 4, textFrom: 6 });
    expect(layout("- a\nb", 2)).toBeNull();
  });

  test("not list lines: bare markers, dates, code, plain text", () => {
    expect(layout("1.", 1)).toBeNull();
    expect(layout("12. March", 1)).toBeNull();
    expect(layout("```\n- a\n```", 2)).toBeNull();
    expect(layout("- a\n\n  ```\n  x\n  ```", 4)).toBeNull();
    expect(layout("text", 1)).toBeNull();
  });

  test("a caret placed in the hidden indentation moves to the marker", () => {
    const state = make("- a\n    - b|", [lists]);
    const line = state.doc.line(2);
    for (const pos of [line.from, line.from + 2]) {
      expect(state.update({ selection: { anchor: pos } }).state.selection.main.head).toBe(line.from + 4);
    }
    // Range selections and other lines are left alone.
    expect(state.update({ selection: { anchor: 0, head: line.from + 1 } }).state.selection.main.head).toBe(line.from + 1);
    expect(state.update({ selection: { anchor: 1 } }).state.selection.main.head).toBe(1);
  });

  test("a click on the indentation or the marker puts the caret at the item text", () => {
    const state = make("- a\n    - [ ] b\n- c|", [lists]);
    const click = (pos: number) => state.update({ selection: { anchor: pos }, userEvent: "select.pointer" }).state.selection.main.head;
    const todo = state.doc.line(2);
    for (const pos of [todo.from, todo.from + 3, todo.from + 4, todo.from + 5]) expect(click(pos)).toBe(todo.from + 10);
    const top = state.doc.line(3);
    expect(click(top.from)).toBe(top.from + 2);
    expect(click(top.from + 3)).toBe(top.from + 3);
  });
});

describe("auto-wrap a selection", () => {
  const wrap = (spec: string, ch: string) => {
    const state = make(spec);
    const out = wrapSelectionSpec(state, ch);
    return out && show(state.update(out).state);
  };

  test.each([
    ['"', '"‹word›"'],
    ["'", "'‹word›'"],
    ["(", "(‹word›)"],
    ["[", "[‹word›]"],
    ["{", "{‹word›}"],
    ["*", "*‹word›*"],
    ["_", "_‹word›_"],
    ["~", "~‹word›~"],
    ["=", "=‹word›="],
    ["`", "`‹word›`"],
  ])("%s wraps the selection", (ch, expected) => {
    expect(wrap("‹word›", ch)).toBe(expected);
  });

  test("twice makes a double mark; a backwards selection stays backwards", () => {
    const state = make("‹word›");
    const once = state.update(wrapSelectionSpec(state, "*")!).state;
    expect(show(once.update(wrapSelectionSpec(once, "*")!).state)).toBe("**‹word›**");
    expect(wrap("›word‹", "(")).toBe("(›word‹)");
  });

  test("no wrap: empty selection, other characters, code", () => {
    expect(wrap("wo|rd", "(")).toBeNull();
    expect(wrap("‹word›", "a")).toBeNull();
    expect(wrap("`co‹d›e`", "*")).toBeNull();
    expect(wrap("```\n‹code›\n```", "(")).toBeNull();
    // A selection around a whole code span may be wrapped.
    expect(wrap("‹`code`›", "*")).toBe("*‹`code`›*");
  });

  test("one undo step", () => {
    let state = make("‹word›", [history()]);
    state = state.update(wrapSelectionSpec(state, "(")!).state;
    expect(undoDepth(state)).toBe(1);
    undo({ state, dispatch: (t) => (state = t.state) });
    expect(show(state)).toBe("‹word›");
  });
});

describe("arrows", () => {
  const arrow = (spec: string, ch: string) => {
    const state = make(spec);
    return arrowConversion(state, state.selection.main.head, ch);
  };

  test("-> and <- become → and ← when the second character is typed", () => {
    expect(arrow("a -|", ">")).toEqual({ from: 2, to: 3, insert: "→" });
    expect(arrow("<|", "-")).toEqual({ from: 0, to: 1, insert: "←" });
  });

  test("not in bare URLs or link targets", () => {
    expect(arrow("see https://example.com/a-|", ">")).toBeNull();
    expect(arrow("www.a-|", ">")).toBeNull();
    expect(arrow("[t](https://a-|", ">")).toBeNull();
    expect(arrow("[t](a-|", ">")).toBeNull();
    expect(arrow("[t](u) a-|", ">")).toEqual({ from: 8, to: 9, insert: "→" });
  });

  test("not in code, not in comments, not for -->", () => {
    expect(arrow("`a -|`", ">")).toBeNull();
    expect(arrow("`a -|", ">")).toBeNull();
    expect(arrow("```\na -|\n```", ">")).toBeNull();
    expect(arrow("<!-- a --|", ">")).toBeNull();
    expect(arrow("a|", ">")).toBeNull();
    expect(arrow("a -|", "-")).toBeNull();
  });
});

describe("Home on a list line", () => {
  test("goes to the item text first, then to the marker", () => {
    const state = make("- a\n  - [ ] todo\n\n12. n\n\ntext");
    const at = (needle: string, delta = 0) => state.doc.toString().indexOf(needle) + delta;
    expect(listLineStart(state, at("todo", 2))).toBe(at("todo"));
    expect(listLineStart(state, at("todo"))).toBe(at("- [ ]"));
    expect(listLineStart(state, at("- [ ]", 1))).toBe(at("- [ ]"));
    expect(listLineStart(state, at("- [ ]"))).toBeNull();
    expect(listLineStart(state, at(" n", 2))).toBe(at(" n", 1));
    expect(listLineStart(state, at("text", 2))).toBeNull();
  });
});

describe("perf: large lists", () => {
  const big = (n: number) => Array.from({ length: n }, (_, i) => `${i + 1}. item ${i}`).join("\n");
  const time = (cmd: StateCommand, state: EditorState) => {
    let tr: Transaction | null = null;
    const start = performance.now();
    cmd({ state, dispatch: (t) => (tr = t) });
    return { ms: performance.now() - start, tr: tr as Transaction | null };
  };

  // Budgets with headroom: these ran ~20-60 ms alone but flaked at 200 ms under parallel load.
  test("select-all + Tab / Shift-Tab on a 2000-item ordered list stays under 600 ms", () => {
    const doc = big(2000);
    const state = make(`‹${doc}›`);
    const tab = time(indentListItem, state);
    expect(tab.ms).toBeLessThan(600);
    const lines = tab.tr!.state.doc.toString().split("\n");
    expect(lines[1]).toBe("   1. item 1");
    expect(lines[1999]).toBe("   1999. item 1999");
    const back = time(outdentListItem, tab.tr!.state);
    console.log(`perf: 2000 items select-all Tab ${tab.ms.toFixed(1)} ms, Shift-Tab ${back.ms.toFixed(1)} ms`);
    expect(back.ms).toBeLessThan(600);
    const backLines = back.tr!.state.doc.toString().split("\n");
    const firstDiff = backLines.findIndex((l, i) => l !== doc.split("\n")[i]);
    expect([firstDiff, backLines[firstDiff]]).toEqual([-1, undefined]);
  });

  test("Enter at the top of a 2000-item ordered list renumbers it quickly", () => {
    const enter = time(insertNewlineContinueList, make(`1. item 0|\n${big(2000).split("\n").slice(1).join("\n")}`));
    console.log(`perf: 2000 items Enter ${enter.ms.toFixed(1)} ms`);
    expect(enter.ms).toBeLessThan(600);
    expect(enter.tr!.state.doc.line(2001).text).toBe("2001. item 1999");
  });
});
