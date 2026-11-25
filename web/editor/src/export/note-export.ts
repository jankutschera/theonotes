// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import type { SyntaxNode } from "@lezer/common";
import { bearParser, highlightColors } from "../editor/dialect";

export type ExportOptions = { keepTags?: boolean; attachments?: Record<string, string>; wikiLinks?: Record<string, string>; foreground?: string };
export type RenderedNote = { html: string; text: string };
const escape = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const piece = (text: string): RenderedNote => ({ html: escape(text), text });
const empty = (): RenderedNote => piece("");
const join = (parts: RenderedNote[]): RenderedNote => ({ html: parts.map(p => p.html).join(""), text: parts.map(p => p.text).join("") });
const decoded = (s: string) => { try { return decodeURIComponent(s); } catch { return s; } };
const safeLink = (s: string): string | null => {
  if (/^[\u0000-\u0020]*$/.test(s) || /[\u0000-\u0020\u007f\\]/.test(s)) return null;
  if (/^(?:https?:|mailto:|tel:|theonotes:|baerchen:)/i.test(s) || s.startsWith("#")) return s;
  if (!/^[^/]*:/.test(s) && !s.startsWith("/") && !decoded(s).split("/").includes("..")) return s;
  return null;
};

/** Render the complete Bear syntax tree, independent of the editor viewport or caret position.
 * Raw HTML is text. Only native-supplied image data is embedded; no remote resource is fetched.
 */
export function renderNote(source: string, options: ExportOptions = {}, renderedNodes: ReadonlyMap<string, RenderedNote> = new Map(), baseOffset = 0): RenderedNote {
  const tree = bearParser.parse(source), read = (n: SyntaxNode) => source.slice(n.from, n.to);
  const definition = new Map<string, number>(), firstReference = new Map<string, number>();
  const marks: { label: string; from: number; definition: boolean }[] = [];
  for (const match of source.matchAll(/\[\^([^\]\s]+)\]/g)) {
    let node: SyntaxNode | null = tree.resolveInner(match.index, 1), excluded = false;
    for (; node; node = node.parent) if (/Code|Math|Comment|FrontMatter|Escape/.test(node.name)) excluded = true;
    if (excluded) continue;
    const isDefinition = (match.index === 0 || source[match.index - 1] === "\n") && source[match.index + match[0].length] === ":";
    marks.push({ label: match[1]!, from: match.index, definition: isDefinition });
    if (isDefinition && !definition.has(match[1]!)) definition.set(match[1]!, match.index);
    if (!isDefinition && !firstReference.has(match[1]!)) firstReference.set(match[1]!, match.index);
  }
  const footnoteID = (label: string) => "fn-" + encodeURIComponent(label);
  const ref = (label: string, from: number): RenderedNote => ({
    html: `<sup><a id="fnref-${from}" href="#${escape(footnoteID(label))}" aria-label="Footnote ${escape(label)}">${escape(label)}</a></sup>`, text: `[${label}]`,
  });
  const inlineText = (value: string, from: number): RenderedNote => {
    const found = marks.filter(mark => !mark.definition && definition.has(mark.label) && mark.from >= from && mark.from < from + value.length);
    if (!found.length) return piece(value);
    const parts: RenderedNote[] = []; let offset = 0;
    for (const mark of found) {
      const at = mark.from - from;
      parts.push(piece(value.slice(offset, at)), ref(mark.label, mark.from)); offset = at + mark.label.length + 3;
    }
    parts.push(piece(value.slice(offset))); return join(parts);
  };
  const textPiece = (node: SyntaxNode, value: string, from: number): RenderedNote => {
    let parent: SyntaxNode | null = node;
    while (parent && parent.name !== "TableCell") {
      if (["InlineCode", "InlineMath", "Comment"].includes(parent.name)) return piece(value);
      parent = parent.parent;
    }
    if (!parent) return inlineText(value, from);
    const parts = value.split(/(<br\s*\/?>)/gi);
    let offset = from;
    return join(parts.map(part => { const result = /^<br\s*\/?>$/i.test(part) ? { html: "<br>", text: "\n" } : inlineText(part, offset); offset += part.length; return result; }));
  };
  const children = (n: SyntaxNode, from = n.from, to = n.to): RenderedNote => {
    const parts: RenderedNote[] = []; let at = from;
    for (let child = n.firstChild; child; child = child.nextSibling) {
      if (child.to <= from || child.from >= to) continue;
      if (child.from > at) parts.push(textPiece(n, source.slice(at, child.from), at));
      parts.push(render(child)); at = child.to;
    }
    if (at < to) parts.push(textPiece(n, source.slice(at, to), at));
    return join(parts);
  };
  const wrap = (tag: string, body: RenderedNote, block = false, attributes = ""): RenderedNote => ({
    html: `<${tag}${attributes}>${body.html}</${tag}>${block ? "\n" : ""}`,
    text: body.text + (block ? "\n" : ""),
  });
  const render = (n: SyntaxNode): RenderedNote => {
    const raw = read(n);
    const rendered = renderedNodes.get(`${n.name}:${n.from + baseOffset}:${n.to + baseOffset}`);
    if (rendered) return rendered;
    const footnote = marks.find(mark => mark.from === n.from);
    if (footnote?.definition && definition.get(footnote.label) === n.from && (n.name === "Paragraph" || n.name === "LinkReference")) {
      const contentStart = footnote.label.length + 4;
      const tail = raw.slice(contentStart), trimmed = tail.trimStart();
      const body = renderNote(trimmed, options, renderedNodes, baseOffset + n.from + contentStart + tail.length - trimmed.length);
      const backlink = firstReference.get(footnote.label);
      return { html: `<div class="footnote" id="${escape(footnoteID(footnote.label))}"><span>${escape(footnote.label)}.</span> ${body.html}${backlink === undefined ? "" : `<a href="#fnref-${backlink}" aria-label="Back to reference">↩</a>`}</div>\n`, text: `[${footnote.label}] ${body.text}` };
    }
    if (footnote && !footnote.definition && n.to === n.from + footnote.label.length + 3 && definition.has(footnote.label)) return ref(footnote.label, n.from);
    if (/^(?:HeaderMark|EmphasisMark|StrikethroughMark|CodeMark|HighlightMark|HighlightColor|UnderlineMark|QuoteMark|ListMark|LinkMark|MathMark|FrontMatterMark|TableDelimiter)$/.test(n.name)) return empty();
    if (/^ATXHeading[1-6]$/.test(n.name)) {
      const body = children(n), level = n.name.slice(-1);
      const line = source.slice(0, n.from).split("\n").length;
      return wrap("h" + level, { html: body.html.trim(), text: body.text.trim() }, true, ` id="h-line-${line}"`);
    }
    switch (n.name) {
      case "Document": return children(n);
      case "Paragraph": return wrap("p", children(n), true);
      case "StrongEmphasis": return wrap("strong", children(n));
      case "Emphasis": return wrap("em", children(n));
      case "Strikethrough": return wrap("s", children(n));
      case "Underline": return wrap("u", children(n));
      case "Highlight": {
        const color = n.getChild("HighlightColor"), name = color && highlightColors[read(color).codePointAt(0)!];
        return wrap("mark", children(n), false, name ? ` class="highlight-${name}"` : "");
      }
      case "InlineCode": return wrap("code", children(n));
      case "Escape": return piece(raw.slice(1));
      case "Entity": {
        // Keep only parser-recognized entities as HTML; decode them for plain-text export.
        const numeric = /^&#(x[0-9a-f]+|\d+);$/i.exec(raw);
        if (numeric) {
          const number = numeric[1]!.toLowerCase().startsWith("x") ? parseInt(numeric[1]!.slice(1), 16) : Number(numeric[1]);
          return piece(number > 0 && number <= 0x10ffff && !(number >= 0xd800 && number <= 0xdfff) ? String.fromCodePoint(number) : "�");
        }
        const named: Record<string, string> = { "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": '"', "&apos;": "'", "&nbsp;": "\u00a0" };
        return named[raw] ? piece(named[raw]) : piece(raw);
      }
      case "Comment": case "HTMLBlock": return empty();
      case "HorizontalRule": return { html: "<hr>\n", text: "\n" };
      case "HardBreak": return { html: "<br>\n", text: "\n" };
      case "Tag": return options.keepTags === false ? empty() : wrap("span", piece(raw), false, ' class="tag"');
      case "WikiLink": {
        const alias = n.getChild("WikiAlias"), target = n.getChild("WikiTarget"), heading = n.getChild("WikiHeading");
        const name = target ? read(target) : "", label = alias ? read(alias) : name + (heading ? "/" + read(heading) : "");
        const mapped = (heading ? options.wikiLinks?.[name + "/" + read(heading)] : undefined) ?? options.wikiLinks?.[name];
        let href = safeLink(mapped ?? "theonotes://x-callback-url/open-note?title=" + encodeURIComponent(name));
        // Only the native export manifest may name sibling tag folders. Source Markdown
        // still cannot introduce parent traversal; generated path segments remain encoded.
        if (!href && mapped?.startsWith("../")) {
          const tail = mapped.replace(/^(?:\.\.\/)+/, "");
          if (tail && !tail.includes(":") && safeLink(tail)) href = mapped;
        }
        return href ? wrap("a", piece(label), false, ` href="${escape(href)}"`) : piece(label);
      }
      case "Link": case "Image": {
        const url = n.getChild("URL"), marks = n.getChildren("LinkMark"), open = marks[0], close = marks[1];
        if (!url || !open || !close) return piece(raw);
        const label = children(n, open.to, close.from), destination = read(url).replace(/^<|>$/g, "");
        if (n.name === "Image") {
          const data = options.attachments?.[decoded(destination)];
          if (data && /^data:image\/(?:png|jpeg|gif|webp|heic|heif);base64,[a-z0-9+/=]+$/i.test(data)) {
            return { html: `<img src="${escape(data)}" alt="${escape(label.text)}">`, text: label.text || decoded(destination) };
          }
          return wrap("span", piece(label.text || decoded(destination)), false, ' class="missing-image"');
        }
        const href = safeLink(destination);
        return href ? wrap("a", label, false, ` href="${escape(href)}"`) : label;
      }
      case "Autolink": {
        const url = n.getChild("URL"), text = url ? read(url) : raw;
        const href = safeLink(text); return href ? wrap("a", piece(text), false, ` href="${escape(href)}"`) : piece(text);
      }
      case "URL": {
        const href = safeLink(raw); return href ? wrap("a", piece(raw), false, ` href="${escape(href)}"`) : piece(raw);
      }
      case "FencedCode": {
        const code = n.getChild("CodeText");
        return wrap("pre", wrap("code", piece(code ? read(code) : "")), true);
      }
      case "MathBlock": case "FrontMatter": return wrap("pre", children(n), true);
      case "InlineMath": return wrap("code", children(n));
      case "Blockquote": {
        const marker = /^>[ \t]*\[!([a-z]+)\]([^\n]*)/i.exec(raw);
        if (!marker) return wrap("blockquote", children(n), true);
        const known = ["note", "tip", "important", "warning", "caution"], rawType = marker[1]!.toLowerCase();
        const type = known.includes(rawType) ? rawType : "note", token = `[!${marker[1]}]`;
        const title = type[0]!.toUpperCase() + type.slice(1), custom = !!marker[2]!.trim(), body = children(n);
        return wrap("blockquote", {
          html: body.html.replace(escape(token), custom ? "" : `<strong>${title}</strong>`),
          text: body.text.replace(token, custom ? "" : title),
        }, true, ` class="callout callout-${type}"`);
      }
      case "BulletList": return wrap("ul", children(n), true);
      case "OrderedList": {
        const first = /^\s*(\d+)[.)]/.exec(raw)?.[1];
        return wrap("ol", children(n), true, first ? ` start="${Number(first)}"` : "");
      }
      case "ListItem": {
        const body = children(n);
        return { html: `<li>${body.html.trim()}</li>\n`, text: "• " + body.text.trim() + "\n" };
      }
      case "Task": return wrap("div", children(n), true, ' class="task"');
      case "TaskMarker": {
        const checked = /[xX]/.test(raw);
        return { html: `<span role="img" aria-label="${checked ? "Completed" : "Incomplete"}">${checked ? "☑" : "☐"}</span>`, text: checked ? "[x]" : "[ ]" };
      }
      case "Table": return wrap("table", children(n), true);
      case "TableHeader": case "TableRow": {
        const cells = n.getChildren("TableCell"), tag = n.name === "TableHeader" ? "th" : "td";
        // Delimiter nodes preserve empty cells, which have no TableCell node.
        const pipes = n.getChildren("TableDelimiter"), rendered: RenderedNote[] = [];
        for (let i = 0; i + 1 < pipes.length; i++) {
          const cell = cells.find(c => c.from >= pipes[i]!.to && c.to <= pipes[i + 1]!.from);
          const body = cell ? children(cell) : empty();
          rendered.push({ html: `<${tag}>${body.html}</${tag}>`, text: body.text + (i + 2 < pipes.length ? "\t" : "") });
        }
        return wrap("tr", join(rendered), true);
      }
      default: return n.firstChild ? children(n) : piece(raw);
    }
  };
  const result = render(tree.topNode);
  return { html: result.html, text: result.text.replace(/\n{3,}/g, "\n\n").trimEnd() + "\n" };
}
