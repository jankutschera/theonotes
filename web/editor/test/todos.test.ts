// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction, type TransactionSpec } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, redo, undo } from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import {
  autoSortTodos,
  insertTodo,
  moveCheckedToBottom,
  TodoCheckbox,
  todoDecorations,
  TodoDecorationsState,
  todoLineStart,
  toggleTodo,
  toggleTodoAt,
} from "../src/editor/features/todos";

type Fixture = { name: string; input: string; expected: { open: number; done: number } };
const todoFixtures = Object.values(
  import.meta.glob("../../../Fixtures/dialect/todos.json", { eager: true, import: "default" }),
)[0] as Fixture[];

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function stateWith(doc: string, anchor = doc.length, head = anchor, extensions: Extension[] = []): EditorState {
  return parsed(
    EditorState.create({
      doc,
      selection: EditorSelection.single(anchor, head),
      extensions: [markdown({ base: bearMarkdown }), ...extensions],
    }),
  );
}

type Item = { from: number; to: number; cls: string | undefined; widget: unknown; editable: string | undefined };
function items(set: DecorationSet): Item[] {
  const out: Item[] = [];
  set.between(0, 1e9, (from, to, d) => {
    const spec = d.spec as { class?: string; attributes?: Record<string, string>; widget?: unknown };
    out.push({ from, to, cls: spec.class ?? spec.attributes?.class, widget: spec.widget, editable: spec.attributes?.contenteditable });
  });
  return out;
}
const boxes = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.widget instanceof TodoCheckbox)
    .map((it) => ({ at: it.from, done: (it.widget as TodoCheckbox).done }));
const hidden = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.cls === "cm-bc-hidden")
    .map((it) => [it.from, it.to]);
const doneMarks = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.cls === "cm-bc-todo-done")
    .map((it) => [it.from, it.to]);

/** Runs a StateCommand; returns the new state and the dispatched transaction. */
function run(state: EditorState, command: (t: { state: EditorState; dispatch(tr: Transaction): void }) => boolean) {
  let tr: Transaction | null = null;
  const handled = command({ state, dispatch: (t) => (tr = t) });
  const t = tr as Transaction | null;
  return { handled, tr: t, state: t ? parsed(t.state) : state, text: t ? t.state.doc.toString() : state.doc.toString() };
}

describe("checkbox decorations", () => {
  test("`- [ ] ` collapses into a checkbox widget; `[x]`/`[X]` are done", () => {
    const doc = "- [ ] open\n- [x] done\n* [X] star\n+ [ ] plus\nend";
    const sets = todoDecorations(stateWith(doc));
    expect(boxes(sets.inner)).toEqual([
      { at: 0, done: false },
      { at: 11, done: true },
      { at: 22, done: true },
      { at: 33, done: false },
    ]);
    // Marker, box and the blank after it: one collapsed range per item, starting at the widget.
    expect(hidden(sets.inner)).toEqual([
      [0, 6],
      [11, 17],
      [22, 28],
      [33, 39],
    ]);
    // Done items: the item text is styled (secondary color + strikethrough).
    expect(doneMarks(sets.outer)).toEqual([
      [17, 21],
      [28, 32],
    ]);
    for (const it of items(sets.inner)) if (it.cls === "cm-bc-hidden") expect(it.editable).toBe("false");
  });

  test("the checkbox stays while the caret is on the line; `- ` shows only while the caret touches it", () => {
    const doc = "- [ ] a\nnext";
    // Caret in the item text: checkbox rendered, whole prefix collapsed.
    for (const caret of [6, 7]) {
      const sets = todoDecorations(stateWith(doc, caret));
      expect(boxes(sets.inner), `caret ${caret}`).toEqual([{ at: 0, done: false }]);
      expect(hidden(sets.inner), `caret ${caret}`).toEqual([[0, 6]]);
    }
    // Caret on or right after the `- ` marker: marker raw, the box still a checkbox.
    for (const caret of [0, 1, 2]) {
      const sets = todoDecorations(stateWith(doc, caret));
      expect(boxes(sets.inner), `caret ${caret}`).toEqual([{ at: 2, done: false }]);
      expect(hidden(sets.inner), `caret ${caret}`).toEqual([[2, 6]]);
    }
  });

  test("quotes, indentation, tabs, a box at the line end and trailing blanks", () => {
    const doc = "> - [ ] q\n  - [x] two\n\t- [ ] tab\n- [ ]\n- [ ]   ";
    const sets = todoDecorations(stateWith(doc, 0));
    expect(boxes(sets.inner).map((b) => b.at)).toEqual([2, 12, 23, 33, 39]);
    expect(hidden(sets.inner)).toEqual([
      [2, 8],
      [12, 18],
      [23, 29],
      [33, 38],
      [39, 47],
    ]);
  });

  test("not todos: code, ordered items, `- []`, `-[ ]`, a glued box, mid-line boxes", () => {
    const doc = "```\n- [ ] code\n```\n1. [ ] ordered\n- [] e\n-[ ] n\n- [ ]x\ntext - [ ] mid";
    const sets = todoDecorations(stateWith(doc));
    expect(boxes(sets.inner)).toEqual([]);
    expect(hidden(sets.inner)).toEqual([]);
  });

  test("a task box opening a fence gets a checkbox but no done style over the code", () => {
    const doc = "- [x] ```\n  code\n  ```\nend";
    const sets = todoDecorations(stateWith(doc));
    expect(boxes(sets.inner)).toEqual([{ at: 0, done: true }]);
    expect(hidden(sets.inner)).toEqual([[0, 6]]);
    expect(doneMarks(sets.outer)).toEqual([]);
  });

  test("the done style covers the item's own line, not a lazy line after it (⇧↩ ends the list)", () => {
    const doc = "- [x] done\nplain\n\nend";
    expect(doneMarks(todoDecorations(stateWith(doc, doc.length)).outer)).toEqual([[6, 10]]);
    // Indented continuation lines are the item's text and stay struck.
    const cont = "- [x] done\n  more\nlazy\n\nend";
    expect(doneMarks(todoDecorations(stateWith(cont, cont.length)).outer)).toEqual([[6, 17]]);
    // In a quote: `> ` is the quote prefix, not indentation.
    const quoted = "> - [x] done\n> lazy\n\nend";
    expect(doneMarks(todoDecorations(stateWith(quoted, quoted.length)).outer)).toEqual([[8, 12]]);
    const quotedCont = "> - [x] done\n>   more\n\nend";
    expect(doneMarks(todoDecorations(stateWith(quotedCont, quotedCont.length)).outer)).toEqual([[8, 21]]);
  });

  test("a quote inside a done todo is struck", () => {
    const doc = "- [x] done\n  > quoted\n  - [ ] sub\nend";
    expect(doneMarks(todoDecorations(stateWith(doc, doc.length)).outer)).toEqual([[6, 21]]);
    // In a quote: the item's own quote is one level deeper.
    const quoted = "> - [x] done\n>   > inner\n> lazy";
    expect(doneMarks(todoDecorations(stateWith(quoted, quoted.length)).outer)).toEqual([[8, 24]]);
    // A nested list inside the item's own quote keeps its own state.
    const inQuote = "- [x] done\n  > quote\n  > - [ ] open";
    expect(doneMarks(todoDecorations(stateWith(inQuote, inQuote.length)).outer)).toEqual([[6, 20]]);
    // An open todo stays unstruck; the nested todo has its own box.
    expect(doneMarks(todoDecorations(stateWith("- [ ] open\n  > q", 0)).outer)).toEqual([]);
  });

  test.each(todoFixtures.map((f) => [f.name, f] as const))(
    "matches the Swift todo count (Fixtures/dialect/todos.json): %s",
    (_name, f) => {
      const sets = todoDecorations(stateWith(f.input, 0));
      const all = boxes(sets.inner);
      expect({ open: all.filter((b) => !b.done).length, done: all.filter((b) => b.done).length }).toEqual(f.expected);
    },
  );

  test("only the requested ranges are decorated", () => {
    const doc = "- [ ] a\n- [ ] b\n- [ ] c";
    const sets = todoDecorations(stateWith(doc), [{ from: 8, to: 15 }]);
    expect(boxes(sets.inner).map((b) => b.at)).toEqual([8]);
  });

  test("invariant: every checkbox sits right before a collapsed range reaching the item text", () => {
    const doc = "- [ ] a\n  * [x] b\n> + [X] c\n- [ ]";
    for (let caret = 0; caret <= doc.length; caret++) {
      const sets = todoDecorations(stateWith(doc, caret));
      const all = items(sets.inner);
      for (const box of all.filter((it) => it.widget instanceof TodoCheckbox)) {
        const range = all.find((it) => it.cls === "cm-bc-hidden" && it.from === box.from);
        expect(range, `caret ${caret}`).toBeDefined();
        const lineText = doc.slice(range!.to, doc.indexOf("\n", range!.to) < 0 ? doc.length : doc.indexOf("\n", range!.to));
        expect(lineText).not.toMatch(/^[ \t]/);
      }
    }
  });
});

describe("composition (Review Focus 3)", () => {
  const fakeView = (state: EditorState, composing: boolean) => ({
    state,
    composing,
    visibleRanges: [{ from: 0, to: state.doc.length }],
  });

  const updateOf = (tr: Transaction, composing: boolean, state = tr.state) => ({
    view: fakeView(state, composing),
    state,
    startState: tr.startState,
    changes: tr.changes,
    docChanged: tr.docChanged,
    selectionSet: tr.selection !== undefined,
    viewportChanged: false,
  });

  test("while composing next to a checkbox the decorations are only mapped (no widget re-render)", () => {
    const start = stateWith("- [ ] a\n- [ ] b", 6);
    const plugin = new TodoDecorationsState(fakeView(start, false));
    const before = items(plugin.sets.inner);
    const widgetBefore = before.find((it) => it.widget instanceof TodoCheckbox)!.widget;

    // The IME inserts its marked text right after the first checkbox.
    const tr = start.update({ changes: { from: 6, insert: "か" }, selection: { anchor: 7 }, userEvent: "input.type.compose" });
    plugin.update(updateOf(tr, true));
    const during = items(plugin.sets.inner);
    expect(plugin.stale).toBe(true);
    // Same widget objects (CodeMirror keeps their DOM), mapped positions; the composed text
    // stays outside the collapsed range.
    expect(during.find((it) => it.widget instanceof TodoCheckbox)!.widget).toBe(widgetBefore);
    expect(hidden(plugin.sets.inner)).toEqual([
      [0, 6],
      [9, 15],
    ]);
    expect(tr.state.doc.toString()).toBe("- [ ] かa\n- [ ] b");

    // Composition over: the next update rebuilds.
    const end = tr.state.update({});
    plugin.update(updateOf(end, false));
    expect(plugin.stale).toBe(false);
    expect(boxes(plugin.sets.inner).map((b) => b.at)).toEqual([0, 9]);
  });

  test("a structural edit during composition is not reflected until it ends", () => {
    const start = stateWith("- [ ] a", 7);
    const plugin = new TodoDecorationsState(fakeView(start, false));
    const tr = start.update({ changes: { from: 7, insert: "\n- [ ] b" } });
    plugin.update(updateOf(tr, true, parsed(tr.state)));
    expect(boxes(plugin.sets.inner)).toHaveLength(1);
    const end = parsed(tr.state).update({});
    plugin.update(updateOf(end, false));
    expect(boxes(plugin.sets.inner)).toHaveLength(2);
  });
});

describe("toggleTodo (⌘.)", () => {
  test("toggles the item at the caret: `[ ]` → `[x]`, `[x]`/`[X]` → `[ ]`; one input.todo transaction", () => {
    const r = run(stateWith("- [ ] a\n- [x] b\n- [X] c", 7), toggleTodo);
    expect(r.handled).toBe(true);
    expect(r.text).toBe("- [x] a\n- [x] b\n- [X] c");
    expect(r.tr!.isUserEvent("input.todo")).toBe(true);
    expect(r.state.selection.main.head).toBe(7);
    expect(run(stateWith("- [ ] a\n- [x] b\n- [X] c", 10), toggleTodo).text).toBe("- [ ] a\n- [ ] b\n- [X] c");
    expect(run(stateWith("- [ ] a\n- [x] b\n- [X] c", 22), toggleTodo).text).toBe("- [ ] a\n- [x] b\n- [ ] c");
  });

  test("toggles every selected item", () => {
    const doc = "- [ ] a\n- [x] b\n- [ ] c\nend";
    expect(run(stateWith(doc, 2, 18), toggleTodo).text).toBe("- [x] a\n- [ ] b\n- [x] c\nend");
    // A selection ending at the start of a line does not include that line.
    expect(run(stateWith(doc, 0, 8), toggleTodo).text).toBe("- [x] a\n- [x] b\n- [ ] c\nend");
  });

  test("converts a non-todo line into an open todo", () => {
    const cases: [string, number, string, number][] = [
      ["text", 2, "- [ ] text", 8],
      ["", 0, "- [ ] ", 6],
      ["- item", 6, "- [ ] item", 10],
      ["* item", 2, "* [ ] item", 6],
      ["1. item", 3, "- [ ] item", 6],
      ["> quoted", 8, "> - [ ] quoted", 14],
      ["  - nested", 10, "  - [ ] nested", 14],
      ["#tag", 0, "- [ ] #tag", 6],
    ];
    for (const [doc, caret, expected, head] of cases) {
      const r = run(stateWith(doc, caret), toggleTodo);
      expect(r.text, doc).toBe(expected);
      expect(r.state.selection.main.head, doc).toBe(head);
    }
  });

  test("leaves code blocks alone", () => {
    const r = run(stateWith("```\ncode\n```", 6), toggleTodo);
    expect(r.handled).toBe(false);
  });

  test("never strips a heading: heading lines are not converted", () => {
    expect(run(stateWith("## Head", 7), toggleTodo).handled).toBe(false);
    expect(run(stateWith("# H\na", 0, 5), toggleTodo).text).toBe("# H\n- [ ] a");
  });

  test("a bare marker becomes the todo's marker", () => {
    expect(run(stateWith("-", 1), toggleTodo).text).toBe("- [ ] ");
    expect(run(stateWith("> *", 3), toggleTodo).text).toBe("> * [ ] ");
  });

  test("a multi-line selection skips blank lines", () => {
    expect(run(stateWith("a\n\nb", 0, 4), toggleTodo).text).toBe("- [ ] a\n\n- [ ] b");
  });

  test("read-only notes are not changed", () => {
    expect(run(stateWith("- [ ] a", 7, 7, [EditorState.readOnly.of(true)]), toggleTodo).handled).toBe(false);
  });
});

describe("insertTodo (⌘T)", () => {
  test("an empty line becomes `- [ ] ` with the caret after it", () => {
    const r = run(stateWith("a\n\nb", 2), insertTodo);
    expect(r.text).toBe("a\n- [ ] \nb");
    expect(r.state.selection.main.head).toBe(8);
    expect(r.tr!.isUserEvent("input.todo")).toBe(true);
  });

  test("a text line is converted; the caret keeps its place in the text", () => {
    const r = run(stateWith("buy milk", 4), insertTodo);
    expect(r.text).toBe("- [ ] buy milk");
    expect(r.state.selection.main.head).toBe(10);
  });

  test("on todo lines it removes the todo (format toggle), keeping indentation and quotes", () => {
    expect(run(stateWith("- [ ] a", 7), insertTodo).text).toBe("a");
    expect(run(stateWith("  - [x] a", 9), insertTodo).text).toBe("  a");
    expect(run(stateWith("> - [ ] a", 9), insertTodo).text).toBe("> a");
    const r = run(stateWith("- [ ] a\n- [ ] b", 0, 15), insertTodo);
    expect(r.text).toBe("a\nb");
  });

  test("a multi-line selection skips blank lines and heading lines", () => {
    expect(run(stateWith("a\n\nb", 0, 4), insertTodo).text).toBe("- [ ] a\n\n- [ ] b");
    expect(run(stateWith("- [ ] a\n\n- [ ] b", 0, 16), insertTodo).text).toBe("a\n\nb");
    expect(run(stateWith("# Shopping\nmilk\neggs", 0, 20), insertTodo).text).toBe("# Shopping\n- [ ] milk\n- [ ] eggs");
    expect(run(stateWith("## Head", 3), insertTodo).handled).toBe(false);
  });

  test("a bare marker becomes the todo's marker (no stray `-`)", () => {
    const r = run(stateWith("-", 1), insertTodo);
    expect(r.text).toBe("- [ ] ");
    expect(r.state.selection.main.head).toBe(6);
    expect(run(stateWith("  +", 3), insertTodo).text).toBe("  + [ ] ");
    expect(run(stateWith("a\n-\nb", 0, 5), insertTodo).text).toBe("- [ ] a\n- [ ] \n- [ ] b");
  });

  test("a selection with todo and non-todo lines converts the non-todo lines", () => {
    expect(run(stateWith("- [ ] a\nb", 0, 9), insertTodo).text).toBe("- [ ] a\n- [ ] b");
  });
});

describe("moveCheckedToBottom", () => {
  test("moves done items to the bottom of each contiguous checklist, keeping their order", () => {
    const r = run(stateWith("- [x] a\n- [ ] b\n- [X] c\n- [ ] d", 0), moveCheckedToBottom);
    expect(r.text).toBe("- [ ] b\n- [ ] d\n- [x] a\n- [X] c");
    expect(r.tr!.isUserEvent("input.todo")).toBe(true);
  });

  test("nested todos move with their children; nested checklists are sorted too", () => {
    const doc = ["- [x] a", "  - [ ] a1", "  - [x] a2", "  - [ ] a3", "- [ ] b", "  text of b"].join("\n");
    expect(run(stateWith(doc, 0), moveCheckedToBottom).text).toBe(
      ["- [ ] b", "  text of b", "- [x] a", "  - [ ] a1", "  - [ ] a3", "  - [x] a2"].join("\n"),
    );
  });

  test("a plain bullet or another block ends a checklist", () => {
    expect(run(stateWith("- [x] a\n- plain\n- [x] c\n- [ ] d", 0), moveCheckedToBottom).text).toBe(
      "- [x] a\n- plain\n- [ ] d\n- [x] c",
    );
    expect(run(stateWith("- [x] a\n- [ ] b\n\npara\n\n- [x] c\n- [ ] d", 0), moveCheckedToBottom).text).toBe(
      "- [ ] b\n- [x] a\n\npara\n\n- [ ] d\n- [x] c",
    );
  });

  test("quoted checklists and loose lists keep their separators", () => {
    expect(run(stateWith("> - [x] a\n> - [ ] b", 0), moveCheckedToBottom).text).toBe("> - [ ] b\n> - [x] a");
    expect(run(stateWith("- [x] a\n\n- [ ] b\n", 0), moveCheckedToBottom).text).toBe("- [ ] b\n\n- [x] a\n");
  });

  test("the caret stays in the text it was in", () => {
    const doc = "- [x] apple\n- [ ] bread";
    const r = run(stateWith(doc, doc.indexOf("pple")), moveCheckedToBottom);
    expect(r.text).toBe("- [ ] bread\n- [x] apple");
    expect(r.state.selection.main.head).toBe(r.text.indexOf("pple"));
    // At the end of an item's text it stays at the end of that item.
    const end = run(stateWith(doc, doc.indexOf("\n")), moveCheckedToBottom);
    expect(end.state.selection.main.head).toBe(end.text.length);
  });

  test("returns false when nothing moves", () => {
    expect(run(stateWith("- [ ] a\n- [x] b", 0), moveCheckedToBottom).handled).toBe(false);
    expect(run(stateWith("text", 0), moveCheckedToBottom).handled).toBe(false);
  });
});

describe("auto-sort (setting autoSortTodos)", () => {
  const auto = [autoSortTodos.of(true)];

  test("off by default: a toggled item stays in place", () => {
    expect(stateWith("x").facet(autoSortTodos)).toBe(false);
    expect(run(stateWith("- [ ] a\n- [ ] b", 7), toggleTodo).text).toBe("- [x] a\n- [ ] b");
  });

  test("on: an item checked off moves to the end of its checklist with its children, in one transaction", () => {
    const doc = ["- [ ] a", "  - [ ] a1", "  - [x] a2", "- [ ] b", "- [x] c", "", "after"].join("\n");
    const r = run(stateWith(doc, 3, 3, auto), toggleTodo);
    expect(r.text).toBe(["- [ ] b", "- [x] c", "- [x] a", "  - [ ] a1", "  - [x] a2", "", "after"].join("\n"));
    // The caret moved with its item.
    expect(r.state.doc.lineAt(r.state.selection.main.head).text).toBe("- [x] a");
  });

  test("on: a nested item moves within its own checklist only", () => {
    const doc = ["- [ ] a", "  - [ ] a1", "  - [ ] a2", "- [ ] b"].join("\n");
    const r = run(stateWith(doc, doc.indexOf("a1") + 2, undefined, auto), toggleTodo);
    expect(r.text).toBe(["- [ ] a", "  - [ ] a2", "  - [x] a1", "- [ ] b"].join("\n"));
  });

  test("[X] uppercase done in a nested auto-sorted list", () => {
    const doc = ["- [ ] a", "  - [X] a1", "  - [ ] a2", "  - [X] a3", "- [ ] b"].join("\n");
    // Checking a2 off moves it below the uppercase done items only (a1, a3 stay in order).
    const checked = run(stateWith(doc, doc.indexOf("a2") + 2, undefined, auto), toggleTodo);
    expect(checked.text).toBe(["- [ ] a", "  - [X] a1", "  - [X] a3", "  - [x] a2", "- [ ] b"].join("\n"));
    // Unchecking an uppercase one writes a blank box and does not move.
    const unchecked = run(stateWith(doc, doc.indexOf("a1") + 2, undefined, auto), toggleTodo);
    expect(unchecked.text).toBe(["- [ ] a", "  - [ ] a1", "  - [ ] a2", "  - [X] a3", "- [ ] b"].join("\n"));
    // Move Checked to the Bottom treats [X] as done at every level.
    const moved = run(stateWith(["- [X] x", "- [ ] y", "  - [X] y1", "  - [ ] y2"].join("\n")), moveCheckedToBottom);
    expect(moved.text).toBe(["- [ ] y", "  - [ ] y2", "  - [X] y1", "- [X] x"].join("\n"));
  });

  test("on: unchecking does not move", () => {
    expect(run(stateWith("- [x] a\n- [ ] b", 7, 7, auto), toggleTodo).text).toBe("- [ ] a\n- [ ] b");
  });

  test("on: a click toggle (toggleTodoAt) sorts too and keeps an unrelated caret where it is", () => {
    const doc = "- [ ] a\n- [ ] b\n\ncaret here";
    const state = stateWith(doc, doc.length, doc.length, auto);
    const spec = toggleTodoAt(state, 0)!;
    const tr = state.update(spec);
    expect(tr.state.doc.toString()).toBe("- [ ] b\n- [x] a\n\ncaret here");
    expect(tr.state.selection.main.head).toBe(doc.length);
  });
});

describe("toggleTodoAt (checkbox click)", () => {
  test("one input.todo transaction that leaves the selection alone", () => {
    const doc = "- [ ] a\n- [ ] b";
    const state = stateWith(doc, 9, 11);
    const spec = toggleTodoAt(state, 8) as TransactionSpec;
    const tr = state.update(spec);
    expect(tr.state.doc.toString()).toBe("- [ ] a\n- [x] b");
    expect(tr.isUserEvent("input.todo")).toBe(true);
    expect(tr.state.selection.main.anchor).toBe(9);
    expect(tr.state.selection.main.head).toBe(11);
    expect(toggleTodoAt(stateWith("plain"), 0)).toBeNull();
  });

  test("one undo step reverts exactly the toggle (Review Focus 2)", () => {
    let state = stateWith("- [ ] a", 7, 7, [history()]);
    const apply = (tr: Transaction) => (state = tr.state);
    // Typing right before the toggle must not merge into its undo step, nor typing after it.
    apply(state.update({ changes: { from: 7, insert: "b" }, selection: { anchor: 8 }, userEvent: "input.type" }));
    apply(state.update(toggleTodoAt(state, 0)!));
    apply(state.update({ changes: { from: 8, insert: "c" }, selection: { anchor: 9 }, userEvent: "input.type" }));
    expect(state.doc.toString()).toBe("- [x] abc");
    undo({ state, dispatch: apply });
    expect(state.doc.toString()).toBe("- [x] ab");
    undo({ state, dispatch: apply });
    expect(state.doc.toString()).toBe("- [ ] ab");
    redo({ state, dispatch: apply });
    expect(state.doc.toString()).toBe("- [x] ab");
  });
});

describe("todoLineStart (Home)", () => {
  test("on a todo line Home goes to the start of the item text, then to the line start", () => {
    const state = stateWith("- [ ] item\nplain", 9);
    expect(todoLineStart(state, 9)).toBe(6);
    expect(todoLineStart(state, 6)).toBeNull();
    expect(todoLineStart(state, 13)).toBeNull();
  });
});
