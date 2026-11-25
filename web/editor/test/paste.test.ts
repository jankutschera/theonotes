// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { EditorSelection, EditorState } from "@codemirror/state";
import { htmlToMarkdown, smartPaste } from "../src/editor/features/paste";
import { bearMarkdown } from "../src/editor/dialect";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { tableAt } from "../src/editor/features/table-model";

// CodeMirror bounds every parse slice by Date.now(); under machine load the
// slices run out and the state's tree stays partial. Freezing only Date makes
// the parse budgets unlimited here, so these tests check results, not timing.
beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
});
afterEach(() => {
  vi.useRealTimers();
});

// Review Focus 4: a URL pasted on a selection becomes `[sel](url)`, rich HTML becomes Markdown,
// plain text stays plain, and nothing else is altered.

function state(doc: string, anchor: number, head = anchor): EditorState {
  return EditorState.create({ doc, selection: EditorSelection.single(anchor, head), extensions: bearMarkdown.extension });
}

function parsedState(s: EditorState): EditorState {
  if (!ensureSyntaxTree(s, s.doc.length, 5000)) throw new Error("parse timed out");
  return s.update({}).state;
}

function pasted(doc: string, anchor: number, head: number, data: { text?: string; html?: string }): string | null {
  const s = state(doc, anchor, head);
  const spec = smartPaste(s, data);
  return spec ? s.update(spec).state.doc.toString() : null;
}

describe("smart paste", () => {
  test("a URL pasted on a selection links the selection", () => {
    expect(pasted("see the docs here", 8, 12, { text: "https://example.com/faq/" })).toBe("see the [docs](https://example.com/faq/) here");
    expect(pasted("x", 0, 1, { text: "  http://a.b/c?d=1#e \n" })).toBe("[x](http://a.b/c?d=1#e)");
    // Also when the browser adds HTML for the URL.
    expect(pasted("x", 0, 1, { text: "https://a.b", html: '<a href="https://a.b">https://a.b</a>' })).toBe("[x](https://a.b)");
  });

  test("only http(s) URLs become links; everything else pastes as usual", () => {
    for (const text of ["javascript:alert(1)", "file:///etc/hosts", "mailto:a@b.c", "data:text/html,x", "https://a.b c", "bear.app"]) {
      expect(pasted("sel", 0, 3, { text }), text).toBeNull();
    }
    // No selection: a URL is plain text.
    expect(pasted("", 0, 0, { text: "https://a.b" })).toBeNull();
  });

  test("plain text is left to the default paste", () => {
    expect(pasted("", 0, 0, { text: "**not** <b>html</b>\n- a" })).toBeNull();
    expect(pasted("", 0, 0, {})).toBeNull();
  });

  test("HTML without formatting pastes its plain text unchanged", () => {
    expect(pasted("", 0, 0, { text: "a * b_c", html: "<meta charset='utf-8'><span style='color:red'>a * b_c</span>" })).toBeNull();
  });

  test("rich HTML becomes Markdown at the selection", () => {
    const html = "<h2>Title</h2><p>Some <b>bold</b>, <i>italic</i> and <s>gone</s> text with <a href='https://x.y/'>a link</a>.</p><ul><li>one</li><li>two</li></ul>";
    expect(pasted("[]", 1, 1, { text: "Title Some bold", html })).toBe(
      "[## Title\n\nSome **bold**, *italic* and ~~gone~~ text with [a link](https://x.y/).\n\n- one\n- two]",
    );
  });

  test("links and images other than http(s) keep only their text", () => {
    expect(htmlToMarkdown("<p><a href='javascript:alert(1)'>click</a> <a href='file:///x'>f</a> <b>b</b></p>")).toBe("click f **b**");
    expect(htmlToMarkdown("<p><img src='data:image/png;base64,AAAA' alt='x'><img src='https://a.b/i.png' alt='i'> <b>b</b></p>")).toBe(
      "![i](https://a.b/i.png) **b**",
    );
  });

  test("text that reads like a tag stays inert text", () => {
    expect(htmlToMarkdown("<p>&lt;script&gt;alert(1)&lt;/script&gt; and <b>x</b></p>")).toBe("\\<script>alert(1)\\</script> and **x**");
  });

  test("scripts and styles are dropped", () => {
    expect(htmlToMarkdown("<style>p{color:red}</style><script>alert(1)</script><p><b>ok</b></p>")).toBe("**ok**");
  });

  test("tables (browsers, Numbers) become GFM tables", () => {
    const html =
      "<table><thead><tr><th>Name</th><th>Qty</th></tr></thead><tbody><tr><td>Apple</td><td>3</td></tr><tr><td>a|b</td><td>x<br>y</td></tr></tbody></table>";
    expect(htmlToMarkdown(html)).toBe("| Name | Qty |\n| --- | --- |\n| Apple | 3 |\n| a\\|b | x y |");
    // Numbers: no thead, the first row is the header.
    expect(htmlToMarkdown("<table><tr><td>A</td><td>B</td></tr><tr><td>1</td></tr></table>")).toBe("| A | B |\n| --- | --- |\n| 1 |  |");
  });

  test("inside code (fenced, inline, math) HTML and URLs paste as plain text (final review I1)", () => {
    const inCode = (doc: string, at: number, data: { text?: string; html?: string }, head = at) => {
      const s = EditorState.create({ doc, selection: EditorSelection.single(at, head), extensions: bearMarkdown.extension });
      return smartPaste(s, data);
    };
    const pre = { html: "<pre><code>a\n```\nb</code></pre>", text: "a\n```\nb" };
    const fenced = "```swift\nlet x = 1\n\n```\nafter";
    expect(inCode(fenced, fenced.indexOf("\n\n") + 1, pre)).toBeNull();
    const table = { html: "<table><tr><td>A</td></tr></table>", text: "A" };
    expect(inCode(fenced, fenced.indexOf("x"), table)).toBeNull();
    const inline = "see `co de` here";
    expect(inCode(inline, inline.indexOf("de"), pre)).toBeNull();
    expect(inCode(inline, inline.indexOf("co"), { text: "https://a.b" }, inline.indexOf("co") + 2)).toBeNull();
    const math = "$$\nx^2\n$$\n";
    expect(inCode(math, math.indexOf("^"), pre)).toBeNull();
    // Outside code the same HTML still converts.
    expect(inCode("plain\n", 6, pre)).not.toBeNull();
  });

  test("code blocks keep their text", () => {
    expect(htmlToMarkdown("<pre><code>let a = 1 * 2;\nb_c()</code></pre>")).toBe("```\nlet a = 1 * 2;\nb_c()\n```");
  });
});

// M6 Task 6: TSV from Numbers or Excel (no HTML) becomes a GFM table; text pasted into a table
// cell is flattened so the row keeps its shape.

describe("table paste", () => {
  test("TSV becomes a GFM table", () => {
    expect(pasted("", 0, 0, { text: "Name\tQty\nApple\t3\nKiwi\t12" })).toBe("| Name | Qty |\n| --- | --- |\n| Apple | 3 |\n| Kiwi | 12 |");
    // Windows line ends, a trailing newline (Excel), empty cells, pipes in cells, cell padding.
    expect(pasted("", 0, 0, { text: "a\t b \r\n\tx|y\r\n" })).toBe("| a | b |\n| --- | --- |\n|  | x\\|y |");
    // Three columns, replacing the selection; HTML without a table does not stop it.
    expect(pasted("old", 0, 3, { text: "a\tb\tc\n1\t2\t3", html: "<span>a</span>" })).toBe("| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |");
  });

  test("a table pasted into a line of text starts on its own line", () => {
    expect(pasted("intro ", 6, 6, { text: "a\tb\n1\t2" })).toBe("intro \n\n| a | b |\n| --- | --- |\n| 1 | 2 |");
    expect(pasted("x tail", 1, 1, { text: "a\tb\n1\t2" })).toBe("x\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n tail");
  });

  test("ragged TSV stays text", () => {
    for (const text of ["a\tb\n1\t2\t3", "a\tb\n1", "a\tb\n\n1\t2", "just\ttab", "one line\nof prose", "a\nb"]) {
      expect(pasted("", 0, 0, { text }), JSON.stringify(text)).toBeNull();
    }
  });

  test("tab-indented lines (code without HTML) are not a table: the first column is empty on every line (final review M5)", () => {
    expect(pasted("", 0, 0, { text: "\tfoo()\n\tbar()" })).toBeNull();
    expect(pasted("", 0, 0, { text: "\tfoo()\n\tbar()\n" })).toBeNull();
    expect(pasted("", 0, 0, { text: " \ta\n\tb\n  \tc" })).toBeNull();
    // An empty first cell on some lines only is still a table.
    expect(pasted("", 0, 0, { text: "\tQ1\nsales\t3" })).toBe("|  | Q1 |\n| --- | --- |\n| sales | 3 |");
  });

  test("TSV on an empty quote or list line keeps the line's prefix; on one with text it is not converted (M6-R83)", () => {
    expect(pasted("> ", 2, 2, { text: "a\tb\n1\t2" })).toBe("> | a | b |\n> | --- | --- |\n> | 1 | 2 |");
    expect(pasted("intro\n> > ", 10, 10, { text: "a\tb\n1\t2" })).toBe("intro\n> > | a | b |\n> > | --- | --- |\n> > | 1 | 2 |");
    expect(pasted("- ", 2, 2, { text: "a\tb\n1\t2" })).toBe("- | a | b |\n  | --- | --- |\n  | 1 | 2 |");
    expect(pasted("> - ", 4, 4, { text: "a\tb\n1\t2" })).toBe("> - | a | b |\n>   | --- | --- |\n>   | 1 | 2 |");
    // A selection on such a line (residual round): converted only when it covers the line's whole
    // content (it is replaced, the prefix stays); a partial selection stays text.
    const tsv = { text: "a\tb\n1\t2" };
    expect(pasted("> old", 2, 5, tsv)).toBe("> | a | b |\n> | --- | --- |\n> | 1 | 2 |");
    expect(pasted("- old", 2, 5, tsv)).toBe("- | a | b |\n  | --- | --- |\n  | 1 | 2 |");
    // The whole line selected, prefix included: the content is covered, the prefix is kept.
    expect(pasted("> old", 0, 5, tsv)).toBe("> | a | b |\n> | --- | --- |\n> | 1 | 2 |");
    expect(pasted("- old", 0, 5, tsv)).toBe("- | a | b |\n  | --- | --- |\n  | 1 | 2 |");
    for (const [doc, from, to] of [["> old", 2, 4], ["- old text", 2, 5], ["> old", 3, 5], ["> old\nnext", 2, 7]] as const) {
      expect(pasted(doc, from, to, tsv), `${doc} ${from}-${to}`).toBeNull();
    }
    for (const [doc, at] of [["> quoted text", 13], ["- item", 6], ["- [ ] ", 6], ["> ", 1]] as const) {
      expect(pasted(doc, at, at, { text: "a\tb\n1\t2" }), doc).toBeNull();
    }
  });

  test("rich HTML with a table keeps the turndown path", () => {
    const html = "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>";
    expect(pasted("", 0, 0, { text: "A\tB\n1\t2", html })).toBe("| A | B |\n| --- | --- |\n| 1 | 2 |");
  });

  test("TSV does not become a table inside code", () => {
    expect(pasted("```\n\n```", 4, 4, { text: "a\tb\n1\t2" })).toBeNull();
    expect(pasted("`xy`", 2, 2, { text: "a\tb\n1\t2" })).toBeNull();
  });

  const cellDoc = "| A | B |\n|---|---|\n| 1 | 2 |";

  test("paste into a cell flattens newlines and pipes", () => {
    const at = cellDoc.indexOf("1");
    expect(pasted(cellDoc, at, at + 1, { text: "x|y\nsecond\tcol\r\nthird" })).toBe(
      "| A | B |\n|---|---|\n| x\\|y<br>second col<br>third | 2 |",
    );
    // A header cell, the caret inside the text, a trailing newline (a copied line).
    expect(pasted(cellDoc, 2, 2, { text: "one\ntwo\n" })).toBe("| one<br>twoA | B |\n|---|---|\n| 1 | 2 |");
    // TSV in a cell is flattened as well, not turned into a table.
    expect(pasted(cellDoc, at, at, { text: "a\tb\n1\t2" })).toBe("| A | B |\n|---|---|\n| a b<br>1 21 | 2 |");
  });

  test("an already escaped \\| pasted into a cell stays one escaped pipe (final review M1)", () => {
    const at = cellDoc.indexOf("1");
    expect(pasted(cellDoc, at, at + 1, { text: "a \\| b\nc" })).toBe("| A | B |\n|---|---|\n| a \\| b<br>c | 2 |");
    // An escaped backslash before a pipe: the pipe itself is unescaped, so it is escaped.
    expect(pasted(cellDoc, at, at + 1, { text: "a \\\\| b\nc" })).toBe("| A | B |\n|---|---|\n| a \\\\\\| b<br>c | 2 |");
    const after = pasted(cellDoc, at, at + 1, { text: "x \\| y | z\nw" })!;
    expect(after).toBe("| A | B |\n|---|---|\n| x \\| y \\| z<br>w | 2 |");
    // The row keeps its two cells.
    const s = state(after, 0);
    expect(tableAt(parsedState(s), 0)!.rows[0]).toHaveLength(2);
    // TSV cells too.
    expect(pasted("", 0, 0, { text: "a \\| b\tc\n1\t2" })).toBe("| a \\| b | c |\n| --- | --- |\n| 1 | 2 |");
  });

  test("a cell far down a long note is found from the ensured tree (final review M2)", () => {
    const doc = "filler line\n\n".repeat(10000) + cellDoc;
    const s = state(doc, doc.indexOf("| 1") + 2, doc.indexOf("| 1") + 3);
    expect(syntaxTree(s).length).toBeLessThan(doc.indexOf("| A"));
    const spec = smartPaste(s, { text: "x|y" });
    expect(spec).not.toBeNull();
    expect(s.update(spec!).state.doc.toString().endsWith("| x\\|y | 2 |")).toBe(true);
  });

  test("a single clean line pastes with the default paste, also in a cell", () => {
    expect(pasted(cellDoc, 3, 3, { text: "plain text" })).toBeNull();
    expect(pasted(cellDoc, 3, 3, { text: "" })).toBeNull();
  });

  test("rich HTML pasted in a cell is flattened too", () => {
    const at = cellDoc.indexOf("1");
    expect(pasted(cellDoc, at, at + 1, { text: "a b", html: "<p>a <b>b</b></p><p>c|d</p>" })).toBe(
      "| A | B |\n|---|---|\n| a **b**<br>c\\|d | 2 |",
    );
  });

  test("outside a cell the text is untouched (lines around the table, its delimiter row)", () => {
    const doc = `before\n\n${cellDoc}\n\nafter`;
    expect(pasted(doc, 2, 2, { text: "a|b\nc" })).toBeNull();
    expect(pasted(doc, doc.length, doc.length, { text: "a|b\nc" })).toBeNull();
    const delimiter = doc.indexOf("|---|") + 2;
    expect(pasted(doc, delimiter, delimiter, { text: "a|b\nc" })).toBeNull();
  });

  test("a selection across cells, rows or the delimiter row is not flattened or converted (fix round 1)", () => {
    const doc = cellDoc;
    const text = { text: "x\ny" };
    const html = { text: "x y", html: "<p>x</p><p><b>y</b></p>" };
    const tsv = { text: "a\tb\n1\t2" };
    const ranges: [number, number][] = [
      [doc.indexOf("A"), doc.indexOf("B") + 1], // header cell to header cell
      [doc.indexOf("A"), doc.indexOf("1") + 1], // header to body
      [doc.indexOf("1"), doc.indexOf("2") + 1], // body cell to body cell
      [doc.indexOf("|---|") + 1, doc.indexOf("|---|") + 3], // inside the delimiter row
      [0, doc.length], // the whole table
    ];
    for (const [from, to] of ranges) {
      for (const data of [text, html, tsv]) {
        expect(pasted(doc, from, to, data), `${from}-${to} ${JSON.stringify(data.text)}`).toBeNull();
      }
    }
    // A selection inside one cell (its blanks included) is still flattened.
    const one = doc.indexOf("1");
    expect(pasted(doc, one - 1, one + 2, text)).toBe("| A | B |\n|---|---|\n|x<br>y| 2 |");
    expect(pasted(doc, one - 1, one + 1, text)).toBe("| A | B |\n|---|---|\n|x<br>y | 2 |");
  });

  test("TSV is not converted for several cursors (fix round 1)", () => {
    const s = EditorState.create({
      doc: "ab cd",
      selection: EditorSelection.create([EditorSelection.cursor(1), EditorSelection.cursor(4)]),
      extensions: [bearMarkdown.extension, EditorState.allowMultipleSelections.of(true)],
    });
    expect(smartPaste(s, { text: "a\tb\n1\t2" })).toBeNull();
  });

  test("read-only notes paste nothing", () => {
    const s = EditorState.create({ doc: "", extensions: [EditorState.readOnly.of(true)] });
    expect(smartPaste(s, { text: "a\tb\n1\t2" })).toBeNull();
  });
});
