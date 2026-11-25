// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { canonicalKey, collapse, isBlank, parseWikiLink, tagName } from "./dialect-grammar";
import { bearParser } from "./dialect";

// What the editor's syntax tree says a note contains, in the shape of the Swift NoteMetadata
// fields that Fixtures/dialect/*.json pin. These walk the Lezer tree (not separate regexes), so
// passing the fixtures shows the editor parses exactly like the Swift parser.

type Tree = ReturnType<typeof bearParser.parse>;
type SyntaxNode = Tree["topNode"];

/** Line endings as NoteParser.splitLines sees them: a leading BOM dropped, CRLF → LF. */
function parse(text: string): { doc: string; tree: Tree } {
  const doc = text.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/\r$/, "");
  return { doc, tree: bearParser.parse(doc) };
}

function nodesNamed(tree: Tree, test: (name: string) => boolean): SyntaxNode[] {
  const out: SyntaxNode[] = [];
  tree.iterate({
    enter(node) {
      if (!test(node.name)) return;
      out.push(node.node);
      return false;
    },
  });
  return out;
}

/** Direct tags without `#`, first-seen spelling, deduped by canonical key. */
export function tagsInDocument(text: string): string[] {
  const { doc, tree } = parse(text);
  const seen = new Set<string>();
  const tags: string[] = [];
  for (const node of nodesNamed(tree, (n) => n === "Tag")) {
    const name = tagName(doc.slice(node.from, node.to));
    const key = canonicalKey(name);
    if (seen.has(key)) continue;
    seen.add(key);
    tags.push(name);
  }
  return tags;
}

export interface WikiLinkRef {
  target: string;
  heading: string | null;
  alias: string | null;
}

export function wikiLinksInDocument(text: string): WikiLinkRef[] {
  const { doc, tree } = parse(text);
  return nodesNamed(tree, (n) => n === "WikiLink").map((node) => {
    const link = parseWikiLink(doc.slice(node.from, node.to), 0)!;
    return { target: link.target, heading: link.heading, alias: link.alias };
  });
}

/** Bare URLs (`URL` nodes outside links, images and autolinks), in document order. */
export function urlsInDocument(text: string): string[] {
  const { doc, tree } = parse(text);
  const out: string[] = [];
  tree.iterate({
    enter(node) {
      if (node.name === "Link" || node.name === "Image" || node.name === "Autolink") return false;
      if (node.name === "URL") out.push(doc.slice(node.from, node.to));
    },
  });
  return out;
}

export function todoCounts(text: string): { open: number; done: number } {
  const { doc, tree } = parse(text);
  const counts = { open: 0, done: 0 };
  for (const task of nodesNamed(tree, (n) => n === "Task")) {
    const marker = task.getChild("TaskMarker");
    if (!marker) continue;
    if (doc[marker.from + 1] === " ") counts.open++;
    else counts.done++;
  }
  return counts;
}

export interface HeadingRef {
  level: number;
  text: string;
  /** 1-based. */
  line: number;
}

/**
 * Headings Swift counts: ATX headings whose line starts with at most 3 columns of blanks
 * (so not in quotes or after list markers), with non-empty visible text.
 */
export function headingsInDocument(text: string): HeadingRef[] {
  const { doc, tree } = parse(text);
  const headings: HeadingRef[] = [];
  // Line numbers counted incrementally (headings come in document order): linear in the note.
  let line = 1;
  let counted = 0;
  for (const node of nodesNamed(tree, (n) => /^ATXHeading[1-6]$/.test(n))) {
    const headingText = indexedHeadingText(doc, doc.lastIndexOf("\n", node.from - 1) + 1, node);
    if (headingText === null) continue;
    for (let nl = doc.indexOf("\n", counted); nl >= 0 && nl < node.from; nl = doc.indexOf("\n", counted)) {
      line++;
      counted = nl + 1;
    }
    headings.push({ level: Number(node.name.slice(-1)), text: headingText, line });
  }
  return headings;
}

/** Anything that slices text by UTF-16 offsets: a string, or a CodeMirror `Text` wrapped. */
export type TextSlicer = { slice(from: number, to: number): string };

/**
 * The text Swift indexes for the ATX heading `node` on the line starting at `lineStart`, or null
 * when Swift does not count it: more than 3 columns or anything but blanks before it (a quote, a
 * list marker), or no visible text. One rule for `headingsInDocument` and folding.
 */
export function indexedHeadingText(doc: TextSlicer, lineStart: number, node: SyntaxNode): string | null {
  const prefix = doc.slice(lineStart, node.from);
  let column = 0;
  for (let i = 0; i < prefix.length; i++) {
    const c = prefix.charCodeAt(i);
    if (!isBlank(c)) return null;
    column += c === 9 ? 4 : 1;
  }
  if (column > 3) return null;
  return collapse(visibleText(doc, node)) || null;
}

/** Marks that InlineStripper.swift removes from visible text. */
const hiddenNodes = new Set([
  "HeaderMark",
  "EmphasisMark",
  "StrikethroughMark",
  "HighlightMark",
  "HighlightColor",
  "UnderlineMark",
  "CodeMark",
  "MathMark",
  "Comment",
  "Tag",
  "Image",
  "LinkMark",
  "LinkTitle",
  "LinkLabel",
]);

/**
 * Visible text of an inline node (InlineStripper text mode): markup delimiters, comments,
 * images and tags removed; links become their text, wiki links their alias (or target).
 */
function visibleText(doc: TextSlicer, node: SyntaxNode): string {
  let out = "";
  let pos = node.from;
  for (let child = node.firstChild; child; child = child.nextSibling) {
    // A link's visible text ends at its `]`.
    if (node.name === "Link" && child.name === "LinkMark" && child.from > node.from) return out + doc.slice(pos, child.from);
    out += doc.slice(pos, child.from);
    pos = child.to;
    if (child.name === "Escape") out += doc.slice(child.from + 1, child.to);
    else if (child.name === "WikiLink") out += parseWikiLink(doc.slice(child.from, child.to), 0)?.display ?? "";
    else if (child.name === "Autolink") out += doc.slice(child.from + 1, child.to - 1);
    else if (child.name === "URL") out += doc.slice(child.from, child.to);
    else if (!hiddenNodes.has(child.name)) out += visibleText(doc, child);
  }
  return out + doc.slice(pos, node.to);
}

/** 1-based lines of every table header, delimiter and body row (NoteParser.tableRowLines). */
export function tableRowLines(text: string): number[] {
  const { doc, tree } = parse(text);
  const lines: number[] = [];
  const lineOf = (pos: number) => doc.slice(0, pos).split("\n").length;
  for (const table of nodesNamed(tree, (n) => n === "Table")) {
    const first = lineOf(table.from);
    const last = lineOf(table.to);
    for (let line = first; line <= last; line++) lines.push(line);
  }
  return lines;
}
