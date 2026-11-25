// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The static note renderer (M8-R5, M8-R6): Bear-dialect Markdown → an HTML body, for HTML/PDF
// export, print and Copy As. One recursive walk over the Lezer tree of the editor's own parser
// emits strings (no DOM, so it runs in node and in the export page). Block constructs read the
// editor's models (headings, wiki links, tables, callouts, footnotes, attachments, code blocks),
// never a second regex parse.
//
// Safety (Review Focus 4): every piece of note text goes through `escapeHTML`, raw HTML and
// entities are text, comments are dropped, a link is an `<a href>` only for the schemes
// `safeHref` allows, and nothing the body holds loads from the network: a non-attachment image
// becomes a link, Mermaid diagrams are `<img>` data URLs, math is the injected (sanitized) SVG.

import { EditorState, type Text } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import type { SyntaxNode, Tree } from "@lezer/common";
import { codePointAt, isBlank, parseWikiLink } from "../editor/dialect-grammar";
import { headingsInDocument } from "../editor/conformance";
import { bearMarkdown, highlightColors } from "../editor/dialect";
import { type Attachment, attachmentsIn, formatBytes } from "../editor/features/attachments";
import { calloutAt } from "../editor/features/callouts";
import { codeBlockText, fenceLanguage } from "../editor/features/codeblocks";
import { type Footnote, footnotesIn } from "../editor/features/footnotes";
import { MAX_TEX } from "../editor/features/math-render";
import { MAX_MERMAID_SOURCE } from "../editor/features/mermaid-render";
import { type CellRef, cellRuns, tableModel } from "../editor/features/table-model";
import { MAX_GRID_ROWS } from "../editor/features/tables";
import { bearchenRed } from "../editor/theme";
import { highlightCode } from "./highlight";

export type RenderMode = "document" | "richText";
/** SVG markup, already sanitized; `null` = failed. */
export type BlockRenderers = {
  math?: (tex: string, display: boolean) => Promise<string | null>;
  mermaid?: (source: string) => Promise<string | null>;
};
export type RenderInput = {
  text: string;
  mode: RenderMode;
  attachmentSources: Record<string, string>;
  /** Byte sizes by filename for the file cards (optional; without one a card shows name and type). */
  attachmentSizes?: Record<string, number>;
  wikiLinks: ({ href: string } | null)[];
};
export type RenderedBody = { body: string; headings: { level: number; text: string; anchor: string }[] };

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Text and attribute values: `& < > " '` escaped. */
export function escapeHTML(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ESCAPES[c]!);
}

const SAFE_SCHEMES = new Set(["http", "https", "mailto", "theonotes", "baerchen", "bear"]);
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
const SCHEME = /^([a-z][a-z0-9+.-]*):/i;

/** The trimmed URL when its scheme is http, https, mailto, theonotes, baerchen or bear; null otherwise. */
export function safeHref(url: string): string | null {
  const s = url.trim();
  if (!s || CONTROL.test(s)) return null;
  const scheme = SCHEME.exec(s)?.[1]?.toLowerCase();
  return scheme && SAFE_SCHEMES.has(scheme) ? s : null;
}

/** A link the host made (wiki links): relative or a fragment as given, a URL only through `safeHref`. */
function hostHref(href: string): string | null {
  const s = href.trim();
  // `//host/x` (and its backslash spellings) is a network path, not a relative link.
  if (!s || CONTROL.test(s) || NETWORK_PATH.test(s)) return null;
  return SCHEME.test(s) ? safeHref(s) : s;
}

const NETWORK_PATH = /^[\\/][\\/]/;
const DATA_IMAGE = /^data:image\/(?:png|jpeg|gif|webp|heic);base64,[A-Za-z0-9+/]*={0,2}$/;

/**
 * An attachment source the host gave, when the export page may load it: a relative path (no
 * scheme, not starting with `/` or `\`), a `baerchen-asset:` URL, or a base64 raster `data:`
 * image (no SVG: image SVG is not sanitized here). Null for anything else (M8-R30).
 */
function attachmentSource(src: string): string | null {
  if (!src || CONTROL.test(src) || src.trim() !== src) return null;
  if (DATA_IMAGE.test(src) || src.startsWith("baerchen-asset:")) return src;
  return SCHEME.test(src) || /^[\\/]/.test(src) ? null : src;
}

const FORMULA_FAILED = "The formula could not be rendered";
const DIAGRAM_FAILED = "The diagram could not be rendered";
const tooLong = (tex: string) => `Formula too long (${tex.length} characters, at most ${MAX_TEX})`;

/** Rich text: highlight colours of the default light theme as fixed backgrounds (M8-R6). */
function highlightBackground(color: string | undefined): string {
  const key = (color ? `--bc-highlight-${color}` : "--bc-highlight") as keyof typeof bearchenRed;
  return bearchenRed[key] ?? bearchenRed["--bc-highlight"];
}

function fileKind(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toUpperCase() : "File";
}

/** Line endings as conformance.ts (and Swift's NoteParser) see them: BOM dropped, CRLF → LF. */
const normalized = (text: string) => text.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/\r$/, "");

type Part = string | Promise<string>;
type Range = { from: number; to: number };

class Renderer {
  private parts: Part[] = [];
  private readonly rich: boolean;
  private readonly doc: Text;
  private readonly wikiIndex = new Map<number, number>();
  private readonly headingIds = new Map<number, number>();
  private readonly footnoteAt = new Map<number, Footnote>();
  private readonly definitionAt = new Map<number, Footnote>();
  private readonly attachmentAt = new Map<number, Attachment>();
  private readonly refCounts = new Map<string, number>();
  private readonly definitions: { label: string; parts: Part[] }[] = [];

  constructor(
    private readonly input: RenderInput,
    private readonly renderers: BlockRenderers | undefined,
    private readonly text: string,
    private readonly state: EditorState,
    private readonly tree: Tree,
    headingLines: readonly number[],
  ) {
    this.rich = input.mode === "richText";
    this.doc = state.doc;
    headingLines.forEach((line, i) => this.headingIds.set(line, i + 1));
    // The i-th wiki link of `wikiLinksInDocument`: the same walk over the same tree.
    let wiki = 0;
    tree.iterate({
      enter: (node) => {
        if (node.name !== "WikiLink") return;
        this.wikiIndex.set(node.from, wiki++);
        return false;
      },
    });
    for (const f of footnotesIn(state, undefined, tree)) {
      this.footnoteAt.set(f.from, f);
      if (f.kind === "def") this.definitionAt.set(f.from, f);
    }
    for (const a of attachmentsIn(state)) this.attachmentAt.set(a.from, a);
  }

  async render(): Promise<string> {
    this.children(this.tree.topNode);
    this.footnoteSection();
    return (await Promise.all(this.parts)).join("");
  }

  private emit(part: Part): void {
    this.parts.push(part);
  }

  private slice(from: number, to: number): string {
    return this.text.slice(from, to);
  }

  // -------------------------------------------------------------------------------------------
  // Blocks

  private children(node: SyntaxNode): void {
    for (let child = node.firstChild; child; child = child.nextSibling) this.block(child);
  }

  private block(node: SyntaxNode): void {
    switch (node.name) {
      case "FrontMatter":
      case "QuoteMark":
      case "ListMark":
        return;
      case "ATXHeading1":
      case "ATXHeading2":
      case "ATXHeading3":
      case "ATXHeading4":
      case "ATXHeading5":
      case "ATXHeading6":
        return this.heading(node);
      case "BulletList":
      case "OrderedList":
        return this.list(node);
      case "Blockquote":
        return this.quote(node);
      case "Table":
        return this.table(node);
      case "FencedCode":
        return this.fencedCode(node);
      case "MathBlock":
        return this.mathBlock(node);
      case "CommentBlock":
        return this.commentBlock(node);
      case "HorizontalRule":
        return this.emit("<hr>\n");
      case "StrayFence":
        return this.emit(`<p>${escapeHTML(this.slice(node.from, node.to))}</p>\n`);
      default:
        // Paragraph, UnclosedOpener (a `$$` / `<!--` line without closer is prose), anything else.
        this.paragraph(node, node.from);
    }
  }

  private skipBlanks(pos: number, to = this.text.length): number {
    while (pos < to && isBlank(this.text.charCodeAt(pos))) pos++;
    return pos;
  }

  private trimEnd(from: number, to: number): number {
    while (to > from && isBlank(this.text.charCodeAt(to - 1))) to--;
    return to;
  }

  /** Where a line's inline content starts: after blanks and the quote marks of its containers. */
  private contentStart(pos: number): number {
    for (;;) {
      pos = this.skipBlanks(pos);
      const node = this.tree.resolveInner(pos, 1);
      if (node.name !== "QuoteMark" || node.from !== pos) return pos;
      pos = node.to;
    }
  }

  /**
   * The inline lines of `node` from `start`: one range per source line (each line of
   * a paragraph as a line), container markup and surrounding blanks left out. A footnote
   * definition line is taken out of the flow into the footnotes section.
   */
  private lines(node: SyntaxNode, start: number): Range[] {
    const out: Range[] = [];
    if (start >= node.to) return out;
    let line = this.doc.lineAt(start);
    for (let first = true; ; first = false) {
      const from = this.contentStart(first ? start : line.from);
      const end = Math.min(line.to, node.to);
      const definition = this.definitionAt.get(from);
      if (definition) this.definition(node, definition, end);
      else {
        const to = this.trimEnd(from, end);
        if (to > from) out.push({ from, to });
      }
      if (line.to >= node.to || line.number >= this.doc.lines) break;
      line = this.doc.line(line.number + 1);
    }
    return out;
  }

  /** A paragraph (`<p>`, or bare in a list item) of the lines of `node` from `start`. */
  private paragraph(node: SyntaxNode, start: number, bare = false): boolean {
    const lines = this.lines(node, start);
    if (lines.length === 0) return false;
    if (!bare) this.emit("<p>");
    lines.forEach((range, i) => {
      if (i > 0) this.emit("<br>\n");
      this.inline(node, range.from, range.to);
    });
    if (!bare) this.emit("</p>\n");
    return true;
  }

  private heading(node: SyntaxNode): void {
    const level = Number(node.name.slice(-1));
    const marks = node.getChildren("HeaderMark");
    const from = this.skipBlanks(marks[0]?.to ?? node.from, node.to);
    const to = this.trimEnd(from, marks.length > 1 ? marks.at(-1)!.from : node.to);
    if (to <= from) return;
    const n = this.headingIds.get(this.doc.lineAt(node.from).number);
    this.emit(`<h${level}${n && !this.rich ? ` id="h-${n}"` : ""}>`);
    this.inline(node, from, to);
    this.emit(`</h${level}>\n`);
  }

  private list(node: SyntaxNode): void {
    const tag = node.name === "OrderedList" ? "ol" : "ul";
    let start = "";
    if (tag === "ol") {
      const mark = node.firstChild?.getChild("ListMark");
      const n = mark ? Number.parseInt(this.slice(mark.from, mark.to), 10) : 1;
      if (Number.isFinite(n) && n !== 1) start = ` start="${n}"`;
    }
    this.emit(`<${tag}${start}>\n`);
    for (let item = node.firstChild; item; item = item.nextSibling) if (item.name === "ListItem") this.item(item);
    this.emit(`</${tag}>\n`);
  }

  private item(node: SyntaxNode): void {
    const blocks: SyntaxNode[] = [];
    for (let child = node.firstChild; child; child = child.nextSibling) if (child.name !== "ListMark") blocks.push(child);
    const first = blocks[0];
    let rest = blocks.slice(1);
    if (first?.name === "Task") {
      const marker = first.getChild("TaskMarker");
      const checked = marker ? this.text[marker.from + 1] !== " " : false;
      if (this.rich) this.emit(`<li>${checked ? "☑" : "☐"} `);
      else this.emit(`<li class="bc-todo"><input type="checkbox" disabled${checked ? " checked" : ""}> `);
      // `- [ ] ```` holds its fenced block (dialect-blocks.ts TaskFence).
      const fence = first.getChild("FencedCode");
      if (fence) rest = [fence, ...rest];
      else this.paragraph(first, marker?.to ?? first.from, true);
    } else {
      this.emit("<li>");
      if (first?.name === "Paragraph") this.paragraph(first, first.from, true);
      else if (first) rest = blocks;
    }
    if (rest.length > 0) {
      this.emit("\n");
      for (const block of rest) this.block(block);
    }
    this.emit("</li>\n");
  }

  private quote(node: SyntaxNode): void {
    const blocks: SyntaxNode[] = [];
    for (let child = node.firstChild; child; child = child.nextSibling) if (child.name !== "QuoteMark") blocks.push(child);
    const callout = calloutAt(this.state, node.from);
    if (!callout) {
      this.emit("<blockquote>\n");
      for (const block of blocks) this.block(block);
      this.emit("</blockquote>\n");
      return;
    }
    // The marker's line is the title (the text after the marker, else the type's default).
    const holder = blocks.find((b) => b.from <= callout.markerFrom && callout.markerFrom < b.to && b.name === "Paragraph");
    const titleEnd = Math.min(this.doc.lineAt(callout.markerTo).to, holder?.to ?? callout.markerTo);
    this.emit(this.rich ? "<blockquote>\n<p><strong>" : `<aside class="bc-callout bc-callout-${callout.type}">\n<p class="bc-callout-title">`);
    if (callout.custom && holder) {
      const from = this.skipBlanks(callout.markerTo, titleEnd);
      this.inline(holder, from, this.trimEnd(from, titleEnd));
    } else this.emit(escapeHTML(callout.title));
    this.emit(this.rich ? "</strong></p>\n" : "</p>\n");
    for (const block of blocks) {
      if (block === holder) this.paragraph(block, titleEnd + 1);
      else this.block(block);
    }
    this.emit(this.rich ? "</blockquote>\n" : "</aside>\n");
  }

  private table(node: SyntaxNode): void {
    const model = tableModel(this.state, node);
    // Over MAX_GRID_ROWS the editor shows the source (M6-R82); the export keeps a table but
    // fills it with each cell's plain text, as the grid would show it, comments omitted (M8-R27).
    const plain = 1 + model.rows.length > MAX_GRID_ROWS;
    const cells = new Map<number, SyntaxNode>();
    if (!plain) {
      for (let row = node.firstChild; row; row = row.nextSibling) {
        if (row.name !== "TableHeader" && row.name !== "TableRow") continue;
        for (let cell = row.firstChild; cell; cell = cell.nextSibling) if (cell.name === "TableCell") cells.set(cell.from, cell);
      }
    }
    let columns = Math.max(model.header.length, 1);
    for (const row of model.rows) columns = Math.max(columns, row.length);
    const style = (c: number) => (model.align[c] ? ` style="text-align:${model.align[c]}"` : "");
    const row = (refs: readonly CellRef[], tag: "th" | "td") => {
      this.emit("<tr>");
      for (let c = 0; c < columns; c++) {
        this.emit(`<${tag}${style(c)}>`);
        const ref = refs[c];
        if (ref && plain) this.emit(this.plainCell(ref));
        else if (ref) {
          const cell = cells.get(ref.contentFrom);
          if (cell) this.inline(cell, cell.from, cell.to, true);
        }
        this.emit(`</${tag}>`);
      }
      this.emit("</tr>\n");
    };
    this.emit("<table>\n<thead>\n");
    row(model.header, "th");
    this.emit("</thead>\n<tbody>\n");
    for (const refs of model.rows) row(refs, "td");
    this.emit("</tbody>\n</table>\n");
  }

  /** A cell's text as the grid shows it (`cellRuns`), escaped, comments left out. */
  private plainCell(ref: CellRef): string {
    const comments: Range[] = [];
    this.tree.iterate({
      from: ref.contentFrom,
      to: ref.contentTo,
      enter: (node) => {
        if (node.name !== "Comment") return;
        comments.push({ from: node.from, to: node.to });
        return false;
      },
    });
    let out = "";
    for (const run of cellRuns(this.state, ref, this.tree)) {
      if (run.kind === "br") {
        out += "<br>";
        continue;
      }
      // A text run is the source from run.from on (runs never cross hidden markup).
      const end = run.from + run.text.length;
      let pos = run.from;
      for (const c of comments) {
        if (c.to <= pos || c.from >= end) continue;
        if (c.from > pos) out += escapeHTML(this.slice(pos, c.from));
        pos = Math.max(pos, c.to);
      }
      if (pos < end) out += escapeHTML(this.slice(pos, end));
    }
    return out;
  }

  private fencedCode(node: SyntaxNode): void {
    const language = fenceLanguage(this.state, node);
    const code = codeBlockText(this.state, node);
    if (this.rich) return this.emit(`<pre><code>${escapeHTML(code)}</code></pre>\n`);
    if (language.toLowerCase() === "mermaid") return this.emit(this.diagram(code));
    this.emit(highlightCode(code, language).then((html) => `<pre class="bc-code"><code>${html}</code></pre>\n`));
  }

  private diagram(source: string): Part {
    const fallback = (error?: string) =>
      `<pre class="bc-mermaid-source"><code>${escapeHTML(source)}</code></pre>\n` +
      (error ? `<p class="bc-render-error">${escapeHTML(error)}</p>\n` : "");
    if (source.length > MAX_MERMAID_SOURCE) return fallback("Diagram too large");
    const render = this.renderers?.mermaid;
    if (!render) return fallback();
    return render(source).then(
      (svg) => {
        if (svg === null) return fallback(DIAGRAM_FAILED);
        const src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
        return `<figure class="bc-mermaid"><img alt="" src="${escapeHTML(src)}"></figure>\n`;
      },
      () => fallback(DIAGRAM_FAILED),
    );
  }

  private mathBlock(node: SyntaxNode): void {
    const source = this.slice(node.from, node.to);
    if (this.rich) return this.emit(`<pre><code>${escapeHTML(source)}</code></pre>\n`);
    const first = this.doc.lineAt(node.from).number;
    const last = this.doc.lineAt(node.to).number;
    const tex = last - first < 2 ? "" : this.doc.sliceString(this.doc.line(first + 1).from, this.doc.line(last - 1).to);
    this.emit(this.formula(tex, true, source, true));
  }

  /** A formula: the renderer's SVG, else its source (and an error line when it cannot render). */
  private formula(tex: string, display: boolean, source: string, block: boolean): Part {
    const fallback = (error?: string) =>
      block
        ? `<pre class="bc-math-source"><code>${escapeHTML(source)}</code></pre>\n` + (error ? `<p class="bc-render-error">${escapeHTML(error)}</p>\n` : "")
        : `<code class="bc-math-source">${escapeHTML(source)}</code>` + (error ? `<span class="bc-render-error">${escapeHTML(error)}</span>` : "");
    if (tex.length > MAX_TEX) return fallback(tooLong(tex));
    const render = this.renderers?.math;
    if (!render || !/\S/.test(tex)) return fallback();
    return render(tex, display).then(
      (svg) => {
        if (svg === null) return fallback(FORMULA_FAILED);
        return block ? `<div class="bc-math bc-math-display">${svg}</div>\n` : `<span class="bc-math${display ? " bc-math-display" : ""}">${svg}</span>`;
      },
      () => fallback(FORMULA_FAILED),
    );
  }

  /** Prose after the `-->` that closes a comment block. */
  private commentBlock(node: SyntaxNode): void {
    const last = this.doc.lineAt(node.to);
    const close = last.text.indexOf("-->");
    if (close >= 0) this.paragraph(node, last.from + close + 3);
  }

  private definition(node: SyntaxNode, f: Footnote, end: number): void {
    const saved = this.parts;
    this.parts = [];
    const from = this.skipBlanks(f.to + 1, end);
    this.inline(node, from, this.trimEnd(from, end));
    this.definitions.push({ label: f.label, parts: this.parts });
    this.parts = saved;
  }

  private footnoteSection(): void {
    if (this.definitions.length === 0) return;
    this.emit(this.rich ? "<hr>\n<ol>\n" : '<section class="bc-footnotes">\n<ol>\n');
    const seen = new Set<string>();
    for (const { label, parts } of this.definitions) {
      const firstOfLabel = !seen.has(label);
      seen.add(label);
      if (this.rich) this.emit("<li>");
      else if (!firstOfLabel) this.emit("<li>");
      else this.emit(`<li id="fn-${escapeHTML(label)}"${/^[1-9]\d{0,8}$/.test(label) ? ` value="${label}"` : ""}>`);
      this.parts.push(...parts);
      if (!this.rich && firstOfLabel && this.refCounts.has(label)) {
        this.emit(` <a class="bc-fn-back" href="#fnref-${escapeHTML(encodeURIComponent(label))}">↩</a>`);
      }
      this.emit("</li>\n");
    }
    this.emit(this.rich ? "</ol>\n" : "</ol>\n</section>\n");
  }

  // -------------------------------------------------------------------------------------------
  // Inline

  /** The inline content of `node` within [from, to). `cell`: `<br>` in text is a line break. */
  private inline(node: SyntaxNode, from: number, to: number, cell = false): void {
    let pos = from;
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (child.to <= pos) continue;
      if (child.from >= to) break;
      if (child.from > pos) this.plain(pos, child.from, cell);
      pos = Math.max(pos, this.element(child, Math.max(pos, child.from), Math.min(to, child.to), cell));
    }
    if (pos < to) this.plain(pos, to, cell);
  }

  private plain(from: number, to: number, cell: boolean): void {
    const text = this.slice(from, to);
    this.emit(cell ? text.split(/<br\s*\/?>/i).map(escapeHTML).join("<br>") : escapeHTML(text));
  }

  private wrap(open: string, close: string, node: SyntaxNode, from: number, to: number, cell: boolean): number {
    this.emit(open);
    this.inline(node, from, to, cell);
    this.emit(close);
    return to;
  }

  /** Emits `node` clipped to [from, to); returns where the text after it starts. */
  private element(node: SyntaxNode, from: number, to: number, cell: boolean): number {
    switch (node.name) {
      case "EmphasisMark":
      case "StrikethroughMark":
      case "HighlightMark":
      case "UnderlineMark":
      case "QuoteMark":
      case "HardBreak":
      case "Comment":
        return to;
      case "Emphasis":
        return this.wrap("<em>", "</em>", node, from, to, cell);
      case "StrongEmphasis":
        return this.wrap("<strong>", "</strong>", node, from, to, cell);
      case "Strikethrough":
        return this.wrap("<s>", "</s>", node, from, to, cell);
      case "Underline":
        return this.wrap("<u>", "</u>", node, from, to, cell);
      case "Highlight": {
        const mark = node.getChild("HighlightColor");
        const color = mark ? highlightColors[codePointAt(this.slice(mark.from, mark.to), 0)] : undefined;
        const open = this.rich
          ? `<span style="background-color:${highlightBackground(color)}">`
          : `<mark class="bc-hl${color ? ` bc-hl-${color}` : ""}">`;
        return this.wrap(open, this.rich ? "</span>" : "</mark>", node, from, to, cell);
      }
      case "HighlightColor":
        if (node.parent?.name === "Highlight") return to;
        break;
      case "InlineCode": {
        const marks = node.getChildren("CodeMark");
        const a = Math.max(from, marks[0]?.to ?? node.from);
        const b = Math.min(to, marks.length > 1 ? marks.at(-1)!.from : node.to);
        this.emit(`<code>${escapeHTML(this.slice(a, Math.max(a, b)))}</code>`);
        return to;
      }
      case "Tag": {
        const tag = escapeHTML(this.slice(from, to));
        this.emit(this.rich ? tag : `<span class="bc-tag">${tag}</span>`);
        return to;
      }
      case "WikiLink":
        this.wikiLink(node);
        return to;
      case "Link":
        return this.link(node, from, to, cell);
      case "Image":
        return this.image(node, from, to, cell);
      case "Autolink": {
        const url = node.getChild("URL");
        const href = url ? safeHref(this.slice(url.from, url.to)) : null;
        if (href && url) this.emit(`<a href="${escapeHTML(href)}">${escapeHTML(this.slice(url.from, url.to))}</a>`);
        else this.plain(from, to, cell);
        return to;
      }
      case "URL": {
        const href = safeHref(this.slice(node.from, node.to));
        if (href) this.emit(`<a href="${escapeHTML(href)}">${escapeHTML(this.slice(from, to))}</a>`);
        else this.plain(from, to, cell);
        return to;
      }
      case "Escape":
        this.emit(escapeHTML(this.slice(Math.max(from, node.from + 1), to)));
        return to;
      case "InlineMath":
        this.inlineMath(node, from, to, cell);
        return to;
    }
    this.inline(node, from, to, cell);
    return to;
  }

  private wikiLink(node: SyntaxNode): void {
    const index = this.wikiIndex.get(node.from);
    const given = index === undefined ? null : (this.input.wikiLinks[index] ?? null);
    const href = given ? hostHref(given.href) : null;
    const source = this.slice(node.from, node.to);
    const display = escapeHTML(parseWikiLink(source, 0)?.display ?? source);
    if (this.rich) this.emit(href ? `<a href="${escapeHTML(href)}">${display}</a>` : display);
    else if (href) this.emit(`<a class="bc-wikilink" href="${escapeHTML(href)}">${display}</a>`);
    else this.emit(`<span class="bc-wikilink">${display}</span>`);
  }

  private footnoteRef(f: Footnote): void {
    const n = (this.refCounts.get(f.label) ?? 0) + 1;
    this.refCounts.set(f.label, n);
    const label = escapeHTML(f.label);
    if (this.rich) return this.emit(`<sup>${label}</sup>`);
    const href = escapeHTML(`#fn-${encodeURIComponent(f.label)}`);
    this.emit(`<sup class="bc-fn-ref"><a href="${href}" id="fnref-${label}${n > 1 ? `-${n}` : ""}">${label}</a></sup>`);
  }

  private link(node: SyntaxNode, from: number, to: number, cell: boolean): number {
    const footnote = this.footnoteAt.get(node.from);
    if (footnote && footnote.to === node.to) {
      this.footnoteRef(footnote);
      return to;
    }
    const attachment = this.attachmentAt.get(node.from);
    if (attachment) return this.attachment(attachment);
    const url = node.getChild("URL");
    const marks = node.getChildren("LinkMark");
    // `[text]` without a destination (no reference links in Bear's dialect) is text.
    if (!url || marks.length < 2) {
      this.inlineSource(node, from, to);
      return to;
    }
    const href = safeHref(this.destination(url));
    if (href) this.emit(`<a href="${escapeHTML(href)}">`);
    this.inline(node, Math.max(from, marks[0]!.to), Math.min(to, marks[1]!.from), cell);
    if (href) this.emit("</a>");
    return to;
  }

  /** An image that is not an attachment never loads: a link to it (when allowed), else its text. */
  private image(node: SyntaxNode, from: number, to: number, cell: boolean): number {
    const attachment = this.attachmentAt.get(node.from);
    if (attachment) return this.attachment(attachment);
    const url = node.getChild("URL");
    const marks = node.getChildren("LinkMark");
    if (!url || marks.length < 2) {
      this.inlineSource(node, from, to);
      return to;
    }
    const href = safeHref(this.destination(url));
    const altFrom = Math.max(from, marks[0]!.to);
    const altTo = Math.min(to, marks[1]!.from);
    if (!href) {
      this.inline(node, altFrom, altTo, cell);
      return to;
    }
    this.emit(`<a href="${escapeHTML(href)}">`);
    if (altTo > altFrom) this.inline(node, altFrom, altTo, cell);
    else this.emit(escapeHTML(href));
    this.emit("</a>");
    return to;
  }

  /** The source of a node with its link marks as text (inline markup inside still rendered). */
  private inlineSource(node: SyntaxNode, from: number, to: number): void {
    let pos = from;
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (child.to <= pos) continue;
      if (child.from >= to) break;
      if (child.from > pos) this.plain(pos, child.from, false);
      pos = child.name === "LinkMark" || child.name === "URL" ? this.textOf(child, pos, to) : this.element(child, Math.max(pos, child.from), Math.min(to, child.to), false);
    }
    if (pos < to) this.plain(pos, to, false);
  }

  private textOf(node: SyntaxNode, pos: number, to: number): number {
    const end = Math.min(to, node.to);
    this.plain(Math.max(pos, node.from), end, false);
    return end;
  }

  private destination(url: SyntaxNode): string {
    const s = this.slice(url.from, url.to);
    return s.startsWith("<") && s.endsWith(">") ? s.slice(1, -1) : s;
  }

  private attachment(a: Attachment): number {
    const sources = this.input.attachmentSources;
    const given = Object.hasOwn(sources, a.filename) ? sources[a.filename] : undefined;
    const src = given === undefined ? undefined : (attachmentSource(given) ?? undefined);
    const sizes = this.input.attachmentSizes;
    const bytes = sizes && Object.hasOwn(sizes, a.filename) ? sizes[a.filename] : undefined;
    const size = typeof bytes === "number" && Number.isFinite(bytes) && bytes >= 0 ? formatBytes(bytes) : null;
    const name = escapeHTML(a.filename);
    if (this.rich) {
      if (a.kind === "image") this.emit(`[${name}]`);
      else this.emit(src === undefined ? name : `<a href="${escapeHTML(src)}">${name}</a>`);
      return a.to;
    }
    if (a.kind === "image" && src !== undefined) {
      const width = Number.parseInt(a.metadata.width ?? "", 10);
      this.emit(`<img src="${escapeHTML(src)}" alt="${name}"${width > 0 ? ` width="${width}"` : ""}>`);
      return a.to;
    }
    const classes = ["bc-file"];
    if (a.kind === "pdf") classes.push("bc-file-pdf");
    if (src === undefined) classes.push("bc-missing");
    const href = src === undefined ? "" : ` href="${escapeHTML(src)}"`;
    // The editor's card: name, then the size (formatBytes); here also the type.
    this.emit(
      `<a class="${classes.join(" ")}"${href}><span class="bc-file-name">${name}</span><span class="bc-file-kind">${escapeHTML(fileKind(a.filename))}</span>` +
        (size === null ? "" : `<span class="bc-file-size">${escapeHTML(size)}</span>`) +
        "</a>",
    );
    return a.to;
  }

  private inlineMath(node: SyntaxNode, from: number, to: number, cell: boolean): void {
    const [open, close] = node.getChildren("MathMark");
    const source = this.slice(node.from, node.to);
    const tex = open && close ? this.slice(open.to, close.from) : "";
    // An empty formula stays text in the editor (hiding.ts).
    if (!open || !close || !/\S/.test(tex)) return this.plain(from, to, cell);
    if (this.rich) return this.emit(`<code>${escapeHTML(source)}</code>`);
    this.emit(this.formula(tex, open.to - open.from === 2, source, false));
  }
}

/** The HTML body of a note (M8-R5; rich-text mode M8-R6) and its headings with their anchors. */
export async function renderBody(input: RenderInput, renderers?: BlockRenderers): Promise<RenderedBody> {
  const text = normalized(input.text);
  const created = EditorState.create({ doc: text, extensions: [bearMarkdown] });
  if (!ensureSyntaxTree(created, text.length, 5000)) throw new Error("The note could not be parsed in time");
  // The state's own tree is the one it was made with; the next state takes the ensured one, so
  // the state-based helpers (callouts, attachments) see the whole note.
  const state = created.update({}).state;
  const tree = syntaxTree(state);
  if (tree.length < text.length) throw new Error("The note could not be parsed in time");
  const headings = headingsInDocument(text);
  const body = await new Renderer(input, renderers, text, state, tree, headings.map((h) => h.line)).render();
  return { body, headings: headings.map((h, i) => ({ level: h.level, text: h.text, anchor: `h-${i + 1}` })) };
}
