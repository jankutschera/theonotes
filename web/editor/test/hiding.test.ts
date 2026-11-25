// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState } from "@codemirror/state";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import {
  computeMarkup,
  hideMarkdown,
  computeHiddenRanges,
  hidingDecorations,
  hidingUpdatePlan,
  lineEdgePastHidden,
  visibleCharDeletion,
} from "../src/editor/features/hiding";

function stateWith(doc: string, anchor: number, head = anchor, hide = true): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(anchor, head),
    extensions: [markdown({ base: bearMarkdown }), hideMarkdown.of(hide)],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  // An empty transaction publishes the finished tree to syntaxTree(state).
  return state.update({}).state;
}

const doc = "# Title\nsome **bold** and [link](https://x.y)";
const at = (needle: string) => doc.indexOf(needle);

describe("computeHiddenRanges", () => {
  test("hides bold and link markup but not the heading the caret is on", () => {
    const ranges = computeHiddenRanges(stateWith(doc, 7));
    const bold = at("**bold**");
    expect(ranges).toContainEqual({ from: bold, to: bold + 2 });
    expect(ranges).toContainEqual({ from: bold + 6, to: bold + 8 });
    const link = at("[link]");
    expect(ranges).toContainEqual({ from: link, to: link + 1 });
    expect(ranges).toContainEqual({ from: at("](https"), to: doc.length });
    expect(ranges.some((r) => r.from === 0)).toBe(false);
  });

  test("hides the heading mark and its space when the caret is on another line", () => {
    const ranges = computeHiddenRanges(stateWith(doc, doc.length));
    expect(ranges).toContainEqual({ from: 0, to: 2 });
  });

  test("reveals bold marks while the caret is inside the bold text", () => {
    const ranges = computeHiddenRanges(stateWith(doc, at("bold") + 2));
    const bold = at("**bold**");
    expect(ranges).not.toContainEqual({ from: bold, to: bold + 2 });
    expect(ranges).not.toContainEqual({ from: bold + 6, to: bold + 8 });
    expect(ranges).toContainEqual({ from: at("[link]"), to: at("[link]") + 1 });
  });

  test("reveals markup touched by a range selection", () => {
    const bold = at("**bold**");
    const ranges = computeHiddenRanges(stateWith(doc, bold - 2, bold + 3));
    expect(ranges).not.toContainEqual({ from: bold, to: bold + 2 });
  });

  test("hides inline code backticks when the caret is elsewhere", () => {
    const code = "`code` end";
    const ranges = computeHiddenRanges(stateWith(code, code.length));
    expect(ranges).toEqual([
      { from: 0, to: 1 },
      { from: 5, to: 6 },
    ]);
  });

  test("does not hide fenced code marks, setext or indented code", () => {
    const text = "```\ncode\n```\n\nTitle\n===\n\n    indented\n\nend";
    expect(computeHiddenRanges(stateWith(text, text.length))).toEqual([]);
  });

  test("hides strikethrough and emphasis marks", () => {
    const text = "~~gone~~ *it* x";
    expect(computeHiddenRanges(stateWith(text, text.length))).toEqual([
      { from: 0, to: 2 },
      { from: 6, to: 8 },
      { from: 9, to: 10 },
      { from: 12, to: 13 },
    ]);
  });

  test("leaves bracketed text without a URL alone", () => {
    const text = "see [1] here";
    expect(computeHiddenRanges(stateWith(text, text.length))).toEqual([]);
  });

  test("splits link ranges at line breaks (multi-line titles)", () => {
    const text = '[a](u "x\ny") end';
    const ranges = computeHiddenRanges(stateWith(text, text.length));
    expect(ranges).toEqual([
      { from: 0, to: 1 },
      { from: 2, to: 8 },
      { from: 9, to: 12 },
    ]);
    for (const r of ranges) expect(text.slice(r.from, r.to)).not.toContain("\n");
  });
});

describe("Bear marks", () => {
  const hidden = (text: string, caret = text.length) => computeHiddenRanges(stateWith(text, caret));

  test("hides the closing # of a multi-word tag, keeps the opening # (IOS-DESIGN-R16)", () => {
    expect(hidden("#getting started# x")).toEqual([{ from: 16, to: 17 }]);
    expect(hidden("#getting started# x", 5)).toEqual([]);
    expect(hidden("#single x")).toEqual([]);
  });

  test("hides highlight marks", () => {
    expect(hidden("==hi== x")).toEqual([
      { from: 0, to: 2 },
      { from: 4, to: 6 },
    ]);
  });

  test("replaces a highlight color emoji with a dot (variation selector included)", () => {
    expect(hidden("==🟢hi== x")).toEqual([
      { from: 0, to: 2 },
      { from: 2, to: 4, color: "green" },
      { from: 6, to: 8 },
    ]);
    expect(hidden("==🔴️a== x")).toContainEqual({ from: 2, to: 5, color: "red" });
    expect(hidden("==🟢hi== x", 5)).toEqual([]);
  });

  test("an unclosed highlight keeps its color emoji as text (M6-R43)", () => {
    expect(hidden("==🔴 never closed")).toEqual([]);
    const state = stateWith("==🔴 never closed", 0);
    let colors = 0;
    syntaxTree(state).iterate({ enter: (n) => void (n.name === "HighlightColor" && colors++) });
    expect(colors).toBe(0);
    // A later closer still makes it a colored highlight.
    expect(hidden("==🔴a b== x")).toContainEqual({ from: 2, to: 4, color: "red" });
    // When the closer pairs with a later opener, the first emoji stays visible text.
    expect(hidden("==🔴a ==b== x").some((r) => r.color)).toBe(false);
    // Many unclosed openers on one line stay linear.
    const many = "==🔴x ".repeat(20_000);
    const start = performance.now();
    expect(hidden(many, 0)).toEqual([]);
    expect(performance.now() - start).toBeLessThan(2000);
  });

  test("a color emoji outside a highlight opener stays text", () => {
    expect(hidden("a 🟢 ==b== x")).toEqual([
      { from: 5, to: 7 },
      { from: 8, to: 10 },
    ]);
  });

  test("hides single-tilde underline marks, double tilde stays strikethrough", () => {
    expect(hidden("~u~ x")).toEqual([
      { from: 0, to: 1 },
      { from: 2, to: 3 },
    ]);
    const tree = stateWith("~u~ ~~s~~", 0);
    expect(computeHiddenRanges(tree)).toEqual([
      { from: 0, to: 1 },
      { from: 2, to: 3 },
      { from: 4, to: 6 },
      { from: 7, to: 9 },
    ]);
  });

  test("hides wiki link brackets, and the target when an alias is shown", () => {
    expect(hidden("[[Note]] x")).toEqual([
      { from: 0, to: 2 },
      { from: 6, to: 8 },
    ]);
    expect(hidden("[[Note/Head]] x")).toEqual([
      { from: 0, to: 2 },
      { from: 11, to: 13 },
    ]);
    expect(hidden("[[Note|alias]] x")).toEqual([
      { from: 0, to: 7 },
      { from: 12, to: 14 },
    ]);
    expect(hidden("[[Note|alias]] x", 3)).toEqual([]);
  });

  test("hides the backslash of escapes unless the caret is between it and the character", () => {
    expect(hidden("\\*no\\* x")).toEqual([
      { from: 0, to: 1 },
      { from: 4, to: 5 },
    ]);
    expect(hidden("\\*no\\* x", 1)).toEqual([{ from: 4, to: 5 }]);
  });

  test("tags, inline math and bare URLs keep their markup", () => {
    // Tags and URLs stay; a formula is rendered (math.ts), so its whole source is hidden.
    const doc = "#tag and $x$ and https://a.b x";
    expect(hidden(doc)).toEqual([{ from: doc.indexOf("$x$"), to: doc.indexOf("$x$") + 3 }]);
    expect(hidden(doc, doc.indexOf("x$"))).toEqual([]);
  });
});

describe("visibleCharDeletion", () => {
  test("Backspace after hidden closing marks deletes the last visible character", () => {
    expect(visibleCharDeletion(stateWith("**bold** x", 8), false)).toEqual({ from: 5, to: 6 });
    const link = "[link](https://x.y) more";
    expect(visibleCharDeletion(stateWith(link, link.indexOf(" more")), false)).toEqual({ from: 4, to: 5 });
    expect(visibleCharDeletion(stateWith("==🟢😀== x", 8), false)).toEqual({ from: 4, to: 6 });
  });

  test("Delete before hidden opening marks deletes the first visible character", () => {
    expect(visibleCharDeletion(stateWith("x **bold**", 2), true)).toEqual({ from: 4, to: 5 });
    expect(visibleCharDeletion(stateWith("==🟢hi== x", 0), true)).toEqual({ from: 4, to: 5 });
  });

  test("defers to the default command when nothing hidden is next to the caret", () => {
    expect(visibleCharDeletion(stateWith("plain", 3), false)).toBeNull();
    expect(visibleCharDeletion(stateWith("**b**", 3), false)).toBeNull();
    expect(visibleCharDeletion(stateWith("**bold** x", 4, 6), false)).toBeNull();
  });
});

describe("composition", () => {
  test("decorations are only mapped while composing and rebuilt once it ends", () => {
    expect(hidingUpdatePlan({ changed: true, composing: true, stale: false })).toBe("map");
    expect(hidingUpdatePlan({ changed: false, composing: false, stale: true })).toBe("rebuild");
    expect(hidingUpdatePlan({ changed: true, composing: false, stale: false })).toBe("rebuild");
    expect(hidingUpdatePlan({ changed: false, composing: false, stale: false })).toBe("keep");
  });
});

describe("lineEdgePastHidden", () => {
  test("End before hidden closing marks at the line end goes to the real line end", () => {
    const state = stateWith("**bold**\nnext", 13);
    expect(lineEdgePastHidden(state, 6, true)).toBe(8);
    expect(lineEdgePastHidden(state, 2, false)).toBe(0);
  });

  test("keeps positions followed by visible text", () => {
    const state = stateWith("**bold** x\nnext", 15);
    expect(lineEdgePastHidden(state, 6, true)).toBe(6);
    expect(lineEdgePastHidden(state, 10, true)).toBe(10);
  });
});

describe("hidingDecorations (accessibility: hidden markup stays in the DOM)", () => {
  type Spec = { class?: string; attributes?: Record<string, string>; widget?: unknown; side?: number };
  const decos = (text: string, caret = text.length) => {
    const out: { from: number; to: number; spec: Spec; point: boolean }[] = [];
    hidingDecorations(computeHiddenRanges(stateWith(text, caret))).between(0, text.length, (from, to, value) => {
      out.push({ from, to, spec: value.spec as Spec, point: value.point });
    });
    return out;
  };

  test("hidden markup becomes a collapsing mark, never a replace", () => {
    const text = "# T\nsome **bold** and [link](https://x.y) ==hi== [[Note|alias]] \\*x";
    const all = decos(text);
    expect(all.length).toBeGreaterThan(0);
    for (const d of all) {
      expect(d.point).toBe(false);
      expect(d.spec.class).toBe("cm-bc-hidden");
      // Not editable: WebKit must never type or compose into the invisible text.
      expect(d.spec.attributes?.contenteditable).toBe("false");
      expect(d.spec.widget).toBeUndefined();
    }
    const ranges = computeHiddenRanges(stateWith(text, text.length));
    expect(all.map(({ from, to }) => ({ from, to }))).toEqual(ranges.map(({ from, to }) => ({ from, to })));
  });

  test("a highlight color emoji stays as hidden text next to an aria-hidden dot widget", () => {
    const all = decos("==🟢hi== x");
    const marks = all.filter((d) => !d.point);
    expect(marks.map(({ from, to }) => [from, to])).toEqual([[0, 2], [2, 4], [6, 8]]);
    for (const m of marks) expect(m.spec.class).toBe("cm-bc-hidden");
    const widgets = all.filter((d) => d.point);
    expect(widgets).toHaveLength(1);
    expect(widgets[0]!.from).toBe(2);
    expect(widgets[0]!.to).toBe(2);
  });
});

describe("dimmed revealed markup (Bear: revealed marks in the secondary color)", () => {
  const md = "# Head **b**\nx **bold** [[Note|alias]] [l](https://u.v) \\* > no\n> quote";
  const pos = (needle: string) => md.indexOf(needle);
  const text = (state: EditorState, ranges: { from: number; to: number }[]) => ranges.map((r) => state.sliceDoc(r.from, r.to));

  test("the marks the caret reveals are dimmed, the hidden ones are not", () => {
    const state = stateWith(md, pos("bold") + 1);
    const { hidden, dim } = computeMarkup(state);
    expect(text(state, dim)).toEqual(["**", "**"]);
    expect(dim[0]).toEqual({ from: pos("**bold"), to: pos("**bold") + 2 });
    expect(hidden.some((h) => h.from === pos("**bold"))).toBe(false);
  });

  test("heading, wiki link, link, escape and quote marks dim when revealed", () => {
    expect(text(stateWith(md, 3), computeMarkup(stateWith(md, 3)).dim)).toEqual(["#"]);
    const wiki = stateWith(md, pos("Note") + 1);
    expect(text(wiki, computeMarkup(wiki).dim)).toEqual(["[[", "]]"]);
    const link = stateWith(md, pos("[l]") + 1);
    expect(text(link, computeMarkup(link).dim)).toEqual(["[", "]", "(", ")"]);
    const esc = stateWith(md, pos("\\*") + 1);
    expect(text(esc, computeMarkup(esc).dim)).toContain("\\");
    const quote = stateWith(md, md.length);
    expect(text(quote, computeMarkup(quote).dim)).toEqual([">"]);
  });

  test("Hide Markdown off: nothing hidden, every mark dimmed", () => {
    const state = stateWith(md, 0, 0, false);
    const { hidden, dim } = computeMarkup(state);
    expect(hidden).toEqual([]);
    expect(text(state, dim)).toEqual(["#", "**", "**", "**", "**", "[[", "]]", "[", "]", "(", ")", "\\"]);
    expect(computeHiddenRanges(state)).toEqual([]);
  });

  test("dimmed ranges never overlap hidden ones, wherever the caret is", () => {
    for (let caret = 0; caret <= md.length; caret++) {
      const { hidden, dim } = computeMarkup(stateWith(md, caret));
      for (const d of dim) {
        expect(hidden.some((h) => h.from < d.to && h.to > d.from), `caret ${caret} dim ${d.from}-${d.to}`).toBe(false);
      }
    }
  });
});
