// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The export page (M8 Task 10): `window.baerchenExport.render(request)` turns a RenderRequest into
// HTML with the real renderers (render.ts, MathJax, Mermaid, the Lezer highlighter) and shows it
// in this page, so the host can also print or snapshot what it rendered. It is a separate Vite
// entry (`export.html`); the editor's entry never loads this code.
//
// Safety: the request is checked again (protocol.ts) before anything is rendered; the body is
// built by `renderBody`, which escapes all note text and loads nothing from outside; theme and
// typography reach the stylesheet only as validated tokens (hex colours, schema names, font
// names without quotes or braces). The page loads no script or style from a note.

import { bearchenRed } from "../editor/theme";
import { renderMath, sanitizeSvg } from "../editor/features/math-render";
import { renderMermaid } from "../editor/features/mermaid-render";
import { typographyDeclarations } from "../editor/features/settings";
import { FONT_STACKS, TYPOGRAPHY_DEFAULTS } from "../editor/features/typography";
import exportCss from "./export.css?raw";
import { parseRenderRequest, type RenderRequest, type RenderResult } from "./protocol";
import { type BlockRenderers, escapeHTML, renderBody } from "./render";

declare global {
  interface Window {
    baerchenExport: { render(request: unknown): Promise<RenderResult> };
  }
}

const renderers = (appearance: RenderRequest["appearance"]): BlockRenderers => ({
  math: async (tex, display) => {
    const result = await renderMath(tex, display);
    if ("error" in result) return null;
    // The result is cached and shared: serialize a sanitized copy.
    return sanitizeSvg(result.svg.cloneNode(true) as SVGElement).outerHTML;
  },
  mermaid: async (source) => {
    const result = await renderMermaid(source, appearance === "dark" ? "dark" : "neutral");
    return "svg" in result ? result.svg : null;
  },
});

/** The typography the editor starts with (its CSS variables), for tokens a request leaves out. */
const typographyDefaults: Record<string, string> = {
  "--bc-font-text": FONT_STACKS.text,
  "--bc-font-heading": FONT_STACKS.heading,
  "--bc-font-code": FONT_STACKS.code,
  "--bc-size": `${TYPOGRAPHY_DEFAULTS.fontSize}px`,
  "--bc-line-height": `${TYPOGRAPHY_DEFAULTS.lineHeight}`,
  "--bc-line-width": `${TYPOGRAPHY_DEFAULTS.lineWidth}px`,
  "--bc-paragraph-spacing": `${TYPOGRAPHY_DEFAULTS.paragraphSpacing}em`,
  "--bc-paragraph-indent": `${TYPOGRAPHY_DEFAULTS.paragraphIndent}em`,
};

/** One `<style>`'s text: `:root{--bc-*}` (theme over the default theme, then typography), then export.css. */
export function exportStyle(request: Pick<RenderRequest, "theme" | "appearance" | "typography">): string {
  const variables: Record<string, string> = { ...bearchenRed, ...request.theme, ...typographyDefaults };
  for (const declaration of typographyDeclarations(request.typography)) {
    const colon = declaration.indexOf(":");
    variables[declaration.slice(0, colon)] = declaration.slice(colon + 1).trim();
  }
  const root = Object.entries(variables).map(([name, value]) => `${name}:${value}`);
  return `:root{color-scheme:${request.appearance};${root.join(";")}}\n${exportCss}`;
}

function documentHTML(request: RenderRequest, body: string): string {
  return [
    "<!doctype html>",
    "<html>",
    "<head>",
    '<meta charset="utf-8">',
    `<title>${escapeHTML(request.title || "Untitled")}</title>`,
    `<style>${exportStyle(request)}</style>`,
    "</head>",
    "<body>",
    `<main class="bc-export">\n${body}</main>`,
    "</body>",
    "</html>",
    "",
  ].join("\n");
}

function show(request: RenderRequest, body: string): HTMLElement {
  let style = document.getElementById("bc-export-style");
  if (!style) {
    style = document.createElement("style");
    style.id = "bc-export-style";
    document.head.append(style);
  }
  style.textContent = exportStyle(request);
  let root = document.getElementById("export-root");
  if (!root) {
    root = document.createElement("main");
    root.id = "export-root";
    root.className = "bc-export";
    document.body.replaceChildren(root);
  }
  // `body` is renderBody's output: all note text escaped, no script, no handler, no remote source.
  root.innerHTML = body;
  return root;
}

async function settled(root: HTMLElement): Promise<void> {
  // A missing or broken image must not fail the export: decode errors are ignored.
  await Promise.all([...root.querySelectorAll("img")].map((img) => img.decode().catch(() => undefined)));
  await document.fonts.ready;
}

async function render(value: unknown): Promise<RenderResult> {
  const request = parseRenderRequest(value);
  if (!request) throw new Error("Invalid render request");
  const { body, headings } = await renderBody(
    {
      text: request.text,
      mode: request.mode,
      attachmentSources: request.attachmentSources,
      ...(request.attachmentSizes && { attachmentSizes: request.attachmentSizes }),
      wikiLinks: request.wikiLinks,
    },
    renderers(request.appearance),
  );
  await settled(show(request, body));
  return { html: request.mode === "document" ? documentHTML(request, body) : body, headings };
}

// The page shows one note at a time: requests run in order.
let queue: Promise<unknown> = Promise.resolve();
window.baerchenExport = {
  render: (request) => {
    const run = queue.then(() => render(request));
    queue = run.catch(() => undefined);
    return run;
  },
};
