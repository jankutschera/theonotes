// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorState } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { tableRowLines } from "../src/editor/conformance";
import { bearMarkdown, bearParser } from "../src/editor/dialect";

// Bear tables (ruling M6-R1): a header row, a delimiter row with the same cell count, then body
// rows; every row's trimmed text starts with `|` and ends with an unescaped `|`.

type Tree = ReturnType<typeof bearParser.parse>;

function names(tree: Tree): string[] {
  const out: string[] = [];
  tree.iterate({ enter: (n) => void out.push(n.name) });
  return out;
}

function positional(tree: Tree): string {
  const out: string[] = [];
  tree.iterate({ enter: (n) => void out.push(`${n.name}@${n.from}-${n.to}`) });
  return out.join(" ");
}

describe("Bear tables", () => {
  test("rows need a pipe at both ends", () => {
    expect(tableRowLines("| a | b |\n|---|---|\n| 1 | 2 |")).toEqual([1, 2, 3]);
    expect(tableRowLines("| a | b\n|---|---|")).toEqual([]);
    expect(tableRowLines("| a | b |\n|---|---|\n| 1 | 2\nafter")).toEqual([1, 2]);
  });

  test("cells keep inline syntax: tags, wiki links, math", () => {
    const tree = bearParser.parse("| #a | [[N]] | $x$ |\n|---|---|---|");
    expect(names(tree)).toEqual(expect.arrayContaining(["TableCell", "Tag", "WikiLink", "InlineMath"]));
  });

  test("node structure matches @lezer/markdown's Table", () => {
    const doc = "| a | b |\n|---|---|\n| 1 |";
    expect(bearParser.parse(doc).toString()).toBe(
      "Document(Table(TableHeader(TableDelimiter,TableCell,TableDelimiter,TableCell,TableDelimiter),TableDelimiter," +
        "TableRow(TableDelimiter,TableCell,TableDelimiter)))",
    );
  });

  test("a row that ends the table starts a paragraph of its own", () => {
    const tree = bearParser.parse("| a |\n|---|\n| 1\nmore");
    expect(positional(tree)).toContain("Table@0-11");
    expect(positional(tree)).toContain("Paragraph@12-20");
  });

  test("a pipe inside a code span or wiki link is not a cell separator", () => {
    const tree = bearParser.parse("| `a|b` | [[N|al]] |\n|---|---|");
    expect(names(tree).filter((n) => n === "TableCell")).toHaveLength(2);
    expect(names(tree)).toEqual(expect.arrayContaining(["InlineCode", "WikiLink"]));
  });

  test("a table interrupting an indented paragraph line", () => {
    // Lezer does not offer lines indented 4+ columns to endLeaf; the interruption still happens.
    expect(tableRowLines("text\n    | a |\n    |---|")).toEqual([2, 3]);
  });

  test("editing the delimiter row re-joins the paragraph before the header", () => {
    const filler = Array.from({ length: 12 }, (_, i) => `Paragraph ${i} with some words and a #tag${i}.`).join("\n\n");
    const doc = `${filler}\n\nIntro line\n| a | b |\n|---|---|\n| 1 | 2 |\n\n${filler}`;
    let state = EditorState.create({ doc, extensions: bearMarkdown.extension });
    ensureSyntaxTree(state, state.doc.length, 5000);
    const at = doc.indexOf("|---|---|") + 1;
    state = state.update({ changes: { from: at, to: at + 3, insert: "x" } }).state;
    const tree = ensureSyntaxTree(state, state.doc.length, 5000)!;
    expect(positional(tree)).toBe(positional(bearParser.parse(state.doc.toString())));
    expect(names(tree)).not.toContain("Table");
  });
});
