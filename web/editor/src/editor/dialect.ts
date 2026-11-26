// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { Language } from "@codemirror/language";
import { commonmarkLanguage, markdownLanguage } from "@codemirror/lang-markdown";
import {
  type DelimiterType,
  type Element,
  type InlineContext,
  type MarkdownConfig,
  MarkdownParser,
  Strikethrough,
} from "@lezer/markdown";
import { codePointAt, findTags, type InlineSpan, isSchemeChar, isSpace, scanInline } from "./dialect-grammar";
import { BearBlocks, BearTable } from "./dialect-blocks";

// Bear's Markdown dialect: CommonMark plus GFM strikethrough, Bear tables (pipes at both ends of
// every row), the dialect's own block rules (dialect-blocks.ts) and inline extensions: tags, wiki links,
// inline math, bare URLs, HTML comments, `==highlight==` (optional color emoji) and `~underline~`.
// No setext headings, no indented code, no HTML, no link reference definitions (spec §3.5).
//
// Tags, wiki links, math, comments, autolinks and URLs come from a per-line port of the Swift
// InlineScanner/TagScanner (dialect-grammar.ts), so the editor recognizes exactly what the Swift
// parser indexes; Lezer only contributes block structure and CommonMark emphasis/links/code.

interface ScanEntry {
  kind: InlineSpan["kind"];
  from: number;
  to: number;
  span: InlineSpan;
  /** Document offset of the span's line (InlineSpan offsets are line-relative). */
  base: number;
}

interface SectionScan {
  tags: Map<number, { to: number; closed: boolean }>;
  spans: Map<number, ScanEntry>;
}

/** Scans every line of an inline section (a paragraph, heading, table cell, …). */
function scanSection(text: string, offset: number): SectionScan {
  const tags = new Map<number, { to: number; closed: boolean }>();
  const spans = new Map<number, ScanEntry>();
  let lineStart = 0;
  let inComment = false;
  let openComment: ScanEntry | null = null;
  for (;;) {
    const nl = text.indexOf("\n", lineStart);
    const lineEnd = nl < 0 ? text.length : nl;
    const line = text.slice(lineStart, lineEnd);
    const base = offset + lineStart;
    const scan = scanInline(line, inComment, nl >= 0 && text.includes("-->", lineEnd));
    for (const span of scan.spans) {
      const runsOn = span.kind === "comment" && scan.endsInComment && span.to === line.length;
      if (openComment && span.from === 0 && span.kind === "comment" && inComment) {
        // Continuation of a comment opened on an earlier line of this section.
        openComment.to = base + span.to;
        if (!runsOn) openComment = null;
        continue;
      }
      if (span.kind === "escape" || span.kind === "code" || span.kind === "linkOpen" || span.kind === "linkClose") {
        continue;
      }
      const entry: ScanEntry = { kind: span.kind, from: base + span.from, to: base + span.to, span, base };
      spans.set(entry.from, entry);
      if (runsOn) openComment = entry;
    }
    for (const tag of findTags(line, scan.mask)) tags.set(base + tag.from, { to: base + tag.to, closed: tag.closed });
    inComment = scan.endsInComment;
    if (nl < 0) break;
    lineStart = nl + 1;
  }
  return { tags, spans };
}

/** One-entry cache: inline parsers run position by position over one section at a time. */
let current: { cx: InlineContext; hasURL: boolean; scan: SectionScan | null } | null = null;

function section(cx: InlineContext) {
  if (current?.cx !== cx) current = { cx, hasURL: cx.text.includes("://"), scan: null };
  return current;
}

function scanOf(cx: InlineContext): SectionScan {
  const s = section(cx);
  return (s.scan ??= scanSection(cx.text, cx.offset));
}

function wikiElement(cx: InlineContext, entry: ScanEntry): Element {
  const w = entry.span.wiki!;
  const b = entry.base;
  const children = [cx.elt("WikiLinkMark", entry.from, entry.from + 2)];
  if (w.targetTo > w.targetFrom) children.push(cx.elt("WikiTarget", b + w.targetFrom, b + w.targetTo));
  if (w.headingFrom !== null) children.push(cx.elt("WikiHeading", b + w.headingFrom, b + w.targetEnd));
  if (w.aliasFrom !== null) children.push(cx.elt("WikiAlias", b + w.aliasFrom, b + w.aliasTo));
  children.push(cx.elt("WikiLinkMark", entry.to - 2, entry.to));
  return cx.elt("WikiLink", entry.from, entry.to, children);
}

function spanElement(cx: InlineContext, entry: ScanEntry | undefined): number {
  if (!entry) return -1;
  const { from, to, span } = entry;
  switch (entry.kind) {
    case "math": {
      const contentFrom = entry.base + span.contentFrom!;
      const contentTo = entry.base + span.contentTo!;
      return cx.addElement(
        cx.elt("InlineMath", from, to, [cx.elt("MathMark", from, contentFrom), cx.elt("MathMark", contentTo, to)]),
      );
    }
    case "comment":
      return cx.addElement(cx.elt("Comment", from, to));
    case "autolink":
      return cx.addElement(
        cx.elt("Autolink", from, to, [
          cx.elt("LinkMark", from, from + 1),
          cx.elt("URL", from + 1, to - 1),
          cx.elt("LinkMark", to - 1, to),
        ]),
      );
    case "url":
      return cx.addElement(cx.elt("URL", from, to));
    case "wikiLink":
      return cx.addElement(wikiElement(cx, entry));
    default:
      return -1;
  }
}

function parseBearInline(cx: InlineContext, next: number, pos: number): number {
  switch (next) {
    case 35 /* # */: {
      const tag = scanOf(cx).tags.get(pos);
      if (!tag) return -1;
      const marks = [cx.elt("TagMark", pos, pos + 1)];
      if (tag.closed) marks.push(cx.elt("TagMark", tag.to - 1, tag.to));
      return cx.addElement(cx.elt("Tag", pos, tag.to, marks));
    }
    case 33 /* ! */:
      // `![[` is not an image opener: skip the `!` so `[[` can become a wiki link.
      return cx.char(pos + 1) === 91 && cx.char(pos + 2) === 91 ? pos + 1 : -1;
    case 36 /* $ */:
    case 60 /* < */:
    case 91 /* [ */:
      return spanElement(cx, scanOf(cx).spans.get(pos));
    default:
      if (!isSchemeChar(next) || !section(cx).hasURL) return -1;
      return spanElement(cx, scanOf(cx).spans.get(pos));
  }
}

/** Code point before / after a position inside the section (-1 outside). */
function charBefore(cx: InlineContext, pos: number): number {
  if (pos <= cx.offset) return -1;
  const c = cx.char(pos - 1);
  if (c >= 0xdc00 && c <= 0xdfff && pos - 2 >= cx.offset) return codePointAt(cx.text, pos - 2 - cx.offset);
  return c;
}
const charAfter = (cx: InlineContext, pos: number) =>
  pos < cx.end ? codePointAt(cx.text, pos - cx.offset) : -1;

/** Per inline section: where its last `==` that could close a highlight starts (-1: none). */
const lastCloser = new WeakMap<InlineContext, number>();

/**
 * A `==` (exactly two, after a non-space) after `from` in this inline section. Not the pairing
 * itself: a stray `HighlightColor` it lets through sits outside any `Highlight`, which hiding.ts
 * leaves as text. Linear: the last candidate is found once per section.
 */
function closerAhead(cx: InlineContext, from: number): boolean {
  let last = lastCloser.get(cx);
  if (last === undefined) {
    last = -1;
    const text = cx.text;
    for (let i = text.lastIndexOf("=="); i >= 0; i = i > 0 ? text.lastIndexOf("==", i - 1) : -1) {
      if (text.charCodeAt(i - 1) === 61 || text.charCodeAt(i + 2) === 61) continue;
      if (!isSpace(charBefore(cx, i + cx.offset))) {
        last = i + cx.offset;
        break;
      }
    }
    lastCloser.set(cx, last);
  }
  return last >= from;
}

// InlineStripper.swift flanking: a delimiter opens before a non-space, closes after one.
const canOpenAt = (cx: InlineContext, end: number) => end < cx.end && !isSpace(charAfter(cx, end));
const canCloseAt = (cx: InlineContext, start: number) => start > cx.offset && !isSpace(charBefore(cx, start));

const HighlightDelim: DelimiterType = { resolve: "Highlight", mark: "HighlightMark" };
const UnderlineDelim: DelimiterType = { resolve: "Underline", mark: "UnderlineMark" };

/** 🟢 🔴 🔵 🟡 🟣 — color marker right after a `==` highlight opener. */
export const highlightColors: Record<number, string> = {
  0x1f7e2: "green",
  0x1f534: "red",
  0x1f535: "blue",
  0x1f7e1: "yellow",
  0x1f7e3: "purple",
};

export const BearInline: MarkdownConfig = {
  defineNodes: [
    "Tag",
    "TagMark",
    "WikiLink",
    "WikiLinkMark",
    "WikiTarget",
    "WikiHeading",
    "WikiAlias",
    "InlineMath",
    "MathMark",
    "Highlight",
    "HighlightMark",
    "HighlightColor",
    "Underline",
    "UnderlineMark",
  ],
  parseInline: [
    { name: "BearScan", before: "Emphasis", parse: parseBearInline },
    {
      name: "Highlight",
      after: "Strikethrough",
      parse(cx, next, pos) {
        // Exactly two `=` (a longer run is text).
        if (next !== 61 || cx.char(pos + 1) !== 61 || cx.char(pos - 1) === 61 || cx.char(pos + 2) === 61) return -1;
        const open = canOpenAt(cx, pos + 2);
        const end = cx.addDelimiter(HighlightDelim, pos, pos + 2, open, canCloseAt(cx, pos));
        const color = open ? charAfter(cx, end) : -1;
        if (!highlightColors[color]) return end;
        const colorEnd = end + 2 + (cx.char(end + 2) === 0xfe0f ? 1 : 0);
        // An opener nothing can close keeps its emoji as text (InlineStripper pairs first).
        if (!closerAhead(cx, colorEnd)) return end;
        return cx.addElement(cx.elt("HighlightColor", end, colorEnd));
      },
    },
    {
      name: "Underline",
      after: "Highlight",
      parse(cx, next, pos) {
        // A single `~`; `~~` is GFM strikethrough.
        if (next !== 126 || cx.char(pos + 1) === 126 || cx.char(pos - 1) === 126) return -1;
        return cx.addDelimiter(UnderlineDelim, pos, pos + 1, canOpenAt(cx, pos + 1), canCloseAt(cx, pos));
      },
    },
  ],
  remove: ["HTMLTag", "Entity"],
};

// `markdownLanguage` is not reconfigurable (it is a plain Language with subscript/superscript/
// emoji baked in), so we configure the CommonMark parser it is built from and reuse
// markdownLanguage's language-data facet.
const base = commonmarkLanguage.parser;
if (!(base instanceof MarkdownParser)) throw new Error("commonmarkLanguage is not a Markdown parser");

export const bearParser = base.configure([Strikethrough, BearTable, BearBlocks, BearInline]);

export const bearMarkdown = new Language(markdownLanguage.data, bearParser, [], "markdown");
