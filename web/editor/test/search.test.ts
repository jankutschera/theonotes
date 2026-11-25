// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Transaction } from "@codemirror/state";
import { countLabel, currentFindMode, findPanelOpen, findStep, openFind } from "../src/editor/features/search";
import { currentMatch, searchHighlight, searchHighlightTransaction } from "../src/editor/features/search-highlight";

describe("find panel count", () => {
  const matches = [
    { from: 0, to: 3 },
    { from: 8, to: 11 },
  ];
  test("labels", () => {
    expect(countLabel(matches, { from: 8, to: 11 }, false)).toBe("2 of 2");
    expect(countLabel(matches, { from: 5, to: 5 }, false)).toBe("2 matches");
    expect(countLabel(matches.slice(0, 1), { from: 5, to: 5 }, false)).toBe("1 match");
    expect(countLabel([], { from: 0, to: 0 }, false)).toBe("No matches");
    expect(countLabel([], { from: 0, to: 0 }, true)).toBe("");
    const many = Array.from({ length: 1001 }, (_, i) => ({ from: i * 2, to: i * 2 + 1 }));
    expect(countLabel(many, { from: 2, to: 3 }, false)).toBe("2 of 1000+");
  });
});

describe("Find commands without a view (state only)", () => {
  function target(doc: string) {
    let state = EditorState.create({ doc, selection: EditorSelection.cursor(0), extensions: [searchHighlight] });
    return {
      get state() {
        return state;
      },
      dispatch: (tr: Transaction) => {
        state = tr.state;
      },
    };
  }

  test("closed panel: Find Next / Previous step the search highlight marker and keep the selection (R32)", () => {
    const t = target("a x b x");
    t.dispatch(t.state.update(searchHighlightTransaction(t.state, ["x"])));
    expect(currentMatch(t.state)).toEqual({ from: 2, to: 3 });
    expect(findStep(1)(t)).toBe(true);
    expect(currentMatch(t.state)).toEqual({ from: 6, to: 7 });
    expect(findStep(-1)(t)).toBe(true);
    expect(currentMatch(t.state)).toEqual({ from: 2, to: 3 });
    expect(t.state.selection.main.head).toBe(0);
    expect(findPanelOpen(t.state)).toBe(false);
  });

  test("Find… needs the view (the panel is DOM)", () => {
    const t = target("a");
    expect(openFind("find")(t)).toBe(false);
    expect(currentFindMode(t.state)).toBe("find");
  });
});
