// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { runCommand } from "../src/editor/features/commands";
import { codeBlockHandlers } from "../src/editor/features/codeblocks";
import { menuTargetEffect, menuTargets } from "../src/editor/features/menu-targets";
import { tableAt } from "../src/editor/features/table-model";
import { tableAsCSV, tableAsHTML, tableAsMarkdown } from "../src/editor/features/table-copy";

// CodeMirror bounds every parse slice by Date.now(); under machine load the
// slices run out and the state's tree stays partial. Freezing only Date makes
// the parse budgets unlimited here, so these tests check results, not timing.
beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
});
afterEach(() => {
  vi.useRealTimers();
});

// M6 Task 6: Copy Table As CSV / HTML / Markdown. The text of a cell is what the grid shows
// (markup hidden, `\|` unescaped, `<br>` a line break); the Markdown copy is the exact source.

function make(doc: string, extra: Extension[] = [], head = 0): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(head),
    extensions: [markdown({ base: bearMarkdown }), menuTargets, ...extra],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function model(state: EditorState, pos = 0) {
  const m = tableAt(state, pos);
  if (!m) throw new Error("no table");
  return m;
}

describe("Copy Table As", () => {
  test("CSV quotes commas, quotes and newlines", () => {
    const doc = [
      "| Name | Note |",
      "|---|---|",
      '| a, b | say "hi" |',
      "| line<br>two | plain |",
      "| x \\| y | `a,b` |",
      "| only |",
    ].join("\n");
    const state = make(doc);
    expect(tableAsCSV(state, model(state))).toBe(
      ["Name,Note", '"a, b","say ""hi"""', '"line\ntwo",plain', 'x | y,"a,b"', "only,"].join("\r\n"),
    );
  });

  test("CSV keeps cells that start with = + - @ unchanged (M6-R53)", () => {
    const state = make("| a | b |\n|---|---|\n| =1+1 | +2 |\n| -3 | @x |");
    expect(tableAsCSV(state, model(state))).toBe("a,b\r\n=1+1,+2\r\n-3,@x");
  });

  test("CSV shows the text the grid shows: markup is dropped", () => {
    const doc = "| **Bold** | [[Wiki]] |\n|---|---|\n| [link](https://a.b) | ==mark== ~~gone~~ |";
    const state = make(doc);
    expect(tableAsCSV(state, model(state))).toBe("Bold,Wiki\r\nlink,mark gone");
  });

  test("HTML escapes and keeps inline markup", () => {
    const doc = [
      "| **Item** | Price <b> |",
      "|---|--:|",
      "| *new* ==hot== ~~old~~ `a<b` | 5 & 6 |",
      "| [site](https://a.b/?x=1&y=2) [[Note]] | <script>alert(1)</script> |",
      "| a<br>b | [bad](javascript:alert(1)) |",
    ].join("\n");
    const state = make(doc);
    expect(tableAsHTML(state, model(state))).toBe(
      "<table><thead><tr><th><strong>Item</strong></th><th>Price &lt;b&gt;</th></tr></thead><tbody>" +
        "<tr><td><em>new</em> <mark>hot</mark> <del>old</del> <code>a&lt;b</code></td><td>5 &amp; 6</td></tr>" +
        '<tr><td><a href="https://a.b/?x=1&amp;y=2">site</a> Note</td><td>&lt;script&gt;alert(1)&lt;/script&gt;</td></tr>' +
        "<tr><td>a<br>b</td><td>bad</td></tr></tbody></table>",
    );
  });

  test("HTML with nested markup and a header-only table", () => {
    const state = make("| ***both*** [**bold link**](http://x.y) |\n|---|");
    expect(tableAsHTML(state, model(state))).toBe(
      '<table><thead><tr><th><strong><em>both</em></strong> <a href="http://x.y"><strong>bold link</strong></a></th></tr></thead><tbody></tbody></table>',
    );
  });

  test("Markdown is the exact source", () => {
    const doc = "intro\n\n|  A | B |\n|:--|--:|\n| x \\| y | `c|d` |\n| ragged |\n\nafter";
    const at = doc.indexOf("| x");
    const state = make(doc, [], at);
    expect(tableAsMarkdown(state, model(state, at))).toBe("|  A | B |\n|:--|--:|\n| x \\| y | `c|d` |\n| ragged |");
  });

  test("a table in a quote copies its lines as they stand", () => {
    const doc = "> | A |\n> |---|\n> | 1 |";
    const state = make(doc);
    expect(tableAsMarkdown(state, model(state))).toBe(doc);
    expect(tableAsCSV(state, model(state))).toBe("A\r\n1");
  });
});

describe("the copyTable command", () => {
  const doc = "x\n\n| A | B |\n|---|---|\n| 1, 2 | <i> |\n\ny";
  const inTable = doc.indexOf("| 1");
  const noop = () => {};

  type Sent = { text: string; html?: string };

  function withHandler(extra: Extension[] = [], head = inTable, source = doc) {
    const sent: Sent[] = [];
    const handler = codeBlockHandlers.of({ copyText: (text, html) => sent.push(html === undefined ? { text } : { text, html }) });
    return { state: make(source, [handler, ...extra], head), sent };
  }

  test("a table past the parsed part of a long note is read from the ensured tree (final review M2)", () => {
    const rows = Array.from({ length: 3000 }, (_, i) => `| r${i} | ${i} |`);
    const table = ["| A | B |", "|---|---|", ...rows].join("\n");
    // 120k characters of short paragraphs before the table (each is its own block, so the
    // initial parse stops long before the table).
    for (const source of [`${"filler line\n\n".repeat(10000)}${table}\n`]) {
      const sent: Sent[] = [];
      const handler = codeBlockHandlers.of({ copyText: (text) => sent.push({ text }) });
      // No ensureSyntaxTree here: the state's tree covers only the first few thousand characters.
      const state = EditorState.create({
        doc: source,
        selection: EditorSelection.single(source.indexOf("| A")),
        extensions: [markdown({ base: bearMarkdown }), menuTargets, handler],
      });
      expect(syntaxTree(state).length).toBeLessThan(source.indexOf("| A"));
      expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "markdown" })).toBe(true);
      expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "csv" })).toBe(true);
      expect(sent[0]!.text).toBe(table);
      expect(sent[1]!.text.split("\r\n")).toHaveLength(3001);
      expect(sent[1]!.text.endsWith("r2999,2999")).toBe(true);
    }
  });

  test("csv and markdown post plain text", () => {
    const { state, sent } = withHandler();
    expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "csv" })).toBe(true);
    expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "markdown" })).toBe(true);
    expect(sent).toEqual([{ text: 'A,B\r\n"1, 2",<i>' }, { text: "| A | B |\n|---|---|\n| 1, 2 | <i> |" }]);
  });

  test("html posts the source as the text and as the html", () => {
    const { state, sent } = withHandler();
    expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "html" })).toBe(true);
    const html = "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1, 2</td><td>&lt;i&gt;</td></tr></tbody></table>";
    expect(sent).toEqual([{ text: html, html }]);
  });

  test("copy works in read-only notes and changes nothing", () => {
    const { state, sent } = withHandler([EditorState.readOnly.of(true)]);
    expect(state.readOnly).toBe(true);
    let dispatched = 0;
    expect(runCommand({ state, dispatch: () => dispatched++ }, "copyTable", { format: "csv" })).toBe(true);
    expect(sent).toHaveLength(1);
    expect(dispatched).toBe(0);
  });

  test("a menuId copies the table of its cell, not the caret's", () => {
    const other = "| P |\n|---|\n| q |\n\n";
    const full = other + doc;
    const { state: base, sent } = withHandler([], full.indexOf("| q"), full);
    const state = base.update({ effects: menuTargetEffect.of({ id: "m1", pos: full.indexOf("| 1") }) }).state;
    expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "csv", menuId: "m1" })).toBe(true);
    expect(sent).toEqual([{ text: 'A,B\r\n"1, 2",<i>' }]);
    // A menuId that no longer resolves copies nothing, whatever the selection says.
    expect(runCommand({ state, dispatch: noop }, "copyTable", { format: "csv", menuId: "gone" })).toBe(false);
    expect(sent).toHaveLength(1);
  });

  test("nothing is copied outside a table, for a bad format or without a handler", () => {
    const outside = withHandler([], 0);
    expect(runCommand({ state: outside.state, dispatch: noop }, "copyTable", { format: "csv" })).toBe(false);
    const inside = withHandler();
    for (const args of [undefined, {}, { format: "xml" }, { format: 1 }]) {
      expect(runCommand({ state: inside.state, dispatch: noop }, "copyTable", args)).toBe(false);
    }
    expect(outside.sent).toEqual([]);
    expect(inside.sent).toEqual([]);
    // No handler (plain tests, a host without the bridge): nothing to copy to.
    expect(runCommand({ state: make(doc, [], inTable), dispatch: noop }, "copyTable", { format: "csv" })).toBe(false);
  });
});
