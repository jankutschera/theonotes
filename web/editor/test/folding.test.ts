// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, StateEffect, type Extension, Transaction } from "@codemirror/state";
import { ensureSyntaxTree, foldedRanges, foldEffect } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import {
  deleteCharBackward,
  deleteCharForward,
  deleteGroupBackward,
  deleteGroupForward,
  history,
  undoDepth,
} from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import { runCommand } from "../src/editor/features/commands";
import {
  applyFoldEntries,
  chevronMarkers,
  foldEntries,
  foldRangeAt,
  folding,
  isFolded,
  lineHash,
  revealEffects,
  enterAfterFold,
} from "../src/editor/features/folding";
import { menuTargetEffect, menuTargets } from "../src/editor/features/menu-targets";
import { MAX_FOLDS } from "../src/bridge/protocol";

const hashFixture = Object.values(
  import.meta.glob("../../../Fixtures/folds/line-hash.json", { eager: true, import: "default" }),
)[0] as { cases: { text: string; hash: string }[] };

/** `‸` marks the caret (default: the end). */
function stateOf(marked: string, extensions: Extension[] = []): EditorState {
  const at = marked.indexOf("‸");
  const doc = marked.replace("‸", "");
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(at < 0 ? doc.length : at),
    extensions: [markdown({ base: bearMarkdown }), history(), menuTargets, folding, ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

/** The range line `n` folds, as 1-based [first, last] lines. */
function lines(state: EditorState, n: number): [number, number] | null {
  const range = foldRangeAt(state, n);
  if (!range) return null;
  expect(range.from).toBe(state.doc.line(n).to);
  return [n, state.doc.lineAt(range.to).number];
}

/** The folded lines (where each fold starts). */
function folded(state: EditorState): number[] {
  const out: number[] = [];
  foldedRanges(state).between(0, state.doc.length, (from) => {
    out.push(state.doc.lineAt(from).number);
  });
  return out.sort((a, b) => a - b);
}

/** Runs a registry command; returns the new state and every transaction it dispatched. */
function run(state: EditorState, name: "toggleFold" | "foldAll" | "unfoldAll" | "selectAll", args?: Record<string, unknown>) {
  const trs: Transaction[] = [];
  const handled = runCommand({ state, dispatch: (tr) => trs.push(tr) }, name, args);
  return { handled, state: trs.at(-1)?.state ?? state, trs };
}

const caretLine = (state: EditorState) => state.doc.lineAt(state.selection.main.head).number;

describe("what folds", () => {
  test("heading section ends before the next same-or-higher heading", () => {
    const state = stateOf("# A\ntext\n## B\nmore\n### C\ndeep\n## D\nx\n# E\nend\nlast");
    expect(lines(state, 1)).toEqual([1, 8]);
    expect(lines(state, 3)).toEqual([3, 6]);
    expect(lines(state, 5)).toEqual([5, 6]);
    expect(lines(state, 7)).toEqual([7, 8]);
    // The last heading folds to the end of the note.
    expect(lines(state, 9)).toEqual([9, 11]);
    // Body lines do not fold.
    expect(lines(state, 2)).toBeNull();
    // Up to 3 spaces before the marks are still a heading.
    expect(lines(stateOf("   ## Indented\nbody"), 1)).toEqual([1, 2]);
  });

  test("trailing blank lines stay visible", () => {
    const state = stateOf("# A\ntext\n\n  \n# B\nmore\n\n\n");
    expect(lines(state, 1)).toEqual([1, 2]);
    expect(lines(state, 5)).toEqual([5, 6]);
    // A heading with only blank lines (or nothing) below has nothing to fold.
    expect(lines(stateOf("# A\n\n\n# B"), 1)).toBeNull();
    expect(lines(stateOf("# A"), 1)).toBeNull();
  });

  test("a heading inside a quote does not fold", () => {
    expect(lines(stateOf("> # Quoted\n> text\nafter"), 1)).toBeNull();
    // Nor does it end a section, nor does a heading after a list marker.
    const state = stateOf("# A\n> # Quoted\n- # Item heading\ntext");
    expect(lines(state, 1)).toEqual([1, 4]);
    expect(lines(state, 3)).toBeNull();
    // Empty headings and tags are not headings NoteParser indexes.
    expect(lines(stateOf("#\ntext"), 1)).toBeNull();
    expect(lines(stateOf("#tag\ntext"), 1)).toBeNull();
  });

  test("a list item folds only with a nested list (todos too)", () => {
    const state = stateOf("- a\n  - b\n    - c\n  - d\n- e\n\n  continued");
    expect(lines(state, 1)).toEqual([1, 4]);
    expect(lines(state, 2)).toEqual([2, 3]);
    expect(lines(state, 3)).toBeNull();
    expect(lines(state, 4)).toBeNull();
    // A continuation paragraph is no nested list.
    expect(lines(state, 5)).toBeNull();
    expect(lines(stateOf("- [ ] task\n    - [x] sub\n- [ ] other"), 1)).toEqual([1, 2]);
    expect(lines(stateOf("1. one\n   1. sub\n2. two"), 1)).toEqual([1, 2]);
    // Trailing blank lines of the nested list stay visible.
    expect(lines(stateOf("- a\n  - b\n\n- c"), 1)).toEqual([1, 2]);
  });

  test("code blocks, quotes and tables do not fold", () => {
    for (const doc of ["```\n# not a heading\nx\n```", "> a\n> b\n> c", "| a | b |\n|---|---|\n| 1 | 2 |", "para\nmore\nlines"]) {
      const state = stateOf(doc);
      for (let n = 1; n <= state.doc.lines; n++) expect(lines(state, n), `${JSON.stringify(doc)} line ${n}`).toBeNull();
    }
    // A code block in a section does not end it.
    expect(lines(stateOf("# A\n```\n# x\n```\ntext"), 1)).toEqual([1, 5]);
    expect(foldRangeAt(stateOf("# A\nx"), 0)).toBeNull();
    expect(foldRangeAt(stateOf("# A\nx"), 3)).toBeNull();
  });
});

describe("commands", () => {
  test("toggleFold at the caret and at a menuId line", () => {
    const start = stateOf("# A‸\ntext\n# B\nmore");
    const once = run(start, "toggleFold");
    expect(once.handled).toBe(true);
    expect(folded(once.state)).toEqual([1]);
    expect(isFolded(once.state, 1)).toBe(true);
    const twice = run(once.state, "toggleFold");
    expect(folded(twice.state)).toEqual([]);
    // A caret right after the ⋯ (the fold's end, on the last folded line) is on the folded row.
    const afterPlaceholder = once.state.update({ selection: { anchor: once.state.doc.line(2).to } }).state;
    expect(folded(afterPlaceholder)).toEqual([1]);
    expect(folded(run(afterPlaceholder, "toggleFold").state)).toEqual([]);

    // A heading menu targets its line, wherever the caret is.
    const targeted = start.update({ effects: menuTargetEffect.of({ id: "m1", pos: start.doc.line(3).from }) }).state;
    const byMenu = run(targeted, "toggleFold", { menuId: "m1" });
    expect(folded(byMenu.state)).toEqual([3]);
    expect(folded(run(byMenu.state, "toggleFold", { menuId: "m1" }).state)).toEqual([]);
    // A dead menu target does nothing (never the caret line instead).
    expect(run(targeted, "toggleFold", { menuId: "gone" }).handled).toBe(false);
    // A target line that cannot fold does nothing either.
    const onBody = start.update({ effects: menuTargetEffect.of({ id: "m2", pos: start.doc.line(2).from }) }).state;
    expect(run(onBody, "toggleFold", { menuId: "m2" }).handled).toBe(false);
  });

  test("⌘' on a body line folds the enclosing section", () => {
    const section = run(stateOf("# A\nte‸xt\nmore\n# B\nx"), "toggleFold");
    expect(folded(section.state)).toEqual([1]);
    // The caret moves to the end of the folded line, so it stays visible.
    expect(section.state.selection.main.head).toBe(section.state.doc.line(1).to);
    // The parent list item comes before the section heading.
    const item = run(stateOf("# A\n- a\n  - b‸\n- c"), "toggleFold");
    expect(folded(item.state)).toEqual([2]);
    expect(caretLine(item.state)).toBe(2);
    // A caret below every fold range does nothing.
    expect(run(stateOf("intro‸\n# A\nx"), "toggleFold").handled).toBe(false);
    // A line in a quote inside a section folds the section.
    expect(folded(run(stateOf("## A\n> quo‸ted\nx"), "toggleFold").state)).toEqual([1]);
  });

  test("foldAll/unfoldAll", () => {
    const start = stateOf("‸# A\nx\n## B\ny\n# C\nz\n- a\n  - b\n# Empty");
    const all = run(start, "foldAll");
    expect(all.handled).toBe(true);
    expect(folded(all.state)).toEqual([1, 3, 5]);
    // Nested folds come back folded when their parent opens.
    const parentOpen = run(all.state, "toggleFold");
    expect(folded(parentOpen.state)).toEqual([3, 5]);
    // Unfold All opens every heading; a folded list item stays folded.
    const listFolded = run(start.update({ selection: { anchor: start.doc.line(7).from } }).state, "toggleFold").state;
    expect(folded(listFolded)).toEqual([7]);
    const both = run(listFolded, "foldAll").state;
    expect(folded(both)).toEqual([1, 3, 5, 7]);
    const none = run(both, "unfoldAll");
    expect(none.handled).toBe(true);
    expect(folded(none.state)).toEqual([7]);
    expect(run(none.state, "unfoldAll").handled).toBe(false);
    // Folding a section with the caret inside moves the caret to the folded line.
    const inside = run(stateOf("# A\nx‸\n# B\ny"), "foldAll").state;
    expect(inside.selection.main.head).toBe(inside.doc.line(1).to);
  });

  test("folding works in read-only and never changes the document", () => {
    const doc = "# A\ntext‸\n- a\n  - b\n# B\nx";
    const start = stateOf(doc, [EditorState.readOnly.of(true)]);
    for (const step of [
      run(start, "toggleFold"),
      run(start, "foldAll"),
      run(run(start, "foldAll").state, "unfoldAll"),
    ]) {
      expect(step.handled).toBe(true);
      for (const tr of step.trs) expect(tr.docChanged).toBe(false);
      expect(step.state.doc.toString()).toBe(doc.replace("‸", ""));
    }
    expect(folded(run(start, "toggleFold").state)).toEqual([1]);
    // No undo step either.
    const editable = stateOf(doc);
    expect(undoDepth(run(run(editable, "foldAll").state, "toggleFold").state)).toBe(0);
  });

  test("a selection moved into a fold unfolds it", () => {
    const start = run(stateOf("‸# A\ntext\n# B\nmore\n# C\nend"), "foldAll").state;
    expect(folded(start)).toEqual([1, 3, 5]);
    // A caret at the end of the folded line (before the placeholder) keeps the fold.
    expect(folded(start.update({ selection: { anchor: start.doc.line(1).to } }).state)).toEqual([1, 3, 5]);
    // A caret inside (find, ToC, a bridge selectRange) opens that fold only.
    const caret = start.update({ selection: { anchor: start.doc.line(4).from + 2 } }).state;
    expect(folded(caret)).toEqual([1, 5]);
    // A selection endpoint inside a fold opens it.
    const reach = start.update({ selection: { anchor: 0, head: start.doc.line(2).from + 1 } }).state;
    expect(folded(reach)).toEqual([3, 5]);
    // A pointer drag or Shift-selection across folds keeps them closed (endpoints outside).
    const across = start.update({ selection: { anchor: 0, head: start.doc.line(5).to }, userEvent: "select.pointer" }).state;
    expect(folded(across)).toEqual([1, 3, 5]);
    expect(folded(start.update({ selection: { anchor: 0, head: start.doc.length }, userEvent: "select" }).state)).toEqual([1, 3, 5]);
    // Find opens every fold its match reaches; ⌘A opens them all.
    const found = start.update({ selection: { anchor: 0, head: start.doc.line(3).to }, userEvent: "select.search" }).state;
    expect(folded(found)).toEqual([3, 5]);
    expect(folded(run(start, "selectAll").state)).toEqual([]);
    // Secondary ranges count too.
    const multi = start.update({
      selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(start.doc.line(6).from + 1)]),
    }).state;
    expect(folded(multi)).toEqual([1, 3]);
    // Through a document change in the same transaction.
    const typed = start.update({ changes: { from: 0, insert: "x" }, selection: { anchor: start.doc.line(2).from + 2 } }).state;
    expect(folded(typed)).toEqual([3, 5]);
    // Scroll targets (the note-list search highlight) unfold with revealEffects.
    const match = { from: start.doc.line(6).from, to: start.doc.line(6).to };
    expect(folded(start.update({ effects: revealEffects(start, match.from, match.to) }).state)).toEqual([1, 3]);
  });

  test("the fold gutter marks folded lines and the hovered foldable line in the visible ranges", () => {
    const state = run(stateOf("‸# A\ntext\n# B\nmore\nplain"), "toggleFold").state;
    const all = [{ from: 0, to: state.doc.length }];
    const marked = (hover: number | null, visible = all) => {
      const out: { line: number; folded: boolean; level: number }[] = [];
      chevronMarkers(state, visible, hover).between(0, state.doc.length, (from, _to, m) => {
        out.push({ line: state.doc.lineAt(from).number, folded: m.folded, level: m.level });
      });
      return out;
    };
    expect(marked(null)).toEqual([{ line: 1, folded: true, level: 1 }]);
    expect(marked(3)).toEqual([{ line: 1, folded: true, level: 1 }, { line: 3, folded: false, level: 1 }]);
    // A hovered line that cannot fold gets no chevron; nor does one outside the visible ranges.
    expect(marked(5)).toEqual([{ line: 1, folded: true, level: 1 }]);
    expect(marked(3, [{ from: 0, to: state.doc.line(1).to }])).toEqual([{ line: 1, folded: true, level: 1 }]);
  });
});

describe("editing on a folded row (M6-R28)", () => {
  // The reviewer's note: text typed after the ⋯ landed on the hidden closing fence.
  const fenced = "# Plan\nintro\n```\ncode\n```\n\n# Notes\nend";
  const foldedPlan = () => run(stateOf("‸" + fenced), "toggleFold").state;

  test("typing, paste and drop at a fold's end go before the ⋯, never into hidden text", () => {
    for (const userEvent of ["input.type", "input.paste", "input.drop"]) {
      const plan = foldedPlan();
      const end = foldRangeAt(plan, 1)!.to;
      expect(plan.doc.lineAt(end).text).toBe("```");
      // The caret right after the ⋯ (⌘→ or a click there puts it at the fold's end).
      const state = plan.update({ selection: { anchor: end } }).state;
      expect(folded(state)).toEqual([1]);
      const next = state.update({ changes: { from: end, insert: "X" }, selection: { anchor: end + 1 }, userEvent }).state;
      expect(next.doc.toString(), userEvent).toBe(fenced.replace("# Plan", "# PlanX"));
      expect(folded(next)).toEqual([1]);
      expect(next.selection.main.head).toBe("# PlanX".length);
    }
    // Input elsewhere, and other edits, are untouched.
    const state = foldedPlan();
    const typed = state.update({ changes: { from: state.doc.length, insert: "!" }, userEvent: "input.type" }).state;
    expect(typed.doc.toString()).toBe(fenced + "!");
    const end = foldRangeAt(state, 1)!.to;
    expect(state.update({ changes: { from: end, insert: "X" }, userEvent: "input" }).state.doc.toString()).not.toBe(
      fenced.replace("# Plan", "# PlanX"),
    );
  });

  test("a caret never rests at a fold's end: it goes to the fold's start (fix round 2)", () => {
    const state = foldedPlan();
    const { from, to } = foldRangeAt(state, 1)!;
    // A click right of the ⋯, ⌘→/End/⌃E, ArrowUp/Down, a host selection: all land before the ⋯.
    for (const userEvent of ["select.pointer", "select", undefined]) {
      const next = state.update({ selection: { anchor: to }, ...(userEvent && { userEvent }) }).state;
      expect(next.selection.main.head, String(userEvent)).toBe(from);
      expect(folded(next)).toEqual([1]);
    }
    // Shift-extended ranges may span or end at the fold.
    const extended = state.update({ selection: { anchor: 0, head: to } }).state;
    expect([extended.selection.main.anchor, extended.selection.main.head]).toEqual([0, to]);
    // Secondary carets too; a caret elsewhere is left alone.
    const multiState = state.update({ effects: StateEffect.appendConfig.of(EditorState.allowMultipleSelections.of(true)) }).state;
    const multi = multiState.update({ selection: EditorSelection.create([EditorSelection.cursor(to), EditorSelection.cursor(state.doc.length)]) }).state;
    expect(multi.selection.ranges.map((r) => r.head)).toEqual([from, state.doc.length]);
    // An edit that leaves the caret there (Backspace at the next line's start) too.
    const deleted = state.update({ changes: { from: to + 1, to: to + 2 }, selection: { anchor: to }, userEvent: "delete" }).state;
    expect(deleted.selection.main.head).toBe(from);
    // A running composition is never moved.
    const composing = state.update({ selection: { anchor: to }, userEvent: "input.type.compose" }).state;
    expect(composing.selection.main.head).toBe(to);
  });

  test("Enter at either edge of a folded heading adds the line after the fold; the fold stays", () => {
    const start = run(stateOf("‸# A\ntext\nmore\n# B"), "toggleFold").state;
    const range = foldRangeAt(start, 1)!;
    for (const edge of [range.from, range.to]) {
      const at = start.update({ selection: { anchor: edge } }).state;
      expect(folded(at)).toEqual([1]);
      const next = enterAfterFold(at)!.state;
      expect(next.doc.toString()).toBe("# A\ntext\nmore\n\n# B");
      expect(caretLine(next)).toBe(4);
      expect(folded(next)).toEqual([1]);
      expect(foldEntries(next)).toEqual([{ line: 1, hash: lineHash("# A") }]);
    }
    // Not on a folded row: the normal Enter.
    expect(enterAfterFold(stateOf("# A‸\ntext"))).toBeNull();
  });

  test("Enter on a folded todo with subtasks continues the list after its block", () => {
    const doc = "- [ ] Project\n    - [ ] sub1\n    - [ ] sub2\n- [ ] Other";
    const start = run(stateOf("- [ ] Project‸" + doc.slice("- [ ] Project".length)), "toggleFold").state;
    expect(folded(start)).toEqual([1]);
    const next = enterAfterFold(start)!.state;
    expect(next.doc.toString()).toBe("- [ ] Project\n    - [ ] sub1\n    - [ ] sub2\n- [ ] \n- [ ] Other");
    expect(next.selection.main.head).toBe(next.doc.line(4).to);
    expect(folded(next)).toEqual([1]);
    // Ordered items renumber after the new one.
    const ordered = run(stateOf("1. a‸\n   1. x\n2. b"), "toggleFold").state;
    expect(enterAfterFold(ordered)!.state.doc.toString()).toBe("1. a\n   1. x\n2. \n3. b");
    // Read-only notes refuse.
    expect(enterAfterFold(run(stateOf("‸# A\nx", [EditorState.readOnly.of(true)]), "toggleFold").state)).toBeNull();
  });

  test("Delete before the ⋯ and Backspace after the fold unfold it instead of editing hidden text (M6-R76)", () => {
    const doc = "# A\ntext\n# B";
    // The char and group deletions only read `state` and `dispatch` of their view.
    const apply = (state: EditorState, command: typeof deleteCharForward) => {
      let next = state;
      command({ state, dispatch: (tr: Transaction) => (next = tr.state) } as unknown as Parameters<typeof deleteCharForward>[0]);
      return next;
    };
    const start = run(stateOf("‸" + doc), "toggleFold").state;
    const { from, to } = foldRangeAt(start, 1)!;
    expect(folded(start)).toEqual([1]);
    const cases: [number, typeof deleteCharForward][] = [
      [from, deleteCharForward],
      [from, deleteGroupForward],
      [to + 1, deleteCharBackward],
      [to + 1, deleteGroupBackward],
    ];
    for (const [at, command] of cases) {
      const state = start.update({ selection: { anchor: at } }).state;
      const next = apply(state, command);
      expect(next.doc.toString(), command.name).toBe(doc);
      expect(folded(next), command.name).toEqual([]);
      expect(next.selection.main.head, command.name).toBe(at);
      // The next press edits the now visible text as usual.
      expect(apply(next, command).doc.toString(), command.name).not.toBe(doc);
    }
    // ⇧⌘K on the folded heading line unfolds too.
    const line = start.update({ changes: { from: 0, to: from + 1 }, userEvent: "delete.line" }).state;
    expect([line.doc.toString(), folded(line)]).toEqual([doc, []]);
    // Deleting a selection that covers the whole fold deletes it (the user selected it).
    const all = start.update({ selection: { anchor: 0, head: to } }).state;
    expect(apply(all, deleteCharBackward).doc.toString()).toBe("\n# B");
    // Backspace before the ⋯ edits the visible heading; the fold stays.
    const visible = apply(start.update({ selection: { anchor: from } }).state, deleteCharBackward);
    expect(visible.doc.toString()).toBe("# \ntext\n# B");
    expect(folded(visible)).toEqual([1]);
  });

  test("⌘' on a trailing blank line inside a section toggles that section", () => {
    expect(folded(run(stateOf("# A\nx\n‸\n# B\ny"), "toggleFold").state)).toEqual([1]);
    expect(folded(run(stateOf("# A\n## S\nx\n‸\n# B"), "toggleFold").state)).toEqual([2]);
  });
});

describe("persisted folds", () => {
  test("lineHash is FNV-1a 32-bit over UTF-8, 8 hex characters", () => {
    expect(lineHash("")).toBe("811c9dc5");
    expect(lineHash("a")).toBe("e40c292c");
    expect(lineHash("foobar")).toBe("bf9cf968");
    expect(lineHash("# Ä")).toMatch(/^[0-9a-f]{8}$/);
    expect(lineHash("# Ä")).not.toBe(lineHash("# A"));
  });

  test("lineHash matches the shared fixture Fixtures/folds/line-hash.json (Swift parity, Task 8)", () => {
    expect(hashFixture.cases.length).toBeGreaterThan(5);
    expect(hashFixture.cases.some((c) => /[^\x00-\x7f]/.test(c.text))).toBe(true);
    expect(hashFixture.cases.some((c) => /\p{Extended_Pictographic}/u.test(c.text))).toBe(true);
    for (const { text, hash } of hashFixture.cases) expect(lineHash(text), JSON.stringify(text)).toBe(hash);
  });

  test("a stored fold moves at most 50 lines; on a tie the earlier line wins", () => {
    const section = "# H\nbody";
    const entry = { line: 1, hash: lineHash("# H") };
    const shifted = (n: number) => stateOf("‸" + "x\n".repeat(n) + section);
    expect(folded(shifted(50).update(applyFoldEntries(shifted(50), [entry])!).state)).toEqual([51]);
    expect(applyFoldEntries(shifted(51), [entry])).toBeNull();
    // Two candidates as far from line 5: line 3 (above) wins over line 7 (below).
    const tie = stateOf("‸a\nb\n# H\nx\nc\nd\n# H\ny");
    expect(folded(tie.update(applyFoldEntries(tie, [{ line: 5, hash: lineHash("# H") }])!).state)).toEqual([3]);
  });

  test("foldEntries/applyFoldEntries round-trip", () => {
    const doc = "# A\ntext\n- a\n  - b\n# B\nmore";
    const start = stateOf(doc);
    const withFolds = run(run(start.update({ selection: { anchor: start.doc.line(3).from } }).state, "toggleFold").state, "foldAll").state;
    expect(folded(withFolds)).toEqual([1, 3, 5]);
    const entries = foldEntries(withFolds);
    expect(entries).toEqual([
      { line: 1, hash: lineHash("# A") },
      { line: 3, hash: lineHash("- a") },
      { line: 5, hash: lineHash("# B") },
    ]);

    const fresh = stateOf("‸" + doc);
    const spec = applyFoldEntries(fresh, entries);
    expect(spec).not.toBeNull();
    const restored = fresh.update(spec!);
    expect(restored.docChanged).toBe(false);
    expect(folded(restored.state)).toEqual([1, 3, 5]);
    expect(foldEntries(restored.state)).toEqual(entries);

    // A changed line drops its entry; lines inserted above move it (within 50 lines).
    expect(applyFoldEntries(fresh, [{ line: 1, hash: lineHash("# Renamed") }])).toBeNull();
    const moved = stateOf("‸new\nlines\n\n" + doc);
    expect(folded(moved.update(applyFoldEntries(moved, entries)!).state)).toEqual([4, 6, 8]);
    // A fold that would hide the restored caret is dropped.
    const caretInside = stateOf("# A\nte‸xt\n# B\nmore");
    expect(folded(caretInside.update(applyFoldEntries(caretInside, foldEntries(run(caretInside, "foldAll").state))!).state)).toEqual([3]);
  });

  // Review Focus 5.
  test("folds follow their heading after lines are inserted above", () => {
    const doc = "# A\ntext\n# B\nmore\n# C\nend";
    const start = stateOf(doc);
    const entries = foldEntries(start.update({ effects: [foldEffect.of(foldRangeAt(start, 3)!)] }).state);
    expect(entries).toEqual([{ line: 3, hash: lineHash("# B") }]);
    const moved = stateOf("‸one\ntwo\nthree\n" + doc);
    const restored = moved.update(applyFoldEntries(moved, entries)!).state;
    expect(folded(restored)).toEqual([6]);
    expect(restored.doc.line(6).text).toBe("# B");
  });

  test("a renamed heading drops its fold", () => {
    const entries = [{ line: 1, hash: lineHash("# A") }, { line: 3, hash: lineHash("# B") }];
    const renamed = stateOf("‸# A\ntext\n# B renamed\nmore");
    expect(folded(renamed.update(applyFoldEntries(renamed, entries)!).state)).toEqual([1]);
    const allRenamed = stateOf("‸# A2\ntext\n# B2\nmore");
    expect(applyFoldEntries(allRenamed, entries)).toBeNull();
  });

  test("an external change maps open folds", () => {
    const start = stateOf("‸# A\ntext\n# B\nmore");
    const withFold = start.update({ effects: [foldEffect.of(foldRangeAt(start, 3)!)] }).state;
    // The host's change (applyExternalChange): two lines inserted at the top, none in the fold.
    const changed = withFold.update({ changes: { from: 0, insert: "x\ny\n" }, annotations: Transaction.remote.of(true) }).state;
    expect(folded(changed)).toEqual([5]);
    expect(foldEntries(changed)).toEqual([{ line: 5, hash: lineHash("# B") }]);
  });

  test("at most MAX_FOLDS entries", () => {
    const doc = Array.from({ length: MAX_FOLDS + 5 }, (_, i) => `- ${i}\n  - x`).join("\n");
    const state = stateOf("‸" + doc);
    const entries = Array.from({ length: MAX_FOLDS + 5 }, (_, i) => ({ line: 2 * i + 1, hash: lineHash(`- ${i}`) }));
    const restored = state.update(applyFoldEntries(state, entries)!).state;
    expect(folded(restored)).toHaveLength(MAX_FOLDS);
    // More folds than that (folded one by one) still post at most MAX_FOLDS entries.
    const effects = [];
    for (let n = 1; n <= state.doc.lines; n += 2) effects.push(foldEffect.of(foldRangeAt(state, n)!));
    const every = state.update({ effects }).state;
    expect(folded(every)).toHaveLength(MAX_FOLDS + 5);
    expect(foldEntries(every)).toEqual(entries.slice(0, MAX_FOLDS));
  });
});
