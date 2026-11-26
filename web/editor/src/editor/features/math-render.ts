// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// MathJax 4 (M6 Task 11): the only module that imports MathJax, through dynamic import,
// so the editor bundle does not load it until a formula is shown. Components are imported
// directly (no loader): TeX input with a fixed package list, SVG output with the STIX Two
// font (SIL OFL 1.1), the browser DOM adaptor. Not loaded: `html` (`\href`, `\class`, `\style`, `\data`),
// `require`, `autoload`, `setoptions`, `action` and the accessibility/speech modules. The font's
// dynamic files come from the bundle (`import.meta.glob`); any other name is refused, so nothing
// is fetched from outside the app.

export type MathResult = { svg: SVGElement } | { error: string };

/** TeX packages (brief): no `html`, `require`, `autoload`, `setoptions`, `action`. */
const PACKAGES = ["base", "ams", "newcommand", "noundefined", "boldsymbol", "cancel", "color", "cases", "mathtools", "braket"];

/** The font's dynamic glyph files, bundled; keyed by their path under the project root. */
const fontFiles = import.meta.glob("/node_modules/@mathjax/mathjax-stix2-font/mjs/svg/dynamic/*.js");
const FONT_PREFIX = "@mathjax/mathjax-stix2-font/js/svg/dynamic/";

type Engine = {
  convert(tex: string, display: boolean): Promise<Element>;
};

/** Longer TeX is refused before MathJax sees it (an imported note must not freeze the editor). */
export const MAX_TEX = 5000;
/** A rendering with more SVG elements than this is shown but not cached. */
const MAX_CACHED_NODES = 4000;

let engine: Promise<Engine> | null = null;

class TexError extends Error {}

async function loadEngine(): Promise<Engine> {
  const [{ mathjax }, { TeX }, { SVG }, { browserAdaptor }, { RegisterHTMLHandler }, { MathJaxStix2Font }] = await Promise.all([
    import("@mathjax/src/js/mathjax.js"),
    import("@mathjax/src/js/input/tex.js"),
    import("@mathjax/src/js/output/svg.js"),
    import("@mathjax/src/js/adaptors/browserAdaptor.js"),
    import("@mathjax/src/js/handlers/html.js"),
    import("@mathjax/mathjax-stix2-font/js/svg.js"),
  ]);
  // Each package registers itself with TeX's configuration handler when imported.
  await Promise.all([
    import("@mathjax/src/js/input/tex/base/BaseConfiguration.js"),
    import("@mathjax/src/js/input/tex/ams/AmsConfiguration.js"),
    import("@mathjax/src/js/input/tex/newcommand/NewcommandConfiguration.js"),
    import("@mathjax/src/js/input/tex/noundefined/NoUndefinedConfiguration.js"),
    import("@mathjax/src/js/input/tex/boldsymbol/BoldsymbolConfiguration.js"),
    import("@mathjax/src/js/input/tex/cancel/CancelConfiguration.js"),
    import("@mathjax/src/js/input/tex/color/ColorConfiguration.js"),
    import("@mathjax/src/js/input/tex/cases/CasesConfiguration.js"),
    import("@mathjax/src/js/input/tex/mathtools/MathtoolsConfiguration.js"),
    import("@mathjax/src/js/input/tex/braket/BraketConfiguration.js"),
  ]);
  mathjax.asyncLoad = (name: string) => {
    const file = name.startsWith(FONT_PREFIX) ? name.slice(FONT_PREFIX.length) : null;
    const load = file && /^[a-z0-9-]+\.js$/i.test(file) ? fontFiles[`/node_modules/@mathjax/mathjax-stix2-font/mjs/svg/dynamic/${file}`] : undefined;
    return load ? load() : Promise.reject(new Error(`MathJax: ${name} is not bundled`));
  };
  const adaptor = browserAdaptor();
  RegisterHTMLHandler(adaptor);
  // fontCache "local": each SVG holds the glyphs it uses, so a copy shows anywhere (shadow roots).
  // No inline line breaking: MathJax 4 otherwise emits one SVG per breakable inline segment and
  // `renderMath` keeps one, which dropped every later term (ios-iphone-ipad 0061337).
  const svg = new SVG({ fontData: MathJaxStix2Font, fontCache: "local", linebreaks: { inline: false } });
  // A fresh TeX input per formula: `\def`, `\newcommand` and `\definecolor` live in its parse
  // options, so one formula's definitions never reach another (or another note); the cache stays
  // a function of the TeX. Conversions run one at a time (a retry waiting for a glyph file must
  // not interleave with another conversion on the shared SVG output).
  let queue: Promise<unknown> = Promise.resolve();
  return {
    convert(source, display) {
      const run = async () => {
        const tex = new TeX({
          packages: PACKAGES,
          maxMacros: 1000,
          // A TeX error becomes the result's message instead of an error node.
          formatError: (_jax: unknown, err: { message: string }) => {
            throw new TexError(err.message);
          },
        });
        const doc = mathjax.document(document, { InputJax: tex, OutputJax: svg });
        return (await mathjax.handleRetriesFor(() => doc.convert(source, { display, em: 16, ex: 8, containerWidth: 1280 }))) as Element;
      };
      const next = queue.then(run, run);
      queue = next.catch(() => undefined);
      return next;
    },
  };
}

/** Elements that never belong in a formula: links, images, foreign content, scripts. */
const UNSAFE = new Set(["a", "image", "foreignobject", "script", "iframe", "animate", "set", "style"]);
/** Presentation attributes that take a paint: a colour value only (no `url(…)`). */
const PAINT = new Set(["fill", "stroke", "color", "stop-color", "flood-color", "lighting-color", "mathcolor", "mathbackground"]);
/** Attributes that take a URL and that MathJax's SVG never needs. */
const URL_ATTRIBUTES = new Set(["filter", "mask", "clip-path", "marker-start", "marker-mid", "marker-end", "cursor", "src"]);
const COLOR = /^(?:#[0-9a-f]{3,8}|[a-z]+|(?:rgba?|hsla?)\(\s*[\d.%\s,/+-]+\))$/i;
/** Style properties MathJax's SVG output uses (layout and colour). */
const STYLE_PROPERTIES = new Set([
  "vertical-align", "width", "height", "min-width", "max-width", "min-height", "margin-left", "margin-right",
  "margin-top", "margin-bottom", "overflow", "display", "color", "fill", "stroke", "background-color", "opacity",
]);
/** A plain CSS value: words, numbers, units, `#hex`; no quotes, backslashes or functions. */
const PLAIN_VALUE = /^[\w\s.%#,+-]*$/;

/** The declarations of `style` that are known properties with plain (or colour) values. */
function safeStyle(style: string): string {
  return style
    .split(";")
    .map((decl) => decl.trim())
    .filter((decl) => {
      const at = decl.indexOf(":");
      if (at < 0) return false;
      const prop = decl.slice(0, at).trim().toLowerCase();
      const value = decl.slice(at + 1).trim();
      return STYLE_PROPERTIES.has(prop) && (PLAIN_VALUE.test(value) || COLOR.test(value));
    })
    .join("; ");
}

/**
 * Keeps only what a formula needs in a MathJax SVG, an allowlist: unsafe elements go
 * (their children stay); `href` only as the SVG's own `#glyph` reference; paint attributes only
 * with a colour; URL-taking attributes and `on*` handlers never; `style` only known layout and
 * colour properties with plain values (so no `url(…)`, `image-set(…)` or CSS escapes); any other
 * value with a backslash, `url` or an image function is dropped. `\mmlToken` and `\color` can
 * carry all of these.
 */
export function sanitizeSvg(svg: SVGElement): SVGElement {
  for (const el of [svg, ...svg.querySelectorAll("*")]) {
    if (el !== svg && UNSAFE.has(el.localName.toLowerCase())) {
      el.replaceWith(...el.childNodes);
      continue;
    }
    for (const attr of [...el.attributes]) {
      const name = attr.localName.toLowerCase();
      const value = attr.value;
      let keep: boolean;
      if (name.startsWith("on") || URL_ATTRIBUTES.has(name)) keep = false;
      else if (name === "href") keep = /^#[\w.:-]+$/.test(value);
      else if (PAINT.has(name)) keep = COLOR.test(value.trim());
      else if (name === "style") {
        const safe = safeStyle(value);
        if (safe !== value) el.setAttribute("style", safe);
        keep = true;
      } else keep = name.startsWith("data-") || !/\\|url|image|expression/i.test(value);
      if (!keep) el.removeAttributeNode(attr);
    }
  }
  return svg;
}

/** Results by (display, tex), least recently used first. */
const cache = new Map<string, Promise<MathResult>>();
const CACHE_SIZE = 500;

/**
 * Renders `tex` (inline or display) to an SVG element, or the TeX error message. Results are
 * cached (the same SVG is returned again: callers insert a copy).
 */
export function renderMath(tex: string, display: boolean): Promise<MathResult> {
  const key = `${display ? "D" : "I"}\u0000${tex}`;
  const hit = cache.get(key);
  if (hit) {
    cache.delete(key);
    cache.set(key, hit);
    return hit;
  }
  if (tex.length > MAX_TEX) return Promise.resolve({ error: `Formula too long (${tex.length} characters, at most ${MAX_TEX})` });
  const result = (async (): Promise<MathResult> => {
    try {
      const load = (engine ??= loadEngine());
      // A failed load (a chunk that did not arrive) is tried again by the next formula.
      load.catch(() => {
        if (engine === load) engine = null;
      });
      const node = await (await load).convert(tex, display);
      const svg = node.querySelector("svg");
      if (!svg) throw new Error("MathJax produced no SVG");
      if (svg.getElementsByTagName("*").length > MAX_CACHED_NODES) cache.delete(key);
      return { svg: sanitizeSvg(svg) };
    } catch (err) {
      if (err instanceof TexError) return { error: err.message };
      // Not the formula's fault: not cached, the next render tries again.
      cache.delete(key);
      return { error: err instanceof Error ? err.message : String(err) };
    }
  })();
  cache.set(key, result);
  if (cache.size > CACHE_SIZE) cache.delete(cache.keys().next().value!);
  return result;
}
