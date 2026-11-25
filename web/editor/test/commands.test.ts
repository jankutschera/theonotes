// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, describe, expect, test, vi } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { ensureSyntaxTree, foldedRanges } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undo } from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import { COMMAND_NAMES, type CommandArgs, type CommandName } from "../src/bridge/protocol";
import {
  editorCommands,
  FORMAT_SHORTCUTS,
  formatDate,
  formatState,
  isFormatShortcut,
  runCommand,
  runHostCommand,
} from "../src/editor/features/commands";
import { addPendingInsert, pendingInserts } from "../src/editor/features/attachments";
import { menuTargetEffect, menuTargets } from "../src/editor/features/menu-targets";
import { folding } from "../src/editor/features/folding";

const shortcutFixture = Object.values(
  import.meta.glob("../../../Fixtures/bridge/format-shortcuts.json", { eager: true, import: "default" }),
)[0] as { shortcut: string; key: string; command: string; args?: CommandArgs }[];

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

/**
 * A document with the selection marked: `‸` a caret, `«`…`»` a selection (anchor at «, head at »).
 */
function stateOf(marked: string, extensions: Extension[] = []): EditorState {
  let doc = "";
  let anchor = -1;
  let head = -1;
  for (const ch of marked) {
    if (ch === "‸") anchor = head = doc.length;
    else if (ch === "«") anchor = doc.length;
    else if (ch === "»") head = doc.length;
    else doc += ch;
  }
  if (anchor < 0) anchor = head = doc.length;
  return parsed(
    EditorState.create({
      doc,
      selection: EditorSelection.single(anchor, head),
      extensions: [markdown({ base: bearMarkdown }), history(), ...extensions],
    }),
  );
}

/** The document with the main selection marked like `stateOf` takes it. */
function show(state: EditorState): string {
  const { anchor, head } = state.selection.main;
  const doc = state.doc.toString();
  if (anchor === head) return doc.slice(0, head) + "‸" + doc.slice(head);
  const [from, to] = [Math.min(anchor, head), Math.max(anchor, head)];
  const [open, close] = anchor <= head ? ["«", "»"] : ["»", "«"];
  return doc.slice(0, from) + open + doc.slice(from, to) + close + doc.slice(to);
}

function apply(name: CommandName, marked: string | EditorState, args?: CommandArgs) {
  const state = typeof marked === "string" ? stateOf(marked) : marked;
  let tr: Transaction | null = null;
  const handled = editorCommands[name]({ state, dispatch: (t) => (tr = t) }, args);
  const t = tr as Transaction | null;
  const next = t ? parsed(t.state) : state;
  return { handled, tr: t, state: next, shown: show(next) };
}

const shown = (name: CommandName, marked: string, args?: CommandArgs) => apply(name, marked, args).shown;

afterEach(() => {
  vi.useRealTimers();
});

describe("the command registry", () => {
  test("implements every CommandName of the protocol", () => {
    expect(Object.keys(editorCommands).sort()).toEqual([...COMMAND_NAMES].sort());
  });

  test("the shortcuts are the shared table Fixtures/bridge/format-shortcuts.json", () => {
    expect(FORMAT_SHORTCUTS.map(({ key, command, args }) => ({ key, command, ...(args && { args }) }))).toEqual(
      shortcutFixture.map(({ key, command, args }) => ({ key, command, ...(args && { args }) })),
    );
    for (const s of FORMAT_SHORTCUTS) expect(COMMAND_NAMES).toContain(s.command);
  });

  test("every command is one undo step", () => {
    const cases: [CommandName, string, CommandArgs?][] = [
      ["bold", "a «b» c"],
      ["highlight", "‸", { color: "green" }],
      ["heading", "x‸", { level: 3 }],
      ["bulletList", "«a\nb»"],
      ["orderedList", "«a\nb»"],
      ["quote", "a‸"],
      ["codeBlock", "a‸"],
      ["horizontalRule", "a‸"],
      ["wikiLink", "«a»"],
      ["footnote", "a‸"],
      ["insertText", "a‸", { text: "xyz" }],
      ["replaceRange", "abc‸", { from: 0, to: 1, expect: "T", text: "Z" }],
      ["pasteCode", "a‸", { text: "x\ny" }],
      ["insertDate", "a‸", { style: "short" }],
    ];
    for (const [name, marked, args] of cases) {
      const before = stateOf(marked);
      const typed = parsed(before.update({ changes: { from: 0, insert: "T" }, userEvent: "input.type" }).state);
      const r = apply(name, typed, args);
      expect(r.handled, name).toBe(true);
      let undone: EditorState | null = null;
      undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
      expect((undone as EditorState | null)?.doc.toString(), name).toBe(typed.doc.toString());
    }
  });

  test("read-only notes are never changed", () => {
    const ro = [EditorState.readOnly.of(true)];
    for (const name of ["bold", "heading", "bulletList", "quote", "codeBlock", "insertText"] as const) {
      const args = name === "heading" ? { level: 1 } : name === "insertText" ? { text: "x" } : undefined;
      expect(apply(name, stateOf("a «b» c", ro), args).handled, name).toBe(false);
    }
  });
});

describe("inline styles toggle", () => {
  test("a selection is wrapped and stays selected; again removes the style", () => {
    expect(shown("bold", "a «word» b")).toBe("a **«word»** b");
    expect(shown("bold", "a **«word»** b")).toBe("a «word» b");
    expect(shown("italic", "a «word» b")).toBe("a _«word»_ b");
    expect(shown("italic", "a _«word»_ b")).toBe("a «word» b");
    expect(shown("underline", "a «word» b")).toBe("a ~«word»~ b");
    expect(shown("strike", "a «word» b")).toBe("a ~~«word»~~ b");
    expect(shown("highlight", "a «word» b")).toBe("a ==«word»== b");
    expect(shown("inlineCode", "a «word» b")).toBe("a `«word»` b");
    expect(shown("inlineCode", "a `«word»` b")).toBe("a «word» b");
  });

  test("a backwards selection stays backwards", () => {
    expect(shown("bold", "a »word« b")).toBe("a **»word«** b");
  });

  test("an empty selection inserts the pair with the caret inside", () => {
    expect(shown("bold", "a ‸ b")).toBe("a **‸** b");
    expect(shown("strike", "‸")).toBe("~~‸~~");
    expect(shown("inlineCode", "x ‸")).toBe("x `‸`");
  });

  test("a caret inside a styled span removes that style", () => {
    expect(shown("bold", "a **bo‸ld** b")).toBe("a bo‸ld b");
    expect(shown("bold", "**‸bold**")).toBe("‸bold");
    expect(shown("highlight", "==🔴re‸d==")).toBe("re‸d");
    expect(shown("italic", "*it‸alic*")).toBe("it‸alic");
  });

  test("nested styles: adding inside another style, removing only the requested one", () => {
    expect(shown("italic", "**«bold»**")).toBe("**_«bold»_**");
    expect(shown("bold", "**_«bold»_**")).toBe("_«bold»_");
    expect(shown("highlight", "**«b»**")).toBe("**==«b»==**");
    expect(shown("underline", "# «Head»")).toBe("# ~«Head»~");
  });

  test("intraword italic uses `*` (an intraword `_` is not emphasis)", () => {
    expect(shown("italic", "foo«bar»baz")).toBe("foo*«bar»*baz");
  });

  test("a partly styled selection becomes styled as a whole", () => {
    expect(shown("bold", "«a **b** c»")).toBe("**«a b c»**");
    expect(shown("bold", "«a **b» c**")).toBe("**«a b» c**");
  });

  test("leading and trailing blanks stay outside the marks", () => {
    expect(apply("bold", "a« word »b").state.doc.toString()).toBe("a **word** b");
  });

  test("a multi-line selection styles each line's text, not list markers or quotes", () => {
    expect(shown("bold", "- «a\n- b»")).toBe("- **«a**\n- **b»**");
    expect(shown("bold", "«> one\n\n> two»")).toBe("«> **one**\n\n> **two»**");
    expect(shown("bold", "- **«a**\n- **b»**")).toBe("- «a\n- b»");
  });

  test("highlight colors: add, change, remove", () => {
    expect(shown("highlight", "«a»", { color: "red" })).toBe("==🔴«a»==");
    expect(shown("highlight", "==🔴«a»==", { color: "blue" })).toBe("==🔵«a»==");
    expect(shown("highlight", "==«a»==", { color: "green" })).toBe("==🟢«a»==");
    expect(shown("highlight", "==🔴«a»==", { color: "red" })).toBe("«a»");
    expect(shown("highlight", "==🔴«a»==")).toBe("«a»");
    expect(shown("highlight", "‸", { color: "yellow" })).toBe("==🟡‸==");
    expect(apply("highlight", "«a»", { color: "orange" }).handled).toBe(false);
  });

  test("inline code around backticks uses a longer fence", () => {
    expect(apply("inlineCode", "«a`b»").state.doc.toString()).toBe("``a`b``");
    expect(apply("inlineCode", "«`a»").state.doc.toString()).toBe("`` `a ``");
  });

  test("never touches text inside code: disabled in code blocks and code spans", () => {
    expect(apply("bold", "```\nco‸de\n```").handled).toBe(false);
    expect(apply("bold", "```\n«code»\n```").handled).toBe(false);
    expect(apply("bold", "`co‸de`").handled).toBe(false);
    expect(apply("italic", "`«co»de`").handled).toBe(false);
    expect(apply("inlineCode", "```\nco‸de\n```").handled).toBe(false);
    // Inside a code span, inline code itself toggles off.
    expect(shown("inlineCode", "`co‸de`")).toBe("co‸de");
    // Around a whole code span is fine.
    expect(shown("bold", "«a `b` c»")).toBe("**«a `b` c»**");
  });

  test("multiple selection ranges", () => {
    const state = parsed(
      EditorState.create({
        doc: "one two",
        selection: EditorSelection.create([EditorSelection.range(0, 3), EditorSelection.range(4, 7)]),
        extensions: [markdown({ base: bearMarkdown }), EditorState.allowMultipleSelections.of(true)],
      }),
    );
    expect(apply("bold", state).state.doc.toString()).toBe("**one** **two**");
  });
});

describe("fix round 1: code blocks, tildes, links", () => {
  const blocks = [
    "a\n```\nx\n```\nb",
    "a\n```js\nlet x = 1\n```\nb",
    "a\n$$\nx^2\n$$\nb",
    "a\n<!--\nnote\n-->\nb",
  ];

  test("⌘A + ⌘B / ⇧⌘U / ⌥⌘C over a note with a block leave the block byte-identical (I1)", () => {
    for (const doc of blocks) {
      const block = doc.slice(2, -2);
      for (const name of ["bold", "strike", "inlineCode", "italic", "highlight"] as const) {
        const r = apply(name, `«${doc}»`);
        const text = r.state.doc.toString();
        expect(text, `${name} ${JSON.stringify(doc)}`).toContain(`\n${block}\n`);
        expect(text.startsWith(STYLE_OPEN[name] + "a"), name).toBe(true);
      }
    }
  });

  test("toggling back after styling around a block restores the note", () => {
    const once = apply("bold", `«${blocks[0]}»`).state;
    expect(once.doc.toString()).toBe("**a**\n```\nx\n```\n**b**");
    expect(apply("bold", once).state.doc.toString()).toBe(blocks[0]);
  });

  test("R11: underline or strike touching an existing ~ run is refused, handled, no change (I2)", () => {
    const cases: [CommandName, string][] = [
      // underline against strike, start of line and mid-line
      ["underline", "~~«a»~~"],
      ["underline", "x ~~«a»~~ y"],
      ["underline", "«~~a~~»"],
      ["underline", "x «~~a~~» y"],
      // strike against underline
      ["strike", "~«a»~"],
      ["strike", "x ~«a»~ y"],
      ["strike", "«~a~»"],
      ["strike", "x «~a~» y"],
      // an empty pair next to a tilde
      ["underline", "~~‸"],
      ["strike", "x~‸"],
    ];
    for (const [name, marked] of cases) {
      const r = apply(name, marked);
      expect(r.handled, `${name} ${marked}`).toBe(true);
      expect(r.tr, `${name} ${marked}`).toBeNull();
    }
    // Not touching: fine.
    expect(apply("underline", "~~a~~ «b»").state.doc.toString()).toBe("~~a~~ ~b~");
    expect(apply("strike", "~a~ «b»").state.doc.toString()).toBe("~a~ ~~b~~");
  });

  test("a selection crossing a link boundary styles the whole link (minor 2)", () => {
    expect(apply("bold", "«see [li»nk](https://x.y) now").state.doc.toString()).toBe("**see [link](https://x.y)** now");
    expect(apply("bold", "[link](https://«x.y) no»w").state.doc.toString()).toBe("**[link](https://x.y) no**w");
    expect(apply("bold", "[link](https://«x.y»)").state.doc.toString()).toBe("**[link](https://x.y)**");
    // Inside the link text is fine as it is.
    expect(apply("bold", "[«li»nk](https://x.y)").state.doc.toString()).toBe("[**li**nk](https://x.y)");
  });

  test("⌘K over several lines is refused (minor 2)", () => {
    expect(apply("link", "«a\nb»").handled).toBe(false);
  });
});

const STYLE_OPEN: Record<string, string> = { bold: "**", strike: "~~", inlineCode: "`", italic: "_", highlight: "==" };

describe("IME and history (I3, minor 1)", () => {
  test("no command runs while composing", () => {
    const state = stateOf("a «b» c");
    let dispatched = 0;
    const composing = { state, dispatch: () => dispatched++, composing: true };
    expect(runCommand(composing, "bold")).toBe(false);
    expect(runCommand(composing, "heading", { level: 1 })).toBe(false);
    expect(dispatched).toBe(0);
    expect(runCommand({ state, dispatch: () => dispatched++, composing: false }, "bold")).toBe(true);
    expect(dispatched).toBe(1);
  });

  test("an attachment insert answered during a composition waits for compositionend (minor M1)", async () => {
    const base = stateOf("ab‸", [pendingInserts]);
    const view = {
      state: parsed(base.update({ effects: addPendingInsert.of({ id: "d", from: 2, to: 2 }) }).state),
      dispatch(tr: Transaction) {
        view.state = tr.state;
      },
      composing: true,
      contentDOM: new EventTarget(),
    };
    expect(runHostCommand(view, "insertText", { text: "![](x.png)", insertId: "d" })).toBe(true);
    expect(view.state.doc.toString()).toBe("ab");
    // Menu commands still do nothing while composing.
    expect(runHostCommand(view, "bold")).toBe(false);
    // The composed text lands first; the insert follows once the composition ends, at the drop
    // point (text typed at that point stays after it).
    view.state = view.state.update({ changes: { from: 2, insert: "é" } }).state;
    view.composing = false;
    view.contentDOM.dispatchEvent(new Event("compositionend"));
    await new Promise((r) => setTimeout(r));
    expect(view.state.doc.toString()).toBe("ab![](x.png)é");
    expect(view.state.field(pendingInserts).size).toBe(0);
  });

  test("indent / outdent are one transaction and one undo step", () => {
    for (const [name, marked] of [
      ["outdent", "- a\n  - b‸"],
      ["indent", "- a\n- b‸"],
      ["indent", "plain‸"],
      ["outdent", "  plain‸"],
    ] as const) {
      const start = stateOf(marked);
      const typed = parsed(start.update({ changes: { from: start.doc.length, insert: "T" }, userEvent: "input.type" }).state);
      const trs: Transaction[] = [];
      expect(editorCommands[name]({ state: typed, dispatch: (tr) => trs.push(tr) }), marked).toBe(true);
      expect(trs, marked).toHaveLength(1);
      expect(trs[0]!.docChanged, marked).toBe(true);
      let undone: EditorState | null = null;
      undo({ state: trs[0]!.state, dispatch: (tr) => (undone = tr.state) });
      expect((undone as EditorState | null)?.doc.toString(), marked).toBe(typed.doc.toString());
      // Typing right after it is a step of its own.
      const after = trs[0]!.state.update({ changes: { from: 0, insert: "U" }, userEvent: "input.type" }).state;
      let back: EditorState | null = null;
      undo({ state: after, dispatch: (tr) => (back = tr.state) });
      expect((back as EditorState | null)?.doc.toString(), marked).toBe(trs[0]!.state.doc.toString());
    }
  });
});

describe("headings", () => {
  test("sets, changes and toggles off the level", () => {
    expect(shown("heading", "Ti‸tle", { level: 2 })).toBe("## Ti‸tle");
    expect(shown("heading", "## Ti‸tle", { level: 2 })).toBe("Ti‸tle");
    expect(shown("heading", "## Ti‸tle", { level: 1 })).toBe("# Ti‸tle");
    expect(shown("heading", "###### Ti‸tle", { level: 6 })).toBe("Ti‸tle");
    expect(shown("heading", "‸", { level: 3 })).toBe("### ‸");
  });

  test("after quotes and list markers; blank lines of a multi-line selection are skipped", () => {
    expect(shown("heading", "> a‸", { level: 1 })).toBe("> # a‸");
    expect(shown("heading", "- it‸em", { level: 2 })).toBe("- ## it‸em");
    expect(apply("heading", "«a\n\nb»", { level: 1 }).state.doc.toString()).toBe("# a\n\n# b");
  });

  test("heading with a menuId changes that line, not the selection", () => {
    const doc = "# One\n\nsecond line\n\n## Two";
    const withTarget = (at: number) => {
      const base = stateOf("# One\n\nsecond ‸line\n\n## Two", [menuTargets]);
      return base.update({ effects: menuTargetEffect.of({ id: "m1", pos: at }) }).state;
    };
    const state = withTarget(doc.indexOf("## Two"));
    const r = apply("heading", state, { level: 3, menuId: "m1" });
    expect(r.handled).toBe(true);
    expect(r.state.doc.toString()).toBe("# One\n\nsecond line\n\n### Two");
    // The caret stays on the line it was on.
    expect(r.shown).toBe("# One\n\nsecond ‸line\n\n### Two");
    // The checked level toggles the heading off, like the shortcut.
    expect(apply("heading", state, { level: 2, menuId: "m1" }).state.doc.toString()).toBe("# One\n\nsecond line\n\nTwo");
    // The target follows an edit made while the menu was open.
    const moved = state.update({ changes: { from: 0, insert: "intro\n" } }).state;
    expect(apply("heading", moved, { level: 1, menuId: "m1" }).state.doc.toString()).toBe("intro\n# One\n\nsecond line\n\n# Two");
    // Without a menuId the selection decides, as before.
    expect(apply("heading", state, { level: 1 }).state.doc.toString()).toBe("# One\n\n# second line\n\n## Two");
  });

  test("a menuId that no longer resolves does nothing, and never falls back to the selection", () => {
    const base = stateOf("one\n‸two\nthree", [menuTargets]);
    const state = base.update({ effects: menuTargetEffect.of({ id: "m1", pos: base.doc.line(3).from }) }).state;
    // The text the target pointed into is gone.
    const gone = state.update({ changes: { from: state.doc.line(2).to, to: state.doc.length } }).state;
    expect(apply("heading", gone, { level: 1, menuId: "m1" }).handled).toBe(false);
    expect(apply("heading", state, { level: 1, menuId: "unknown" }).handled).toBe(false);
    expect(apply("heading", state, { level: 1, menuId: 7 }).handled).toBe(false);
    // A target inside a code block is rejected like a selection there.
    const code = stateOf("```\nco‸de\n```\n# T", [menuTargets]);
    const inCode = code.update({ effects: menuTargetEffect.of({ id: "c", pos: 4 }) }).state;
    expect(apply("heading", inCode, { level: 1, menuId: "c" }).handled).toBe(false);
  });

  test("code and invalid levels are rejected", () => {
    expect(apply("heading", "```\nco‸de\n```", { level: 1 }).handled).toBe(false);
    expect(apply("heading", "a‸").handled).toBe(false);
    expect(apply("heading", "a‸", { level: 7 }).handled).toBe(false);
    expect(apply("heading", "a‸", { level: "2" }).handled).toBe(false);
  });
});

describe("lists and quotes", () => {
  test("⌘L: bullets on, off; converts ordered items and todos", () => {
    expect(shown("bulletList", "a‸")).toBe("- a‸");
    expect(shown("bulletList", "- a‸")).toBe("a‸");
    expect(shown("bulletList", "‸")).toBe("- ‸");
    expect(apply("bulletList", "«1. a\n2. b»").state.doc.toString()).toBe("- a\n- b");
    expect(apply("bulletList", "- [ ] a‸").state.doc.toString()).toBe("- a");
    expect(apply("bulletList", "«a\n\nb»").state.doc.toString()).toBe("- a\n\n- b");
    expect(apply("bulletList", "-‸").state.doc.toString()).toBe("- ");
    expect(apply("bulletList", "> a‸").state.doc.toString()).toBe("> - a");
  });

  test("⌘L skips headings and code", () => {
    expect(apply("bulletList", "# H‸").handled).toBe(false);
    expect(apply("bulletList", "```\nco‸de\n```").handled).toBe(false);
  });

  test("⇧⌘L: numbered on (renumbered), off", () => {
    expect(apply("orderedList", "«a\nb\nc»").state.doc.toString()).toBe("1. a\n2. b\n3. c");
    expect(apply("orderedList", "«1. a\n2. b»").state.doc.toString()).toBe("a\nb");
    expect(apply("orderedList", "«- a\n- b»").state.doc.toString()).toBe("1. a\n2. b");
    expect(apply("orderedList", "1. x\nb‸").state.doc.toString()).toBe("1. x\n2. b");
  });

  test("⇧⌘T: quote on, off; blank lines inside stay in the quote", () => {
    expect(shown("quote", "a‸")).toBe("> a‸");
    expect(shown("quote", "> a‸")).toBe("a‸");
    expect(apply("quote", "«a\n\nb»").state.doc.toString()).toBe("> a\n>\n> b");
    expect(apply("quote", "«> a\n>\n> b»").state.doc.toString()).toBe("a\n\nb");
    expect(shown("quote", "‸")).toBe("> ‸");
  });

  test("todos, indentation and moving lines reuse the list and todo commands", () => {
    expect(apply("todo", "a‸").state.doc.toString()).toBe("- [ ] a");
    expect(apply("toggleTodo", "- [ ] a‸").state.doc.toString()).toBe("- [x] a");
    expect(apply("moveCheckedToBottom", "- [x] a\n- [ ] b‸").state.doc.toString()).toBe("- [ ] b\n- [x] a");
    expect(apply("indent", "- a\n- b‸").state.doc.toString()).toBe("- a\n  - b");
    expect(apply("outdent", "- a\n  - b‸").state.doc.toString()).toBe("- a\n- b");
    expect(apply("indent", "a‸").state.doc.toString()).toBe("  a");
    expect(apply("moveLineUp", "a\nb‸").state.doc.toString()).toBe("b\na");
    expect(apply("moveLineDown", "a‸\nb").state.doc.toString()).toBe("b\na");
  });
});

describe("blocks", () => {
  test("⌃⌘C: wraps lines in a fence, an empty line gets an empty block, inside a block removes it", () => {
    expect(shown("codeBlock", "‸")).toBe("```\n‸\n```");
    expect(shown("codeBlock", "a\n‸\nb")).toBe("a\n```\n‸\n```\nb");
    expect(apply("codeBlock", "«a\nb»").state.doc.toString()).toBe("```\na\nb\n```");
    expect(shown("codeBlock", "co‸de")).toBe("```\nco‸de\n```");
    expect(shown("codeBlock", "x\n```\nco‸de\n```\ny")).toBe("x\nco‸de\ny");
    expect(shown("codeBlock", "```js\na‸\n```")).toBe("a‸");
  });

  test("⌥⌘S: a line separator on its own line, caret below it", () => {
    expect(shown("horizontalRule", "a‸")).toBe("a\n---\n‸");
    expect(shown("horizontalRule", "‸")).toBe("---\n‸");
    expect(shown("horizontalRule", "a\n‸\nb")).toBe("a\n---\n‸\nb");
  });

  test("⌘K opens the link panel (links.test.ts) and never edits the text itself", () => {
    expect(apply("link", "«site»").tr).toBeNull();
    expect(apply("link", "`co‸de`").handled).toBe(false);
  });

  test("setLink only answers a ⌘K request (links.test.ts): a bare range is refused", () => {
    expect(apply("setLink", "site‸", { from: 0, to: 4, title: "Bear", url: "https://example.com" }).handled).toBe(false);
    expect(apply("setLink", "site‸").handled).toBe(false);
  });

  test("insertText replaces the selection", () => {
    expect(shown("insertText", "a«b»c", { text: "![](x.png)" })).toBe("a![](x.png)‸c");
    expect(apply("insertText", "a‸").handled).toBe(false);
  });

  test("insertText with an insertId fills that pending insert (drop point or pasted-over range), once", () => {
    const base = stateOf("a«b»c", [pendingInserts]);
    const pending = parsed(base.update({ effects: addPendingInsert.of({ id: "d", from: 3, to: 3 }) }).state);
    const r = apply("insertText", pending, { text: "![](x.png)", insertId: "d" });
    expect(r.shown).toBe("abc![](x.png)‸");
    expect(r.state.field(pendingInserts).size).toBe(0);
    expect(apply("insertText", r.state, { text: "x", insertId: "d" }).handled).toBe(false);
    expect(apply("insertText", pending, { text: "x", insertId: "unknown" }).handled).toBe(false);
    // The host gave up: an empty text only drops the pending insert.
    const dropped = apply("insertText", pending, { text: "", insertId: "d" });
    expect(dropped.handled).toBe(true);
    expect(dropped.state.doc.toString()).toBe("abc");
    expect(dropped.state.field(pendingInserts).size).toBe(0);
    const over = parsed(base.update({ effects: addPendingInsert.of({ id: "p", from: 1, to: 2 }) }).state);
    expect(apply("insertText", over, { text: "Z", insertId: "p" }).shown).toBe("aZ‸c");
  });

  test("replaceRange (attachment rename/delete/metadata) only applies to the text it expects", () => {
    expect(shown("replaceRange", "x ![](a.png) y‸", { from: 2, to: 12, expect: "![](a.png)", text: "![](b.png)" })).toBe("x ![](b.png)‸ y");
    expect(shown("replaceRange", "x ![](a.png) y‸", { from: 2, to: 12, expect: "![](a.png)", text: "" })).toBe("x ‸ y");
    // Stale positions (the text moved) do nothing.
    expect(apply("replaceRange", "xx ![](a.png)‸", { from: 2, to: 12, expect: "![](a.png)", text: "" }).handled).toBe(false);
    expect(apply("replaceRange", "x‸", { from: 0, to: 5, expect: "x", text: "" }).handled).toBe(false);
  });

  test("replaceRange with keepSelection maps the caret and does not scroll", () => {
    // A tag appended at the end: the caret mid-text stays on the same character.
    const append = apply("replaceRange", "Plan the‸ week\n\n#idea", { from: 20, to: 20, expect: "", text: "x", keepSelection: true });
    expect(append.handled).toBe(true);
    expect(append.shown).toBe("Plan the‸ week\n\n#ideax");
    expect(append.tr!.scrollIntoView).toBe(false);
    // A tag before the caret is replaced: the caret follows the text after it.
    const before = apply("replaceRange", "#idea hello‸ world", { from: 1, to: 5, expect: "idea", text: "log", keepSelection: true });
    expect(before.shown).toBe("#log hello‸ world");
    expect(before.tr!.scrollIntoView).toBe(false);
    // Without the flag the caret still lands after the new text (attachments).
    expect(apply("replaceRange", "a‸b #idea", { from: 3, to: 8, expect: "#idea", text: "#log" }).tr!.scrollIntoView).toBe(true);
    // One undo step.
    const typed = parsed(stateOf("Plan‸ x").update({ changes: { from: 0, insert: "T" }, userEvent: "input.type" }).state);
    const r = apply("replaceRange", typed, { from: 7, to: 7, expect: "", text: "\n\n#idea", keepSelection: true });
    let undone: EditorState | null = null;
    undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
    expect((undone as EditorState | null)?.doc.toString()).toBe(typed.doc.toString());
  });

  test("insertFile is the host's (no editor change)", () => {
    expect(apply("insertFile", "a‸").handled).toBe(false);
  });

  test("toggleFold, foldAll and unfoldAll fold without editing (folding.ts)", () => {
    const state = stateOf("# a‸\nbody\n# b\nmore", [folding]);
    const folded = apply("toggleFold", state);
    expect(folded.handled).toBe(true);
    expect(folded.tr!.docChanged).toBe(false);
    expect(foldedRanges(folded.state).size).toBe(1);
    expect(apply("foldAll", state).handled).toBe(true);
    expect(foldedRanges(apply("unfoldAll", apply("foldAll", state).state).state).size).toBe(0);
    // Without the folding extension there is nothing to fold into.
    expect(apply("toggleFold", "# a‸\nbody").handled).toBe(false);
  });
});

describe("dates", () => {
  test("Bear's formats (inventory §2.2.1)", () => {
    const date = new Date(2017, 6, 11, 10, 43);
    expect(formatDate("longTime", date)).toBe("11 Jul 2017, 10:43");
    expect(formatDate("long", date)).toBe("11 Jul 2017");
    expect(formatDate("short", date)).toBe("11/07/2017");
    expect(formatDate("hours", date)).toBe("10:43");
    const early = new Date(2026, 0, 3, 7, 5);
    expect(formatDate("long", early)).toBe("3 Jan 2026");
    expect(formatDate("short", early)).toBe("03/01/2026");
    expect(formatDate("hours", early)).toBe("07:05");
  });

  test("insertDate inserts at the caret; an unknown style is rejected", () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2017, 6, 11, 10, 43));
    expect(shown("insertDate", "on ‸", { style: "longTime" })).toBe("on 11 Jul 2017, 10:43‸");
    expect(shown("insertDate", "«x»", { style: "hours" })).toBe("10:43‸");
    expect(apply("insertDate", "‸", { style: "iso" }).handled).toBe(false);
    expect(apply("insertDate", "‸").handled).toBe(false);
  });
});

describe("select all (⌘A)", () => {
  test("inside a code block: the block first, then the whole note", () => {
    const first = apply("selectAll", "x\n```\nco‸de\nmore\n```\ny");
    expect(first.shown).toBe("x\n```\n«code\nmore»\n```\ny");
    expect(apply("selectAll", first.state).shown).toBe("«x\n```\ncode\nmore\n```\ny»");
  });

  test("from a fence line, in an unclosed block, in a quoted block; an empty block selects the note", () => {
    expect(shown("selectAll", "x\n```sw‸ift\ncode\n```")).toBe("x\n```swift\n«code»\n```");
    expect(shown("selectAll", "x\n```\ncode\n``‸`")).toBe("x\n```\n«code»\n```");
    expect(shown("selectAll", "```\nopen‸\nrest")).toBe("```\n«open\nrest»");
    expect(shown("selectAll", "> ```\n> a‸\n> ```")).toBe("> ```\n«> a»\n> ```");
    expect(shown("selectAll", "x\n```‸\n```")).toBe("«x\n```\n```»");
  });

  test("elsewhere: the whole note, also when read-only", () => {
    expect(shown("selectAll", "a‸\nb")).toBe("«a\nb»");
    expect(apply("selectAll", stateOf("a‸", [EditorState.readOnly.of(true)])).shown).toBe("«a»");
  });
});

describe("formatState (native menu checkmarks)", () => {
  const fs = (marked: string) => formatState(stateOf(marked));

  test("inline styles at the caret or covering the selection", () => {
    expect(fs("**bo‸ld**").active).toEqual(["bold"]);
    expect(fs("**_b‸_**").active.sort()).toEqual(["bold", "italic"]);
    expect(fs("==🔴a‸==").active).toEqual(["highlight"]);
    expect(fs("~a‸~ ~~b~~").active).toEqual(["underline"]);
    expect(fs("[a‸](https://x.y)").active).toEqual(["link"]);
    expect(fs("**«bold»**").active).toEqual(["bold"]);
    expect(fs("«a **b** c»").active).toEqual([]);
    expect(fs("**bold**‸").active).toEqual([]);
  });

  test("blocks: heading level, lists, todos, quotes", () => {
    const h = fs("## **H‸**");
    expect(h.active.sort()).toEqual(["bold", "heading"]);
    expect(h.headingLevel).toBe(2);
    expect(fs("plain‸").headingLevel).toBeUndefined();
    expect(fs("- a‸").active).toEqual(["bulletList"]);
    expect(fs("1. a‸").active).toEqual(["orderedList"]);
    expect(fs("> a‸").active).toEqual(["quote"]);
    const todo = fs("- [ ] a‸");
    expect(todo.active).toEqual(["todo"]);
    expect(todo.inTodo).toBe(true);
    expect(fs("- a‸").inTodo).toBe(false);
  });

  test("code: inCode in spans and blocks", () => {
    expect(fs("`co‸de`")).toMatchObject({ active: ["inlineCode"], inCode: true });
    expect(fs("```\nco‸de\n```")).toMatchObject({ active: ["codeBlock"], inCode: true });
    expect(fs("`code`‸").inCode).toBe(false);
  });

  test("a selection over more than 2,000 lines gets an empty state (minor 3)", () => {
    const doc = Array.from({ length: 2500 }, (_, i) => `**line ${i}**`).join("\n");
    expect(formatState(stateOf(`«${doc}»`))).toEqual({ active: [], inTodo: false, inCode: false, canIndent: false });
    expect(formatState(stateOf(`«**a**»\n${doc}`)).active).toEqual(["bold"]);
  });

  test("canIndent: Tab would indent a list item", () => {
    expect(fs("- a\n- b‸").canIndent).toBe(true);
    expect(fs("- a‸").canIndent).toBe(false);
    expect(fs("text‸").canIndent).toBe(false);
  });
});

describe("shortcut ownership", () => {
  const ev = (key: string, mods: { meta?: boolean; shift?: boolean; alt?: boolean; ctrl?: boolean } = {}, keyCode = 0, code?: string) => ({
    key,
    keyCode,
    ...(code !== undefined && { code }),
    metaKey: !!mods.meta,
    shiftKey: !!mods.shift,
    altKey: !!mods.alt,
    ctrlKey: !!mods.ctrl,
  });

  test("the native menu's shortcuts are recognized, by character or key code", () => {
    expect(isFormatShortcut(ev("b", { meta: true }))).toBe(true);
    expect(isFormatShortcut(ev("B", { meta: true }))).toBe(true);
    expect(isFormatShortcut(ev("U", { meta: true, shift: true }))).toBe(true);
    expect(isFormatShortcut(ev(".", { meta: true }))).toBe(true);
    expect(isFormatShortcut(ev("&", { meta: true, shift: true }, 55))).toBe(true);
    expect(isFormatShortcut(ev("ç", { meta: true, alt: true }, 67))).toBe(true);
    expect(isFormatShortcut(ev("c", { meta: true, ctrl: true }))).toBe(true);
    expect(isFormatShortcut(ev("0", { meta: true, ctrl: true, shift: true }, 48))).toBe(true);
    expect(isFormatShortcut(ev("ArrowUp", { meta: true, alt: true }))).toBe(true);
  });

  test("the table and fold shortcuts (bridge v3) belong to the menu too", () => {
    expect(isFormatShortcut(ev("†", { meta: true, alt: true }, 84))).toBe(true); // ⌥⌘T
    expect(isFormatShortcut(ev("ArrowDown", { meta: true, ctrl: true }))).toBe(true); // ⌃⌘↓
    expect(isFormatShortcut(ev("ArrowRight", { meta: true, ctrl: true }))).toBe(true); // ⌃⌘→
    expect(isFormatShortcut(ev("Backspace", { meta: true, ctrl: true }))).toBe(true); // ⌃⌘⌫
    expect(isFormatShortcut(ev("Backspace", { meta: true, ctrl: true, shift: true }))).toBe(true); // ⌃⇧⌘⌫
    expect(isFormatShortcut(ev("'", { meta: true }))).toBe(true); // ⌘'
    expect(isFormatShortcut(ev("Backspace", { meta: true }))).toBe(false); // delete line stays CodeMirror's
  });

  test("⌘' is the physical quote key (M6-R5): other layouts type another character there", () => {
    // Matched by `code` ("Quote", the native keyCode 39), like the native menu.
    expect(isFormatShortcut(ev("ä", { meta: true }, 222, "Quote"))).toBe(true); // German
    expect(isFormatShortcut(ev("é", { meta: true }, 0, "Quote"))).toBe(true);
    expect(isFormatShortcut(ev("ä", { meta: true }, 0))).toBe(false); // not by the character alone
    expect(isFormatShortcut(ev("ä", { meta: true }, 222))).toBe(false); // nor by the legacy key code
    expect(isFormatShortcut(ev("'", { meta: true }, 0, "Backslash"))).toBe(true); // the character "'" itself (US)
    expect(isFormatShortcut(ev("ä", { meta: true, shift: true }, 222, "Quote"))).toBe(false);
  });

  test("everything else stays with the editor", () => {
    expect(isFormatShortcut(ev("z", { meta: true }))).toBe(false);
    expect(isFormatShortcut(ev("a", { meta: true }))).toBe(false);
    expect(isFormatShortcut(ev("b", { ctrl: true }))).toBe(false);
    expect(isFormatShortcut(ev("b"))).toBe(false);
    expect(isFormatShortcut(ev("0", { meta: true, shift: true }, 48))).toBe(false);
    expect(isFormatShortcut(ev("ArrowUp", { alt: true }))).toBe(false);
  });
});
