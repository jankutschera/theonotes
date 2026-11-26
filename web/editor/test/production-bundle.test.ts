// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { build, type Rollup } from "vite";

// M0 carry / M3 Task 10: debug hooks (`debugText`, `debugInsert`, `debugView`, …) and the mock host
// are compiled out of production builds; only dev builds (vite dev, e2e) have them. Builds the real
// bundle in memory (nothing is written) and greps its JavaScript.
const root = decodeURIComponent(new URL("..", import.meta.url).pathname);

/** Node's environment (no @types/node in this package). */
const env = (globalThis as unknown as { process: { env: Record<string, string | undefined> } }).process.env;

type Build = { chunks: Rollup.OutputChunk[]; assets: Rollup.OutputAsset[] };
let built: Promise<Build> | null = null;

/** The production build, in memory (nothing is written), once for all tests of this file. */
function productionBuild(): Promise<Build> {
  built ??= (async () => {
    // Vitest runs with NODE_ENV=test, which would make the build a dev build (`import.meta.env.DEV`);
    // `vite build` from scripts/build-editor.sh runs without it, i.e. production.
    const nodeEnv = env.NODE_ENV;
    env.NODE_ENV = "production";
    let result: Awaited<ReturnType<typeof build>>;
    try {
      result = await build({ root, logLevel: "silent", mode: "production", build: { write: false, emptyOutDir: false } });
    } finally {
      env.NODE_ENV = nodeEnv;
    }
    const outputs = (Array.isArray(result) ? result : [result]) as Rollup.RollupOutput[];
    return {
      chunks: outputs.flatMap((o) => o.output).filter((chunk): chunk is Rollup.OutputChunk => chunk.type === "chunk"),
      assets: outputs.flatMap((o) => o.output).filter((asset): asset is Rollup.OutputAsset => asset.type === "asset"),
    };
  })();
  return built;
}

async function productionJS(): Promise<string> {
  return (await productionBuild()).chunks.map((chunk) => chunk.code).join("\n");
}

/** The debug hook names main.ts exposes in dev builds (`debugText: …`). */
const mainSource = Object.values(import.meta.glob("../src/main.ts", { eager: true, query: "?raw", import: "default" }))[0] as string;
const hookNames = [...new Set(mainSource.match(/\bdebug[A-Z]\w*(?=\s*:)/g) ?? [])];

describe("production bundle", () => {
  test("has no debug hooks and no mock host", { timeout: 120_000 }, async () => {
    const js = await productionJS();
    // The grep looks at the real bundle: the bridge entry point is there.
    expect(js.length).toBeGreaterThan(100_000);
    expect(js).toContain("receive");
    // The editor's own hooks (main.ts), not words in third-party chunks (Mermaid's `debugID`).
    expect(hookNames.length).toBeGreaterThan(5);
    expect(hookNames.filter((name) => js.includes(name))).toEqual([]);
    expect(js).not.toContain("mock host offline");
    // The block layer is in, its dev-only test renderer (`?testBlocks`, M6 Task 3) is not.
    expect(js).toContain("cm-bc-block-collapsed");
    for (const s of ["Rendered block (", "testBlocks", "test-block", "Test block"]) expect(js).not.toContain(s);
  });

  test("export.html is built, and index.html's chunk graph does not reach src/export", { timeout: 120_000 }, async () => {
    const { chunks } = await productionBuild();
    const byFile = new Map(chunks.map((chunk) => [chunk.fileName, chunk]));
    const entry = (page: string) => chunks.find((chunk) => chunk.isEntry && chunk.facadeModuleId?.endsWith(`/${page}.html`));
    const index = entry("index");
    const exportPage = entry("export");
    expect(index, "index.html entry chunk").toBeDefined();
    expect(exportPage, "export.html entry chunk").toBeDefined();
    // Everything index.html can load: its chunk and every static or dynamic import, transitively.
    const reached = new Set<string>();
    const visit = (file: string) => {
      if (reached.has(file)) return;
      reached.add(file);
      const chunk = byFile.get(file);
      for (const next of [...(chunk?.imports ?? []), ...(chunk?.dynamicImports ?? [])]) visit(next);
    };
    visit(index!.fileName);
    const exportModules = (chunk: Rollup.OutputChunk) => Object.keys(chunk.modules).filter((id) => id.includes("/src/export/"));
    const leaked = [...reached].flatMap((file) => exportModules(byFile.get(file)!));
    // Temporary, exact exception (integration merge 2026-10-26): the iOS app renders its exports
    // through `window.__baerchen.renderNote` on the editor page (ios-iphone-ipad's
    // note-export.ts / rich-note-export.ts). It goes when iOS export moves onto export.html and
    // render.ts (follow-up port); any other module under src/export still fails here.
    const iosLegacyExport = ["/src/export/note-export.ts", "/src/export/rich-note-export.ts"];
    expect(leaked.map((id) => id.slice(id.indexOf("/src/export/"))).sort()).toEqual(iosLegacyExport);
    // The export page does carry the renderer, and the page script.
    const exportReached = new Set<string>();
    const visitExport = (file: string) => {
      if (exportReached.has(file)) return;
      exportReached.add(file);
      const chunk = byFile.get(file);
      for (const next of chunk?.imports ?? []) visitExport(next);
    };
    visitExport(exportPage!.fileName);
    const exportIds = [...exportReached].flatMap((file) => exportModules(byFile.get(file)!));
    expect(exportIds.some((id) => id.endsWith("/src/export/page.ts"))).toBe(true);
    expect(exportIds.some((id) => id.endsWith("/src/export/render.ts"))).toBe(true);
  });

  // Elkjs (EPL-2.0 without a GPL secondary licence) is not part of the app, so the
  // GPL-3.0-only claim holds for the whole bundle. vite.config.ts aliases it to stubs/elkjs-disabled.
  // The check looks at module ids and at the bytes: the library's licence header, its SPDX line, its
  // Java package names and the EMF namespace URIs it carries.
  test("no elkjs module and no elkjs bytes are in the bundle", { timeout: 120_000 }, async () => {
    const { chunks, assets } = await productionBuild();
    const ids = chunks.flatMap((chunk) => Object.keys(chunk.modules));
    expect(ids.filter((id) => /\/elkjs\//.test(id) && !id.includes("/stubs/elkjs-disabled/"))).toEqual([]);
    expect(ids.some((id) => id.includes("/stubs/elkjs-disabled/"))).toBe(true);
    expect(chunks.map((chunk) => chunk.fileName).filter((name) => /elkjs/.test(name))).toEqual([]);
    const text = (asset: Rollup.OutputAsset) => (typeof asset.source === "string" ? asset.source : new TextDecoder().decode(asset.source));
    const everything = [...chunks.map((chunk) => chunk.code), ...assets.map(text)].join("\n");
    for (const needle of ["EPL-2.0", "Eclipse Public License", "org.eclipse.elk", "eclipse.org/elk", "elk.bundled", "ELK_LAYOUT_GWT"]) {
      expect(everything, needle).not.toContain(needle);
    }
    // The stub is what Mermaid's ELK glue reaches; it refuses with a clear message.
    expect(everything).toContain("ELK layout is not included");
  });

  // The maths font is STIX Two (SIL OFL 1.1). @mathjax/src names New Computer Modern as its
  // default font through the `#default-font` import map; vite.config.ts points that at STIX Two,
  // so no New Computer Modern data is built into the app.
  test("the maths font is STIX Two and New Computer Modern is not bundled", { timeout: 120_000 }, async () => {
    const { chunks } = await productionBuild();
    const ids = chunks.flatMap((chunk) => Object.keys(chunk.modules));
    expect(ids.filter((id) => id.includes("mathjax-newcm-font"))).toEqual([]);
    expect(ids.some((id) => id.includes("mathjax-stix2-font"))).toBe(true);
    const js = chunks.map((chunk) => chunk.code).join("\n");
    expect(js).not.toContain("mathjax-newcm");
    expect(js).toContain("mathjax-stix2");
  });

  // M10 T2 (network audit): the bundle names no remote resource to load. HTML pages and stylesheets
  // have no remote src/href/url()/@import; every http(s) host that appears in JavaScript is on a short
  // list of names that are not requests (XML namespaces, documentation links in strings). A new host
  // fails here, so someone looks at it before it ships.
  test("names no remote resource, and the hosts in JavaScript are an exact list", { timeout: 120_000 }, async () => {
    const { chunks, assets } = await productionBuild();
    const text = (asset: Rollup.OutputAsset) => (typeof asset.source === "string" ? asset.source : new TextDecoder().decode(asset.source));
    const pages = assets.filter((asset) => asset.fileName.endsWith(".html"));
    const sheets = assets.filter((asset) => asset.fileName.endsWith(".css"));
    expect(pages.length).toBeGreaterThanOrEqual(2);
    // Styles are mostly built into the JavaScript (shadow roots), so they are checked there too.
    for (const chunk of chunks) {
      expect(chunk.code, chunk.fileName).not.toMatch(/url\(\s*\\?["']?\s*(?:https?:)?\/\//i);
      expect(chunk.code, chunk.fileName).not.toMatch(/@import\s+(?:url\()?\s*\\?["']?\s*(?:https?:)?\/\//i);
    }
    for (const page of pages) expect(text(page), page.fileName).not.toMatch(/(?:src|href|action|poster|data)\s*=\s*["']?\s*(?:https?:)?\/\//i);
    for (const sheet of sheets) {
      expect(text(sheet), sheet.fileName).not.toMatch(/url\(\s*["']?\s*(?:https?:)?\/\//i);
      expect(text(sheet), sheet.fileName).not.toMatch(/@import\s+(?:url\()?\s*["']?\s*(?:https?:)?\/\//i);
    }
    const hosts = new Set<string>();
    for (const chunk of chunks) for (const match of chunk.code.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)) hosts.add(match[1]!.toLowerCase());
    // Read on 2026-10-28: error messages that point to docs or issue trackers (Mermaid, Chevrotain,
    // Langium, marked), SVG/XML namespaces. (The Rolldown runtime message went with elkjs, the only
    // CommonJS file.)
    expect([...hosts].sort()).toEqual([
      "chevrotain.io",
      "en.wikipedia.org",
      "github.com",
      "langium.org",
      "www.w3.org",
    ]);
    // None of them is the argument of a call that opens a connection.
    for (const chunk of chunks) {
      expect(chunk.code, chunk.fileName).not.toMatch(/\b(?:fetch|sendBeacon|importScripts|WebSocket|EventSource)\(\s*[`"']https?:/);
    }
  });
});
