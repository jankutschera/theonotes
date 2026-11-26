// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  type ChangeDesc,
  type ChangeSpec,
  ChangeSet,
  EditorSelection,
  EditorState,
  type Extension,
  Facet,
  Prec,
  type Range as Ranged,
  type SelectionRange,
  type StateCommand,
  type Text,
  type TransactionSpec,
} from "@codemirror/state";
import { type Command, Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, WidgetType } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { isolateHistory } from "@codemirror/commands";
import { hiddenMark, hidingUpdatePlan, type Range } from "./hiding";

// Todos (inventory §2.9): `- [ ]`, `* [ ]`, `+ [ ]` with `[x]`/`[X]` done, recognized by the
// dialect's Task nodes (the same rules as the Swift indexer, Fixtures/dialect/todos.json).
//
// Presentation: the list marker, the box and the blanks after it stay in the DOM (finding F8)
// but are collapsed with the shared hidden mark; a checkbox widget (a VoiceOver checkbox control
// without text, M7 Task 11) sits right before the collapsed range. The checkbox is always shown (Bear), the `- ` only while the
// selection touches it (from the marker to the box).
//
// Caret invariant (Review Focus 1): every collapsed todo range is atomic (EditorView.atomicRanges),
// so cursor motion, Backspace/Delete and mouse selection skip it as a whole. The only positions
// a caret can reach on a todo line before the text are the line start and, while `- ` is shown,
// the positions inside `- ` — and those keep `- ` shown, so a caret is never inside a collapsed
// range. Home goes to the start of the item text first (todoLineStart).

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

/** Setting "completed todos move to the bottom" (Task 10 provides it from setSettings). */
export const autoSortTodos = Facet.define<boolean, boolean>({ combine: (values) => values[0] ?? false });

/** The user event of every todo edit (checkbox click, ⌘., ⌘T, sorting). */
const TODO_EVENT = "input.todo";

/** The checkbox drawn in place of the collapsed `- [ ] `. */
export class TodoCheckbox extends WidgetType {
  constructor(readonly done: boolean) {
    super();
  }

  override eq(other: TodoCheckbox) {
    return other.done === this.done;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("span");
    el.className = "cm-bc-todo";
    el.dataset.done = String(this.done);
    // A control, not text (F8 holds: the span has no text node). A VoiceOver press arrives as the
    // click below and takes the same toggle path (one undo step).
    el.setAttribute("role", "checkbox");
    el.setAttribute("aria-checked", String(this.done));
    el.setAttribute("aria-label", "Todo");
    if (view.state.readOnly) el.setAttribute("aria-disabled", "true");
    // Keep focus and selection where they are; the click toggles.
    el.addEventListener("mousedown", (event) => event.preventDefault());
    el.addEventListener("click", (event) => {
      event.preventDefault();
      if (view.composing || view.state.readOnly) return;
      const spec = toggleTodoAt(view.state, view.posAtDOM(el));
      if (spec) view.dispatch(spec);
    });
    return el;
  }
}

/** A recognized todo item. */
export type TodoItem = {
  /** The ListItem node. */
  item: SyntaxNode;
  /** `-`, `*` or `+`. */
  listMark: Range;
  /** `[ ]`, `[x]` or `[X]`. */
  box: Range;
  /** After the box and the blanks following it: where the item text starts. */
  contentStart: number;
  done: boolean;
  /** End of the item's own text (the done style; without lazy lines), `contentStart` when there is none. */
  textEnd: number;
};

const isBlank = (c: string) => c === " " || c === "\t";

function todoFromTask(doc: Text, task: SyntaxNode): TodoItem | null {
  const marker = task.getChild("TaskMarker");
  const item = task.parent;
  const listMark = item?.name === "ListItem" ? item.getChild("ListMark") : null;
  if (!marker || !item || !listMark) return null;
  const line = doc.lineAt(marker.from);
  let contentStart = marker.to;
  while (contentStart < line.to && isBlank(line.text[contentStart - line.from]!)) contentStart++;
  // The box's line and the indented continuation lines after it, including the item's own
  // blocks after its text (an indented quote) up to a nested list (its items have their
  // own boxes) or a fence. An unindented (lazy) line is a paragraph of its own for Bear (⇧↩ ends
  // the list).
  // The first nested list or fence anywhere in the item's later blocks (also one inside its quote).
  let stop = item.to;
  const cursor = item.cursor();
  cursor.firstChild();
  search: do {
    if (cursor.from < task.to) continue;
    const inner = cursor.node.cursor();
    do {
      if (inner.name === "BulletList" || inner.name === "OrderedList" || inner.name === "FencedCode") {
        stop = doc.lineAt(inner.from).from;
        break search;
      }
    } while (inner.next() && inner.from < cursor.to);
  } while (cursor.nextSibling());
  // The quote levels the item itself is in (each `>` takes at most one blank); deeper `>` are the
  // item's own quote.
  const depth = (/^(?:[ \t]*>[ \t]?)*/.exec(line.text)![0].match(/>/g) ?? []).length;
  const outerQuote = new RegExp(`^(?:[ \\t]*>[ \\t]?){${depth}}`);
  let end = line.to;
  for (let next = line.to + 1; next < stop; ) {
    const l = doc.lineAt(next);
    if (!/^[ \t]+\S/.test(l.text.replace(outerQuote, ""))) break;
    end = l.to;
    next = l.to + 1;
  }
  const textEnd = task.getChild("FencedCode") ? contentStart : Math.max(contentStart, Math.min(stop, end));
  return {
    item,
    listMark: { from: listMark.from, to: listMark.to },
    box: { from: marker.from, to: marker.to },
    contentStart,
    done: doc.sliceString(marker.from + 1, marker.from + 2) !== " ",
    textEnd,
  };
}

/** Nodes that may contain todo items; the tree walks skip everything else. */
const containers = new Set(["Document", "BulletList", "OrderedList", "ListItem", "Blockquote"]);

/** The todo whose box is on line `lineFrom`…`lineTo`, if any. */
function todoOnLine(state: EditorState, lineFrom: number, lineTo: number): TodoItem | null {
  let found: TodoItem | null = null;
  syntaxTree(state).iterate({
    from: lineFrom,
    to: lineTo,
    enter(ref) {
      if (found) return false;
      if (ref.name === "Task") {
        const todo = todoFromTask(state.doc, ref.node);
        if (todo && todo.box.from >= lineFrom && todo.box.from <= lineTo) found = todo;
        return false;
      }
      return containers.has(ref.name);
    },
  });
  return found;
}

export type TodoSets = {
  /** Checkbox widgets and the collapsed ranges (also the atomic ranges). */
  inner: DecorationSet;
  /** The done style on the text of done items (`EditorView.outerDecorations`). */
  outer: DecorationSet;
};

const doneMark = Decoration.mark({ class: "cm-bc-todo-done" });
const checkboxes = [false, true].map((done) => Decoration.widget({ widget: new TodoCheckbox(done), side: 1 }));

const touches = (sel: readonly SelectionRange[], from: number, to: number) =>
  sel.some((r) => r.from <= to && r.to >= from);

/** Todo decorations for `within` (default: the whole document; the plugin passes the visible ranges). Pure. */
export function todoDecorations(state: EditorState, within?: readonly Range[]): TodoSets {
  const sel = state.selection.ranges;
  const inner: Ranged<Decoration>[] = [];
  const outer: Ranged<Decoration>[] = [];
  const seen = new Set<number>();
  for (const span of within ?? [{ from: 0, to: state.doc.length }]) {
    syntaxTree(state).iterate({
      from: span.from,
      to: span.to,
      enter(ref) {
        if (ref.name !== "Task") return containers.has(ref.name);
        const todo = todoFromTask(state.doc, ref.node);
        if (!todo || seen.has(todo.box.from)) return false;
        seen.add(todo.box.from);
        const start = touches(sel, todo.listMark.from, todo.box.from) ? todo.box.from : todo.listMark.from;
        inner.push(checkboxes[todo.done ? 1 : 0]!.range(start), hiddenMark.range(start, todo.contentStart));
        if (todo.done && todo.textEnd > todo.contentStart) outer.push(doneMark.range(todo.contentStart, todo.textEnd));
        return false;
      },
    });
  }
  return { inner: Decoration.set(inner, true), outer: Decoration.set(outer, true) };
}

/** What the plugin needs of a view (an EditorView; tests pass a stand-in with `composing`). */
export type TodoViewLike = { state: EditorState; visibleRanges: readonly Range[]; composing: boolean };
export type TodoUpdateLike = {
  view: TodoViewLike;
  state: EditorState;
  startState: EditorState;
  changes: ChangeDesc;
  docChanged: boolean;
  selectionSet: boolean;
  viewportChanged: boolean;
};

/**
 * The plugin's state. Never touches the DOM around an IME composition: while composing the
 * decorations are only mapped (the widgets keep their DOM); they are rebuilt once it ends.
 */
export class TodoDecorationsState {
  sets: TodoSets;
  stale = false;

  constructor(view: TodoViewLike) {
    this.sets = todoDecorations(view.state, view.visibleRanges);
  }

  update(update: TodoUpdateLike) {
    const changed =
      update.docChanged ||
      update.selectionSet ||
      update.viewportChanged ||
      syntaxTree(update.startState) !== syntaxTree(update.state);
    switch (hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale })) {
      case "map":
        this.sets = { inner: this.sets.inner.map(update.changes), outer: this.sets.outer.map(update.changes) };
        this.stale ||= changed;
        return;
      case "rebuild":
        this.sets = todoDecorations(update.view.state, update.view.visibleRanges);
        this.stale = false;
        return;
      case "keep":
        return;
    }
  }
}

const todoPlugin = ViewPlugin.fromClass(TodoDecorationsState, {
  eventHandlers: {
    compositionend(_event, view) {
      afterComposition(() => {
        if (this.stale && !view.composing) view.dispatch({});
      });
    },
  },
});

// ---------------------------------------------------------------------------------------------
// Sorting

type Seg = { from: number; to: number; item: boolean };
type SortKey = (todo: TodoItem) => number;

function push(out: Seg[], from: number, to: number, item: boolean) {
  if (to > from) out.push({ from, to, item });
}

/**
 * Appends the segments that make up `node`'s new text (source ranges, reordered) to `out`;
 * returns whether anything moved. Inside every bullet list, each run of consecutive todo items
 * (a contiguous checklist) is stably sorted by `key`; an item moves with everything nested in
 * it. The gaps between items stay in place.
 */
function render(state: EditorState, node: SyntaxNode, key: SortKey, out: Seg[], inItem: boolean): boolean {
  if (node.name !== "BulletList") return renderChildren(state, node, key, out, inItem);
  const items: { node: SyntaxNode; segs: Seg[]; key: number | null }[] = [];
  let changed = false;
  for (let c = node.firstChild; c; c = c.nextSibling) {
    if (c.name !== "ListItem") continue;
    const segs: Seg[] = [];
    changed = renderChildren(state, c, key, segs, true) || changed;
    const task = c.getChild("Task");
    const todo = task && todoFromTask(state.doc, task);
    items.push({ node: c, segs, key: todo ? key(todo) : null });
  }
  const order = items.map((_, i) => i);
  for (let i = 0; i < items.length; ) {
    let j = i;
    while (j < items.length && items[j]!.key !== null) j++;
    if (j > i) {
      const run = order.slice(i, j).sort((a, b) => items[a]!.key! - items[b]!.key! || a - b);
      if (run.some((v, k) => v !== i + k)) changed = true;
      order.splice(i, j - i, ...run);
    }
    i = Math.max(j, i + 1);
  }
  let pos = node.from;
  // The gaps between items (line breaks, indentation, quote marks) stay in place.
  items.forEach((it, i) => {
    push(out, pos, it.node.from, false);
    out.push(...items[order[i]!]!.segs);
    pos = it.node.to;
  });
  push(out, pos, node.to, false);
  return changed;
}

function renderChildren(state: EditorState, node: SyntaxNode, key: SortKey, out: Seg[], inItem: boolean): boolean {
  let pos = node.from;
  let changed = false;
  for (let c = node.firstChild; c; c = c.nextSibling) {
    if (!containers.has(c.name)) continue;
    push(out, pos, c.from, inItem);
    changed = render(state, c, key, out, inItem) || changed;
    pos = c.to;
  }
  push(out, pos, node.to, inItem);
  return changed;
}

type Reorder = { from: number; to: number; segs: Seg[] };

/** Where `pos` ends up after the reorders (lengths are unchanged, so outside them it stays). */
function mapReordered(reorders: readonly Reorder[], pos: number): number {
  for (const r of reorders) {
    if (pos < r.from || pos > r.to) continue;
    let fallback: number | null = null;
    let at = r.from;
    for (const s of r.segs) {
      // Item text first, edges included: a caret at the end of an item stays with that item.
      if (s.item && pos >= s.from && pos <= s.to) return at + (pos - s.from);
      if (fallback === null && pos >= s.from && pos < s.to) fallback = at + (pos - s.from);
      at += s.to - s.from;
    }
    return fallback ?? pos;
  }
  return pos;
}

function fullTree(state: EditorState) {
  return ensureSyntaxTree(state, state.doc.length, 200) ?? syntaxTree(state);
}

/** Reorders `nodes` (none nested in another) by `key`; only the ones where something moved. */
function reorders(state: EditorState, nodes: readonly SyntaxNode[], key: SortKey): Reorder[] {
  const out: Reorder[] = [];
  for (const node of nodes) {
    const segs: Seg[] = [];
    if (render(state, node, key, segs, false)) out.push({ from: node.from, to: node.to, segs });
  }
  return out;
}

/**
 * One transaction: `edits` (length-preserving box flips) plus the reorders, whose new text is
 * taken from the document with the flips applied. The selection follows the moved text.
 */
type Edit = { from: number; to: number; insert: string };

function withReorders(state: EditorState, edits: readonly Edit[], moves: readonly Reorder[]): TransactionSpec {
  const flipped: Text = ChangeSet.of(edits, state.doc.length).apply(state.doc);
  const changes: ChangeSpec[] = [];
  for (const edit of edits) {
    if (!moves.some((m) => edit.from >= m.from && edit.to <= m.to)) changes.push(edit);
  }
  for (const m of moves) {
    changes.push({ from: m.from, to: m.to, insert: m.segs.map((s) => flipped.sliceString(s.from, s.to)).join("") });
  }
  const selection = EditorSelection.create(
    state.selection.ranges.map((r) => EditorSelection.range(mapReordered(moves, r.anchor), mapReordered(moves, r.head))),
    state.selection.mainIndex,
  );
  return { changes, selection };
}

// ---------------------------------------------------------------------------------------------
// Commands

const codeBlocks = new Set(["FencedCode", "CodeBlock", "MathBlock", "FrontMatter", "HTMLBlock", "CommentBlock"]);

function inCodeBlock(state: EditorState, pos: number): boolean {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, 1); n; n = n.parent) {
    if (codeBlocks.has(n.name)) return true;
  }
  return false;
}

const BLANK_LINE = /^(?:[ \t]*>[ \t]?)*[ \t]*$/;
const HEADING_LINE = /^(?:[ \t]*>[ \t]?)*[ \t]*#{1,6}(?:[ \t]|$)/;

/**
 * The lines the selection covers (a range ending at a line start leaves that line out). A
 * selection over several lines skips the blank ones (unless all of them are blank).
 */
function selectedLines(state: EditorState): { from: number; to: number; text: string }[] {
  const lines = new Map<number, { from: number; to: number; text: string }>();
  for (const r of state.selection.ranges) {
    const last = r.empty || r.to > state.doc.lineAt(r.to).from ? r.to : r.to - 1;
    for (let n = state.doc.lineAt(r.from).number; n <= state.doc.lineAt(last).number; n++) {
      const line = state.doc.line(n);
      lines.set(n, { from: line.from, to: line.to, text: line.text });
    }
  }
  const all = [...lines.keys()].sort((a, b) => a - b).map((n) => lines.get(n)!);
  const filled = all.filter((line) => !BLANK_LINE.test(line.text));
  return all.length > 1 && filled.length > 0 ? filled : all;
}

/** Heading lines are never turned into todos (that would strip the heading). */
const isHeadingLine = (line: { text: string }) => HEADING_LINE.test(line.text);

// Quotes and indentation, then a bullet (also a bare one at the line end) or an ordered marker.
const linePrefix = /^((?:[ \t]*>[ \t]?)*[ \t]*)(?:([-*+])([ \t]+|$)|(\d{1,9}[.)])[ \t]+)?/;

/** Turns a line into an open todo: `- [ ] ` after its quotes and indentation; a bullet keeps its marker. */
function convertLine(line: { from: number; text: string }): ChangeSpec {
  const m = linePrefix.exec(line.text)!;
  const prefix = m[1]!.length;
  if (m[2]) return { from: line.from + prefix + 1 + m[3]!.length, insert: m[3] ? "[ ] " : " [ ] " };
  return { from: line.from + prefix, to: line.from + m[0].length, insert: "- [ ] " };
}

const flipBox = (todo: TodoItem): Edit => ({
  from: todo.box.from + 1,
  to: todo.box.from + 2,
  insert: todo.done ? " " : "x",
});

const todoSpec = (spec: TransactionSpec, scrollIntoView: boolean): TransactionSpec => ({
  ...spec,
  userEvent: TODO_EVENT,
  annotations: isolateHistory.of("full"),
  scrollIntoView,
});

/**
 * Toggles `todos`; with auto-sort on, items checked off move to the end of their checklist in
 * the same transaction.
 */
function toggleSpec(state: EditorState, todos: readonly TodoItem[]): TransactionSpec {
  const flips = todos.map(flipBox);
  const checked = new Set(todos.filter((t) => !t.done).map((t) => t.box.from));
  if (!state.facet(autoSortTodos) || checked.size === 0) return { changes: flips };
  // The lists holding the checked items; a list nested in another one is sorted with it.
  const lists = [
    ...new Map(todos.filter((t) => checked.has(t.box.from)).map((t) => [t.item.parent!.from, t.item.parent!])).values(),
  ];
  const outermost = lists.filter((l) => !lists.some((o) => o !== l && o.from <= l.from && o.to >= l.to));
  const moves = reorders(state, outermost, (t) => (checked.has(t.box.from) ? 1 : 0));
  return withReorders(state, flips, moves);
}

/** The checkbox click: toggles the todo on the line of `pos`; the selection stays (unless it moves with a sorted item). */
export function toggleTodoAt(state: EditorState, pos: number): TransactionSpec | null {
  if (state.readOnly) return null;
  const line = state.doc.lineAt(pos);
  const todo = todoOnLine(state, line.from, line.to);
  return todo ? todoSpec(toggleSpec(state, [todo]), false) : null;
}

/**
 * ⌘. (Toggle Todo): toggles the todo at the caret / every selected todo; non-todo lines (outside
 * code blocks, not headings) become open todos.
 */
export const toggleTodo: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const todos: TodoItem[] = [];
  const converts: ChangeSpec[] = [];
  for (const line of selectedLines(state)) {
    const todo = todoOnLine(state, line.from, line.to);
    if (todo) todos.push(todo);
    else if (!inCodeBlock(state, line.from) && !isHeadingLine(line)) converts.push(convertLine(line));
  }
  if (todos.length === 0 && converts.length === 0) return false;
  if (converts.length === 0) {
    dispatch(state.update(todoSpec(toggleSpec(state, todos), true)));
    return true;
  }
  // Mixed with conversions: toggles only, no auto-sort (positions shift).
  const changes = state.changes([...todos.map(flipBox), ...converts]);
  dispatch(state.update(todoSpec({ changes, selection: state.selection.map(changes, 1) }, true)));
  return true;
};

/**
 * ⌘T (Todo): an empty line gets `- [ ] `, other lines become todos; when every selected line
 * already is a todo, the todos are removed again (like the other format toggles).
 */
export const insertTodo: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const lines = selectedLines(state).filter((line) => !inCodeBlock(state, line.from) && !isHeadingLine(line));
  if (lines.length === 0) return false;
  const todos = lines.map((line) => todoOnLine(state, line.from, line.to));
  const specs: ChangeSpec[] = todos.every((t) => t)
    ? todos.map((t) => ({ from: t!.listMark.from, to: t!.contentStart }))
    : lines.flatMap((line, i) => (todos[i] ? [] : [convertLine(line)]));
  const changes = state.changes(specs);
  dispatch(state.update(todoSpec({ changes, selection: state.selection.map(changes, 1) }, true)));
  return true;
};

/** Format → Todo → Move Checked to the Bottom: every contiguous checklist of the note, nested ones too. */
export const moveCheckedToBottom: StateCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const top: SyntaxNode[] = [];
  for (let c = fullTree(state).topNode.firstChild; c; c = c.nextSibling) if (containers.has(c.name)) top.push(c);
  const moves = reorders(state, top, (t) => (t.done ? 1 : 0));
  if (moves.length === 0) return false;
  dispatch(state.update(todoSpec(withReorders(state, [], moves), true)));
  return true;
};

/**
 * Home on a todo line: the start of the item text when the caret is after it, else null (the
 * default command then goes on to the line start).
 */
export function todoLineStart(state: EditorState, pos: number): number | null {
  const line = state.doc.lineAt(pos);
  const todo = todoOnLine(state, line.from, line.to);
  return todo && pos > todo.contentStart ? todo.contentStart : null;
}

const toTextStart =
  (extend: boolean): Command =>
  (view) => {
    const { state } = view;
    let moved = false;
    const ranges = state.selection.ranges.map((r) => {
      const start = todoLineStart(state, r.head);
      // A wrapped line: a caret on a later visual row goes to that row's start first.
      const boundary = view.moveToLineBoundary(EditorSelection.cursor(r.head), false, true).head;
      const head = start !== null && boundary <= start ? ((moved = true), start) : boundary;
      return extend ? EditorSelection.range(r.anchor, head) : EditorSelection.cursor(head);
    });
    if (!moved) return false;
    view.dispatch({ selection: EditorSelection.create(ranges, state.selection.mainIndex), scrollIntoView: true, userEvent: "select" });
    return true;
  };

const todoTheme = EditorView.baseTheme({
  ".cm-bc-todo": {
    display: "inline-block",
    position: "relative",
    boxSizing: "border-box",
    width: "0.95em",
    height: "0.95em",
    marginRight: "0.45em",
    verticalAlign: "-0.14em",
    border: "1.5px solid var(--bc-color-secondary)",
    borderRadius: "0.25em",
    cursor: "pointer",
  },
  ".cm-bc-todo:hover": { borderColor: "var(--bc-color-accent)" },
  // A read-only note's box is only drawn: it toggles nothing, so no pointer and no hover accent.
  "&.cm-bc-readonly .cm-bc-todo": { cursor: "default" },
  "&.cm-bc-readonly .cm-bc-todo:hover": { borderColor: "var(--bc-color-secondary)" },
  ".cm-bc-todo[data-done=true]": {
    backgroundColor: "var(--bc-color-secondary)",
    borderColor: "var(--bc-color-secondary)",
  },
  // The check mark.
  ".cm-bc-todo[data-done=true]::after": {
    content: '""',
    position: "absolute",
    left: "0.27em",
    top: "0.08em",
    width: "0.2em",
    height: "0.45em",
    border: "solid var(--bc-color-bg)",
    borderWidth: "0 0.11em 0.11em 0",
    transform: "rotate(45deg)",
  },
  ".cm-bc-todo-done": { color: "var(--bc-color-secondary)", textDecoration: "line-through" },
});

export const todos: Extension = [
  todoPlugin,
  EditorView.decorations.of((view) => view.plugin(todoPlugin)?.sets.inner ?? Decoration.none),
  EditorView.outerDecorations.of((view) => view.plugin(todoPlugin)?.sets.outer ?? Decoration.none),
  // Styling hook for the read-only look (the checkbox cursor); a reconfigured mode updates it.
  EditorView.editorAttributes.compute([EditorState.readOnly], (state) => ({
    class: state.facet(EditorState.readOnly) ? "cm-bc-readonly" : "",
  })),
  // A reconfigured read-only mode reuses the checkbox widgets (their `eq` ignores it), so their
  // `aria-disabled` follows here.
  ViewPlugin.define(() => ({
    update(update) {
      if (update.state.readOnly === update.startState.readOnly) return;
      for (const box of update.view.contentDOM.querySelectorAll(".cm-bc-todo")) {
        if (update.state.readOnly) box.setAttribute("aria-disabled", "true");
        else box.removeAttribute("aria-disabled");
      }
    },
  })),
  // The collapsed ranges are atomic (see the caret invariant above).
  EditorView.atomicRanges.of((view) => view.plugin(todoPlugin)?.sets.inner ?? Decoration.none),
  // Before hiding's Home (Prec.high).
  Prec.highest(keymap.of([
    { key: "Home", run: toTextStart(false), shift: toTextStart(true) },
    { mac: "Cmd-ArrowLeft", run: toTextStart(false), shift: toTextStart(true) },
  ])),
  // ⌘T / ⌘. are Format menu commands (commands.ts).
  todoTheme,
];
