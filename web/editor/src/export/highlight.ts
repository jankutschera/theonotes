// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Code highlighting for the static export: the language the editor would pick for the
// info string (codeblocks.ts `languageFor`), parsed on its own and coloured with Lezer's
// `classHighlighter` (`tok-*` classes; the export page colours them with the theme's
// `--bc-color-code-*` tokens). Unknown languages and blocks over MAX_HIGHLIGHT_CHARS stay plain.

import { classHighlighter, highlightCode as highlightTokens } from "@lezer/highlight";
import { languageFor, MAX_HIGHLIGHT_CHARS } from "../editor/features/codeblocks";
import { escapeHTML } from "./render";

/** `code` as escaped HTML, with `<span class="tok-…">` around highlighted tokens when the language is known. */
export async function highlightCode(code: string, language: string): Promise<string> {
  const desc = code.length > MAX_HIGHLIGHT_CHARS ? null : languageFor(language);
  if (!desc) return escapeHTML(code);
  let support = desc.support;
  try {
    support ??= await desc.load();
  } catch {
    return escapeHTML(code);
  }
  const tree = support.language.parser.parse(code);
  let out = "";
  highlightTokens(
    code,
    tree,
    classHighlighter,
    (text, classes) => {
      out += classes ? `<span class="${escapeHTML(classes)}">${escapeHTML(text)}</span>` : escapeHTML(text);
    },
    () => {
      out += "\n";
    },
  );
  return out;
}
