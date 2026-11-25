// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorState, Text, type Transaction } from "@codemirror/state";
import {
  currentMatch,
  foldCharacter,
  isSearchHighlightActive,
  searchHighlight,
  SearchHighlightState,
  searchHighlightMatches,
  searchHighlightTransaction,
  stepSearchHighlight,
} from "../src/editor/features/search-highlight";
import { editorCommands } from "../src/editor/features/commands";
import { BridgeClient, type EditorHandle } from "../src/bridge/client";
import { MockHost } from "../src/bridge/hosts";

type FoldCase = { name: string; text: string; terms: string[]; matches: string[] };
const foldCases = Object.values(
  import.meta.glob("../../../Fixtures/search/fold.json", { eager: true, import: "default" }),
)[0] as FoldCase[];

const stateOf = (doc: string) => EditorState.create({ doc, extensions: [searchHighlight] });

function matched(doc: string, terms: string[]): string[] {
  return searchHighlightMatches(Text.of(doc.split("\n")), terms).map((r) => doc.slice(r.from, r.to));
}

describe("matching agrees with TheoNotesCore SearchOffsets (Fixtures/search/fold.json)", () => {
  test("there are shared cases", () => {
    expect(foldCases.length).toBeGreaterThanOrEqual(20);
  });

  test.each(foldCases.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    expect(matched(c.text, c.terms)).toEqual(c.matches);
  });

  test("folds like Foundation (caseInsensitive + diacriticInsensitive)", () => {
    const cases: [string, string][] = [
      ["й", "и"],
      ["Ё", "е"],
      ["ά", "α"],
      ["ᾳ", "α"],
      ["ß", "ss"],
      ["ẞ", "ss"],
      ["ﬁ", "fi"],
      ["İ", "i"],
      ["ı", "ı"],
      ["ς", "σ"],
      ["ǅ", "ǆ"],
      ["ǰ", "j"],
      ["ŉ", "ʼn"],
      ["ø", "ø"],
      ["ł", "ł"],
      ["Ꭰ", "ꭰ"],
      ["Ａ", "ａ"],
      ["が", "が"],
      ["が", "が"],
      ["한", "한"],
      ["कि", "कि"],
      ["مَ", "مَ"],
      ["❤️", "❤️"],
      ["́", "́"],
      ["a⃗", "a"],
    ];
    for (const [input, folded] of cases) expect(foldCharacter(input), input).toBe(folded);
  });
});

describe("tag terms (editor only)", () => {
  test("#work does not light up inside #workshop, but in nested and closed tags", () => {
    expect(matched("#workshop #work #work/projects #work# a#work", ["#work"])).toEqual(["#work", "#work", "#work"]);
  });
});

describe("searchHighlightTransaction", () => {
  test("marks the first word-start match as current and never touches the selection", () => {
    let state = stateOf("start art\nmore art");
    const tr = state.update(searchHighlightTransaction(state, ["art"]));
    state = tr.state;
    expect(tr.selection).toBeUndefined();
    expect(state.selection.main.head).toBe(0);
    expect(currentMatch(state)).toEqual({ from: 6, to: 9 });
    expect(isSearchHighlightActive(state)).toBe(true);
    expect(tr.docChanged).toBe(false);
  });

  test("falls back to a match inside a word; no match leaves no current match", () => {
    let state = stateOf("restart");
    state = state.update(searchHighlightTransaction(state, ["art"])).state;
    expect(currentMatch(state)).toEqual({ from: 4, to: 7 });
    state = state.update(searchHighlightTransaction(state, ["zzz"])).state;
    expect(currentMatch(state)).toBeNull();
    expect(isSearchHighlightActive(state)).toBe(true);
  });

  test("empty terms clear", () => {
    let state = stateOf("hello");
    state = state.update(searchHighlightTransaction(state, ["hello"])).state;
    state = state.update(searchHighlightTransaction(state, [])).state;
    expect(isSearchHighlightActive(state)).toBe(false);
    expect(currentMatch(state)).toBeNull();
  });

  test("the current match follows edits before it", () => {
    let state = stateOf("x two");
    state = state.update(searchHighlightTransaction(state, ["two"])).state;
    state = state.update({ changes: { from: 0, insert: "abc " } }).state;
    expect(currentMatch(state)).toEqual({ from: 6, to: 9 });
  });
});

describe("highlight decorations", () => {
  test("are only mapped while composing and rebuilt once it ends (minor M2)", () => {
    const view = (state: EditorState, composing: boolean) => ({ state, composing, visibleRanges: [{ from: 0, to: state.doc.length }] });
    const updateOf = (tr: Transaction, composing: boolean) => ({
      view: view(tr.state, composing),
      state: tr.state,
      startState: tr.startState,
      changes: tr.changes,
      docChanged: tr.docChanged,
      viewportChanged: false,
    });
    const marks = (plugin: SearchHighlightState) => {
      const found: string[] = [];
      plugin.decorations.between(0, 1e9, (from, to) => void found.push(`${from}-${to}`));
      return found;
    };
    let start = stateOf("two and tw");
    start = start.update(searchHighlightTransaction(start, ["two"])).state;
    const plugin = new SearchHighlightState(view(start, false));
    expect(marks(plugin)).toEqual(["0-3"]);

    // The IME composes "o" after "tw": a new match next to the composition is not drawn yet, the
    // existing mark is only mapped.
    const tr = start.update({ changes: [{ from: 0, insert: "か" }, { from: 10, insert: "o" }], userEvent: "input.type.compose" });
    plugin.update(updateOf(tr, true));
    expect(plugin.stale).toBe(true);
    expect(marks(plugin)).toEqual(["1-4"]);

    // Composition over: rebuilt.
    plugin.update(updateOf(tr.state.update({}), false));
    expect(plugin.stale).toBe(false);
    expect(marks(plugin)).toEqual(["1-4", "9-12"]);
  });
});

describe("findNext / findPrevious", () => {
  const run = (state: EditorState, name: "findNext" | "findPrevious") => {
    let next = state;
    const handled = editorCommands[name]({ state, dispatch: (tr: Transaction) => (next = tr.state) });
    return { handled, state: next };
  };

  test("step from the current match, wrap around, and leave the selection alone", () => {
    let state = stateOf("one two\nthree two\nfour two");
    state = state.update(searchHighlightTransaction(state, ["two"])).state;
    expect(currentMatch(state)).toEqual({ from: 4, to: 7 });
    for (const expected of [14, 23, 4]) {
      const r = run(state, "findNext");
      expect(r.handled).toBe(true);
      state = r.state;
      expect(currentMatch(state)?.from).toBe(expected);
    }
    state = run(state, "findPrevious").state;
    expect(currentMatch(state)?.from).toBe(23);
    expect(state.selection.main.head).toBe(0);
  });

  test("without a highlight they do nothing", () => {
    expect(run(stateOf("two two"), "findNext").handled).toBe(false);
    expect(stepSearchHighlight(stateOf("two"), 1)).toBeNull();
  });
});

describe("bridge searchHighlight message", () => {
  function setup(text: string) {
    const host = new MockHost({ text });
    let state = stateOf("");
    const editor: EditorHandle = {
      get state() {
        return state;
      },
      dispatch: (spec) => {
        const tr = state.update(spec);
        state = tr.state;
        client.onTransaction(tr);
      },
      load: (doc) => {
        state = EditorState.create({ doc: doc.text, extensions: [searchHighlight] });
      },
      setReadOnly: () => {},
      focus: () => {},
      command: () => false,
      scrollToHeading: () => false,
      applySettings: () => {},
      commitComposition: async () => true,
      freeze: () => {},
      unfreeze: () => {},
    };
    const client = new BridgeClient(host, () => editor);
    host.onMessage((msg) => client.handleHostMessage(msg));
    host.loadNote();
    return { host, state: () => state };
  }

  test("applies to the loaded note without moving the caret or posting anything", () => {
    const { host, state } = setup("alpha beta\ngamma beta");
    const sent = host.sent.length;
    host.deliver({ type: "searchHighlight", noteId: "mock-note", query: "beta", terms: ["beta"] });
    expect(currentMatch(state())).toEqual({ from: 6, to: 10 });
    expect(state().selection.main.head).toBe(0);
    expect(host.sent.length).toBe(sent);
  });

  test("is dropped for another note", () => {
    const { host, state } = setup("alpha beta");
    host.deliver({ type: "searchHighlight", noteId: "other", query: "beta", terms: ["beta"] });
    expect(isSearchHighlightActive(state())).toBe(false);
  });
});
