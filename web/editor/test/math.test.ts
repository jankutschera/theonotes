// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test, vi } from "vitest";
import { EditorSelection, EditorState, type Extension, type Transaction } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undoDepth } from "@codemirror/commands";

// MathJax never loads in unit tests: the renderer is stubbed.
vi.mock("../src/editor/features/math-render", async (importOriginal) => ({
  // MAX_TEX stays real; MathJax itself is only reached through renderMath's dynamic import().
  ...(await importOriginal<typeof import("../src/editor/features/math-render")>()),
  renderMath: vi.fn(async () => ({ error: "stub" })),
}));

import { bearMarkdown } from "../src/editor/dialect";
import { computeHiddenRanges, hideMarkdown } from "../src/editor/features/hiding";
import { enterFormulaCommand, formulaEntry, inlineFormulas, mathBlockRenderer, mathLayout } from "../src/editor/features/math";
import { MAX_TEX } from "../src/editor/features/math-render";
import { runCommand } from "../src/editor/features/commands";

function stateOf(doc: string, caret = doc.length, extensions: Extension[] = []): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(caret),
    extensions: [markdown({ base: bearMarkdown }), history(), ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

const shown = (state: EditorState) => {
  const layout = mathLayout(state);
  return { rendered: layout.rendered.map((f) => f.tex), previews: layout.previews.map((f) => f.tex) };
};

function insertMath(state: EditorState, args?: Record<string, unknown>) {
  const trs: Transaction[] = [];
  const handled = runCommand({ state, dispatch: (tr) => trs.push(tr) }, "insertMath", args);
  return { handled, state: trs.at(-1)?.state ?? state };
}

describe("inline math", () => {
  test("rendered when the caret is outside, source + preview inside", () => {
    const doc = "a $x^2$ and $$\\frac{1}{2}$$ b";
    const outside = stateOf(doc, 0);
    expect(shown(outside)).toEqual({ rendered: ["x^2", "\\frac{1}{2}"], previews: [] });
    expect(inlineFormulas(outside).map((f) => f.display)).toEqual([false, true]);
    // Their whole source is hidden markup.
    expect(computeHiddenRanges(outside).map((r) => doc.slice(r.from, r.to))).toEqual(["$x^2$", "$$\\frac{1}{2}$$"]);
    // Caret inside the first: its source with dimmed `$` and a preview; the second still renders.
    const inside = stateOf(doc, doc.indexOf("^"));
    expect(shown(inside)).toEqual({ rendered: ["\\frac{1}{2}"], previews: ["x^2"] });
    expect(computeHiddenRanges(inside).map((r) => doc.slice(r.from, r.to))).toEqual(["$$\\frac{1}{2}$$"]);
    // On the outer edge it still renders (as for hidden markup).
    expect(shown(stateOf(doc, doc.indexOf("$x"))).rendered).toContain("x^2");
    // An empty formula keeps its (dimmed) marks visible.
    expect(computeHiddenRanges(stateOf("a $ $ b", 0))).toEqual([]);
    // Empty formulas, code and Hide Markdown off: nothing renders.
    expect(shown(stateOf("a $ $ b `$x$`", 0))).toEqual({ rendered: [], previews: [] });
    expect(shown(stateOf(doc, 0, [hideMarkdown.of(false)]))).toEqual({ rendered: [], previews: [] });
  });

  test("arrow keys enter a rendered formula", () => {
    const doc = "a $x^2$ b";
    const before = stateOf(doc, 2);
    expect(formulaEntry(before, true)).toBe(3);
    expect(formulaEntry(before, false)).toBeNull();
    const after = stateOf(doc, 7);
    expect(formulaEntry(after, false)).toBe(6);
    expect(formulaEntry(after, true)).toBeNull();
    // A range selection or a caret elsewhere: the default keys.
    expect(formulaEntry(stateOf(doc, 0), true)).toBeNull();
  });

  test("nothing changes while composing", () => {
    const state = stateOf("a $x^2$ b", 2);
    let dispatched = 0;
    const view = { composing: true, state, dispatch: () => void dispatched++ };
    expect(enterFormulaCommand(true)(view as never)).toBe(false);
    expect(dispatched).toBe(0);
    view.composing = false;
    expect(enterFormulaCommand(true)(view as never)).toBe(true);
    expect(dispatched).toBe(1);
  });
});

describe("huge math blocks (M6-R82)", () => {
  test("a $$ block whose TeX is over MAX_TEX always shows its source (it can never render)", () => {
    const block = (tex: string) => {
      const key = `$$\n${tex}\n$$`;
      return { kind: "mathBlock" as const, from: 0, to: key.length, key };
    };
    expect(mathBlockRenderer.sourceOnly!(block("x".repeat(MAX_TEX)))).toBe(false);
    expect(mathBlockRenderer.sourceOnly!(block("x".repeat(MAX_TEX + 1)))).toBe(true);
    expect(mathBlockRenderer.sourceOnly!(block(Array.from({ length: 6000 }, (_, i) => `x_{${i}}`).join("\n")))).toBe(true);
    expect(mathBlockRenderer.sourceOnly!(block("x^2"))).toBe(false);
  });
});

describe("insertMath", () => {
  test("insertMath inline and display", () => {
    const empty = insertMath(stateOf("a  b", 2));
    expect(empty.state.doc.toString()).toBe("a $$ b");
    expect(empty.state.selection.main.head).toBe(3);
    const sel = stateOf("a x+y b").update({ selection: EditorSelection.single(2, 5) }).state;
    const wrapped = insertMath(sel);
    expect(wrapped.state.doc.toString()).toBe("a $x+y$ b");
    expect(wrapped.state.selection.main.head).toBe(6);
    expect(undoDepth(wrapped.state)).toBe(1);

    const block = insertMath(stateOf("intro", 5), { display: true });
    expect(block.state.doc.toString()).toBe("intro\n$$\n\n$$");
    expect(block.state.selection.main.head).toBe("intro\n$$\n".length);
    const around = insertMath(stateOf("x^2").update({ selection: EditorSelection.single(0, 3) }).state, { display: true });
    expect(around.state.doc.toString()).toBe("$$\nx^2\n$$");
    // Not in code or math, not around them, one selection only.
    expect(insertMath(stateOf("```\nco", 6)).handled).toBe(false);
    expect(insertMath(stateOf("a `code` b", 4)).handled).toBe(false);
    expect(insertMath(stateOf("a $x$ b", 3)).handled).toBe(false);
    expect(insertMath(stateOf("a `code` b").update({ selection: EditorSelection.single(0, 6) }).state).handled).toBe(false);
    expect(insertMath(stateOf("a\n```\nc\n```\nb").update({ selection: EditorSelection.single(0, 12) }).state, { display: true }).handled).toBe(false);
    // A caret right after inline code is outside it.
    expect(insertMath(stateOf("a `code` b", 8)).handled).toBe(true);
    const multi = stateOf("ab", 0, [EditorState.allowMultipleSelections.of(true)]).update({
      selection: EditorSelection.create([EditorSelection.cursor(0), EditorSelection.cursor(2)]),
    }).state;
    expect(insertMath(multi).handled).toBe(false);
  });

  test("read-only renders and refuses insertMath", () => {
    const ro = stateOf("a $x$ b", 0, [EditorState.readOnly.of(true)]);
    expect(shown(ro).rendered).toEqual(["x"]);
    expect(insertMath(ro).handled).toBe(false);
  });
});
