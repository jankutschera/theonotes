// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, describe, expect, test, vi } from "vitest";
import { EditorState } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";

// Mermaid never loads in unit tests.
vi.mock("mermaid", () => ({ default: { initialize: vi.fn(), render: vi.fn(async () => ({ svg: "<svg/>" })) } }));

import { bearMarkdown } from "../src/editor/dialect";
import { MERMAID_DEBOUNCE_MS, mermaidRenderer, RenderQueue } from "../src/editor/features/mermaid";
import { cachedMermaid, MAX_MERMAID_SOURCE, layoutFor, refusedSource, renderMermaid, withDefaultLayout, withoutConfig } from "../src/editor/features/mermaid-render";

function stateOf(doc: string): EditorState {
  const state = EditorState.create({ doc, extensions: [markdown({ base: bearMarkdown })] });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function matches(doc: string) {
  const state = stateOf(doc);
  const out: { from: number; to: number }[] = [];
  syntaxTree(state).iterate({
    enter(node) {
      const block = mermaidRenderer.match(state, node);
      if (block) out.push({ from: block.from, to: block.to });
    },
  });
  return out;
}

afterEach(() => vi.useRealTimers());

describe("mermaid", () => {
  test("matches only mermaid fences", () => {
    const doc = "```mermaid\nflowchart LR\n  A --> B\n```\n\n```js\nx\n```\n\n```Mermaid\ngraph TD\n```\n\n```\nplain\n```";
    const second = doc.indexOf("```Mermaid");
    expect(matches(doc)).toEqual([
      { from: 0, to: doc.indexOf("```\n\n```js") + 3 },
      { from: second, to: doc.indexOf("```", second + 10) + 3 },
    ]);
    // Not a fence: inline code.
    expect(matches("`mermaid` and ``` mermaid ```")).toEqual([]);
  });

  test("debounces while editing", () => {
    vi.useFakeTimers();
    const queue = new RenderQueue();
    const runs: string[] = [];
    // Each edit replaces the preview widget: the old one cancels, the new one schedules.
    let token = {};
    for (const source of ["g", "gr", "gra", "grap"]) {
      queue.cancel(token);
      token = {};
      queue.schedule(token, MERMAID_DEBOUNCE_MS, () => runs.push(source));
      vi.advanceTimersByTime(100);
    }
    expect(runs).toEqual([]);
    vi.advanceTimersByTime(MERMAID_DEBOUNCE_MS);
    vi.runAllTimers();
    expect(runs).toEqual(["grap"]);
    expect(queue.pending).toBe(0);
    // Rescheduling the same widget keeps one pending render.
    queue.schedule(token, 50, () => runs.push("a"));
    queue.schedule(token, 50, () => runs.push("b"));
    vi.runAllTimers();
    expect(runs).toEqual(["grap", "b"]);
  });

  test("sources that would fetch are refused (fix round 1)", async () => {
    expect(refusedSource("flowchart LR\n  A --> B")).toBeNull();
    expect(refusedSource("flowchart LR\n  style A fill:url(/x.svg#a)")).toMatch(/cannot load/);
    expect(refusedSource("flowchart LR\n  style A fill:URL ( /x )")).toMatch(/cannot load/);
    expect(refusedSource("flowchart LR\n  classDef c background:image-set('/x.png' 1x)")).toMatch(/cannot load/);
    expect(refusedSource("%%{init: {'themeCSS': '@import \"/x.css\";'}}%%\nflowchart LR")).toMatch(/cannot load/);
    expect(refusedSource("flowchart LR\n  classDef c fill:u\\72l(/x)")).toMatch(/escapes/);
    // Security review: escapes after `;` on one line, an image shape.
    expect(refusedSource("flowchart LR\n  A --> B; style A fill:u\\72l(/x)")).toMatch(/escapes/);
    expect(refusedSource('flowchart LR\n  A@{ img: "/x.png", label: "a" }')).toMatch(/cannot load/);
    // A backslash before other characters in a label is fine.
    expect(refusedSource('flowchart LR\n  A["a\\Xb"]')).toBeNull();
    // Directives and front matter never reach Mermaid.
    expect(withoutConfig('%%{init: {"flowchart": {"htmlLabels": true}}}%%\nflowchart LR\n  A --> B')).toBe("\nflowchart LR\n  A --> B");
    expect(withoutConfig("---\nconfig:\n  theme: forest\n---\nflowchart LR")).toBe("flowchart LR");
    expect(await renderMermaid("flowchart LR\n  style A fill:url(/x)")).toEqual({ error: expect.stringMatching(/cannot load/) });
  });

  // REN2-R10: the ELK layout (elkjs, EPL-2.0) is not part of the app. The only way left for a diagram
  // to ask for it (directives and front matter are removed) is the `flowchart-elk` keyword; it is read
  // as a plain `flowchart` so the diagram renders with Mermaid's default layout.
  test("flowchart-elk falls back to the default layout", () => {
    expect(withDefaultLayout("flowchart-elk TD\n  A --> B")).toBe("flowchart TD\n  A --> B");
    expect(withDefaultLayout("  \n%% note\nflowchart-elk LR\n  A --> B")).toBe("  \n%% note\nflowchart LR\n  A --> B");
    expect(withDefaultLayout("flowchart-elk\n  A --> B")).toBe("flowchart\n  A --> B");
    // Everything else is untouched, including the word in a label or a longer keyword.
    const same = ["flowchart TD\n  A[flowchart-elk] --> B", "flowchart LR\n  A --> B", "flowchart-elkx TD", "sequenceDiagram\n  A->>B: flowchart-elk"];
    for (const source of same) expect(withDefaultLayout(source)).toBe(source);
    // The keyword behind a directive is still caught, because the directive is removed first.
    expect(withDefaultLayout(withoutConfig('%%{init: {"layout": "elk"}}%%\nflowchart-elk TD\n  A --> B'))).toBe("\nflowchart TD\n  A --> B");
  });

  test("the app asks for dagre, a mindmap for its radial layout", () => {
    expect(layoutFor("flowchart-v2")).toBe("dagre");
    expect(layoutFor("stateDiagram")).toBe("dagre");
    expect(layoutFor(undefined)).toBe("dagre");
    expect(layoutFor("mindmap")).toBe("cose-bilkent");
  });

  test("entry(): the first and last code line, closed or not; quoted fences", () => {
    const at = (doc: string, from: "above" | "below") => {
      const state = stateOf(doc);
      let pos = -1;
      syntaxTree(state).iterate({
        enter(node) {
          const block = mermaidRenderer.match(state, node);
          if (block) pos = mermaidRenderer.entry(state, block, from);
        },
      });
      return pos;
    };
    const closed = "```mermaid\ngraph TD\n  A --> B\n```";
    expect(at(closed, "above")).toBe(closed.indexOf("graph"));
    expect(at(closed, "below")).toBe(closed.indexOf("\n```"));
    const open = "```mermaid\ngraph TD\n  A --> B";
    expect(at(open, "below")).toBe(open.length);
    expect(at("```mermaid\n```", "above")).toBe("```mermaid".length);
    // A fence in a quote: its source without the quote marks.
    const quoted = "> ```mermaid\n> graph TD\n> ```";
    const state = stateOf(quoted);
    let widgetSource = "";
    syntaxTree(state).iterate({
      enter(node) {
        const block = mermaidRenderer.match(state, node);
        if (block) widgetSource = (mermaidRenderer.rendered(block) as unknown as { source: string }).source;
      },
    });
    expect(widgetSource).toBe("graph TD");
  });

  test("too-large source shows an error", async () => {
    const big = "flowchart LR\n" + "x".repeat(MAX_MERMAID_SOURCE);
    expect(await renderMermaid(big)).toEqual({ error: "Diagram too large" });
    expect(cachedMermaid(big, "neutral")).toEqual({ error: "Diagram too large" });
    expect(cachedMermaid("graph TD", "neutral")).toBeNull();
  });
});
