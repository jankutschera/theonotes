// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Stand-in for elkjs (Eclipse Layout Kernel, EPL-2.0), which Mermaid's optional ELK layout imports
// as `elkjs/lib/elk.bundled.js`. elkjs carries no GPL secondary-licence notice, so it cannot ship
// in a GPL-3.0-only program (REN2-R10). vite.config.ts aliases every `elkjs` import to this file;
// nothing of elkjs is read, copied or bundled. The editor reads a `flowchart-elk` diagram as a plain
// `flowchart` before Mermaid sees it (mermaid-render.ts), so this class is only reached by a
// request that slipped past that, and it fails with a plain message.

export default class ELK {
  layout() {
    return Promise.reject(new Error("ELK layout is not included in this app"));
  }
  knownLayoutAlgorithms() {
    return Promise.resolve([]);
  }
  knownLayoutOptions() {
    return Promise.resolve([]);
  }
  knownLayoutCategories() {
    return Promise.resolve([]);
  }
  terminateWorker() {}
}
