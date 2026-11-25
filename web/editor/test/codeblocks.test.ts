// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import type { DecorationSet, EditorView } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { CompletionContext } from "@codemirror/autocomplete";
import { history, undo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import {
  codeBlockDecorations,
  codeBlockText,
  codeBlockTokens,
  codePaste,
  CopyCodeButton,
  fenceAt,
  HIGHLIGHT_CACHE_CHARS,
  HighlightCache,
  LanguageLabel,
  MAX_HIGHLIGHT_CHARS,
  languageCompletionSource,
  languageFor,
} from "../src/editor/features/codeblocks";
import { runCommand } from "../src/editor/features/commands";

function stateWith(doc: string, anchor: number, head = anchor, extensions: Extension[] = []): EditorState {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(anchor, head),
    extensions: [markdown({ base: bearMarkdown }), ...extensions],
  });
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

type Item = { from: number; to: number; spec: Record<string, unknown> };

function items(set: DecorationSet): Item[] {
  const out: Item[] = [];
  set.between(0, 1e9, (from, to, d) => {
    out.push({ from, to, spec: d.spec as Record<string, unknown> });
  });
  return out;
}

const classOf = (it: Item) => (it.spec.class as string | undefined) ?? (it.spec.attributes as Record<string, string> | undefined)?.class;
const hidden = (set: DecorationSet) => items(set).filter((it) => classOf(it) === "cm-bc-hidden").map(({ from, to }) => [from, to]);
const labels = (set: DecorationSet) =>
  items(set)
    .filter((it) => it.spec.widget instanceof LanguageLabel)
    .map((it) => ({ at: it.from, language: (it.spec.widget as LanguageLabel).language }));
const copyButtons = (set: DecorationSet) => items(set).filter((it) => it.spec.widget instanceof CopyCodeButton).map((it) => it.from);

/** Line number → the classes of its line decorations (joined). */
function lineClasses(state: EditorState, set: DecorationSet): Record<number, string> {
  const out: Record<number, string> = {};
  for (const it of items(set)) {
    const cls = classOf(it);
    if (it.from !== it.to || it.spec.widget || !cls) continue;
    const n = state.doc.lineAt(it.from).number;
    out[n] = out[n] ? `${out[n]} ${cls}` : cls;
  }
  return out;
}

/** Line number → merged attributes of its line decorations (without class). */
function lineAttributes(state: EditorState, set: DecorationSet): Record<number, Record<string, string>> {
  const out: Record<number, Record<string, string>> = {};
  for (const it of items(set)) {
    const attrs = it.spec.attributes as Record<string, string> | undefined;
    if (it.from !== it.to || it.spec.widget || !attrs) continue;
    const n = state.doc.lineAt(it.from).number;
    const { class: _cls, ...rest } = attrs;
    out[n] = { ...out[n], ...rest };
  }
  return out;
}

const tokens = (state: EditorState, set: DecorationSet) =>
  items(set)
    .filter((it) => it.from < it.to && classOf(it)?.startsWith("cm-bc-tok-"))
    .map((it) => `${classOf(it)}:${state.sliceDoc(it.from, it.to)}`);

const NOTE = "Intro\n```swift\nlet a = 1\n```\nOutro";
// Offsets in NOTE: "Intro\n" 0–6, "```swift" 6–14, "let a = 1" 15–24, "```" 25–28, "Outro" 29–34.

describe("fence hiding", () => {
  test("caret outside the block: both fence lines are collapsed, the header shows the language", () => {
    const state = stateWith(NOTE, 2);
    const { inner, outer } = codeBlockDecorations(state);
    expect(hidden(inner)).toEqual([
      [6, 14],
      [25, 28],
    ]);
    expect(labels(inner)).toEqual([{ at: 6, language: "swift" }]);
    const lines = lineClasses(state, outer);
    expect(lines[2]).toContain("cm-bc-fence-open");
    expect(lines[2]).toContain("cm-bc-fence-collapsed");
    expect(lines[4]).toContain("cm-bc-fence-close");
    expect(lines[4]).toContain("cm-bc-fence-collapsed");
    expect(lines[3]).not.toContain("cm-bc-fence-collapsed");
    expect(lines[1]).toBeUndefined();
  });

  test("caret inside the block, on either fence line, or a selection reaching in: fences revealed", () => {
    for (const [anchor, head] of [
      [18, 18], // content
      [6, 6], // start of the opening fence line
      [14, 14], // end of the opening fence line
      [28, 28], // end of the closing fence line
      [2, 16], // a selection from the intro into the content
      [0, 34], // select all
    ] as const) {
      const state = stateWith(NOTE, anchor, head);
      const { inner, outer } = codeBlockDecorations(state);
      expect(hidden(inner), `${anchor}-${head}`).toEqual([]);
      expect(labels(inner)).toEqual([]);
      expect(Object.values(lineClasses(state, outer)).join(" ")).not.toContain("cm-bc-fence-collapsed");
    }
  });

  test("the caret right after the closing fence's line break is outside", () => {
    expect(hidden(codeBlockDecorations(stateWith(NOTE, 29)).inner)).toEqual([
      [6, 14],
      [25, 28],
    ]);
  });

  test("a block without a language gets no label; an unclosed fence hides only its opener", () => {
    const bare = stateWith("```\ncode\n```\nx", 14);
    expect(hidden(codeBlockDecorations(bare).inner)).toEqual([
      [0, 3],
      [9, 12],
    ]);
    expect(labels(codeBlockDecorations(bare).inner)).toEqual([]);
    const unclosed = stateWith("x\n```js\ncode", 0);
    expect(hidden(codeBlockDecorations(unclosed).inner)).toEqual([[2, 7]]);
    expect(labels(codeBlockDecorations(unclosed).inner)).toEqual([{ at: 2, language: "js" }]);
  });

  test("a fence in a list item or quote collapses only the fence, not the container markup", () => {
    const list = stateWith("- ```js\n  x()\n  ```\n\nend", 22);
    expect(hidden(codeBlockDecorations(list).inner)).toEqual([
      [2, 7],
      [16, 19],
    ]);
    const quote = stateWith("> ```\n> q\n> ```\n\nend", 18);
    expect(hidden(codeBlockDecorations(quote).inner)).toEqual([
      [2, 5],
      [12, 15],
    ]);
  });

  test("the label shows the first word of the info string; the text stays the document text", () => {
    const state = stateWith("```python title.py\nprint()\n```\n", 31);
    expect(labels(codeBlockDecorations(state).inner)).toEqual([{ at: 0, language: "python" }]);
    // Widgets add no text (the accessibility text stays the document, finding F8).
    const label = new LanguageLabel("python");
    expect(label.eq(new LanguageLabel("python"))).toBe(true);
    expect(label.eq(new LanguageLabel("swift"))).toBe(false);
  });

  test("only the spans asked for are decorated", () => {
    const doc = `${NOTE}\n\n${"filler\n".repeat(50)}\`\`\`\nlate\n\`\`\`\n`;
    const state = stateWith(doc, 2);
    const { inner } = codeBlockDecorations(state, [{ from: 0, to: 40 }]);
    expect(hidden(inner)).toEqual([
      [6, 14],
      [25, 28],
    ]);
  });
});

describe("copy button", () => {
  test("every non-empty block gets one button on its first line", () => {
    const state = stateWith(`${NOTE}\n\`\`\`\n\`\`\`\n`, 2);
    expect(copyButtons(codeBlockDecorations(state).inner)).toEqual([14]);
    // Also while the fences are revealed.
    expect(copyButtons(codeBlockDecorations(stateWith(NOTE, 18)).inner)).toEqual([14]);
  });

  test("copies exactly the code: without fences, quote markers or list indentation", () => {
    const at = (doc: string, pos: number) => {
      const state = stateWith(doc, 0);
      const fence = fenceAt(syntaxTree(state), pos);
      if (!fence) throw new Error(`no fence at ${pos}`);
      return codeBlockText(state, fence);
    };
    expect(at(NOTE, 18)).toBe("let a = 1");
    expect(at("```\n  indented\n\n\ttab \n```", 5)).toBe("  indented\n\n\ttab ");
    expect(at("> ```\n> one\n>\n> two\n> ```", 8)).toBe("one\n\ntwo");
    expect(at("- ```js\n  a()\n    b()\n  ```", 10)).toBe("a()\n  b()");
    expect(at("```\nunclosed\nrest", 5)).toBe("unclosed\nrest");
    expect(at("```\n```", 1)).toBe("");
  });
});

describe("spellcheck and autocorrect off in code", () => {
  const off = { spellcheck: "false", autocorrect: "off", autocapitalize: "off", writingsuggestions: "false" };

  test("on every line of a code block, fences included, and on inline code spans", () => {
    const doc = "Some `inline` text\n```\ncode\n```\nprose";
    const state = stateWith(doc, 0);
    const { outer } = codeBlockDecorations(state);
    const attrs = lineAttributes(state, outer);
    expect(attrs[2]).toEqual(off);
    expect(attrs[3]).toEqual(off);
    expect(attrs[4]).toEqual(off);
    expect(attrs[1]).toBeUndefined();
    expect(attrs[5]).toBeUndefined();
    const inline = items(outer).filter((it) => it.from < it.to && it.spec.attributes);
    expect(inline.map((it) => [state.sliceDoc(it.from, it.to), it.spec.attributes])).toEqual([["`inline`", off]]);
  });
});

describe("syntax highlighting", () => {
  test("a known language highlights once loaded; until then the block is plain and pending", async () => {
    const state = stateWith("```swift\nlet greeting = \"hi\" // note\n```\n", 0);
    const swift = languageFor("swift");
    expect(swift?.name).toBe("Swift");
    if (!swift!.support) {
      expect(tokens(state, codeBlockTokens(state))).toEqual([]);
      expect(codeBlockDecorations(state).pending).toContain(swift);
    }
    await swift!.load();
    expect(codeBlockDecorations(state).pending).toEqual([]);
    const found = tokens(state, codeBlockTokens(state));
    expect(found).toContain("cm-bc-tok-keyword:let");
    expect(found).toContain('cm-bc-tok-string:"hi"');
    expect(found).toContain("cm-bc-tok-comment:// note");
  });

  test("tokens are placed on the code, not on quote markers", async () => {
    await languageFor("js")!.load();
    const state = stateWith("> ```js\n> const a = 1\n> ```\n", 0);
    const found = items(codeBlockTokens(state)).filter((it) => classOf(it) === "cm-bc-tok-keyword");
    expect(found.map((it) => state.sliceDoc(it.from, it.to))).toEqual(["const"]);
  });

  test("unknown languages and blocks without one stay plain (exact names only)", () => {
    expect(languageFor("nope")).toBeNull();
    expect(languageFor("")).toBeNull();
    // `text` must not fuzzily match `tex` (LaTeX).
    expect(languageFor("text")).toBeNull();
    expect(languageFor("Swift")?.name).toBe("Swift");
    expect(languageFor("py")?.name).toBe("Python");
    const state = stateWith("```nope\nlet x = 1\n```\n```\nlet y\n```\n", 0);
    expect(tokens(state, codeBlockTokens(state))).toEqual([]);
    expect(codeBlockDecorations(state).pending).toEqual([]);
  });
});

describe("incremental highlighting (review I3, I4)", () => {
  const JS_LINE = 'const value = compute("text", 42) + other.call(x); // comment\n';
  const PY_LINE = 'def value(x):\n    return compute("text", 42) + other.call(x)  # comment\n';
  const SWIFT_LINE = 'let value = compute("text", 42) + other.call(x) // comment\n';
  const reparsed = (state: EditorState) => {
    if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
    return state.update({}).state;
  };
  const body = (line: string, chars: number) => line.repeat(Math.ceil(chars / line.length));

  test("tokens after edits through the cache equal a fresh highlight", async () => {
    await languageFor("js")!.load();
    let state = stateWith(`\`\`\`js\n${JS_LINE.repeat(30)}\`\`\`\n`, 0);
    const cache = new HighlightCache();
    codeBlockTokens(state, undefined, cache);
    let seed = 7;
    const random = (n: number) => ((seed = (seed * 1103515245 + 12345) % 2147483648) % n);
    const inserts = ["x", '"', "/*", "*/", "\n    ", " ", "", "'", "(", ")"];
    for (let i = 0; i < 80; i++) {
      const fence = fenceAt(syntaxTree(state), 8)!;
      const line = state.doc.line(2 + random(state.doc.lineAt(fence.to).number - 3));
      const at = line.from + 1 + random(Math.max(1, line.length - 1));
      const tr = state.update({ changes: { from: at, to: Math.min(line.to, at + random(3)), insert: inserts[random(inserts.length)]! } });
      cache.map(tr.changes);
      state = reparsed(tr.state);
      expect(tokens(state, codeBlockTokens(state, undefined, cache))).toEqual(tokens(state, codeBlockTokens(state)));
    }
  });

  // M6 Task 18 (triage 46): edits that open, close and move fences shift every block start the
  // cache is keyed by.
  test.each([7, 42, 2026])("random fence inserts and deletes keep the highlight cache equal to a fresh highlight (seed %i)", async (start) => {
    await languageFor("js")!.load();
    let state = reparsed(stateWith(`intro\n\`\`\`js\n${JS_LINE.repeat(3)}\`\`\`\n- item\n\`\`\`js\n${JS_LINE}\`\`\`\nend\n`, 0));
    const cache = new HighlightCache();
    codeBlockTokens(state, undefined, cache);
    let seed = start;
    const random = (n: number) => ((seed = (seed * 1103515245 + 12345) % 2147483648) % Math.max(1, n));
    const pieces = ["```", "```js", "\n", "- ", "x"];
    for (let i = 0; i < 400; i++) {
      const at = random(state.doc.length + 1);
      const spec =
        random(3) === 0 && state.doc.length > 0
          ? { from: Math.min(at, state.doc.length - 1), to: Math.min(state.doc.length, at + 1 + random(4)) }
          : { from: at, insert: pieces[random(pieces.length)]! };
      const tr = state.update({ changes: spec });
      cache.map(tr.changes);
      state = reparsed(tr.state);
      expect(tokens(state, codeBlockTokens(state, undefined, cache)), `edit ${i}`).toEqual(tokens(state, codeBlockTokens(state)));
    }
  });

  test("the cache keeps only the blocks of the last build and is bounded by characters", async () => {
    await languageFor("js")!.load();
    const three = stateWith("```js\na\n```\n```js\nb\n```\n```js\nc\n```\n", 0);
    const cache = new HighlightCache();
    codeBlockTokens(three, undefined, cache);
    expect(cache.size).toBe(3);
    codeBlockTokens(three, [{ from: 0, to: 10 }], cache);
    expect(cache.size).toBe(1);
    const big = `\`\`\`js\n${body(JS_LINE, 27_000)}\`\`\`\n`;
    const many = stateWith(big.repeat(8), 0);
    codeBlockTokens(many, undefined, cache);
    expect(cache.chars).toBeLessThanOrEqual(HIGHLIGHT_CACHE_CHARS);
    expect(cache.size).toBeGreaterThan(0);
  });

  test("blocks over the cap stay plain without building their lines", async () => {
    await languageFor("js")!.load();
    const state = stateWith(`\`\`\`js\n${body(JS_LINE, MAX_HIGHLIGHT_CHARS + 100)}\`\`\`\n`, 0);
    expect(tokens(state, codeBlockTokens(state, [{ from: 0, to: 500 }]))).toEqual([]);
  });

  // Typing never parses code (the plugin maps the tokens and re-highlights HIGHLIGHT_DELAY_MS after
  // the last edit); the deferred re-highlight re-parses incrementally from the block's last tree.
  test("typing in a 29k-char block: keystroke path and deferred re-highlight cost (JS, Python, Swift)", async () => {
    // Deferred re-highlight budgets (ms, p50, Node; its p95 is GC- and load-bound, so only logged): a pause in typing, not a keystroke.
    const deferredBudget: Record<string, number> = { js: 10, python: 4, swift: 8 };
    for (const [lang, line] of [
      ["js", JS_LINE],
      ["python", PY_LINE],
      ["swift", SWIFT_LINE],
    ] as const) {
      await languageFor(lang)!.load();
      const code = body(line, 29_000);
      let state = stateWith(`\`\`\`${lang}\n${code}\`\`\`\n`, 0);
      const cache = new HighlightCache();
      const mid = state.doc.lineAt(Math.floor(code.length / 2)).from + 4;
      const view = () => [{ from: mid - 2000, to: mid + 2000 }];
      let shown = codeBlockTokens(state, view(), cache);
      const keystroke: number[] = [];
      const deferred: number[] = [];
      for (let i = 0; i < 120; i++) {
        const tr = state.update({ changes: { from: mid + i, insert: "a" } });
        state = reparsed(tr.state);
        let start = performance.now();
        cache.map(tr.changes);
        shown = shown.map(tr.changes);
        codeBlockDecorations(state, view());
        keystroke.push(performance.now() - start);
        start = performance.now();
        shown = codeBlockTokens(state, view(), cache);
        deferred.push(performance.now() - start);
      }
      expect(tokens(state, shown)).toEqual(tokens(state, codeBlockTokens(state, view())));
      const stats = (times: number[]) => {
        const sorted = times.slice(20).sort((a, b) => a - b);
        const p = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor((q / 100) * sorted.length))]!;
        return { p50: p(50), p95: p(95), max: sorted.at(-1)! };
      };
      const k = stats(keystroke);
      const d = stats(deferred);
      const fmt = (x: { p50: number; p95: number; max: number }) => `p50 ${x.p50.toFixed(2)}, p95 ${x.p95.toFixed(2)}, max ${x.max.toFixed(2)} ms`;
      console.log(`code ${lang} 29k: keystroke ${fmt(k)}; deferred re-highlight ${fmt(d)}`);
      expect(k.p95).toBeLessThan(4);
      expect(d.p50).toBeLessThan(deferredBudget[lang]!);
    }
  });
});

describe("Paste as Code", () => {
  const paste = (marked: string, text: string) => {
    const caret = marked.indexOf("‸");
    const state = stateWith(marked.replace("‸", ""), caret);
    const next = state.update(codePaste(state, text)).state;
    const head = next.selection.main.head;
    const doc = next.doc.toString();
    return `${doc.slice(0, head)}‸${doc.slice(head)}`;
  };

  test("wraps the clipboard text in a fence on lines of its own", () => {
    expect(paste("‸", "let a = 1\nlet b = 2")).toBe("```\nlet a = 1\nlet b = 2\n```‸");
    expect(paste("‸", "single line")).toBe("```\nsingle line\n```‸");
    expect(paste("before ‸after", "x")).toBe("before \n```\nx\n```‸\nafter");
    expect(paste("a\n‸\nb", "x\n")).toBe("a\n```\nx\n```‸\nb");
    expect(paste("‸", "a\r\nb\rc")).toBe("```\na\nb\nc\n```‸");
  });

  test("a fence longer than any backtick run in the text", () => {
    expect(paste("‸", "```js\nx\n```")).toBe("````\n```js\nx\n```\n````‸");
  });

  test("inside a code block the text is pasted as is", () => {
    expect(paste("```\na‸\n```", "b\nc")).toBe("```\nab\nc‸\n```");
  });

  test("on the opening fence line the text becomes the block's first lines (review I1)", () => {
    expect(paste("```swift‸\nlet a\n```", "x\ny")).toBe("```swift\nx\ny‸\nlet a\n```");
    expect(paste("``‸`swift\nlet a\n```", "x")).toBe("```swift\nx‸\nlet a\n```");
    expect(paste("```‸\n```", "x\n")).toBe("```\nx‸\n```");
  });

  test("on the closing fence line a new block follows the closer (review I1)", () => {
    expect(paste("```swift\nlet a\n```‸", "x")).toBe("```swift\nlet a\n```\n```\nx\n```‸");
    expect(paste("```swift\nlet a\n`‸``\nafter", "x")).toBe("```swift\nlet a\n```\n```\nx\n```‸\nafter");
  });

  test("text with a fence run at a line start lengthens both fences instead of breaking out (review I2)", () => {
    expect(paste("```\na‸\n```", "b\n```\nc")).toBe("````\nab\n```\nc‸\n````");
    expect(paste("~~~\n‸\n~~~", "~~~~")).toBe("~~~~~\n~~~~‸\n~~~~~");
    // Backticks in a tilde block and a fence run that does not start a line are harmless.
    expect(paste("~~~\n‸\n~~~", "```")).toBe("~~~\n```‸\n~~~");
    expect(paste("```\na‸\n```", "```")).toBe("```\na```‸\n```");
    // Indented by up to three spaces still closes; an unclosed block lengthens its opener only.
    expect(paste("```\n‸", "x\n   ```")).toBe("````\nx\n   ```‸");
    // On the opening line too.
    expect(paste("```js‸\n```", "```")).toBe("````js\n```‸\n````");
  });

  test("inside a quoted or list block the pasted lines get the block's container prefix", () => {
    expect(paste("> ```\n> a‸\n> ```", "b\nc")).toBe("> ```\n> ab\n> c‸\n> ```");
    expect(paste("- ```\n  a‸\n  ```", "b\nc")).toBe("- ```\n  ab\n  c‸\n  ```");
    expect(paste("> ```js‸\n> ```", "x")).toBe("> ```js\n> x‸\n> ```");
  });

  test("on a quote or list line the new block stays in the container", () => {
    expect(paste("> quote‸", "x\ny")).toBe("> quote\n> ```\n> x\n> y\n> ```‸");
    expect(paste("> ‸", "x")).toBe("> ```\n> x\n> ```‸");
    expect(paste("- item‸", "x")).toBe("- item\n  ```\n  x\n  ```‸");
    expect(paste("> a ‸b", "x")).toBe("> a \n> ```\n> x\n> ```‸\n> b");
  });

  test("lengthening is one undo step with the paste", () => {
    const state = stateWith("```\na\n```", 5, 5, [history()]);
    let next = state;
    runCommand({ state, dispatch: (tr) => (next = tr.state) }, "pasteCode", { text: "\n```" });
    expect(next.doc.toString()).toBe("````\na\n```\n````");
    let undone = next;
    undo({ state: next, dispatch: (tr) => (undone = tr.state) });
    expect(undone.doc.toString()).toBe("```\na\n```");
  });

  test("the pasteCode command is one undo step; read-only and empty text do nothing", () => {
    const state = stateWith("x", 1, 1, [history()]);
    let next = state;
    expect(runCommand({ state, dispatch: (tr) => (next = tr.state) }, "pasteCode", { text: "y" })).toBe(true);
    expect(next.doc.toString()).toBe("x\n```\ny\n```");
    let undone = next;
    undo({ state: next, dispatch: (tr) => (undone = tr.state) });
    expect(undone.doc.toString()).toBe("x");
    const readOnly = stateWith("x", 1, 1, [EditorState.readOnly.of(true)]);
    expect(runCommand({ state: readOnly, dispatch: () => {} }, "pasteCode", { text: "y" })).toBe(false);
    expect(runCommand({ state, dispatch: () => {} }, "pasteCode", { text: "" })).toBe(false);
    expect(runCommand({ state, dispatch: () => {} }, "pasteCode", {})).toBe(false);
  });
});

describe("language autocomplete after ```", () => {
  const complete = (doc: string, explicit = false) => {
    const state = stateWith(doc, doc.length);
    return languageCompletionSource(new CompletionContext(state, doc.length, explicit));
  };

  test("completes the language being typed on an opening fence", () => {
    const result = complete("```sw");
    expect(result?.from).toBe(3);
    expect(result?.options.map((o) => o.label)).toContain("swift");
    expect(result?.options.find((o) => o.label === "swift")?.detail).toBe("Swift");
    expect(result?.options.map((o) => o.label)).toContain("js");
    expect(result?.options.every((o) => !/\s/.test(o.label))).toBe(true);
    expect(complete("~~~py")?.from).toBe(3);
    expect(complete("- ```ja")?.from).toBe(5);
    expect(complete("> ```c")?.from).toBe(5);
    expect(complete("text\n\n```ru")?.from).toBe(9);
  });

  test("an empty language only on explicit request (Enter after ``` stays a new line)", () => {
    expect(complete("```")).toBeNull();
    expect(complete("```", true)?.from).toBe(3);
  });

  test("the language starts with a letter; nothing while an IME composes", () => {
    expect(complete("```1")).toBeNull();
    expect(complete("```.n")).toBeNull();
    expect(complete("```c#")?.from).toBe(3);
    const state = stateWith("```sw", 5);
    const composing = { composing: true } as unknown as EditorView;
    expect(languageCompletionSource(new CompletionContext(state, 5, false, composing))).toBeNull();
  });

  test("nothing on a closing fence, after a space, in prose or inside code", () => {
    expect(complete("```\ncode\n```sw")).toBeNull();
    expect(complete("```js x")).toBeNull();
    expect(complete("some ```sw")).toBeNull();
    expect(complete("```\n```sw")).toBeNull();
  });
});
