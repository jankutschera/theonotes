// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Mermaid 12 (M6 Task 12): the only module that imports Mermaid, through dynamic import,
// so the editor does not load it until a diagram is shown. `securityLevel: "strict"` (Mermaid
// sanitizes labels and drops click callbacks), labels as SVG text (`htmlLabels: false`: no HTML
// element from a label exists, even in Mermaid's scratch DOM), no configuration from the diagram
// (`%%{init}%%` directives and front matter are removed; `secure` locks the options as well), and
// sources that name a resource (`url(…)`, an image function, `@import`, an image shape, any CSS
// escape) refused, so nothing is fetched while Mermaid lays a diagram out in the page. The result is an SVG string that mermaid.ts shows only as an
// `<img>` (no live SVG DOM from note text in the editor).

export type MermaidTheme = "neutral" | "dark";
export type MermaidResult = { svg: string } | { error: string };

/** Longer sources are refused before Mermaid sees them. */
export const MAX_MERMAID_SOURCE = 20_000;

/** Options only the app sets: a diagram's `%%{init}%%` or front matter cannot change them. */
const SECURE = [
  "secure", "securityLevel", "startOnLoad", "maxTextSize", "maxEdges", "suppressErrorRendering",
  "theme", "themeCSS", "themeVariables", "fontFamily", "altFontFamily", "darkMode", "htmlLabels", "look", "layout",
];

type Mermaid = (typeof import("mermaid"))["default"];

let loaded: Promise<Mermaid> | null = null;
let sequence = 0;
/** Renders run one at a time: Mermaid's configuration and its scratch DOM are global. */
let queue: Promise<unknown> = Promise.resolve();

type Entry = { promise: Promise<MermaidResult>; result?: MermaidResult };
/** Results by (theme, source), least recently used first. */
const cache = new Map<string, Entry>();
const CACHE_SIZE = 50;

const keyOf = (source: string, theme: MermaidTheme) => `${theme}\u0000${source}`;

function touch(key: string, entry: Entry): void {
  cache.delete(key);
  cache.set(key, entry);
}

/** A finished result for `source` without waiting (the widget draws it at once), else null. */
export function cachedMermaid(source: string, theme: MermaidTheme): MermaidResult | null {
  if (source.length > MAX_MERMAID_SOURCE) return { error: "Diagram too large" };
  const refused = refusedSource(source);
  if (refused) return { error: refused };
  const key = keyOf(source, theme);
  const entry = cache.get(key);
  if (!entry?.result) return null;
  touch(key, entry);
  return entry.result;
}

/** Syntax that makes the browser fetch: a URL, an image function, an import, an image shape. */
const RESOURCE = /url\s*\(|image(?:-set)?\s*\(|@import|\bimg\s*:/i;
/** A CSS escape (`u\72l(` is `url(`), or a backslash before a line break, anywhere in the source. */
const CSS_ESCAPE = /\\(?:[0-9a-f]|\r?\n)/i;
/** `%%{init: …}%%` directives and front matter: a diagram never configures the renderer. */
const DIRECTIVE = /%%\{[\s\S]*?\}%%/g;
const FRONT_MATTER = /^\s*---\r?\n[\s\S]*?\r?\n---[ \t]*(?:\r?\n|$)/;

/** The source without directives and front matter (the app alone sets the options). */
export function withoutConfig(source: string): string {
  return source.replace(FRONT_MATTER, "").replace(DIRECTIVE, "");
}

/** The `flowchart-elk` keyword, after blank and comment lines: the one way left to ask for the ELK layout. */
const ELK_KEYWORD = /^((?:[ \t]*(?:%%[^\n]*)?\r?\n)*[ \t]*)flowchart-elk(?![\w-])/;

/**
 * The source with the ELK layout turned into Mermaid's default one: elkjs is not part of the app
 *, so `flowchart-elk TD` is drawn as `flowchart TD`. Run after `withoutConfig`, which
 * already removes `layout: elk` from directives and front matter.
 */
export function withDefaultLayout(source: string): string {
  return source.replace(ELK_KEYWORD, "$1flowchart");
}

/**
 * The layout the app asks Mermaid for. Mermaid 12.2 defaults to ELK, which is not part of the app, so
 * graph diagrams use dagre (Mermaid's classic layout). A mindmap keeps the radial layout it picks by
 * itself when the app sets none.
 */
export function layoutFor(diagramType: string | undefined): "dagre" | "cose-bilkent" {
  return diagramType === "mindmap" ? "cose-bilkent" : "dagre";
}

/** Why `source` is refused, or null: it would make the browser fetch something. */
export function refusedSource(source: string): string | null {
  if (RESOURCE.test(source)) return "Diagrams cannot load images, URLs or styles from outside the note";
  if (CSS_ESCAPE.test(source)) return "Diagrams cannot contain escapes (a backslash before a digit, a-f or a line break)";
  return null;
}

/**
 * The SVG as well-formed XML, which an `<img>` needs (a label's text with `<` or `&` could break
 * it): an SVG that does not parse as XML is re-read by the HTML parser in an inert `DOMParser`
 * document (no scripts, nothing loads) and serialized back as XML.
 */
function wellFormed(svg: string): string {
  const parser = new DOMParser();
  if (!parser.parseFromString(svg, "image/svg+xml").querySelector("parsererror")) return svg;
  const el = parser.parseFromString(`<body>${svg}</body>`, "text/html").querySelector("svg");
  return el ? new XMLSerializer().serializeToString(el) : svg;
}

/** Renders `source` with `theme` to an SVG string, or Mermaid's error message. Cached. */
export function renderMermaid(source: string, theme: MermaidTheme = "neutral"): Promise<MermaidResult> {
  if (source.length > MAX_MERMAID_SOURCE) return Promise.resolve({ error: "Diagram too large" });
  const refused = refusedSource(source);
  if (refused) return Promise.resolve({ error: refused });
  const key = keyOf(source, theme);
  const hit = cache.get(key);
  if (hit) {
    touch(key, hit);
    return hit.promise;
  }
  const entry: Entry = { promise: Promise.resolve({ error: "" }) };
  const publish = (result: MermaidResult, keep: boolean): MermaidResult => {
    // An entry evicted while it rendered stays out of the cache.
    if (cache.get(key) === entry) {
      if (keep) entry.result = result;
      else cache.delete(key);
    }
    return result;
  };
  const run = async (): Promise<MermaidResult> => {
    const load = (loaded ??= import("mermaid").then((m) => m.default));
    load.catch(() => {
      if (loaded === load) loaded = null;
    });
    let mermaid: Mermaid;
    try {
      mermaid = await load;
    } catch (err) {
      // Not the diagram's fault: not cached, the next render tries again.
      return publish({ error: err instanceof Error ? err.message : String(err) }, false);
    }
    const id = `bc-mermaid-${++sequence}`;
    try {
      const text = withDefaultLayout(withoutConfig(source));
      let type: string | undefined;
      try {
        type = mermaid.detectType(text);
      } catch {
        // Not a diagram Mermaid knows: render() reports it.
      }
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme, htmlLabels: false, layout: layoutFor(type), secure: SECURE });
      const { svg } = await mermaid.render(id, text);
      return publish({ svg: wellFormed(svg) }, true);
    } catch (err) {
      return publish({ error: err instanceof Error ? err.message : String(err) }, true);
    } finally {
      // Mermaid leaves its scratch element behind when a render fails.
      for (const stray of [id, `d${id}`, `i${id}`]) document.getElementById(stray)?.remove();
    }
  };
  entry.promise = queue.then(run, run);
  queue = entry.promise.catch(() => undefined);
  cache.set(key, entry);
  while (cache.size > CACHE_SIZE) cache.delete(cache.keys().next().value!);
  return entry.promise;
}
