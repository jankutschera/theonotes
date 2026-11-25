// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undo } from "@codemirror/commands";
import { bearMarkdown } from "../src/editor/dialect";
import type { CommandArgs, CommandName, EditLinkFields, OpenLinkFields } from "../src/bridge/protocol";
import { editorCommands } from "../src/editor/features/commands";
import { encodeLinkUrl, linkEditRequest, linkHandlers, linkTargetAt } from "../src/editor/features/links";

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

/** `‸` a caret, `«`…`»` a selection (anchor at «, head at »). */
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

/** A caret position as `stateOf` marks it. */
const at = (marked: string) => {
  const state = stateOf(marked);
  return linkTargetAt(state, state.selection.main.head);
};

function undoesInOneStep(name: CommandName, marked: string, args?: CommandArgs) {
  const before = stateOf(marked);
  const typed = parsed(before.update({ changes: { from: 0, insert: "T" }, userEvent: "input.type" }).state);
  const r = apply(name, typed, args);
  expect(r.handled, name).toBe(true);
  let undone: EditorState | null = null;
  undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
  expect((undone as EditorState | null)?.doc.toString(), name).toBe(typed.doc.toString());
}

describe("the link at a position", () => {
  test("inline links, autolinks and bare URLs are url links", () => {
    expect(at("see [te‸xt](https://example.com/a?b=1) now")).toEqual({ kind: "url", target: "https://example.com/a?b=1" });
    expect(at("<https://example.‸com>")).toEqual({ kind: "url", target: "https://example.com" });
    expect(at("go https://example.‸com/x now")).toEqual({ kind: "url", target: "https://example.com/x" });
    expect(at("[m](mailto:‸a@b.c)")).toEqual({ kind: "url", target: "mailto:a@b.c" });
    // Every scheme is reported; the host decides what it opens.
    expect(at("[x](javascript:al‸ert(1))")).toMatchObject({ kind: "url" });
  });

  test("bear:// links, attachments and images", () => {
    expect(at("[n](bear://x-callback-url/open-note?id=AB‸C-1)")).toEqual({
      kind: "bearURL",
      target: "bear://x-callback-url/open-note?id=ABC-1",
    });
    expect(at("[doc.pdf](do‸c.pdf)")).toEqual({ kind: "attachment", target: "doc.pdf" });
    expect(at("![](pho‸to%202.jpg)")).toEqual({ kind: "attachment", target: "photo%202.jpg" });
    expect(at("![](https://e.com/i‸.png)")).toEqual({ kind: "url", target: "https://e.com/i.png" });
  });

  test("wiki links: target, heading, same-note heading, alias", () => {
    expect(at("[[No‸te]]")).toEqual({ kind: "wiki", target: "Note" });
    expect(at("[[Note/Next St‸eps|later]]")).toEqual({ kind: "wiki", target: "Note", heading: "Next Steps" });
    expect(at("[[/Head‸ing]]")).toEqual({ kind: "wiki", target: "", heading: "Heading" });
    expect(at("[[Note|al‸ias]]")).toEqual({ kind: "wiki", target: "Note" });
  });

  test("tags: the tag path without #", () => {
    expect(at("a #wo‸rk b")).toEqual({ kind: "tag", target: "work" });
    expect(at("#my ta‸g# x")).toEqual({ kind: "tag", target: "my tag" });
    expect(at("#a/b/‸c")).toEqual({ kind: "tag", target: "a/b/c" });
  });

  test("nothing in plain text, code, or at a link's edge unless inclusive", () => {
    expect(at("plain te‸xt")).toBeNull();
    expect(at("`[x](https://a.b‸)`")).toBeNull();
    expect(at("```\n[[No‸te]]\n```")).toBeNull();
    const state = stateOf("[a](https://x.y) b");
    expect(linkTargetAt(state, 0)).toBeNull();
    expect(linkTargetAt(state, 16)).toBeNull();
    expect(linkTargetAt(state, 16, true)).toEqual({ kind: "url", target: "https://x.y" });
    expect(linkTargetAt(state, 0, true)).toEqual({ kind: "url", target: "https://x.y" });
  });
});

describe("⌘K: the link panel request", () => {
  const req = (marked: string) => linkEditRequest(stateOf(marked));

  test("a new link at the caret or around the selection (insert mode)", () => {
    expect(req("a ‸b")).toEqual({ from: 2, to: 2, title: "", url: "", editing: false });
    expect(req("a «site» b")).toEqual({ from: 2, to: 6, title: "site", url: "", editing: false });
    // A selected URL fills both fields; it is still a new link (minor 3).
    expect(req("see «https://example.com»")).toEqual({ from: 4, to: 23, title: "https://example.com", url: "https://example.com", editing: false });
  });

  test("inside a link, or over a selection holding a whole link, edits that link", () => {
    const link = { from: 4, to: 31, title: "Bear", url: "https://example.com", editing: true };
    expect(req("see [Be‸ar](https://example.com) now")).toEqual(link);
    expect(req("se«e [Bear](https://example.com) n»ow")).toEqual(link);
    expect(req("see [«Bear»](https://example.com) now")).toEqual(link);
    expect(req("see [Bear](https://«example».com) now")).toEqual(link);
    expect(req("[‸]()")).toEqual({ from: 0, to: 4, title: "", url: "", editing: true });
    // A shortcut or reference link has no `(url)`: insert mode, so no Remove Link.
    expect(req("[fo‸o] x")).toMatchObject({ title: "foo", url: "", editing: false });
    expect(req("[fo‸o][bar] x")).toMatchObject({ editing: false });
    // Autolinks and bare URLs become links: insert mode (no Remove Link).
    expect(req("go <https://b‸.c> x")).toEqual({ from: 3, to: 16, title: "https://b.c", url: "https://b.c", editing: false });
    expect(req("go https://b‸.c x")).toEqual({ from: 3, to: 14, title: "https://b.c", url: "https://b.c", editing: false });
  });

  test("after a triple-click the selected line's newline is left out", () => {
    expect(req("«a line\n»next")).toEqual({ from: 0, to: 6, title: "a line", url: "", editing: false });
  });

  test("refused: several lines, code, wiki links, images, two links, read-only", () => {
    expect(req("«a\nb»")).toBeNull();
    expect(req("`co‸de`")).toBeNull();
    expect(req("[[No‸te]]")).toBeNull();
    expect(req("![al‸t](x.png)")).toBeNull();
    expect(req("«[a](https://a.b) [b](https://b.c)»")).toBeNull();
    expect(linkEditRequest(stateOf("a‸", [EditorState.readOnly.of(true)]))).toBeNull();
  });

  test("⌘K sends the request with an id and the caret rect to the panel, without editing", () => {
    const requests: EditLinkFields[] = [];
    const state = stateOf("a «site» b", [linkHandlers.of({ editLink: (r) => requests.push(r) })]);
    const r = apply("link", state);
    expect(r.handled).toBe(true);
    expect(r.state.doc.toString()).toBe("a site b");
    expect(r.tr?.docChanged ?? false).toBe(false);
    expect(requests).toEqual([
      { requestId: expect.any(String), from: 2, to: 6, title: "site", url: "", editing: false, caretRect: { x: 0, y: 0, width: 0, height: 0 } },
    ]);
  });

  test("⌘K without a panel (no handler) or with a refused request does nothing", () => {
    expect(apply("link", "a «site» b").handled).toBe(false);
    const requests: EditLinkFields[] = [];
    expect(apply("link", stateOf("«a\nb»", [linkHandlers.of({ editLink: (r) => requests.push(r) })])).handled).toBe(false);
    expect(requests).toEqual([]);
  });
});

/** ⌘K on `marked`: the state holding the pending request, and its id. */
function requested(marked: string | EditorState) {
  const requests: EditLinkFields[] = [];
  const state = typeof marked === "string" ? stateOf(marked, [linkHandlers.of({ editLink: (r) => requests.push(r) })]) : marked;
  const r = apply("link", state);
  const request = requests.at(-1);
  if (!r.handled || !request) throw new Error("no link request");
  return { state: r.state, requestId: request.requestId };
}

describe("setLink (the panel's answer)", () => {
  const set = (marked: string, title: string, url: string) => {
    const { state, requestId } = requested(marked);
    return apply("setLink", state, { requestId, title, url });
  };

  test("writes [title](url) over the requested range, caret after it", () => {
    expect(set("a «site»", "Bear", "https://example.com").shown).toBe("a [Bear](https://example.com)‸");
    expect(set("a ‸", "x", "https://x.y").shown).toBe("a [x](https://x.y)‸");
  });

  test("the range follows edits made while the panel is open (I1)", () => {
    const { state, requestId } = requested("see «bear» now");
    // An external change (another window, the CLI) prepends text and edits after the range.
    const moved = parsed(state.update({ changes: [{ from: 0, insert: "Hello! " }, { from: 12, insert: " here" }] }).state);
    expect(moved.doc.toString()).toBe("Hello! see bear now here");
    const r = apply("setLink", moved, { requestId, title: "Bear", url: "https://example.com" });
    expect(r.state.doc.toString()).toBe("Hello! see [Bear](https://example.com) now here");
  });

  test("refused: the range was deleted, an unknown or reused id, missing args", () => {
    const { state, requestId } = requested("see «bear» now");
    const deleted = parsed(state.update({ changes: { from: 2, to: 12 } }).state);
    expect(apply("setLink", deleted, { requestId, title: "B", url: "https://b.c" }).handled).toBe(false);
    expect(apply("setLink", state, { requestId: "nope", title: "B", url: "https://b.c" }).handled).toBe(false);
    expect(apply("setLink", state, { title: "B", url: "https://b.c" }).handled).toBe(false);
    expect(apply("setLink", state, { requestId, title: 1, url: "https://b.c" }).handled).toBe(false);
    // An answer is used once.
    const once = apply("setLink", state, { requestId, title: "B", url: "https://b.c" });
    expect(once.handled).toBe(true);
    expect(apply("setLink", once.state, { requestId, title: "C", url: "https://c.d" }).handled).toBe(false);
  });

  test("URLs are percent-encoded on insert; existing escapes and URL syntax stay", () => {
    expect(encodeLinkUrl("https://e.com/a b/(c)")).toBe("https://e.com/a%20b/%28c%29");
    expect(encodeLinkUrl("https://e.com/ä?q=ü&x=1#frag")).toBe("https://e.com/%C3%A4?q=%C3%BC&x=1#frag");
    expect(encodeLinkUrl("https://e.com/a%20b?x=%zz")).toBe("https://e.com/a%20b?x=%25zz");
    expect(encodeLinkUrl("mailto:a@b.c?subject=Hi there")).toBe("mailto:a@b.c?subject=Hi%20there");
    expect(encodeLinkUrl("photo 2.jpg")).toBe("photo%202.jpg");
    expect(encodeLinkUrl("<x>`\"\\")).toBe("%3Cx%3E%60%22%5C");
    expect(set("‸", "t", " https://e.com/a b ").shown).toBe("[t](https://e.com/a%20b)‸");
  });

  test("an empty title shows the URL; an empty URL leaves the plain title (unlink)", () => {
    expect(set("‸", "", "https://example.com").shown).toBe("[https://example.com](https://example.com)‸");
    expect(set("x [Be‸ar](https://example.com)", "Bear", "").shown).toBe("x Bear‸");
  });

  test("an empty title and URL keep the original text (minor 2)", () => {
    expect(set("‸", "", "").handled).toBe(false);
    const r = set("a «site» b", "", "");
    expect(r.handled).toBe(false);
    expect(r.state.doc.toString()).toBe("a site b");
  });

  test("titles: newlines become spaces, unbalanced brackets and a trailing backslash are escaped", () => {
    expect(set("‸", "a\nb", "u").shown).toBe("[a b](u)‸");
    expect(set("‸", "a [b] c", "u").shown).toBe("[a [b] c](u)‸");
    expect(set("‸", "a ] b", "u").shown).toBe("[a \\] b](u)‸");
    // Minor 7: `[a\](u)` would escape the closing bracket.
    expect(set("‸", "a\\", "u").shown).toBe("[a\\\\](u)‸");
    expect(set("‸", "a\\\\", "u").shown).toBe("[a\\\\](u)‸");
  });

  test("one undo step", () => {
    const { state, requestId } = requested("a «site»");
    const r = apply("setLink", state, { requestId, title: "Bear", url: "https://example.com" });
    let undone: EditorState | null = null;
    undo({ state: r.state, dispatch: (tr) => (undone = tr.state) });
    expect((undone as EditorState | null)?.doc.toString()).toBe("a site");
  });
});

describe("⌘D: wiki link", () => {
  test("an empty selection inserts [[]] with the caret inside", () => {
    expect(shown("wikiLink", "see ‸")).toBe("see [[‸]]");
  });

  test("a selection is wrapped (blanks stay outside), caret after it", () => {
    expect(shown("wikiLink", "see «My Note» now")).toBe("see [[My Note]]‸ now");
    expect(shown("wikiLink", "see« My Note »now")).toBe("see [[My Note]]‸ now");
    expect(shown("wikiLink", "«My Note\n»x")).toBe("[[My Note]]‸\nx");
  });

  test("refused: several lines, code, inside a wiki link, brackets in the selection, read-only", () => {
    expect(apply("wikiLink", "«a\nb»").handled).toBe(false);
    expect(apply("wikiLink", "`co‸de`").handled).toBe(false);
    expect(apply("wikiLink", "[[No‸te]]").handled).toBe(false);
    expect(apply("wikiLink", "«a]] b»").handled).toBe(false);
    expect(apply("wikiLink", stateOf("a‸", [EditorState.readOnly.of(true)])).handled).toBe(false);
  });

  test("one undo step", () => {
    undoesInOneStep("wikiLink", "a «b»");
  });
});

describe("⇧⌘E: footnote", () => {
  test("inserts the reference at the caret and the definition at the end, caret in the definition", () => {
    expect(shown("footnote", "Some text‸ here")).toBe("Some text[^1] here\n\n[^1]: ‸");
    expect(shown("footnote", "a‸\n")).toBe("a[^1]\n\n[^1]: ‸");
    expect(shown("footnote", "«sel»")).toBe("sel[^1]\n\n[^1]: ‸");
  });

  test("the next number; definitions stay together at the end", () => {
    expect(shown("footnote", "a[^1] b‸\n\n[^1]: one")).toBe("a[^1] b[^2]\n\n[^1]: one\n[^2]: ‸");
  });

  test("numbers follow the references' order: earlier ones are renumbered", () => {
    expect(shown("footnote", "‸x a[^1] b[^2]\n\n[^1]: one\n[^2]: two")).toBe(
      "[^1]x a[^2] b[^3]\n\n[^2]: one\n[^3]: two\n[^1]: ‸",
    );
  });

  test("named labels and labels in code stay as they are", () => {
    expect(shown("footnote", "a[^note] `[^1]` b‸\n\n[^note]: n")).toBe("a[^note] `[^1]` b[^1]\n\n[^note]: n\n[^1]: ‸");
  });

  test("refused in code and read-only; one undo step", () => {
    expect(apply("footnote", "`co‸de`").handled).toBe(false);
    expect(apply("footnote", stateOf("a‸", [EditorState.readOnly.of(true)])).handled).toBe(false);
    undoesInOneStep("footnote", "a ‸b[^1]\n\n[^1]: x");
  });
});

describe("⇧⌘K / ⌥⇧⌘K: open the link at the caret", () => {
  test("sends the link to the host, in a new window with window: new", () => {
    const opened: OpenLinkFields[] = [];
    const ext = [linkHandlers.of({ openLink: (l) => opened.push(l) })];
    expect(apply("openLink", stateOf("[[No‸te/H]]", ext)).handled).toBe(true);
    expect(apply("openLink", stateOf("[a](https://x.y)‸", ext), { window: "new" }).handled).toBe(true);
    expect(opened).toEqual([
      { kind: "wiki", target: "Note", heading: "H", newWindow: false },
      { kind: "url", target: "https://x.y", newWindow: true },
    ]);
  });

  test("no link at the caret, or no host: nothing", () => {
    const opened: OpenLinkFields[] = [];
    expect(apply("openLink", stateOf("pla‸in", [linkHandlers.of({ openLink: (l) => opened.push(l) })])).handled).toBe(false);
    expect(apply("openLink", "[[No‸te]]").handled).toBe(false);
    expect(opened).toEqual([]);
  });

  test("works in read-only notes (opening is not editing)", () => {
    const opened: OpenLinkFields[] = [];
    const ext = [EditorState.readOnly.of(true), linkHandlers.of({ openLink: (l) => opened.push(l) })];
    expect(apply("openLink", stateOf("#ta‸g", ext)).handled).toBe(true);
    expect(opened).toEqual([{ kind: "tag", target: "tag", newWindow: false }]);
  });
});

describe("inline styles over link markup (carried from Task 5)", () => {
  const bold = (marked: string) => apply("bold", marked).state.doc.toString();

  test("an image nested in link text: a selection crossing it takes the whole image", () => {
    expect(bold("[«see ![i](x.p»ng) here](https://u.v)")).toBe("[**see ![i](x.png)** here](https://u.v)");
    expect(bold("[see «here»](https://u.v)")).toBe("[see **here**](https://u.v)");
  });

  test("autolinks and bare URLs are styled whole", () => {
    expect(bold("«go <https://a.»b> now")).toBe("**go <https://a.b>** now");
    expect(bold("<https://«a.b»>")).toBe("**<https://a.b>**");
    expect(bold("«go https://a.b/»c now")).toBe("**go https://a.b/c** now");
  });

  test("wiki links are styled whole", () => {
    expect(bold("«see [[No»te]] x")).toBe("**see [[Note]]** x");
    expect(bold("[[«Note»]]")).toBe("**[[Note]]**");
    expect(bold("[[Note|«ali»as]]")).toBe("**[[Note|alias]]**");
  });
});
