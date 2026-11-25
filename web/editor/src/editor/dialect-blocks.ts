// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import type { BlockContext, BlockParser, Element, LeafBlock, LeafBlockParser, Line, MarkdownConfig } from "@lezer/markdown";
import { tags as t } from "@lezer/highlight";
import {
  classifyFenceLine,
  type Fence,
  isBareCloser,
  isBlank,
  isMathFence,
  isTableDelimiterFor,
  openFence,
  tableHeader,
  tableRowOf,
  tableRowShape,
  type TableRowShape,
  tableSeparators,
  trimmedEnd,
  trimmedEquals,
} from "./dialect-grammar";

// Block-level rules of Bear's dialect that differ from CommonMark, ported from NoteParser.swift:
// YAML front matter, `$$` math blocks, line-based HTML comments, ATX headings with a tab after
// the marker, task items only in bullet lists, and the stray closer after a list fence that was
// ended by an under-indented line (ruling R3).

type WrapArgs = Parameters<NonNullable<MarkdownConfig["wrap"]>>;
type Input = WrapArgs[1];
type Fragment = WrapArgs[2][number];

/** The input of each block parse, so block parsers can look before and after the current line. */
const inputs = new WeakMap<object, Input>();
const inputOf = (cx: BlockContext): Input | undefined => inputs.get(cx);

interface DocLine {
  from: number;
  /** Position of the line break (or the input end). */
  to: number;
  text: string;
}

const CHUNK = 512;

function lineAt(input: Input, from: number): DocLine {
  let text = "";
  let to = from;
  while (to < input.length) {
    const chunk = input.read(to, Math.min(input.length, to + CHUNK));
    const nl = chunk.indexOf("\n");
    if (nl >= 0) return { from, to: to + nl, text: text + chunk.slice(0, nl) };
    text += chunk;
    to += chunk.length;
  }
  return { from, to, text };
}

function lineBefore(input: Input, lineStart: number): DocLine | null {
  if (lineStart <= 0) return null;
  const to = lineStart - 1;
  let from = to;
  while (from > 0) {
    const chunkFrom = Math.max(0, from - CHUNK);
    const nl = input.read(chunkFrom, from).lastIndexOf("\n");
    if (nl >= 0) {
      from = chunkFrom + nl + 1;
      break;
    }
    from = chunkFrom;
  }
  return { from, to, text: input.read(from, to) };
}

/** The first line at or after `from` (a line start) matching `test`. */
function findLine(input: Input, from: number, test: (text: string) => boolean): DocLine | null {
  for (let pos = from; pos <= input.length; ) {
    const line = lineAt(input, pos);
    if (test(line.text)) return line;
    if (line.to >= input.length) return null;
    pos = line.to + 1;
  }
  return null;
}

/** Moves `cx` to the line starting at `lineStart` (a later line of the same top-level block). */
function skipTo(cx: BlockContext, lineStart: number): void {
  while (cx.lineStart < lineStart && cx.nextLine()) {}
}

const atDocumentLevel = (cx: BlockContext) => cx.depth === 1;

/** YAML front matter: line 1 is `---` and a later line is `---`. */
const frontMatter: BlockParser = {
  name: "FrontMatter",
  before: "LinkReference",
  parse(cx, line) {
    if (cx.lineStart !== 0 || !atDocumentLevel(cx) || !trimmedEquals(line.text, "---")) return false;
    const input = inputOf(cx);
    const close = input && findLine(input, line.text.length + 1, (t) => trimmedEquals(t, "---"));
    if (!close) return false;
    const marks = [cx.elt("FrontMatterMark", 0, line.text.length)];
    skipTo(cx, close.from);
    marks.push(cx.elt("FrontMatterMark", close.from, close.to));
    cx.nextLine();
    cx.addElement(cx.elt("FrontMatter", 0, close.to, marks));
    return true;
  },
};

/**
 * A `$$` or `<!--` line with no closer after it is prose (Swift: the opener only counts when a
 * closer exists later). It gets its own node so incremental parses re-check it once a closer is
 * typed further down (stabilizeFragments).
 */
function unclosedOpener(cx: BlockContext, line: Line): true {
  const from = cx.lineStart + line.pos;
  const to = cx.lineStart + line.text.length;
  const content = cx.parser.parseInline(line.text.slice(line.pos), from);
  cx.nextLine();
  cx.addElement(cx.elt("UnclosedOpener", from, to, content));
  return true;
}

/** `$$` lines (trimmed) enclose a math block, but only when a later `$$` line exists. */
const mathBlock: BlockParser = {
  name: "MathBlock",
  before: "FencedCode",
  parse(cx, line) {
    if (!atDocumentLevel(cx) || !isMathFence(line.text)) return false;
    const input = inputOf(cx);
    const start = cx.lineStart;
    if (!input) return false;
    const close = findLine(input, start + line.text.length + 1, isMathFence);
    if (!close) return unclosedOpener(cx, line);
    const open = start + line.text.indexOf("$$");
    const marks = [cx.elt("MathMark", open, open + 2)];
    skipTo(cx, close.from);
    const closeAt = close.from + close.text.indexOf("$$");
    marks.push(cx.elt("MathMark", closeAt, closeAt + 2));
    cx.nextLine();
    cx.addElement(cx.elt("MathBlock", open, closeAt + 2, marks));
    return true;
  },
  endLeaf: (cx, line) => atDocumentLevel(cx) && isMathFence(line.text),
};

/**
 * A line starting with `<!--` that has no `-->` after it comments out whole lines up to the
 * first line containing `-->` (if there is one); text after that `-->` is prose again. Replaces
 * CommonMark HTML blocks, which the dialect does not have. Prose after the `-->` is parsed inline as the
 * block's children.
 */
const commentBlock: BlockParser = {
  name: "HTMLBlock",
  parse(cx, line) {
    const text = line.text;
    if (!atDocumentLevel(cx) || !text.startsWith("<!--", line.pos) || text.includes("-->", line.pos + 4)) return false;
    const input = inputOf(cx);
    const from = cx.lineStart + line.pos;
    if (!input) return false;
    const close = findLine(input, cx.lineStart + text.length + 1, (t) => t.includes("-->"));
    if (!close) return unclosedOpener(cx, line);
    skipTo(cx, close.from);
    // The node ends at the line end (Lezer reuses whole lines); inline nodes of the prose after
    // `-->` are its children.
    const rest = close.from + close.text.indexOf("-->") + 3;
    const content = cx.parser.parseInline(close.text.slice(rest - close.from), rest);
    cx.nextLine();
    cx.addElement(cx.elt("CommentBlock", from, close.to, content));
    return true;
  },
};

/** `#{1,6}` followed by a blank or the line end, indented less than 4 columns. */
function atxLevel(line: Line): number {
  if (line.next !== 35 || line.indent - line.baseIndent >= 4) return -1;
  let pos = line.pos + 1;
  while (pos < line.text.length && line.text.charCodeAt(pos) === 35) pos++;
  const size = pos - line.pos;
  if (size > 6 || (pos < line.text.length && !isBlank(line.text.charCodeAt(pos)))) return -1;
  return size;
}

/** ATX headings; the content excludes an optional closing `#` sequence (LineShape.atxHeading). */
const atxHeading: BlockParser = {
  name: "ATXHeading",
  parse(cx, line) {
    const size = atxLevel(line);
    if (size < 0) return false;
    const text = line.text;
    const base = cx.lineStart;
    const from = base + line.pos;
    const end = trimmedEnd(text);
    let q = line.pos + size;
    while (q < end && isBlank(text.charCodeAt(q))) q++;
    let r = end;
    while (r > q && text.charCodeAt(r - 1) === 35) r--;
    const closing = r < end && (r === q || isBlank(text.charCodeAt(r - 1)));
    let contentEnd = end;
    if (closing) {
      contentEnd = r;
      while (contentEnd > q && isBlank(text.charCodeAt(contentEnd - 1))) contentEnd--;
    }
    const children = [
      cx.elt("HeaderMark", from, from + size),
      ...cx.parser.parseInline(text.slice(q, contentEnd), base + q),
    ];
    if (closing) children.push(cx.elt("HeaderMark", base + r, base + end));
    const to = base + text.length;
    cx.nextLine();
    cx.addElement(cx.elt(`ATXHeading${size}`, from, to, children));
    return true;
  },
  endLeaf: (_cx, line) => atxLevel(line) > 0,
};

const inBulletItem = (cx: BlockContext) =>
  cx.parentType().name === "ListItem" && cx.parentType(cx.depth - 2).name === "BulletList";

class TaskParser implements LeafBlockParser {
  nextLine() {
    return false;
  }

  finish(cx: BlockContext, leaf: LeafBlock) {
    cx.addLeafElement(
      leaf,
      cx.elt("Task", leaf.start, leaf.start + leaf.content.length, [
        cx.elt("TaskMarker", leaf.start, leaf.start + 3),
        ...cx.parser.parseInline(leaf.content.slice(3), leaf.start + 3),
      ]),
    );
    return true;
  }
}

/**
 * `[ ]`, `[x]`, `[X]` followed by a blank or the line end, right after a bullet marker
 * (ordered list items are not todos).
 */
const taskList: BlockParser = {
  name: "TaskList",
  after: "SetextHeading",
  leaf(cx, leaf) {
    if (!/^\[[ xX]\](?:[ \t]|$)/.test(leaf.content)) return null;
    if (!inBulletItem(cx)) return null;
    const input = inputOf(cx);
    if (input && !/[-*+][ \t]+$/.test(input.read(cx.lineStart, leaf.start))) return null;
    return new TaskParser();
  },
};

/**
 * `- [ ] ```` — a task box followed by a fence opener: a Task holding the box and a fenced code
 * block (NoteParser.Fence.open accepts a task box before the fence).
 * The fence body follows Lezer's FencedCode; the item ends where its indentation ends.
 */
const taskFence: BlockParser = {
  name: "TaskFence",
  before: "FencedCode",
  parse(cx, line) {
    if (line.next !== 91 || !inBulletItem(cx)) return false;
    const match = /^\[[ xX]\][ \t]+(`{3,}|~{3,})/.exec(line.text.slice(line.pos));
    if (!match) return false;
    const text = line.text;
    const base = cx.lineStart;
    const fence = match[1]!;
    const marker = fence.charCodeAt(0);
    const fenceStart = line.pos + match[0].length - fence.length;
    const fenceEnd = fenceStart + fence.length;
    if (marker === 96 && text.indexOf("`", fenceEnd) >= 0) return false;
    const input = inputOf(cx);
    if (input && !/[-*+][ \t]+$/.test(input.read(base, base + line.pos))) return false;

    const box = base + line.pos;
    const from = base + fenceStart;
    const marks = [cx.elt("CodeMark", from, from + fence.length)];
    const infoFrom = line.skipSpace(fenceEnd);
    const infoTo = trimmedEnd(text);
    if (infoFrom < infoTo) marks.push(cx.elt("CodeInfo", base + infoFrom, base + infoTo));
    const itemIndent = line.baseIndent;
    let end = base + text.length;
    while (cx.nextLine() && line.baseIndent >= itemIndent) {
      let i = line.pos;
      if (line.indent - line.baseIndent < 4) while (line.text.charCodeAt(i) === marker) i++;
      for (const m of line.markers) marks.push(m);
      if (i - line.pos >= fence.length && line.skipSpace(i) === line.text.length) {
        marks.push(cx.elt("CodeMark", cx.lineStart + line.pos, cx.lineStart + i));
        end = cx.lineStart + line.text.length;
        cx.nextLine();
        break;
      }
      const textStart = cx.lineStart + line.basePos;
      end = cx.lineStart + line.text.length;
      if (textStart < end) marks.push(cx.elt("CodeText", textStart, end));
    }
    // The fence is a child of the Task so the Task node ends at a line end (Lezer reuses lines).
    const code = cx.elt("FencedCode", from, end, marks);
    cx.addElement(cx.elt("Task", box, end, [cx.elt("TaskMarker", box, box + 3), code]));
    return true;
  },
};

/**
 * Ruling R3 (NoteParser.swift `strayCloser`): after a list fence ended by an under-indented
 * line, the next bare matching fence line is that fence's hand-typed closer, not a new opener.
 * Decided from the text before the line (stateless), so incremental parses agree with full ones.
 */
export function isStrayCloser(input: Input, lineStart: number, text: string): boolean {
  let p = 0;
  while (p < text.length && isBlank(text.charCodeAt(p))) p++;
  const marker = text.charCodeAt(p);
  let length = 0;
  while (text.charCodeAt(p + length) === marker) length++;

  let opener: Fence | null = null;
  const between: string[] = [];
  for (let line = lineBefore(input, lineStart); line; line = lineBefore(input, line.from)) {
    if (line.text.includes("```") || line.text.includes("~~~")) {
      opener = openFence(line.text);
      if (opener) break;
    }
    between.push(line.text);
  }
  if (!opener || opener.listColumn === null || opener.marker !== marker || length < opener.length) return false;
  for (let i = between.length - 1; i >= 0; i--) {
    const kind = classifyFenceLine(opener, between[i]!);
    if (kind === "endedByIndent") return true;
    if (kind !== "content") return false;
  }
  const kind = classifyFenceLine(opener, text);
  return kind === "close" || kind === "endedByIndent";
}

const strayFence: BlockParser = {
  name: "StrayFence",
  before: "FencedCode",
  parse(cx, line) {
    const marker = line.next;
    if ((marker !== 96 && marker !== 126) || !isBareCloser(line.text, 0, marker, 3)) return false;
    const input = inputOf(cx);
    if (!input || !isStrayCloser(input, cx.lineStart, line.text)) return false;
    let markEnd = line.pos;
    while (line.text.charCodeAt(markEnd) === marker) markEnd++;
    const from = cx.lineStart + line.pos;
    const mark = cx.elt("CodeMark", from, cx.lineStart + markEnd);
    const to = cx.lineStart + line.text.length;
    cx.nextLine();
    cx.addElement(cx.elt("StrayFence", from, to, [mark]));
    return true;
  },
};

// ---------------------------------------------------------------------------------------------
// Tables (ruling M6-R1). Port of the Table block parser of @lezer/markdown 1.8.1
// (src/extension.ts; MIT License, Copyright (C) 2020 by Marijn Haverbeke
// and others). Changed for Bear: every row starts and ends with a cell
// separator `|`; a `|` inside an escape, code span, math, wiki link, link destination, URL or
// comment does not separate cells; the table ends at the first line that is not a row of it; a
// header row interrupts a paragraph on any line. Rows are decided from the line text with the
// rules NoteParser's TableScanner uses (dialect-grammar.ts), so Swift and the editor agree.

/** TableDelimiter and TableCell elements of a row (Lezer's parseRow, cells split at `separators`). */
function rowElements(cx: BlockContext, line: string, lineStart: number, separators: number[]): Element[] {
  const elts: Element[] = [];
  for (let k = 0; k < separators.length; k++) {
    const at = separators[k]!;
    elts.push(cx.elt("TableDelimiter", lineStart + at, lineStart + at + 1));
    const next = separators[k + 1];
    if (next === undefined) break;
    let cellStart = -1;
    let cellEnd = -1;
    let esc = false;
    for (let i = at + 1; i < next; i++) {
      const c = line.charCodeAt(i);
      if (esc || (c !== 32 && c !== 9)) {
        if (cellStart < 0) cellStart = i;
        cellEnd = i + 1;
      }
      esc = !esc && c === 92;
    }
    if (cellStart >= 0) {
      const from = lineStart + cellStart;
      const content = cx.parser.parseInline(line.slice(cellStart, cellEnd), from);
      elts.push(cx.elt("TableCell", from, lineStart + cellEnd, content));
    }
  }
  return elts;
}

/** Ends `leaf` before the current line the way Lezer's finishLeaf does (other leaf parsers, then a paragraph). */
function finishBefore(cx: BlockContext, leaf: LeafBlock, self: LeafBlockParser): void {
  for (const parser of leaf.parsers) if (parser !== self && parser.finish(cx, leaf)) return;
  const content = cx.parser.parseInline(leaf.content, leaf.start);
  cx.addLeafElement(leaf, cx.elt("Paragraph", leaf.start, leaf.start + leaf.content.length, content));
}

class TableParser implements LeafBlockParser {
  /** The table's rows so far; null while it is not (or not yet) a table. */
  private rows: Element[] | null = null;

  /** `header`: the leaf's first line when it has the shape of a header row, until line 2 decides. */
  constructor(
    private header: TableRowShape | null,
    private readonly headerLine: string,
    private readonly headerStart: number,
  ) {}

  nextLine(cx: BlockContext, line: Line, leaf: LeafBlock): boolean {
    const text = line.text;
    if (this.rows) {
      const row = tableRowOf(this.header!, text);
      if (row) {
        const elts = rowElements(cx, text, cx.lineStart, row.separators);
        this.rows.push(cx.elt("TableRow", cx.lineStart + row.shape.from, cx.lineStart + text.length, elts));
        return false;
      }
      cx.addLeafElement(leaf, cx.elt("Table", leaf.start, leaf.start + leaf.content.length, this.rows));
      return true;
    }
    const header = this.header;
    this.header = null;
    if (header && isTableDelimiterFor(header, this.headerLine, text)) {
      this.header = header;
      const separators = tableSeparators(this.headerLine, header)!;
      const shape = tableRowShape(text)!;
      this.rows = [
        cx.elt("TableHeader", leaf.start, leaf.start + leaf.content.length, rowElements(cx, this.headerLine, this.headerStart, separators)),
        cx.elt("TableDelimiter", cx.lineStart + shape.from, cx.lineStart + text.length),
      ];
      return false;
    }
    // From the line text, not line.pos: `2. | a |` continues a paragraph in Lezer (an ordered
    // list not starting at 1 cannot interrupt one) but is a list item with a table to Swift.
    if (tableHeader(text, cx.peekLine())) {
      finishBefore(cx, leaf, this);
      return true;
    }
    return false;
  }

  finish(cx: BlockContext, leaf: LeafBlock): boolean {
    if (!this.rows) return false;
    cx.addLeafElement(leaf, cx.elt("Table", leaf.start, leaf.start + leaf.content.length, this.rows));
    return true;
  }
}

export const BearTable: MarkdownConfig = {
  defineNodes: [
    { name: "Table", block: true },
    { name: "TableHeader", style: { "TableHeader/...": t.heading } },
    "TableRow",
    { name: "TableCell", style: t.content },
    { name: "TableDelimiter", style: t.processingInstruction },
  ],
  parseBlock: [
    {
      name: "Table",
      // Every paragraph gets one: a header row can interrupt it on any line (also lines indented
      // 4+ columns, which Lezer does not offer to endLeaf).
      leaf(cx, leaf) {
        const input = leaf.content.charCodeAt(0) === 124 ? inputOf(cx) : undefined;
        const line = input ? lineAt(input, cx.lineStart).text : "";
        const shape = input ? tableRowShape(line) : null;
        const header = shape && cx.lineStart + shape.from === leaf.start ? shape : null;
        return new TableParser(header, line, cx.lineStart);
      },
      before: "SetextHeading",
    },
  ],
};

/** Blocks that can contain fences (a Task only in the `- [ ] ```` form). */
const blockContainers = new Set(["Document", "BulletList", "OrderedList", "ListItem", "Blockquote", "Task"]);

type Cut = { from: number; to: number };

/**
 * Lookbehind (R3): a stray closer or bare fence opener depends on the lines back to the previous
 * fence line, and an edit can remove or create such a line anywhere before it, so every one in
 * [from, to) of a fragment after such an edit is reparsed (ruling R4: correctness first). Edits
 * that cannot change fence pairing do not count (`safeFragments`).
 */
function fencesAfter(f: Fragment, from: number, to: number, cuts: Cut[]): void {
  const off = f.offset;
  f.tree.iterate({
    from: from + off,
    to: to + off,
    enter(node) {
      const name = node.type.name;
      if (name === "StrayFence" || (name === "FencedCode" && !node.node.getChild("CodeInfo"))) {
        cuts.push({ from: node.from - off, to: node.to - off });
        return false;
      }
      return blockContainers.has(name);
    },
  });
}

/**
 * Lookahead (M6-R1): a header row interrupts the paragraph before it only when the next line is a
 * matching delimiter row. Lezer never reuses the node on the line right before an edit, but that
 * paragraph ends one line earlier, so it is reparsed whenever an edit reaches the delimiter row.
 */
function tablesBefore(f: Fragment, cuts: Cut[]): void {
  const off = f.offset;
  const end = f.to + off;
  f.tree.iterate({
    from: Math.max(0, end - 1),
    to: end,
    enter(node) {
      if (node.name === "Table") {
        const delimiter = node.node.getChildren("TableDelimiter")[0];
        const prev = node.node.prevSibling;
        if (prev && (!delimiter || delimiter.to >= end)) cuts.push({ from: prev.from - off, to: node.to - off });
        return false;
      }
      return blockContainers.has(node.name);
    },
  });
}

/** Lookahead: unclosed `$$` / `<!--` lines (top level only) flip when a closer is typed later. */
function unclosedOpenersIn(f: Fragment, cuts: Cut[]): void {
  const off = f.offset;
  const c = f.tree.cursor();
  for (let more = c.firstChild(); more && c.from < f.to + off; more = c.nextSibling()) {
    if (c.name === "UnclosedOpener" && c.from >= f.from + off) cuts.push({ from: c.from - off, to: c.to - off });
  }
}

/**
 * Keeps nodes whose meaning depends on text outside them out of incremental reuse when that
 * text changed: bare fence nodes after an edit (earlier lines), unclosed `$$`/`<!--` lines and
 * a first-line `---` before an edit (later lines). Lezer has no public hook for this, so the
 * parse's fragment cursor is rebuilt (pinned @lezer/markdown; covered by the incremental tests).
 *
 * Only what the parse can use is looked at: Lezer's cursor moves through the fragments in order,
 * so a fragment is used only past the end of the ones before it, and a parse stopped at `stop`
 * (the editor parses long notes up to the viewport) does not need a fragment that has to be cut
 * beyond it, so that fragment ends there.
 */
function stabilizeFragments(inner: object, input: Input, fragments: readonly Fragment[], stop: number | null): void {
  const holder = inner as { fragments?: unknown };
  const cursor = holder.fragments;
  if (!fragments.length || !cursor || typeof cursor !== "object") return;
  const cuts: Cut[] = [];
  const first = lineAt(input, 0);
  if (trimmedEquals(first.text, "---")) cuts.push({ from: 0, to: first.to + 1 });
  const safe = safeFragments(input, fragments);
  let reach = 0;
  let trimmed = false;
  const spans = fragments.map((f, i) => {
    const from = Math.max(f.from, reach);
    reach = Math.max(reach, f.to);
    const to = safe[i] || stop === null ? f.to : Math.min(f.to, stop);
    if (from !== f.from || to !== f.to) trimmed = true;
    if (!safe[i] && from < to) fencesAfter(f, from, to, cuts); // something before it changed
    if (f.to < input.length) {
      // something after it changed
      unclosedOpenersIn(f, cuts);
      tablesBefore(f, cuts);
    }
    return { from, to };
  });
  if (fragments.some((f, i) => safe[i] && (f.from > 0 || f.offset !== 0))) fenceGuardStats.skipped++;
  if (!cuts.length && !trimmed) return;
  cuts.sort((a, b) => a.from - b.from);
  const FragmentClass = fragments[0]!.constructor as new (
    from: number,
    to: number,
    tree: Fragment["tree"],
    offset: number,
    openStart: boolean,
    openEnd: boolean,
  ) => Fragment;
  const kept: Fragment[] = [];
  fragments.forEach((f, i) => {
    let { from } = spans[i]!;
    const { to } = spans[i]!;
    let openStart = from === f.from ? f.openStart : true;
    const openEnd = to === f.to ? f.openEnd : true;
    for (const cut of cuts) {
      if (cut.to <= from || cut.from >= to) continue;
      if (cut.from > from) kept.push(new FragmentClass(from, cut.from, f.tree, f.offset, openStart, true));
      from = Math.max(from, cut.to);
      openStart = true;
    }
    if (from < to) kept.push(new FragmentClass(from, to, f.tree, f.offset, openStart, openEnd));
  });
  const CursorClass = cursor.constructor as new (fragments: readonly Fragment[], input: Input) => unknown;
  holder.fragments = kept.length ? new CursorClass(kept, input) : null;
}

// ---------------------------------------------------------------------------------------------
// Fence pairing guard (final review I2): most keystrokes cannot change which fence lines pair,
// so the R4 walk over every bare fence after the edit is skipped for them.

/** Parses that skipped the bare-fence walk (tests check that the skip path runs). */
export const fenceGuardStats = { skipped: 0 };

/**
 * The input each parse ran over, keyed by the children of the tree it returned (finished or
 * stopped). Keyed by the children because markdown()'s mixed-parse wrapper hands the editor a
 * stopped tree as a new Tree over the same children.
 */
const treeInputs = new WeakMap<object, Input>();
const treeKey = (tree: Fragment["tree"]): object => tree.children;

/** Leading indentation, quote and list markers and a task box: what the fence rules look at. */
const BLOCK_PREFIX = /^(?:[ \t]*(?:>|[-*+](?=[ \t]|$)|\d{1,9}[.)](?=[ \t]|$)|\[[ xX]\](?=[ \t]|$)))*[ \t]*/;
const FENCE_RUNS = /`{3,}|~{3,}/g;
/** HTML/comment, math and front matter/rule markers: their blocks pair lines too. */
const PAIRING_MARKERS = /<|\$\$|---|-->/;
/** Whitespace the dialect trims (`\p{White_Space}`) but `String.trimEnd()` may not (U+0085…). */
const NON_ASCII_SPACE = /[^\x00-\x7F](?<=\p{White_Space})/u;
const MAX_EDIT = 4096;
const MAX_LINE = 10_000;

/**
 * Whether turning `oldLine` into `newLine` (the change starting at `oldAt` / `newAt`) leaves every
 * fence rule's view of the line alone: both lines have content after the same block prefix, the
 * change is after the prefix, no fence marker is added or removed, and neither line starts a
 * fence or contains `<`, `$$` or `---`.
 */
export function editKeepsFencePairing(oldLine: string, newLine: string, oldAt: number, newAt: number): boolean {
  const prefix = BLOCK_PREFIX.exec(oldLine)![0];
  if (BLOCK_PREFIX.exec(newLine)![0] !== prefix || oldAt < prefix.length || newAt < prefix.length) return false;
  for (const line of [oldLine, newLine]) {
    // Non-ASCII whitespace: the dialect's blank-line test and JS's can disagree; re-parse.
    if (NON_ASCII_SPACE.test(line)) return false;
    if (line.trimEnd().length <= prefix.length || PAIRING_MARKERS.test(line)) return false;
    const next = line.charCodeAt(prefix.length);
    if (next === 96 || next === 126) return false;
  }
  const oldRuns = oldLine.match(FENCE_RUNS);
  const newRuns = newLine.match(FENCE_RUNS);
  if (oldRuns || newRuns) {
    if (String(oldRuns) !== String(newRuns) || openFence(oldLine) || openFence(newLine)) return false;
  }
  return true;
}

/** The line around `pos`, or null when it is longer than MAX_LINE. */
function boundedLineAround(input: Input, pos: number): DocLine | null {
  let from = pos;
  while (from > 0) {
    const chunkFrom = Math.max(0, from - CHUNK);
    const nl = input.read(chunkFrom, from).lastIndexOf("\n");
    if (nl >= 0) {
      from = chunkFrom + nl + 1;
      break;
    }
    from = chunkFrom;
    if (pos - from > MAX_LINE) return null;
  }
  let text = input.read(from, pos);
  for (let to = pos; to < input.length; ) {
    const chunk = input.read(to, Math.min(input.length, to + CHUNK));
    const nl = chunk.indexOf("\n");
    if (nl >= 0) return { from, to: to + nl, text: text + chunk.slice(0, nl) };
    text += chunk;
    to += chunk.length;
    if (text.length > MAX_LINE) return null;
  }
  return { from, to: input.length, text };
}

/** Whether old[oldFrom, oldTo) → input[newFrom, newTo) (one gap between fragments) keeps pairing. */
function gapKeepsFencePairing(old: Input, oldFrom: number, oldTo: number, input: Input, newFrom: number, newTo: number): boolean {
  if (oldTo < oldFrom || newTo < newFrom || oldTo > old.length) return false;
  if (oldTo - oldFrom > MAX_EDIT || newTo - newFrom > MAX_EDIT) return false;
  const a = old.read(oldFrom, oldTo);
  const b = input.read(newFrom, newTo);
  if (a === b) return true;
  // The smallest region that differs; every other line reads the same in both texts.
  let start = 0;
  while (start < a.length && start < b.length && a.charCodeAt(start) === b.charCodeAt(start)) start++;
  let end = 0;
  while (end < a.length - start && end < b.length - start && a.charCodeAt(a.length - 1 - end) === b.charCodeAt(b.length - 1 - end)) end++;
  if (a.slice(start, a.length - end).includes("\n") || b.slice(start, b.length - end).includes("\n")) return false;
  const oldLine = boundedLineAround(old, oldFrom + start);
  const newLine = boundedLineAround(input, newFrom + start);
  if (!oldLine || !newLine) return false;
  return editKeepsFencePairing(oldLine.text, newLine.text, oldFrom + start - oldLine.from, newFrom + start - newLine.from);
}

/**
 * For each fragment: whether no edit before it can have changed fence pairing since its tree
 * was parsed. The edits are the gaps between the fragments of the same tree, read back from the
 * input that parse ran over; a tree without a recorded input counts as edited.
 */
function safeFragments(input: Input, fragments: readonly Fragment[]): boolean[] {
  const seen = new Map<object, { oldEnd: number; newEnd: number; safe: boolean }>();
  return fragments.map((f) => {
    const key = treeKey(f.tree);
    const old = treeInputs.get(key);
    if (!old) return false;
    let state = seen.get(key);
    if (!state) seen.set(key, (state = { oldEnd: 0, newEnd: 0, safe: true }));
    if (state.safe) state.safe = gapKeepsFencePairing(old, state.oldEnd, f.from + f.offset, input, state.newEnd, f.from);
    state.oldEnd = f.to + f.offset;
    state.newEnd = f.to;
    return state.safe;
  });
}

/**
 * Stabilizes the fragments on the first `advance` (once the editor has set where the parse
 * stops) and records the input of the tree the parse returns, for the next parse's guard.
 */
function instrument(parse: WrapArgs[0], input: Input, fragments: readonly Fragment[]): void {
  const advance = parse.advance.bind(parse);
  let stabilized = false;
  parse.advance = () => {
    if (!stabilized) {
      stabilized = true;
      stabilizeFragments(parse, input, fragments, parse.stoppedAt);
    }
    const tree = advance();
    if (tree) treeInputs.set(treeKey(tree), input);
    return tree;
  };
}

export const BearBlocks: MarkdownConfig = {
  defineNodes: [
    { name: "FrontMatter", block: true },
    "FrontMatterMark",
    { name: "MathBlock", block: true },
    "MathMark",
    { name: "StrayFence", block: true },
    { name: "UnclosedOpener", block: true },
    { name: "Task", block: true },
    "TaskMarker",
  ],
  parseBlock: [frontMatter, strayFence, taskFence, mathBlock, atxHeading, commentBlock, taskList],
  remove: ["SetextHeading", "IndentedCode", "LinkReference"],
  wrap: (inner, input, fragments) => {
    inputs.set(inner, input);
    instrument(inner, input, fragments);
    return inner;
  },
};
