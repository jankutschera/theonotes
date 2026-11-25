// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Copy Table As CSV / HTML / Markdown (M6 Task 6). Format ▸ Table and the cell menu run
// `copyTable {format, menuId?}`; the text goes to the host through the code-block handlers'
// `copyText(text, html?)`. Copying is not an edit: it also works in read-only notes.
//
// A cell is read the way the grid shows it (table-model.ts `cellRuns`): markup hidden, `\|`
// unescaped, `<br>` a line break. The Markdown copy is the exact source of the table's lines.

import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import type { EditorState } from "@codemirror/state";
import type { Tree } from "@lezer/common";
import type { EditorCommand } from "./commands";
import { codeBlockHandlers } from "./codeblocks";
import { linkTargetAt } from "./links";
import { resolveMenuTarget } from "./menu-targets";
import { type CellRef, cellRuns, plainCellText, type TableModel, tableAt } from "./table-model";

const columnCount = (model: TableModel) => Math.max(model.header.length, ...model.rows.map((r) => r.length), 1);

const rowsOf = (model: TableModel): CellRef[][] => [model.header, ...model.rows];

/** RFC 4180: records end in CRLF, a field with a comma, a quote or a line break is quoted, `"` doubled. */
function csvField(text: string): string {
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

/** The table as CSV (RFC 4180): ragged rows are padded with empty fields, `<br>` is a line break. */
export function tableAsCSV(state: EditorState, model: TableModel, tree?: Tree): string {
  const columns = columnCount(model);
  return rowsOf(model)
    .map((cells) => Array.from({ length: columns }, (_, c) => (cells[c] ? csvField(plainCellText(state, cells[c]!, tree)) : "")).join(","))
    .join("\r\n");
}

const escapeHTML = (text: string) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

/** Element → the typography class of its inline markup, in nesting order (outermost first). */
const TAGS: readonly (readonly [tag: string, cls: string])[] = [
  ["a", "cm-bc-link"],
  ["strong", "cm-bc-strong"],
  ["em", "cm-bc-em"],
  ["del", "cm-bc-strike"],
  ["u", "cm-bc-underline"],
  ["mark", "cm-bc-highlight"],
  ["code", "cm-bc-code"],
];

const SAFE_HREF = /^(?:https?:\/\/|mailto:)/i;

type Wrap = { tag: string; href?: string };

/** The elements around a run: a link only when it points at http(s) or mailto, else its text alone. */
function wrapsOf(state: EditorState, from: number, classes: readonly string[]): Wrap[] {
  // A run's class entry may hold several (a coloured highlight: `cm-bc-highlight cm-bc-highlight-red`).
  const have = new Set(classes.flatMap((cls) => cls.split(" ")));
  const wraps: Wrap[] = [];
  for (const [tag, cls] of TAGS) {
    if (!have.has(cls)) continue;
    if (tag !== "a") {
      wraps.push({ tag });
      continue;
    }
    const link = linkTargetAt(state, from, true);
    if (link?.kind === "url" && SAFE_HREF.test(link.target)) wraps.push({ tag, href: link.target });
  }
  return wraps;
}

const sameWrap = (a: Wrap, b: Wrap) => a.tag === b.tag && a.href === b.href;

/** One cell as inline HTML: `strong em del u mark code a`, `<br>` for line breaks, all text escaped. */
function cellHTML(state: EditorState, cell: CellRef, tree?: Tree): string {
  let out = "";
  const open: Wrap[] = [];
  const close = (keep: number) => {
    while (open.length > keep) out += `</${open.pop()!.tag}>`;
  };
  for (const run of cellRuns(state, cell, tree)) {
    if (run.kind === "br") {
      out += "<br>";
      continue;
    }
    const wraps = wrapsOf(state, run.from, run.classes);
    let keep = 0;
    while (keep < open.length && keep < wraps.length && sameWrap(open[keep]!, wraps[keep]!)) keep++;
    close(keep);
    for (const wrap of wraps.slice(keep)) {
      out += wrap.href === undefined ? `<${wrap.tag}>` : `<a href="${escapeHTML(wrap.href)}">`;
      open.push(wrap);
    }
    out += escapeHTML(run.text);
  }
  close(0);
  return out;
}

/** The table as HTML: `<table><thead>…</thead><tbody>…</tbody></table>`, ragged rows padded. */
export function tableAsHTML(state: EditorState, model: TableModel, tree?: Tree): string {
  const columns = columnCount(model);
  const row = (cells: readonly CellRef[], tag: "th" | "td") =>
    `<tr>${Array.from({ length: columns }, (_, c) => `<${tag}>${cells[c] ? cellHTML(state, cells[c]!, tree) : ""}</${tag}>`).join("")}</tr>`;
  return `<table><thead>${row(model.header, "th")}</thead><tbody>${model.rows.map((cells) => row(cells, "td")).join("")}</tbody></table>`;
}

/** The table's lines exactly as written (quote and list prefixes included). */
export function tableAsMarkdown(state: EditorState, model: TableModel): string {
  return state.sliceDoc(model.from, model.to);
}

const FORMATS = ["csv", "html", "markdown"] as const;
type Format = (typeof FORMATS)[number];
const isFormat = (value: unknown): value is Format => FORMATS.includes(value as Format);

/**
 * `copyTable {format, menuId?}`: the table of the menu's cell (else of the main selection's head)
 * to the pasteboard. HTML is posted as both the plain text (the HTML source) and the `html`
 * flavour, so a plain paste gives the source and a rich paste gives a table.
 */
export const copyTable: EditorCommand = ({ state }, args) => {
  const format = args?.format;
  const copy = state.facet(codeBlockHandlers).copyText;
  if (!isFormat(format) || !copy) return false;
  const at = resolveMenuTarget(state, args);
  if (at.kind === "dead") return false;
  const pos = at.kind === "target" ? at.pos : state.selection.main.head;
  // The whole table must be parsed, or a long one would be missed or copied cut short. The
  // ensured tree is read itself: `syntaxTree(state)` stays the tree the state was made with.
  const tree = ensureSyntaxTree(state, state.doc.length, 200) ?? syntaxTree(state);
  const model = tableAt(state, pos, tree);
  if (!model) return false;
  switch (format) {
    case "csv":
      copy(tableAsCSV(state, model, tree));
      break;
    case "markdown":
      copy(tableAsMarkdown(state, model));
      break;
    case "html": {
      const html = tableAsHTML(state, model, tree);
      copy(html, html);
      break;
    }
  }
  return true;
};
