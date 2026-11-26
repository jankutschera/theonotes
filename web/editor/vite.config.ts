// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { defineConfig } from "vite";

// @mathjax/src names its default font through the package import map `#default-font/*`, which points
// at New Computer Modern. The editor always passes STIX Two (math-render.ts), but the SVG output
// still imports the default, which would build New Computer Modern into the app. Pointing the map
// at STIX Two keeps that font out.
const stixDir = decodeURIComponent(new URL("./node_modules/@mathjax/mathjax-stix2-font/mjs/", import.meta.url).pathname);

// Mermaid's optional ELK layout imports elkjs (EPL-2.0, no GPL secondary-licence notice), which
// cannot ship in a GPL-3.0-only program. Every `elkjs` import is pointed at a stub of our own that
// only refuses; the ELK layout is not available.
const elkStub = decodeURIComponent(new URL("./stubs/elkjs-disabled/index.js", import.meta.url).pathname);

export default defineConfig({
  base: "./",
  resolve: {
    alias: [
      { find: /^#default-font\//, replacement: stixDir },
      { find: /^elkjs(?:\/.*)?$/, replacement: elkStub },
    ],
  },
  // MathJax's font loads its glyph files by path (math-render.ts); pre-bundled copies of
  // @mathjax would be a second module instance those files never reach (dev server only).
  optimizeDeps: { exclude: ["@mathjax/src", "@mathjax/mathjax-stix2-font"] },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Two pages: the editor, and the export page (M8 Task 10). The editor's chunk graph must not
    // reach src/export (test/production-bundle.test.ts).
    rollupOptions: {
      input: { index: "index.html", export: "export.html" },
    },
  },
});
