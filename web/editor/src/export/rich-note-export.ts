// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { bearParser } from "../editor/dialect";
import { renderNote, type ExportOptions, type RenderedNote } from "./note-export";
import { renderMath } from "../editor/features/math-render";
import { renderMermaid } from "../editor/features/mermaid-render";
import { EditorState } from "@codemirror/state";
import { codeBlockText } from "../editor/features/codeblocks";

// iOS export path (ios-iphone-ipad), kept compiling on the M6 rich blocks after the integration
// merge; these three helpers lived in ios's own math/mermaid modules. The iOS export moves onto
// the M8 renderer (render.ts) in a follow-up port, after which this file goes.
function mathSource(source: string): string {
  if (/^\s*\$\$[ \t]*\n/.test(source)) { const lines = source.split("\n"); lines.shift(); lines.pop(); return lines.join("\n"); }
  return source.slice(1, -1);
}
function diagramSource(fence: string): string {
  const state = EditorState.create({ doc: fence });
  let source = "";
  bearParser.parse(fence).iterate({ enter(node) { if (node.name === "FencedCode") { source = codeBlockText(state, node.node); return false; } } });
  return source;
}
function mermaidImageURL(svg: string): string { return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`; }

const escape = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
/** Render every rich block, including those outside the editor viewport, with bundled engines.
 * SVG travels as an image document so exported diagrams cannot run callbacks or scripts.
 */
export async function renderRichNote(source: string, options: ExportOptions = {}): Promise<RenderedNote> {
  const tree = bearParser.parse(source), overrides = new Map<string, RenderedNote>();
  const jobs: Promise<void>[] = [];
  tree.iterate({ enter(ref) {
    const node = ref.node, raw = source.slice(node.from, node.to), key = `${node.name}:${node.from}:${node.to}`;
    if (node.name === "MathBlock" || node.name === "InlineMath") {
      const display = node.name === "MathBlock", tex = mathSource(raw);
      jobs.push(renderMath(tex, display).then(result => {
        if (!("svg" in result)) return; // Invalid TeX remains readable source, like the editor.
        // Image documents do not inherit the surrounding HTML's currentColor.
        if (options.foreground && /^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/i.test(options.foreground)) result.svg.style.color = options.foreground;
        const image = `<img class="${display ? "display-math" : "inline-math"}" alt="${escape(tex)}" src="${escape(mermaidImageURL(result.svg.outerHTML))}">`;
        overrides.set(key, { html: display ? `<div class="formula">${image}</div>\n` : image, text: tex + (display ? "\n" : "") });
      }));
      return false;
    }
    if (node.name === "FencedCode") {
      const info = node.getChild("CodeInfo");
      if (!info || source.slice(info.from, info.to).trim().split(/\s+/)[0]?.toLowerCase() !== "mermaid") return false;
      const diagram = diagramSource(raw);
      jobs.push(renderMermaid(diagram).then(result => {
        if (!("svg" in result)) return;
        overrides.set(key, { html: `<figure class="diagram"><img alt="Mermaid diagram" src="${escape(mermaidImageURL(result.svg))}"></figure>\n`, text: diagram + "\n" });
      }));
      return false;
    }
  } });
  await Promise.all(jobs);
  return renderNote(source, options, overrides);
}
