// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type RangeSet, type RangeValue } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import { computeHiddenRanges } from "../src/editor/features/hiding";
import { BulletWidget, HeadingBadge, headingMenuDetail, OrderedMarkerWidget, TYPOGRAPHY_DEFAULTS, typographyDecorations } from "../src/editor/features/typography";
import typographyDefaults from "../../../Fixtures/themes/typography-defaults.json";

describe("typography defaults", () => {
  test("match Fixtures/themes/typography-defaults.json (the numbers the host shows as defaults)", () => {
    expect({ ...TYPOGRAPHY_DEFAULTS }).toEqual(typographyDefaults);
  });
});

function stateWith(doc: string, anchor: number, head = anchor): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(anchor, head),
    extensions: markdown({ base: bearMarkdown }),
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

type Item = { from: number; to: number; cls: string | undefined; widget: unknown; editable: string | undefined };

function items(set: DecorationSet): Item[] {
  const out: Item[] = [];
  set.between(0, 1e9, (from, to, d) => {
    const spec = d.spec as { class?: string; attributes?: Record<string, string>; widget?: unknown };
    out.push({
      from,
      to,
      cls: spec.class ?? spec.attributes?.class,
      widget: spec.widget,
      editable: spec.attributes?.contenteditable,
    });
  });
  return out;
}

function values<T extends RangeValue>(set: RangeSet<T>): { from: number; value: T }[] {
  const out: { from: number; value: T }[] = [];
  set.between(0, 1e9, (from, _to, value) => {
    out.push({ from, value });
  });
  return out;
}

/** Line decorations: line number → class. */
function lineClasses(state: EditorState, set: DecorationSet): Record<number, string> {
  const out: Record<number, string> = {};
  for (const it of items(set)) {
    if (it.from === it.to && !it.widget && it.cls) out[state.doc.lineAt(it.from).number] = it.cls;
  }
  return out;
}

/** Line decorations: line number → style attribute. */
function lineStyles(state: EditorState, set: DecorationSet): Record<number, string> {
  const out: Record<number, string> = {};
  set.between(0, 1e9, (from, to, d) => {
    const style = (d.spec as { attributes?: Record<string, string> }).attributes?.style;
    if (from === to && style) out[state.doc.lineAt(from).number] = style;
  });
  return out;
}

const bullets = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.widget instanceof BulletWidget)
    .map((it) => ({ at: it.from, level: (it.widget as BulletWidget).level }));
const hidden = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.cls === "cm-bc-hidden")
    .map((it) => ({ from: it.from, to: it.to, editable: it.editable }));
const marks = (set: DecorationSet, cls: string) =>
  items(set)
    .filter((it) => it.from < it.to && it.cls?.split(" ").includes(cls))
    .map((it) => [it.from, it.to]);

describe("headings", () => {
  test("ATX headings get cm-h1…cm-h6 line classes and a gutter badge with their level", () => {
    const doc = "# One\ntext\n## Two\n###### Six\n####### seven";
    const state = stateWith(doc, doc.indexOf("text"));
    const sets = typographyDecorations(state);
    expect(lineClasses(state, sets.outer)).toEqual({
      1: "cm-bc-heading cm-h1",
      3: "cm-bc-heading cm-h2",
      4: "cm-bc-heading cm-h6",
    });
    expect(values(sets.headings).map((h) => [h.from, (h.value as HeadingBadge).level])).toEqual([
      [0, 1],
      [doc.indexOf("## Two"), 2],
      [doc.indexOf("###### Six"), 6],
    ]);
  });
});

describe("the heading menu", () => {
  test("a badge click reports the heading and the badge's own rect", () => {
    // DOMRect fields: the menu opens under the badge, not at the line start.
    const box = { left: 12.5, top: 40, width: 24, height: 18, right: 36.5, bottom: 58, x: 12.5, y: 40 };
    expect(headingMenuDetail(3, 2, box)).toEqual({ line: 3, level: 2, rect: { x: 12.5, y: 40, width: 24, height: 18 } });
  });
});

describe("bullets", () => {
  test("• ◦ ▪ by nesting level; marker and indentation stay in the DOM, collapsed and not editable", () => {
    const doc = "- a\n  - b\n    - c\n      - d\n\nend";
    const sets = typographyDecorations(stateWith(doc, doc.length));
    const at = [0, doc.indexOf("- b"), doc.indexOf("- c"), doc.indexOf("- d")];
    expect(bullets(sets.inner)).toEqual(at.map((pos, i) => ({ at: pos, level: i + 1 })));
    expect([1, 2, 3, 4].map((level) => new BulletWidget(level).glyph)).toEqual(["•", "◦", "▪", "•"]);
    // The indentation (shown as padding) and `- ` (shown as the bullet) are collapsed.
    const expected = at.flatMap((pos) => {
      const lineFrom = doc.lastIndexOf("\n", pos - 1) + 1;
      const indent = lineFrom < pos ? [{ from: lineFrom, to: pos, editable: "false" }] : [];
      return [...indent, { from: pos, to: pos + 2, editable: "false" }];
    });
    expect(hidden(sets.inner)).toEqual(expected);
  });

  test("* and + markers become bullets too", () => {
    const doc = "* a\n\n+ b\n\nend";
    expect(bullets(typographyDecorations(stateWith(doc, doc.length)).inner).map((b) => b.at)).toEqual([0, 5]);
  });

  test("no bullet widget (raw marker in a box of the bullet's width) while the caret is on the marker", () => {
    const doc = "- a\n- b";
    for (const caret of [0, 1]) {
      const sets = typographyDecorations(stateWith(doc, caret));
      expect(bullets(sets.inner), `caret ${caret}`).toEqual([{ at: 4, level: 1 }]);
      expect(hidden(sets.inner), `caret ${caret}`).toEqual([{ from: 4, to: 6, editable: "false" }]);
      expect(marks(sets.outer, "cm-bc-li-raw"), `caret ${caret}`).toEqual([[0, 2]]);
    }
    // Typing the item text (caret after "- ") keeps the bullet.
    expect(bullets(typographyDecorations(stateWith(doc, 2)).inner)).toHaveLength(2);
    // A range selection over the marker reveals it.
    expect(bullets(typographyDecorations(stateWith(doc, 3, 6)).inner)).toEqual([{ at: 0, level: 1 }]);
  });

  test("ordered markers: a widget with the number unless the caret is on it; task items keep their marker (Task 3)", () => {
    const doc = "1. a\n10. b\n\n- [ ] todo\n\nend";
    const sets = typographyDecorations(stateWith(doc, doc.length));
    expect(bullets(sets.inner)).toEqual([]);
    const ordered = items(sets.inner).filter((it) => it.widget instanceof OrderedMarkerWidget);
    expect(ordered.map((it) => [it.from, (it.widget as OrderedMarkerWidget).marker])).toEqual([
      [0, "1."],
      [5, "10."],
    ]);
    expect(hidden(sets.inner)).toEqual([
      { from: 0, to: 3, editable: "false" },
      { from: 5, to: 9, editable: "false" },
    ]);
    const onMarker = typographyDecorations(stateWith(doc, 6));
    expect(marks(onMarker.outer, "cm-bc-ordered-marker")).toEqual([[5, 9]]);
    expect(marks(onMarker.outer, "cm-bc-li-raw")).toEqual([[5, 9]]);
  });

  test("list lines: level and marker width as line style, hanging indent class; continuation lines align with the text", () => {
    const doc = "- a\n  - b\n    more\n1. c\n- [ ] d\ne\n\nend";
    const state = stateWith(doc, doc.length);
    const sets = typographyDecorations(state);
    expect(lineClasses(state, sets.outer)).toEqual({ 1: "cm-bc-li", 2: "cm-bc-li", 3: "cm-bc-li-cont", 4: "cm-bc-li", 5: "cm-bc-li" });
    expect(lineStyles(state, sets.outer)).toEqual({
      1: "--bc-li-level:0;--bc-li-mark:var(--bc-li-bullet)",
      2: "--bc-li-level:1;--bc-li-mark:var(--bc-li-bullet)",
      3: "--bc-li-level:1;--bc-li-mark:var(--bc-li-bullet)",
      4: "--bc-li-level:0;--bc-li-mark:calc(1 * var(--bc-li-digit) + var(--bc-li-ordered))",
      5: "--bc-li-level:0;--bc-li-mark:var(--bc-li-todo)",
    });
    // The continuation line's indentation is collapsed too; the lazy line `e` is a paragraph.
    const more = doc.indexOf("    more");
    expect(hidden(sets.inner)).toContainEqual({ from: more, to: more + 4, editable: "false" });
  });

  test("dialect rules: a bare marker and a date are text, code is code", () => {
    for (const doc of ["1.\n\nend", "-\n\nend", "12. March\n\nend", "```\n- a\n```\nend"]) {
      const state = stateWith(doc, doc.length);
      const sets = typographyDecorations(state);
      expect(items(sets.inner).filter((it) => it.widget), doc).toEqual([]);
      expect(Object.values(lineClasses(state, sets.outer)).filter((c) => c.includes("cm-bc-li")), doc).toEqual([]);
    }
  });
});

describe("blocks", () => {
  test("quote lines get the bar; `> ` is hidden unless the caret is on that line", () => {
    const doc = "> a\n> b\n\nx";
    const off = typographyDecorations(stateWith(doc, doc.length));
    expect(lineClasses(stateWith(doc, doc.length), off.outer)).toEqual({ 1: "cm-bc-quote", 2: "cm-bc-quote" });
    expect(hidden(off.inner)).toEqual([
      { from: 0, to: 2, editable: "false" },
      { from: 4, to: 6, editable: "false" },
    ]);
    const on = typographyDecorations(stateWith(doc, 1));
    expect(hidden(on.inner)).toEqual([{ from: 4, to: 6, editable: "false" }]);
  });

  test("--- is a hairline rule unless the caret is on its line (then the raw text shows)", () => {
    const doc = "a\n\n---\n\nb";
    const off = stateWith(doc, doc.length);
    const offSets = typographyDecorations(off);
    expect(lineClasses(off, offSets.outer)).toEqual({ 3: "cm-bc-hr" });
    expect(hidden(offSets.inner)).toEqual([{ from: 3, to: 6, editable: "false" }]);
    const on = stateWith(doc, 4);
    const onSets = typographyDecorations(on);
    expect(lineClasses(on, onSets.outer)).toEqual({});
    expect(hidden(onSets.inner)).toEqual([]);
  });

  test("code: inline code mark and fenced block lines (first/last rounded)", () => {
    const doc = "a `c` b\n```js\nx\n```\nz";
    const state = stateWith(doc, doc.length);
    const sets = typographyDecorations(state);
    expect(marks(sets.outer, "cm-bc-code")).toEqual([[2, 5]]);
    expect(lineClasses(state, sets.outer)).toEqual({
      2: "cm-bc-codeblock cm-bc-codeblock-first",
      3: "cm-bc-codeblock",
      4: "cm-bc-codeblock cm-bc-codeblock-last",
    });
  });
});

describe("inline styles", () => {
  test("tag pills, links, wiki links, bare URLs, highlight colors and underline", () => {
    const doc = "#work and [l](https://u.v) and [[Note]] and https://e.com x\n==hi== ==🟢g== ~u~\nend";
    const state = stateWith(doc, doc.length);
    const { outer } = typographyDecorations(state);
    const span = (s: string) => [doc.indexOf(s), doc.indexOf(s) + s.length];
    expect(marks(outer, "cm-bc-tag")).toEqual([span("#work")]);
    // Link text only: the hidden brackets and URL are not colored when the caret reveals them.
    const l = doc.indexOf("[l]") + 1;
    expect(marks(outer, "cm-bc-link")).toEqual([[l, l + 1], span("https://e.com")]);
    expect(marks(outer, "cm-bc-wikilink")).toEqual([span("[[Note]]")]);
    expect(marks(outer, "cm-bc-highlight")).toEqual([span("==hi=="), span("==🟢g==")]);
    expect(marks(outer, "cm-bc-highlight-green")).toEqual([span("==🟢g==")]);
    expect(marks(outer, "cm-bc-underline")).toEqual([span("~u~")]);
  });

  test("bold, italic and strike as classes", () => {
    const doc = "**b** _i_ ~~s~~ # x";
    const { outer } = typographyDecorations(stateWith(doc, doc.length));
    expect(marks(outer, "cm-bc-strong")).toEqual([[0, 5]]);
    expect(marks(outer, "cm-bc-em")).toEqual([[6, 9]]);
    expect(marks(outer, "cm-bc-strike")).toEqual([[10, 15]]);
  });

  test("outer marks never cut a hidden range (CodeMirror would split the collapsed span)", () => {
    const doc = [
      "# Heading **bold** #tag",
      "some **bold** _it_ ~~s~~ `code` [link](https://e.com/x) ==🟢hi== ~u~ [[Note|alias]] [[Plain]] \\*e\\*",
      "> quote with [l](https://u.v)",
      "- item **b**",
      "1. one",
      "---",
      "end",
    ].join("\n");
    const state = stateWith(doc, doc.length);
    const sets = typographyDecorations(state);
    const hiddenRanges = [...computeHiddenRanges(state), ...hidden(sets.inner)];
    expect(hiddenRanges.length).toBeGreaterThan(15);
    for (const m of items(sets.outer).filter((it) => it.from < it.to)) {
      for (const h of hiddenRanges) {
        const overlaps = m.from < h.to && h.from < m.to;
        const contains = m.from <= h.from && h.to <= m.to;
        expect(!overlaps || contains, `${m.cls} ${m.from}-${m.to} vs hidden ${h.from}-${h.to}`).toBe(true);
      }
    }
  });

  test("only the given ranges are decorated (visible ranges)", () => {
    const doc = Array.from({ length: 20 }, (_, i) => `## H${i}`).join("\n");
    const state = stateWith(doc, 0);
    const line = state.doc.line(10);
    const sets = typographyDecorations(state, [{ from: line.from, to: line.to }]);
    expect(lineClasses(state, sets.outer)).toEqual({ 10: "cm-bc-heading cm-h2" });
    expect(values(sets.headings).map((h) => h.from)).toEqual([line.from]);
  });
});
