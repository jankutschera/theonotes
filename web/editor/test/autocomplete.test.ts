// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test, vi } from "vitest";
import { EditorSelection, EditorState, type Extension, Transaction, type TransactionSpec } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { history, undo } from "@codemirror/commands";
import { CompletionContext, type CompletionResult } from "@codemirror/autocomplete";
import type { EditorView } from "@codemirror/view";
import { bearMarkdown } from "../src/editor/dialect";
import {
  type CompletionBridge,
  type CompletionQuery,
  bearCompletionSource,
  completionBridge,
  completionEdit,
  completionQueryAt,
  fenceLanguageSource,
  guardedCompletionKeymap,
  tagIconPositions,
  tagconURL,
  TagConWidget,
  TagIconsState,
} from "../src/editor/features/autocomplete";
import { BridgeClient, type EditorHandle, type LoadedDocument } from "../src/bridge/client";
import type { Host } from "../src/bridge/hosts";
import type { ChangesReply, CompletionItem, CompletionKind, EditorToHost, HostToEditor } from "../src/bridge/protocol";
import { loadedState } from "../src/editor/setup";

/** `‸` marks the caret. */
function stateOf(marked: string, extensions: Extension[] = [], readOnly = false): EditorState {
  const pos = marked.indexOf("‸");
  const doc = pos < 0 ? marked : marked.slice(0, pos) + marked.slice(pos + 1);
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(pos < 0 ? doc.length : pos),
    extensions: [markdown({ base: bearMarkdown }), history(), EditorState.readOnly.of(readOnly), ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function show(state: EditorState): string {
  const head = state.selection.main.head;
  const doc = state.doc.toString();
  return doc.slice(0, head) + "‸" + doc.slice(head);
}

const queryAt = (marked: string, readOnly = false) => {
  const state = stateOf(marked, [], readOnly);
  return completionQueryOf(state);
};

const completionQueryOf = (state: EditorState) => completionQueryAt(state, state.selection.main.head);

describe("where completion starts (completionQueryAt)", () => {
  test("# after a tag opener completes tags; the range covers the whole tag word", () => {
    expect(queryAt("#wo‸")).toEqual({ kind: "tag", query: "wo", from: 0, to: 3 });
    expect(queryAt("see #wo‸ now")).toEqual({ kind: "tag", query: "wo", from: 4, to: 7 });
    expect(queryAt("(#wo‸")).toEqual({ kind: "tag", query: "wo", from: 1, to: 4 });
    expect(queryAt("#wo‸rk more")).toEqual({ kind: "tag", query: "wo", from: 0, to: 5 });
    expect(queryAt("#work/pro‸")).toEqual({ kind: "tag", query: "work/pro", from: 0, to: 9 });
    expect(queryAt("- [ ] task #ur‸")).toEqual({ kind: "tag", query: "ur", from: 11, to: 14 });
  });

  test("no tag completion without a valid opener or a typed character", () => {
    for (const marked of ["#‸", "a#wo‸", "# Heading‸", "## wo‸", "#wo #‸", "x.#wo‸", "#️⃣‸", "#wo.‸", "#wo ‸"]) {
      expect(queryAt(marked), marked).toBeNull();
    }
  });

  test("[[ completes note titles; a / after the title its headings; [[/ the note's own", () => {
    expect(queryAt("[[‸")).toEqual({ kind: "note", query: "", from: 2, to: 2 });
    expect(queryAt("see [[Pro‸")).toEqual({ kind: "note", query: "Pro", from: 6, to: 9 });
    expect(queryAt("[[Pro‸]]")).toEqual({ kind: "note", query: "Pro", from: 2, to: 5 });
    expect(queryAt("[[Pro‸ject]] x")).toEqual({ kind: "note", query: "Pro", from: 2, to: 9 });
    expect(queryAt("[[2024\\/25 B‸")).toEqual({ kind: "note", query: "2024/25 B", from: 2, to: 12 });
    expect(queryAt("[[Project  Plan/Ne‸")).toEqual({ kind: "heading", query: "Ne", noteTitle: "Project Plan", from: 16, to: 18 });
    expect(queryAt("[[Plan/Ne‸xt]]")).toEqual({ kind: "heading", query: "Ne", noteTitle: "Plan", from: 7, to: 11 });
    expect(queryAt("[[/‸")).toEqual({ kind: "heading", query: "", noteTitle: "", from: 3, to: 3 });
    expect(queryAt("#tag [[#wo‸")).toEqual({ kind: "note", query: "#wo", from: 7, to: 10 });
  });

  test("no note completion in the alias part, after a closed link or across brackets", () => {
    for (const marked of ["[[Title|al‸", "[[Title\\|al‸", "[[a]] b‸", "[[a [b‸", "[a] b‸", "[‸"]) {
      expect(queryAt(marked), marked).toBeNull();
    }
  });

  test(": and two letters complete emoji (English or German names)", () => {
    expect(queryAt(":ca‸")).toEqual({ kind: "emoji", query: "ca", from: 0, to: 3 });
    expect(queryAt("nice :katze‸ yes")).toEqual({ kind: "emoji", query: "katze", from: 5, to: 11 });
    expect(queryAt("(:thumbs_up‸")).toEqual({ kind: "emoji", query: "thumbs_up", from: 1, to: 11 });
    for (const marked of [":c‸", "http:ca‸", "12:30‸", "a:bc‸", ":12‸", ":ca:‸", "::ca‸"]) {
      expect(queryAt(marked), marked).toBeNull();
    }
  });

  test("never inside code, math, comments or front matter", () => {
    for (const marked of [
      "`#wo‸`",
      "`[[Pro‸`",
      "`:cat‸`",
      "```\n#wo‸\n```",
      "```\n#wo‸",
      "$$\n#wo‸\n$$",
      "$x #wo‸$",
      "<!-- #wo‸ -->",
      "<!--\n#wo‸\n-->",
      "---\ntags: #wo‸\n---\nbody",
      "https://x.y/#wo‸",
      "<https://x.y/#wo‸>",
    ]) {
      expect(queryAt(marked), marked).toBeNull();
    }
  });

  test("nothing in a read-only note", () => {
    expect(queryAt("#wo‸", true)).toBeNull();
  });
});

// ---------------------------------------------------------------------------------------------

type Request = { kind: CompletionKind; query: string; noteTitle?: string };

function fakeBridge(items: CompletionItem[] | null, enabled = true) {
  const requests: Request[] = [];
  const bridge: CompletionBridge = {
    enabled: () => enabled,
    tagIcons: () => new Map(),
    request: (kind, query, noteTitle) => {
      requests.push({ kind, query, ...(noteTitle !== undefined && { noteTitle }) });
      return Promise.resolve(items);
    },
  };
  return { bridge, requests };
}

const work: CompletionItem = { label: "work", insert: "#work ", detail: "3", icon: "briefcase" };

async function runSource(marked: string, bridge: CompletionBridge, view?: Partial<EditorView>) {
  const state = stateOf(marked, [completionBridge.of(bridge)]);
  const context = new CompletionContext(state, state.selection.main.head, false, view as EditorView | undefined);
  return (await bearCompletionSource(context)) as CompletionResult | null;
}

describe("the completion source", () => {
  test("asks the bridge and lists its answer in the host's order (no re-filtering)", async () => {
    const { bridge, requests } = fakeBridge([work, { label: "wonder", insert: "#wonder " }]);
    const result = await runSource("see #wo‸", bridge);
    expect(requests).toEqual([{ kind: "tag", query: "wo" }]);
    expect(result).toMatchObject({ from: 4, to: 7, filter: false });
    expect(result!.options.map((o) => o.label)).toEqual(["work", "wonder"]);
    expect(result!.options[0]).toMatchObject({ detail: "3" });
  });

  test("sends the heading's note title", async () => {
    const { bridge, requests } = fakeBridge([]);
    expect(await runSource("[[Plan/Ne‸", bridge)).toBeNull();
    expect(requests).toEqual([{ kind: "heading", query: "Ne", noteTitle: "Plan" }]);
  });

  test("no popup while composing (IME), with the setting off, or for a stale answer", async () => {
    const composing = fakeBridge([work]);
    expect(await runSource("#wo‸", composing.bridge, { composing: true })).toBeNull();
    expect(composing.requests).toEqual([]);

    const off = fakeBridge([work], false);
    expect(await runSource("#wo‸", off.bridge)).toBeNull();
    expect(off.requests).toEqual([]);

    const stale = fakeBridge(null);
    expect(await runSource("#wo‸", stale.bridge)).toBeNull();
    expect(stale.requests).toHaveLength(1);
  });

  test("an empty answer opens nothing", async () => {
    expect(await runSource("#wo‸", fakeBridge([]).bridge)).toBeNull();
  });
});

describe("accepting a completion (completionEdit)", () => {
  function accept(marked: string, item: CompletionItem) {
    const state = stateOf(marked);
    const query = completionQueryOf(state) as CompletionQuery;
    expect(query).not.toBeNull();
    const tr = state.update(completionEdit(state, query, item));
    return { tr, shown: show(tr.state) };
  }

  const plan: CompletionItem = { label: "Project Plan", insert: "Project Plan" };
  const slash: CompletionItem = { label: "2024/25", insert: "2024\\/25" };
  const next: CompletionItem = { label: "Next Steps", insert: "Next Steps", detail: "H2" };

  test("tags: the item's text replaces #query; an existing space is reused", () => {
    expect(accept("#wo‸", work).shown).toBe("#work ‸");
    expect(accept("see #wo‸ now", work).shown).toBe("see #work ‸now");
    expect(accept("#wo‸rk", work).shown).toBe("#work ‸");
    expect(accept("x #my‸", { label: "my tag", insert: "#my tag# " }).shown).toBe("x #my tag# ‸");
  });

  test("notes: the title, closing ]] added when missing, caret after the link", () => {
    expect(accept("[[Pro‸", plan).shown).toBe("[[Project Plan]]‸");
    expect(accept("see [[Pro‸]] x", plan).shown).toBe("see [[Project Plan]]‸ x");
    expect(accept("[[Pro‸ject old]]", plan).shown).toBe("[[Project Plan]]‸");
    expect(accept("[[Pro‸|alias]]", plan).shown).toBe("[[Project Plan|alias]]‸");
    expect(accept("[[Pro‸/Head]]", plan).shown).toBe("[[Project Plan/Head]]‸");
    expect(accept("[[20‸", slash).shown).toBe("[[2024\\/25]]‸");
  });

  test("R28: only Enter and Tab accept; / and | stay typed text (/ then lists the typed title's headings)", () => {
    const accepting = guardedCompletionKeymap.filter((b) => b.key === "Enter" || b.key === "Tab");
    expect(accepting).toHaveLength(2);
    expect(guardedCompletionKeymap.map((b) => b.key)).not.toContain("/");
    expect(guardedCompletionKeymap.map((b) => b.key)).not.toContain("|");
    expect(queryAt("[[a/‸")).toEqual({ kind: "heading", query: "", noteTitle: "a", from: 4, to: 4 });
    expect(queryAt("[[a/b‸")).toEqual({ kind: "heading", query: "b", noteTitle: "a", from: 4, to: 5 });
    expect(queryAt("[[foo|‸")).toBeNull();
  });

  test("headings: the heading text, ]] added when missing", () => {
    expect(accept("[[Plan/Ne‸", next).shown).toBe("[[Plan/Next Steps]]‸");
    expect(accept("[[/Ne‸xt]] more", next).shown).toBe("[[/Next Steps]]‸ more");
  });

  test("emoji: the emoji replaces :query", () => {
    expect(accept("I :ca‸", { label: "🐈 cat", insert: "🐈" }).shown).toBe("I 🐈‸");
  });

  test("one undo step, marked as a completion", () => {
    const { tr } = accept("x #wo‸", work);
    expect(tr.isUserEvent("input.complete")).toBe(true);
    let state = tr.state;
    undo({ state, dispatch: (t: Transaction) => (state = t.state) });
    expect(show(state)).toBe("x #wo‸");
  });
});

describe("keys while the popup is open", () => {
  test("no key accepts or moves while composing", () => {
    const state = stateOf("#wo‸");
    for (const binding of guardedCompletionKeymap) {
      const view = { state, composing: true, dispatch: () => {} } as unknown as EditorView;
      expect(binding.run!(view), binding.key).toBe(false);
    }
    expect(guardedCompletionKeymap.map((b) => b.key)).toEqual(
      expect.arrayContaining(["Enter", "Tab", "ArrowDown", "ArrowUp", "Escape"]),
    );
  });
});

describe("TagCons next to tag pills", () => {
  const icons = new Map([
    ["work", "briefcase"],
    ["work/projects", "folder.fill"],
    ["my tag", "star.fill"],
  ]);

  test("an icon position at the start of each tag whose path has a TagCon", () => {
    const state = stateOf("#Work and #work/Projects and #my tag# and #none `#work` and https://x.y/#work");
    expect(tagIconPositions(state, icons)).toEqual([
      { pos: 0, symbol: "briefcase" },
      { pos: 10, symbol: "folder.fill" },
      { pos: 29, symbol: "star.fill" },
    ]);
  });

  test("only within the given ranges; no icons without a map", () => {
    const state = stateOf("#work\n#work");
    expect(tagIconPositions(state, icons, [{ from: 6, to: 11 }])).toEqual([{ pos: 6, symbol: "briefcase" }]);
    expect(tagIconPositions(state, new Map())).toEqual([]);
  });

  test("while composing the TagCon widgets are only mapped (no rebuild); rebuilt once it ends", () => {
    const { bridge } = fakeBridge([]);
    const iconBridge: CompletionBridge = { ...bridge, tagIcons: () => icons };
    const start = stateOf("#work x", [completionBridge.of(iconBridge)]);
    const view = (state: EditorState, composing: boolean) => ({ state, composing, visibleRanges: [{ from: 0, to: state.doc.length }] });
    const updateOf = (tr: Transaction, composing: boolean) => ({
      view: view(tr.state, composing),
      state: tr.state,
      startState: tr.startState,
      changes: tr.changes,
      docChanged: tr.docChanged,
      viewportChanged: false,
      transactions: [tr],
    });
    const widgets = (plugin: TagIconsState) => {
      const found: { at: number; widget: unknown }[] = [];
      plugin.decorations.between(0, 1e9, (from, _to, deco) => void found.push({ at: from, widget: deco.spec.widget }));
      return found;
    };
    const plugin = new TagIconsState(view(start, false));
    const [before] = widgets(plugin);
    expect(before).toMatchObject({ at: 0 });
    expect(before!.widget).toBeInstanceOf(TagConWidget);

    // The IME writes its marked text in front of the tag: mapped, the same widget object.
    const tr = start.update({ changes: { from: 0, insert: "か" }, userEvent: "input.type.compose" });
    plugin.update(updateOf(tr, true));
    expect(plugin.stale).toBe(true);
    const [during] = widgets(plugin);
    expect(during!.widget).toBe(before!.widget);
    expect(during!.at).toBe(1);

    // Composition over: rebuilt from the tree ("か#work" is no tag: no icon).
    plugin.update(updateOf(tr.state.update({}), false));
    expect(plugin.stale).toBe(false);
    expect(widgets(plugin)).toEqual([]);
  });

  test("tagcon URLs carry the v2 segment", () => {
    expect(tagconURL("star")).toMatch(/^baerchen-asset:\/\/tagcon\/v2\/star\.png$/);
  });

  test("icons are served by the asset scheme; other symbol names are refused", () => {
    expect(tagconURL("folder.fill")).toBe("baerchen-asset://tagcon/v2/folder.fill.png");
    expect(tagconURL("../x")).toBeNull();
    expect(tagconURL("a b")).toBeNull();
    expect(tagconURL("")).toBeNull();
  });
});

// ---------------------------------------------------------------------------------------------
// The bridge client side: requestCompletions → completionResults, tagIcons, setSettings.

class StubHost implements Host {
  sent: EditorToHost[] = [];
  private cb: ((msg: HostToEditor) => void) | null = null;
  send(msg: EditorToHost): Promise<ChangesReply | void> {
    this.sent.push(msg);
    return Promise.resolve();
  }
  onMessage(cb: (msg: HostToEditor) => void): void {
    this.cb = cb;
  }
  deliver(msg: HostToEditor): void {
    this.cb?.(msg);
  }
}

class FakeEditor implements EditorHandle {
  state = EditorState.create({});
  dispatched: TransactionSpec[] = [];
  closed = 0;
  dispatch(spec: TransactionSpec): void {
    this.dispatched.push(spec);
    this.state = this.state.update(spec).state;
  }
  load(doc: LoadedDocument): void {
    this.state = EditorState.create({ doc: doc.text });
  }
  setReadOnly(): void {}
  focus(): void {}
  command(): boolean {
    return false;
  }
  scrollToHeading(): boolean {
    return false;
  }
  closeCompletion(): void {
    this.closed++;
  }
  applySettings(): void {}
  commitComposition = async () => true;
  freeze(): void {}
  unfreeze(): void {}
}

function connected() {
  const host = new StubHost();
  const editor = new FakeEditor();
  const client = new BridgeClient(host, () => editor);
  host.onMessage((msg) => client.handleHostMessage(msg));
  host.deliver({ type: "loadNote", noteId: "n1", text: "", revision: 0, readOnly: false });
  return { host, editor, client, bridge: client.completionBridge };
}

const requestsOf = (host: StubHost) =>
  host.sent.filter((m): m is Extract<EditorToHost, { type: "requestCompletions" }> => m.type === "requestCompletions");

describe("bridge client completions", () => {
  test("a request posts requestCompletions and resolves with the matching completionResults", async () => {
    const { host, bridge } = connected();
    const answer = bridge.request("heading", "Ne", "Plan");
    const [request] = requestsOf(host);
    expect(request).toMatchObject({ type: "requestCompletions", noteId: "n1", kind: "heading", query: "Ne", noteTitle: "Plan" });
    host.deliver({ type: "completionResults", requestId: request!.requestId, items: [work] });
    expect(await answer).toEqual([work]);
  });

  test("stale requestIds are ignored: a newer request supersedes the older one", async () => {
    const { host, bridge } = connected();
    const first = bridge.request("tag", "w");
    const second = bridge.request("tag", "wo");
    const [a, b] = requestsOf(host);
    expect(a!.requestId).not.toBe(b!.requestId);
    expect(await first).toBeNull();
    // The answer to the first request arrives late: ignored.
    host.deliver({ type: "completionResults", requestId: a!.requestId, items: [{ label: "w", insert: "#w " }] });
    host.deliver({ type: "completionResults", requestId: "unknown", items: [] });
    host.deliver({ type: "completionResults", requestId: b!.requestId, items: [work] });
    expect(await second).toEqual([work]);
    // Answered once.
    host.deliver({ type: "completionResults", requestId: b!.requestId, items: [] });
  });

  test("a request without an answer gives up; loading another note drops it", async () => {
    vi.useFakeTimers();
    try {
      const { host, bridge } = connected();
      const lost = bridge.request("tag", "wo");
      vi.advanceTimersByTime(5000);
      expect(await lost).toBeNull();
      const dropped = bridge.request("tag", "wo");
      host.deliver({ type: "loadNote", noteId: "n2", text: "", revision: 0, readOnly: false });
      expect(await dropped).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  test("setSettings autocomplete off: nothing is requested and an open popup closes", async () => {
    const { host, editor, bridge } = connected();
    expect(bridge.enabled()).toBe(true);
    host.deliver({ type: "setSettings", autocomplete: false });
    expect(bridge.enabled()).toBe(false);
    expect(editor.closed).toBe(1);
    expect(await bridge.request("tag", "wo")).toBeNull();
    expect(requestsOf(host)).toEqual([]);
    host.deliver({ type: "setSettings" });
    expect(bridge.enabled()).toBe(false);
    host.deliver({ type: "setSettings", autocomplete: true });
    expect(bridge.enabled()).toBe(true);
  });

  test("tagIcons replace the icon map (kept across note loads) and redraw the icons", () => {
    const { host, editor, bridge } = connected();
    host.deliver({ type: "tagIcons", icons: { work: "briefcase" } });
    expect([...bridge.tagIcons()]).toEqual([["work", "briefcase"]]);
    expect(editor.dispatched.length).toBe(1);
    host.deliver({ type: "loadNote", noteId: "n2", text: "#work", revision: 0, readOnly: false });
    expect(bridge.tagIcons().get("work")).toBe("briefcase");
  });
});

describe("loading a note keeps the completion bridge", () => {
  test("loadedState carries the facet", () => {
    const { bridge } = fakeBridge([]);
    const state = loadedState({ text: "#wo", readOnly: false }, { completion: bridge });
    expect(state.facet(completionBridge)).toBe(bridge);
  });
});

describe("fence languages are one source of the completion config", () => {
  test("they complete after ``` and follow the autocomplete setting", () => {
    const at = (enabled: boolean) => {
      const state = loadedState({ text: "```sw", readOnly: false }, { completion: fakeBridge([], enabled).bridge });
      ensureSyntaxTree(state, state.doc.length, 1000);
      return fenceLanguageSource(new CompletionContext(state, state.doc.length, false));
    };
    expect(at(true)?.options.map((o) => o.label)).toContain("swift");
    expect(at(false)).toBeNull();
  });
});

describe("read-only notes", () => {
  test("accepting a completion changes nothing (the read-only transaction filter)", () => {
    const editable = loadedState({ text: "#wo", readOnly: false });
    const q = completionQueryAt(editable, 3)!;
    expect(q.kind).toBe("tag");
    const item = { label: "work", insert: "#work " };
    expect(editable.update(completionEdit(editable, q, item)).state.doc.toString()).toBe("#work ");
    const readOnly = loadedState({ text: "#wo", readOnly: true });
    expect(completionQueryAt(readOnly, 3)).toBeNull();
    expect(readOnly.update(completionEdit(readOnly, q, item)).state.doc.toString()).toBe("#wo");
  });
});
