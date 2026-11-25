// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { type ChangeSpec, EditorState } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown, bearParser } from "../src/editor/dialect";
import { editKeepsFencePairing, fenceGuardStats } from "../src/editor/dialect-blocks";

// Incremental reparses (what the editor does on every keystroke) must give the same tree as a
// fresh parse, including for rules that depend on other lines (stray fence closers, front matter).

type Tree = ReturnType<typeof bearParser.parse>;

/** Every node with its position, so a shifted or re-split node also counts as a difference. */
function positional(tree: Tree): string {
  const out: string[] = [];
  tree.iterate({ enter: (n) => void out.push(`${n.name}@${n.from}-${n.to}`) });
  return out.join(" ");
}

function parsed(state: EditorState): string {
  const tree = ensureSyntaxTree(state, state.doc.length, 5000);
  if (!tree) throw new Error("parse timed out");
  return positional(tree);
}

const fresh = (state: EditorState) => positional(bearParser.parse(state.doc.toString()));

function expectIncrementalEqualsFresh(doc: string, ...edits: ChangeSpec[]) {
  let state = EditorState.create({ doc, extensions: bearMarkdown.extension });
  parsed(state);
  for (const changes of edits) {
    state = state.update({ changes }).state;
    expect(parsed(state)).toBe(fresh(state));
  }
}

/** The editor's configuration (setup.ts): markdown() adds a mixed-parse wrapper around the dialect's. */
const editorMarkdown = () => markdown({ base: bearMarkdown, addKeymap: false, completeHTMLTags: false });

// Lezer only reuses fragments of at least 128 characters, so the edits need room around them.
const filler = Array.from({ length: 12 }, (_, i) => `Paragraph ${i} with some words and a #tag${i}.`).join("\n\n");

describe("incremental parsing", () => {
  const strayDoc = `${filler}\n\n- \`\`\`\n  x\ncode\n\`\`\`\n#b\n\n${filler}`;

  test("removing the list fence opener turns a stray closer back into an opener", () => {
    expect(bearParser.parse(strayDoc).toString()).toContain("StrayFence");
    expectIncrementalEqualsFresh(strayDoc, { from: strayDoc.indexOf("```"), to: strayDoc.indexOf("```") + 3, insert: "x" });
  });

  test("adding a list fence opener turns a bare opener into a stray closer", () => {
    const doc = `${filler}\n\n- a\n  x\ncode\n\`\`\`\n#b\n\n${filler}`;
    expectIncrementalEqualsFresh(doc, { from: doc.indexOf("- a") + 2, to: doc.indexOf("- a") + 3, insert: "```" });
  });

  test("closing front matter later in the note", () => {
    const doc = `---\ntitle: x\n\n${filler}`;
    expectIncrementalEqualsFresh(doc, { from: doc.length, insert: "\n---" });
  });

  test("typing a closer far below an unclosed `$$` or `<!--` line", () => {
    for (const [opener, closer] of [["$$", "$$"], ["<!--", "-->"]] as const) {
      const doc = `${filler}\n\n${opener}\nformula #x\n\n${filler}\n\n${filler}`;
      expect(bearParser.parse(doc).toString()).toContain("UnclosedOpener");
      expectIncrementalEqualsFresh(doc, { from: doc.length, insert: `\n${closer}\n` }, { from: doc.length, to: doc.length + closer.length + 2 });
    }
  });

  test("editing the first fence line after a list fence flips a later bare fence", () => {
    const doc = `${filler}\n\n- \`\`\`\n  c\nh\n\`\`\`\nmid\n\n\`\`\`\ncode\n\`\`\`\n${filler}`;
    expectIncrementalEqualsFresh(doc, { from: doc.indexOf("h\n```") + 2, insert: "x" });
  });

  test("edits next to nodes that share a line (comment closer, task box fence)", () => {
    const comment = `${filler}\n\n<!--\nhidden\n--> #after\nnext line\n\n${filler}`;
    const at = comment.indexOf("next line");
    expectIncrementalEqualsFresh(comment, { from: at, insert: "x" });
    const task = `${filler}\n\n- [ ] \`\`\`\n  code\n  more\n  \`\`\`\n\n${filler}`;
    expectIncrementalEqualsFresh(task, { from: task.indexOf("more"), insert: "x" });
  });

  // Under parallel load (the whole unit suite) 1500 edits with two parses each take seconds.
  test.each([7, 42, 2026, 99, 31337, 123456])("random edits keep incremental and fresh parses equal (seed %i)", { timeout: 60_000 }, (start) => {
    const pieces = [
      ...["\n", " ", "  ", "#", "#a", "- ", "- [ ] ", "1. ", "> ", "```", "~~~", "`", "**", "==", "~", "[[", "]]", "x", "|"],
      ...["$$", "\n$$\n", "<!--", "\n<!--\n", "-->", "---", "\n---\n"],
      ...["\n```\n", "- ```\n  c\n", "\n  ```\n"],
      ...["| ", " |", "|---|", "\n| a | b |\n|---|---|\n"],
    ];
    let seed = start;
    const random = (n: number) => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed % n;
    };
    let state = EditorState.create({
      doc: `# Title #tag\n\n${filler}\n\n- \`\`\`\n  code\n\`\`\`\ntext [[Note|alias]] ==hi==\n\n> quote\n\n- [ ] todo\n\n${filler}`,
      extensions: bearMarkdown.extension,
    });
    parsed(state);
    for (let i = 0; i < 1500; i++) {
      const from = random(state.doc.length + 1);
      const remove = random(3) === 0 ? Math.min(random(4), state.doc.length - from) : 0;
      state = state.update({ changes: { from, to: from + remove, insert: pieces[random(pieces.length)]! } }).state;
      expect(parsed(state), `edit ${i}: ${JSON.stringify(state.doc.toString())}`).toBe(fresh(state));
    }
  });

  // Final review I2: edits that cannot change fence pairing skip the R4 bare-fence cuts. The
  // guard must never let a stale node through, so these notes are full of bare, list and quoted
  // fences, stray closers, math and comments, and the edits mix plain typing (the skip path)
  // with fence markers, `<`, `$$`, `---`, prefixes and line breaks (the cut path).
  const fenceBlock = [
    "Prose line with words and a #tag.",
    "```",
    "bare code",
    "```",
    "- ```",
    "  list code",
    "code",
    "```",
    "> ```",
    "> quoted code",
    "> ```",
    "1. item",
    "   ```",
    "   ordered code",
    "   ```",
    "- [ ] ```",
    "  task code",
    "  ```",
    "~~~",
    "tilde code",
    "~~~",
    "$$",
    "x^2",
    "$$",
    "<!--",
    "hidden",
    "-->",
    "text ``` mid-line `code` and ~~gone~~",
    "",
  ].join("\n");

  test.each([3, 17, 404, 8086, 65537, 271828])("random edits around many bare fences keep parses equal (seed %i)", { timeout: 60_000 }, (start) => {
    const typing = ["a", "b", "x", " ", "word", "é", "#t", "**"];
    const structural = [
      ...["\n", "\n\n", "  ", "- ", "> ", "1. ", "- [ ] ", "#", "|"],
      ...["```", "``", "`", "~~~", "~", "\n```\n", "- ```\n  c\n", "\n  ```\n", "\n> ```\n"],
      ...["<", "<!--", "-->", "\n<!--\n", "$$", "\n$$\n", "---", "\n---\n"],
      ...["| ", " |", "|---|", "\n| a | b |\n|---|---|\n"],
    ];
    let seed = start;
    const random = (n: number) => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed % n;
    };
    let state = EditorState.create({
      doc: `---\ntitle: x\n---\n${fenceBlock}${filler}\n\n${fenceBlock}${fenceBlock}${filler}`,
      extensions: bearMarkdown.extension,
    });
    parsed(state);
    const skippedBefore = fenceGuardStats.skipped;
    for (let i = 0; i < 1200; i++) {
      const from = random(state.doc.length + 1);
      const kind = random(10);
      let changes: ChangeSpec;
      if (kind < 6) {
        changes = { from, insert: typing[random(typing.length)]! }; // plain typing
      } else if (kind < 7) {
        const line = state.doc.lineAt(from);
        changes = { from, to: Math.min(line.to, from + 1 + random(3)) }; // deleting within a line
      } else if (kind < 9) {
        changes = { from, insert: structural[random(structural.length)]! };
      } else {
        changes = { from, to: Math.min(state.doc.length, from + 1 + random(6)) }; // may join lines
      }
      state = state.update({ changes }).state;
      expect(parsed(state), `edit ${i}: ${JSON.stringify(state.doc.toString())}`).toBe(fresh(state));
    }
    // The skip path was exercised, not just the cut path.
    expect(fenceGuardStats.skipped - skippedBefore).toBeGreaterThan(100);
  });

  test.each([5, 1999, 77777])("random edits over partial parses keep parses equal (seed %i)", { timeout: 60_000 }, (start) => {
    // The editor parses long notes up to the viewport first; the guard must also hold when the
    // previous tree stopped early (its fragments then mix with older ones).
    const typing = ["a", "x", " ", "word"];
    const structural = [
      ...["\n", "```", "\n```\n", "- ```\n  c\n", "  ", "- ", "$$", "<!--", "---", "~~~"],
      ...["| ", " |", "|---|", "\n| a | b |\n|---|---|\n"],
    ];
    let seed = start;
    const random = (n: number) => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return seed % n;
    };
    let state = EditorState.create({
      doc: `${fenceBlock}${filler}\n\n${fenceBlock}${filler}\n\n${fenceBlock}${fenceBlock}${filler}`,
      extensions: editorMarkdown(),
    });
    const skippedBefore = fenceGuardStats.skipped;
    for (let i = 0; i < 600; i++) {
      const from = random(state.doc.length + 1);
      const insert = random(4) === 0 ? structural[random(structural.length)]! : typing[random(typing.length)]!;
      const remove = random(5) === 0 ? Math.min(random(4), state.doc.length - from) : 0;
      state = state.update({ changes: { from, to: from + remove, insert } }).state;
      if (random(3) === 0) ensureSyntaxTree(state, random(state.doc.length + 1), 5000);
      if (random(8) === 0) expect(parsed(state), `edit ${i}: ${JSON.stringify(state.doc.toString())}`).toBe(fresh(state));
    }
    expect(parsed(state)).toBe(fresh(state));
    expect(fenceGuardStats.skipped - skippedBefore).toBeGreaterThan(20);
  });

  test.each([
    ["the dialect language", () => bearMarkdown.extension],
    ["the editor's markdown() setup", editorMarkdown],
  ])("typing in prose of a partly parsed note skips the bare-fence cuts (%s)", (_name, extension) => {
    // Long notes are parsed up to the viewport (3000 characters without a view): every tree here
    // comes from a stopped parse.
    let state = EditorState.create({ doc: `${filler}\n\n${fenceBlock.repeat(40)}`, extensions: extension() });
    const before = fenceGuardStats.skipped;
    for (let i = 0; i < 5; i++) state = state.update({ changes: { from: filler.indexOf("Paragraph 3") + 5, insert: "x" } }).state;
    expect(fenceGuardStats.skipped - before).toBe(5);
    expect(parsed(state)).toBe(fresh(state));
  });

  test.each([
    ["the dialect language", () => bearMarkdown.extension],
    ["the editor's markdown() setup", editorMarkdown],
  ])("typing in prose skips the bare-fence cuts; fence markers and line breaks do not (%s)", (_name, extension) => {
    const doc = `${filler}\n\n${fenceBlock}${fenceBlock}`;
    let state = EditorState.create({ doc, extensions: extension() });
    parsed(state);
    const at = doc.indexOf("Paragraph 3") + 5;
    const skips = (insert: string, from = at) => {
      const before = fenceGuardStats.skipped;
      state = state.update({ changes: { from, insert } }).state;
      expect(parsed(state)).toBe(fresh(state));
      return fenceGuardStats.skipped - before;
    };
    expect(skips("x")).toBe(1);
    expect(skips("```")).toBe(0);
    expect(skips("\n")).toBe(0);
    expect(skips("<")).toBe(0);
  });
});

describe("fence pairing guard", () => {
  test("plain edits after the block prefix keep pairing", () => {
    expect(editKeepsFencePairing("Some words here", "Some wordxs here", 9, 9)).toBe(true);
    expect(editKeepsFencePairing("- item", "- items", 6, 6)).toBe(true);
    // U+0085 (NEL) and NBSP are whitespace to the dialect but not all to trimEnd(): never skip.
    expect(editKeepsFencePairing("> a", "> \u0085", 2, 2)).toBe(false);
    expect(editKeepsFencePairing("a b", "a\u00a0b", 1, 1)).toBe(false);
    expect(editKeepsFencePairing("> - [ ] todo", "> - [ ] todos", 12, 12)).toBe(true);
    expect(editKeepsFencePairing("ab```", "abc```", 2, 2)).toBe(true);
    expect(editKeepsFencePairing("  code", "  coxde", 4, 4)).toBe(true);
  });

  test("blank lines and prefix changes can change pairing", () => {
    expect(editKeepsFencePairing("", "a", 0, 0)).toBe(false);
    expect(editKeepsFencePairing("a", " ", 0, 0)).toBe(false);
    expect(editKeepsFencePairing("> ", "> a", 2, 2)).toBe(false);
    expect(editKeepsFencePairing("- ", "- a", 2, 2)).toBe(false);
    expect(editKeepsFencePairing("a", "- a", 0, 0)).toBe(false);
    expect(editKeepsFencePairing("-a", "- a", 1, 1)).toBe(false);
    expect(editKeepsFencePairing("  a", "   a", 2, 2)).toBe(false);
    expect(editKeepsFencePairing("1x. a", "1. a", 1, 1)).toBe(false);
    expect(editKeepsFencePairing("- a", "xa", 0, 0)).toBe(false);
  });

  test("fence markers, `<`, `$$` and `---` on the line can change pairing", () => {
    expect(editKeepsFencePairing("a ``", "a ```", 4, 4)).toBe(false);
    expect(editKeepsFencePairing("a ~~", "a ~~~", 4, 4)).toBe(false);
    expect(editKeepsFencePairing("```", "a```", 0, 0)).toBe(false);
    expect(editKeepsFencePairing("a```", "```", 0, 0)).toBe(false);
    expect(editKeepsFencePairing("- [ ] ```a", "- [ ] ```ab", 10, 10)).toBe(false);
    // No blank after the box: not a fence opener, so the run is inline text.
    expect(editKeepsFencePairing("- [ ]```a", "- [ ]```a`", 9, 9)).toBe(true);
    expect(editKeepsFencePairing("`a", "`ab", 2, 2)).toBe(false);
    expect(editKeepsFencePairing("~a", "~ab", 2, 2)).toBe(false);
    for (const marker of ["<", "$$", "---", "-->"]) {
      expect(editKeepsFencePairing(`a ${marker} b`, `a ${marker} bc`, 6, 6), marker).toBe(false);
      expect(editKeepsFencePairing("a b", `a ${marker}b`, 2, 2), marker).toBe(false);
    }
  });
});
