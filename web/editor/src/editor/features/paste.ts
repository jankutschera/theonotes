// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { EditorSelection, type EditorState, type Extension, type TransactionSpec } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import TurndownService from "turndown";
import { codeAt, parseLinePrefix } from "./lists";
import { cellAt, rowOf, tableAt } from "./table-model";

// Smart paste (spec §4.4, Review Focus 4): an http(s) URL pasted on a selection links it
// (`[sel](url)`); rich HTML (browsers, Numbers) becomes Markdown through turndown, tables as GFM
// tables; plain text (and HTML that carries no formatting) is left to the default paste. Edit ▸
// Paste From ▸ Code is codeblocks.ts `codePaste`. Inside code (a fenced block, inline code, math)
// everything pastes as plain text: converted HTML would bring its own fences and markup.
//
// Tables (M6 Task 6): plain text of tab-separated lines with one column count (≥ 2), Numbers or
// Excel without HTML, becomes a GFM table; whatever is pasted into a table cell is flattened
// (newline → `<br>`, `|` → `\|`, tab → space) so the row keeps its shape.

const URL_ONLY = /^https?:\/\/\S+$/i;

/** The pasted text as an http(s) URL, if it is exactly one. */
function httpURL(text: string | undefined): string | null {
  const trimmed = text?.trim() ?? "";
  if (!URL_ONLY.test(trimmed)) return null;
  try {
    const url = new URL(trimmed);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  } catch {
    return null;
  }
  // Parentheses would end the destination early; the link resolves the same encoded.
  return trimmed.replace(/\(/g, "%28").replace(/\)/g, "%29");
}

/** Elements whose presence makes pasted HTML "rich" (worth converting). */
const RICH = "b,strong,i,em,u,s,del,strike,mark,a[href],h1,h2,h3,h4,h5,h6,ul,ol,li,table,pre,code,img,blockquote,hr";

function isRich(html: string): boolean {
  if (typeof DOMParser === "undefined") return /<(b|strong|i|em|u|s|del|strike|mark|a|h[1-6]|ul|ol|li|table|pre|code|img|blockquote|hr)[\s>]/i.test(html);
  const doc = new DOMParser().parseFromString(html, "text/html");
  return doc.body.querySelector(RICH) !== null;
}

/**
 * What a paste of `data` does, or null for the default paste. The selection is replaced and the
 * caret placed after the pasted text (one undo step).
 */
export function smartPaste(state: EditorState, data: { text?: string; html?: string }): TransactionSpec | null {
  if (state.readOnly || selectionInCode(state)) return null;
  const main = state.selection.main;
  const url = httpURL(data.text);
  if (url && !main.empty && state.selection.ranges.length === 1) {
    const selected = state.sliceDoc(main.from, main.to);
    if (!/[\n[\]]/.test(selected)) return replaceSelection(state, `[${selected}](${url})`);
  }
  const where = selectionInTable(state);
  // A selection that reaches across cells (or the delimiter row) would be replaced with its pipes:
  // nothing is converted, the default paste runs.
  if (where === "across") return null;
  const inCell = where === "cell";
  if (data.html && isRich(data.html)) {
    const markdown = htmlToMarkdown(data.html);
    if (markdown) return replaceSelection(state, inCell ? flattenForCell(markdown) : markdown);
  }
  const text = data.text;
  if (text === undefined || text === "") return null;
  if (inCell) {
    const flat = flattenForCell(text);
    return flat === text ? null : replaceSelection(state, flat);
  }
  // One cursor only: a table is a block, and several inline copies of it would not parse.
  if (state.selection.ranges.length > 1) return null;
  const table = tsvToTable(text);
  return table ? tablePaste(state, table) : null;
}

/**
 * A pasted table on a quote or list line (M6-R83): on a line that is empty apart from its quote
 * markers or list marker, the table replaces the rest of the line and its other rows get the
 * line's continuation prefix (as Create Table does), so the table stays in the quote or item.
 * On such a line with text (or a todo) it is not converted. Elsewhere it goes on its own lines.
 */
function tablePaste(state: EditorState, table: string): TransactionSpec | null {
  const { from, to } = state.selection.main;
  const line = state.doc.lineAt(from);
  const p = parseLinePrefix(line.text);
  const lead = p.list ? line.text.slice(0, p.list.contentFrom) : p.quote;
  if (lead === "") return replaceSelection(state, table, true);
  const start = line.from + lead.length;
  // A caret (or selection) inside the prefix only is not on the content: not converted.
  if (p.list?.box || to > line.to || (from < start && (from === to || to < start))) return null;
  // The line's text outside the selection (a selection over the prefix counts from the content
  // start) must be blank: an empty line, or a selection covering its whole content.
  const outside = from < start ? state.sliceDoc(Math.max(start, to), line.to) : state.sliceDoc(start, from) + state.sliceDoc(to, line.to);
  if (/\S/.test(outside)) return null;
  const follow = p.list ? p.quote + " ".repeat(lead.length - p.quote.length) : lead;
  const insert = table.split("\n").join("\n" + follow);
  return {
    changes: { from: start, to: line.to, insert },
    selection: EditorSelection.cursor(start + insert.length),
    scrollIntoView: true,
    userEvent: "input.paste",
  };
}

/**
 * Where the selection is: `cell` when every range lies within one cell of a table's header or body
 * row (between its pipes), `none` when no range touches a table, `across` otherwise (a range over
 * several cells or rows, the delimiter row, or a table's line outside its pipes).
 */
function selectionInTable(state: EditorState): "cell" | "across" | "none" {
  const end = Math.max(...state.selection.ranges.map((r) => r.to));
  // The ensured tree itself: `syntaxTree(state)` may end before a table far down a long note
  // (right after a load, before the background parse got there). A paste is one action, not a
  // keystroke path: up to 200 ms of parsing, as Copy Table As.
  const tree = ensureSyntaxTree(state, Math.min(state.doc.length, end + 2000), 200) ?? syntaxTree(state);
  let touches = false;
  let allInCells = true;
  for (const r of state.selection.ranges) {
    const model = tableAt(state, r.from, tree);
    const last = tableAt(state, r.to, tree);
    if (model || last) touches = true;
    if (!model || !last || model.from !== last.from) {
      allInCells = false;
      continue;
    }
    const hit = cellAt(model, r.from);
    const cells = hit ? rowOf(model, hit.row) : undefined;
    const cell = hit && cells ? cells[hit.column] : undefined;
    // Both ends within that one cell's pipes (the closing pipe's position is still inside).
    allInCells &&= !!cell && r.from >= cell.from && r.to <= cell.to;
  }
  return !touches ? "none" : allInCells ? "cell" : "across";
}

/**
 * `|` escaped as `\|` unless it already is (an odd number of backslashes before it): `a \| b`
 * copied from another cell's source stays one escaped pipe (final review M1).
 */
const escapePipes = (text: string) => text.replace(/(?<!\\)((?:\\\\)*)\|/g, "$1\\|");

/** Text for one table cell: one line (`<br>` for line breaks), unescaped pipes escaped, tabs spaces. */
function flattenForCell(text: string): string {
  const flat = text
    .replace(/\r\n?/g, "\n")
    .replace(/\n+$/, "")
    .replace(/\n{2,}/g, "\n")
    .replace(/\t/g, " ");
  return escapePipes(flat).replace(/\n/g, "<br>");
}

/**
 * `a\tb\n1\t2` as a GFM table, first row the header; null unless every line has the same column
 * count (≥ 2) and the first column has text on some line: tab-indented lines (code copied without
 * HTML) are not a table (final review M5).
 */
function tsvToTable(text: string): string | null {
  const lines = text.replace(/\r\n?/g, "\n").replace(/\n$/, "").split("\n");
  if (lines.length < 2) return null;
  const rows = lines.map((line) => line.split("\t"));
  const columns = rows[0]!.length;
  if (columns < 2 || rows.some((row) => row.length !== columns)) return null;
  if (rows.every((row) => !/\S/.test(row[0]!))) return null;
  const line = (cells: string[]) => `| ${cells.map((cell) => escapePipes(cell.trim())).join(" | ")} |`;
  const [header, ...body] = rows;
  return [line(header!), `| ${Array(columns).fill("---").join(" | ")} |`, ...body.map(line)].join("\n");
}

function selectionInCode(state: EditorState): boolean {
  const end = Math.max(...state.selection.ranges.map((r) => r.to));
  const tree = ensureSyntaxTree(state, Math.min(state.doc.length, end + 2000), 50) ?? syntaxTree(state);
  return state.selection.ranges.some((r) => codeAt(tree, r.from) !== null || codeAt(tree, r.to) !== null);
}

/** `block`: the text is a block that starts and ends on its own lines (a table pasted into a line of text). */
function replaceSelection(state: EditorState, text: string, block = false): TransactionSpec {
  if (block && state.selection.ranges.length === 1) {
    const { from, to } = state.selection.main;
    const before = state.doc.lineAt(from);
    const after = state.doc.lineAt(to);
    const lead = /\S/.test(state.sliceDoc(before.from, from)) ? "\n\n" : "";
    const trail = /\S/.test(state.sliceDoc(to, after.to)) ? "\n\n" : "";
    text = lead + text + trail;
  }
  return { ...state.replaceSelection(text), scrollIntoView: true, userEvent: "input.paste" };
}

let service: TurndownService | null = null;

const isHTTP = (url: string | null) => !!url && /^https?:\/\//i.test(url.trim());

function cellText(cell: Element, turndown: TurndownService): string {
  return turndown.turndown(cell.innerHTML).replace(/\s*\n\s*/g, " ").replace(/\|/g, "\\|").trim();
}

function owningTable(node: Node): Node | null {
  let n: Node | null = node.parentNode;
  while (n && n.nodeName !== "TABLE") n = n.parentNode;
  return n;
}

function tableMarkdown(table: HTMLElement, turndown: TurndownService): string {
  const rows = Array.from(table.querySelectorAll("tr")).filter((tr) => owningTable(tr) === table);
  if (rows.length === 0) return "";
  const cells = rows.map((tr) => Array.from(tr.children).filter((c) => c.tagName === "TD" || c.tagName === "TH").map((c) => cellText(c, turndown)));
  const columns = Math.max(1, ...cells.map((r) => r.length));
  const line = (r: string[]) => "| " + Array.from({ length: columns }, (_, i) => r[i] ?? "").join(" | ") + " |";
  const [header, ...body] = cells;
  return [line(header!), "| " + Array(columns).fill("---").join(" | ") + " |", ...body.map(line)].join("\n");
}

function turndownService(): TurndownService {
  if (service) return service;
  const t = new TurndownService({
    headingStyle: "atx",
    bulletListMarker: "-",
    codeBlockStyle: "fenced",
    emDelimiter: "*",
    strongDelimiter: "**",
    hr: "---",
  });
  t.remove(["script", "style", "meta", "head", "title", "noscript", "template"]);
  // Text that reads like a tag (`&lt;script&gt;` in the page) stays text: `\<` is an escape.
  const escape = t.escape.bind(t);
  t.escape = (text: string) => escape(text).replace(/</g, "\\<");
  t.addRule("strikethrough", { filter: ["del", "s", "strike"], replacement: (content) => (content ? `~~${content}~~` : "") });
  // Only http(s) targets become links and images; other schemes keep their text.
  t.addRule("safeLink", {
    filter: (node) => node.nodeName === "A",
    replacement: (content, node) => {
      const href = node.getAttribute("href");
      if (!isHTTP(href) || !content.trim()) return content;
      const title = node.getAttribute("title");
      return `[${content}](${href!.trim().replace(/\(/g, "%28").replace(/\)/g, "%29")}${title ? ` "${title.replace(/"/g, '\\"')}"` : ""})`;
    },
  });
  t.addRule("safeImage", {
    filter: "img",
    replacement: (_content, node) => {
      const src = node.getAttribute("src");
      if (!isHTTP(src)) return "";
      const alt = (node.getAttribute("alt") ?? "").replace(/[[\]]/g, "");
      return `![${alt}](${src!.trim().replace(/\(/g, "%28").replace(/\)/g, "%29")})`;
    },
  });
  t.addRule("listItem", {
    filter: "li",
    replacement: (content, node, options) => {
      const parent = node.parentNode as HTMLElement | null;
      let prefix = `${options.bulletListMarker ?? "-"} `;
      if (parent?.nodeName === "OL") {
        const start = Number(parent.getAttribute("start") ?? "1");
        prefix = `${(Number.isFinite(start) ? start : 1) + Array.prototype.indexOf.call(parent.children, node)}. `;
      }
      const body = content.replace(/^\n+/, "").replace(/\n+$/, "\n").replace(/\n/gm, "\n" + " ".repeat(prefix.length));
      return prefix + body + (node.nextSibling && !/\n$/.test(body) ? "\n" : "");
    },
  });
  t.addRule("table", {
    filter: "table",
    replacement: (_content, node) => `\n\n${tableMarkdown(node, t)}\n\n`,
  });
  service = t;
  return t;
}

/** Pasted HTML as Markdown of our dialect. */
export function htmlToMarkdown(html: string): string {
  return turndownService().turndown(html).replace(/\n{3,}/g, "\n\n").trim();
}

/** The paste handler: smart paste where it applies, the default paste otherwise. */
export const smartPasteHandler: Extension = EditorView.domEventHandlers({
  paste(event, view) {
    const data = event.clipboardData;
    if (!data || data.files.length > 0) return false;
    const spec = smartPaste(view.state, { text: data.getData("text/plain"), html: data.getData("text/html") });
    if (!spec) return false;
    event.preventDefault();
    view.dispatch(spec);
    return true;
  },
});
