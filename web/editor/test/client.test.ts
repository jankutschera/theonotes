// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { ChangeSet, EditorState, Text, Transaction, type TransactionSpec } from "@codemirror/state";
import { history, undo } from "@codemirror/commands";
import { BridgeClient, type BridgeClientOptions, type EditorHandle, type LoadedDocument } from "../src/bridge/client";
import { MockHost, type Host } from "../src/bridge/hosts";
import { addPendingInsert, pendingInserts } from "../src/editor/features/attachments";
import { loadedState } from "../src/editor/setup";
import type { ChangesReply, CommandArgs, CommandName, EditorSettings, EditorToHost, FormatStateFields, HostToEditor } from "../src/bridge/protocol";

/** The host's placeholder loadNote (EditorBridgeController.placeholderLoad pins the same file). */
const placeholderLoad = Object.values(
  import.meta.glob("../../../Fixtures/bridge/messages-loadNote-placeholder.json", { eager: true, import: "default" }),
)[0] as HostToEditor;

class FakeEditor implements EditorHandle {
  state = EditorState.create({ extensions: [history()] });
  client: BridgeClient | null = null;
  loads: LoadedDocument[] = [];
  readOnly = true;

  dispatch(spec: TransactionSpec | Transaction): void {
    const tr = spec instanceof Transaction ? spec : this.state.update(spec);
    this.state = tr.state;
    this.client?.onTransaction(tr);
  }

  load(doc: LoadedDocument): void {
    this.loads.push(doc);
    this.readOnly = doc.readOnly;
    this.state = EditorState.create({ doc: doc.text, extensions: [history()] });
  }

  setReadOnly(readOnly: boolean): void {
    this.readOnly = readOnly;
  }

  // Capture close (W1): what the real handle does with the compartment, recorded.
  frozen = false;
  freezes = 0;
  unfreezes = 0;
  commits = 0;
  /** How `commitComposition` settles; a promise to hold it. */
  commitOutcome: boolean | Promise<boolean> = true;
  commitComposition(): Promise<boolean> {
    this.commits++;
    return Promise.resolve(this.commitOutcome);
  }
  freeze(): void {
    this.freezes++;
    this.frozen = true;
  }
  unfreeze(): void {
    this.unfreezes++;
    this.frozen = false;
  }

  focus(): void {}

  settings: EditorSettings[] = [];
  applySettings(settings: EditorSettings): void {
    this.settings.push(settings);
  }

  scrollToHeading(_index: number): boolean {
    return false;
  }

  commands: { name: CommandName; args?: CommandArgs }[] = [];
  command(name: CommandName, args?: CommandArgs): boolean {
    this.commands.push({ name, ...(args && { args }) });
    if (name === "insertText" && typeof args?.text === "string") this.type(args.text);
    return true;
  }

  type(text: string): void {
    const pos = this.state.selection.main.head;
    this.dispatch({
      changes: { from: pos, insert: text },
      selection: { anchor: pos + text.length },
      userEvent: "input.type",
    });
  }

  get text(): string {
    return this.state.doc.toString();
  }
}

class StubHost implements Host {
  sent: EditorToHost[] = [];
  reply: () => Promise<ChangesReply | void> = async () => {};
  recoveryReply: (base: number) => Promise<ChangesReply | void> = async (revision) => ({ status: "acked", revision });
  private cb: ((msg: HostToEditor) => void | Promise<void>) | null = null;
  send(msg: EditorToHost): Promise<ChangesReply | void> {
    this.sent.push(msg);
    if (msg.type === "recoveryText") return this.recoveryReply(msg.baseRevision);
    return msg.type === "changes" ? this.reply() : Promise.resolve();
  }
  onMessage(cb: (msg: HostToEditor) => void | Promise<void>): void {
    this.cb = cb;
  }
  deliver(msg: HostToEditor): void | Promise<void> {
    return this.cb?.(msg);
  }
}

/** A stand-in format state: bold while the caret is after position 0. */
const fakeFormatState = (state: EditorState): FormatStateFields => ({
  active: state.selection.main.head > 0 ? ["bold"] : [],
  inTodo: false,
  inCode: false,
  canIndent: false,
});

function connect<H extends Host>(host: H, options: BridgeClientOptions = {}): { host: H; editor: FakeEditor; client: BridgeClient } {
  const editor = new FakeEditor();
  const client = new BridgeClient(host, () => editor, { formatState: fakeFormatState, ...options });
  editor.client = client;
  host.onMessage((msg) => client.handleHostMessage(msg));
  return { host, editor, client };
}

const flush = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
const changesOf = (sent: EditorToHost[]) => sent.filter((m) => m.type === "changes");

describe("BridgeClient", () => {
  test("a pending first load is not swallowed if halt happened before a note was shown", async () => {
    const { host, editor, client } = connect(new StubHost());
    (client as unknown as { halted: boolean }).halted = true;
    await host.deliver({ type: "loadNote", noteId: "first", text: "visible", revision: 0, readOnly: false });
    expect(editor.text).toBe("visible");
  });
  test("a clean load replaces synchronously without a recovery request", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "one", text: "first", revision: 0, readOnly: false });
    const result = host.deliver({ type: "loadNote", noteId: "two", text: "second", revision: 0, readOnly: false });
    expect(result).toBeUndefined();
    expect(editor.text).toBe("second");
    expect(host.sent.some((message) => message.type === "recoveryText")).toBe(false);
  });
  test("failed composition while halting blocks further edits", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "one", text: "abc", revision: 0, readOnly: false });
    editor.commitOutcome = false;
    host.reply = () => new Promise(() => {});
    editor.type("x");
    const external = ChangeSet.of({ from: 0, insert: "E" }, 3);
    host.deliver({ type: "applyExternalChange", noteId: "one", revision: 1, changeSet: external.toJSON() });
    await flush();
    expect(editor.readOnly).toBe(true);
    expect(editor.text).toBe("xabc");
  });
  test("a load received while halting waits for composition and the recovery commit", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "abc", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("x");
    let finishComposition!: (ok: boolean) => void;
    editor.commitOutcome = new Promise((resolve) => { finishComposition = resolve; });
    let commit!: (reply: ChangesReply) => void;
    host.recoveryReply = () => new Promise((resolve) => { commit = resolve; });
    const external = ChangeSet.of({ from: 0, insert: "E" }, 3);
    host.deliver({ type: "applyExternalChange", noteId: "n1", revision: 1, changeSet: external.toJSON() });
    let completed = false;
    const load = Promise.resolve(host.deliver({ type: "loadNote", noteId: "n2", text: "new", revision: 0, readOnly: false })).then(() => { completed = true; });
    await flush();
    expect(completed).toBe(false);
    finishComposition(true);
    await flush();
    expect(completed).toBe(false);
    expect(editor.text).toBe("xabc");
    commit({ status: "acked", revision: 0 });
    await load;
    expect(completed).toBe(true);
    expect(editor.text).toBe("new");
  });
  test("privacy recovery persists browser text without loading a new page", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("unsaved ");
    expect(await client.preserveForPrivacy("original")).toBe(true);
    expect(host.sent.find((msg) => msg.type === "recoveryText")).toMatchObject({ noteId: "original", text: "unsaved base" });
    expect(editor.loads).toHaveLength(1);
    expect(editor.readOnly).toBe(true);
  });
  test("privacy recovery never reports success when native persistence fails", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("unsaved ");
    host.recoveryReply = async () => { throw new Error("storage failed"); };
    expect(await client.preserveForPrivacy("original")).toBe(false);
    expect(editor.text).toBe("unsaved base");
    expect(editor.loads).toHaveLength(1);
  });
  test("recovery ends composition before read-only and preserves the completed text", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("typed ");
    let finish!: (value: boolean) => void;
    editor.commitOutcome = new Promise((resolve) => { finish = resolve; });
    host.deliver({ type: "loadNote", noteId: "other", text: "other", revision: 0, readOnly: false });
    expect(editor.readOnly).toBe(false);
    editor.type("IME ");
    finish(true);
    await flush();
    expect(host.sent.find((msg) => msg.type === "recoveryText")).toMatchObject({ text: "typed IME base" });
  });
  test("late recovery ACK loads only the latest destination and never discards post-snapshot edits", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("A");
    let persist!: (reply: ChangesReply) => void;
    host.recoveryReply = () => new Promise((resolve) => { persist = resolve; });
    host.deliver({ type: "loadNote", noteId: "first", text: "first destination", revision: 0, readOnly: false });
    await flush();
    host.deliver({ type: "loadNote", noteId: "second", text: "latest destination", revision: 0, readOnly: false });
    // A programmatic change can bypass the read-only user input filter.
    editor.type("B");
    persist({ status: "acked", revision: 0 });
    await flush();
    expect(editor.text).toBe("ABbase");
    expect(editor.loads).toHaveLength(1);
    expect(client.unackedCount).toBe(1);
  });
  test("loadNote preserves the full original browser document before replacing unacknowledged text", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 4, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("unacknowledged ");
    let persist!: (reply: ChangesReply) => void;
    host.recoveryReply = () => new Promise((resolve) => { persist = resolve; });
    host.deliver({ type: "loadNote", noteId: "other", text: "different note", revision: 9, readOnly: false });
    await flush();
    expect(host.sent.find((msg) => msg.type === "recoveryText")).toEqual({
      type: "recoveryText", noteId: "original", baseRevision: 4, text: "unacknowledged base",
    });
    expect(editor.text).toBe("unacknowledged base");
    expect(editor.readOnly).toBe(true);
    expect(client.unackedCount).toBe(1);
    persist({ status: "acked", revision: 4 });
    await flush();
    expect(editor.text).toBe("different note");
    expect(client.unackedCount).toBe(0);
  });

  test("failed recovery persistence never clears or replaces unacknowledged browser text", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("keep ");
    host.recoveryReply = async () => { throw new Error("storage unavailable"); };
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    await flush();
    expect(editor.text).toBe("keep base");
    expect(client.unackedCount).toBe(1);
    expect(editor.readOnly).toBe(true);
    expect(editor.loads).toHaveLength(1);
  });
  test("a late rejected recovery during a previously sent load keeps the unacknowledged document", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("unsaved ");
    let rejectRecovery!: (error: Error) => void;
    host.recoveryReply = () => new Promise((_resolve, reject) => { rejectRecovery = reject; });
    const loadAttempt = host.deliver({ type: "loadNote", noteId: "original", text: "base", revision: 0, readOnly: false });
    await flush();
    expect(host.sent.find((message) => message.type === "recoveryText")).toMatchObject({ text: "unsaved base" });
    rejectRecovery(new Error("session invalidated"));
    await expect(loadAttempt).rejects.toThrow();
    await flush();
    expect(editor.text).toBe("unsaved base");
    expect(editor.loads).toHaveLength(1);
    expect(client.unackedCount).toBe(1);
    expect(editor.readOnly).toBe(true);
  });
  test("typing sends changes that reproduce the editor text on the host", async () => {
    const { host, editor, client } = connect(new MockHost({ text: "hello" }));
    host.loadNote();
    expect(editor.text).toBe("hello");

    for (const chunk of [" ", "w", "😀", "👩‍👩‍👧", "漢字", "!"]) {
      editor.type(chunk);
      await flush();
      expect(host.text).toBe(editor.text);
    }
    const changes = changesOf(host.sent);
    expect(changes).toHaveLength(6);
    changes.forEach((m, i) => {
      expect(m).toMatchObject({ noteId: host.noteId, baseRevision: i, revision: i + 1 });
      expect(m.txId).toMatch(/^[0-9a-f-]{36}$/);
    });
    expect(host.revision).toBe(6);
    expect(client.unackedCount).toBe(0);
  });

  test("a needsFullText reply stops sending until the next loadNote", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "abc", revision: 4, readOnly: false });
    host.reply = async () => ({ status: "needsFullText", currentRevision: 9 });

    editor.type("x");
    await flush();
    expect(changesOf(host.sent)).toHaveLength(1);
    expect(host.sent.some((m) => m.type === "error")).toBe(true);

    editor.type("y");
    await flush();
    expect(changesOf(host.sent)).toHaveLength(1);

    host.reply = async () => ({ status: "acked", revision: 10 });
    await host.deliver({ type: "loadNote", noteId: "n1", text: "abcx", revision: 9, readOnly: false });
    editor.type("z");
    await flush();
    const changes = changesOf(host.sent);
    expect(changes).toHaveLength(2);
    expect(changes[1]).toMatchObject({ baseRevision: 9, revision: 10 });
  });

  test("applyExternalChange updates the doc without echoing changes and adopts the revision", async () => {
    const { host, editor } = connect(new MockHost({ text: "one two" }));
    host.loadNote();
    editor.dispatch({ selection: { anchor: 7 } });
    editor.type("!");
    await flush();
    const before = changesOf(host.sent).length;

    host.externalEdit({ from: 0, to: 3, insert: "1" });
    expect(editor.text).toBe("1 two!");
    expect(host.text).toBe(editor.text);
    await flush();
    expect(changesOf(host.sent)).toHaveLength(before);

    editor.type("?");
    await flush();
    expect(changesOf(host.sent).at(-1)).toMatchObject({ baseRevision: 2, revision: 3 });
    expect(host.text).toBe("1 two!?");
  });

  test("an external change is not in the undo history; undo reverts the earlier local edit (R9)", async () => {
    const { host, editor } = connect(new MockHost({ text: "one two" }));
    host.loadNote();
    editor.dispatch({ selection: { anchor: 7 } });
    editor.type("!");
    await flush();
    host.externalEdit({ from: 0, to: 3, insert: "1" });
    expect(editor.text).toBe("1 two!");

    undo({ state: editor.state, dispatch: (tr) => editor.dispatch(tr) });
    expect(editor.text).toBe("1 two");
    await flush();
    expect(host.text).toBe("1 two");

    // Nothing left to undo: the external change stays.
    expect(undo({ state: editor.state, dispatch: (tr) => editor.dispatch(tr) })).toBe(false);
    expect(editor.text).toBe("1 two");
  });

  test("an external change based on a revision the editor is ahead of is not applied", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "abc", revision: 0, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("x");

    const external = ChangeSet.of({ from: 0, insert: "E" }, 3);
    host.deliver({ type: "applyExternalChange", noteId: "n1", revision: 1, changeSet: external.toJSON() });
    expect(editor.text).toBe("xabc");
    await flush(); // halt ends any active composition before reporting the error
    expect(host.sent.some((m) => m.type === "error")).toBe(true);
  });

  test("loadNote replaces the doc, emits no changes and resets the revision", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "first", revision: 3, readOnly: false });
    host.reply = () => new Promise(() => {});
    editor.type("x");
    expect(client.unackedCount).toBe(1);

    await host.deliver({
      type: "loadNote",
      noteId: "n2",
      text: "second",
      revision: 11,
      readOnly: true,
      selection: { anchor: 2, head: 4 },
      scrollTop: 40,
    });
    expect(editor.text).toBe("second");
    expect(editor.loads.at(-1)).toEqual({
      noteId: "n2",
      text: "second",
      readOnly: true,
      selection: { anchor: 2, head: 4 },
      scrollTop: 40,
    });
    expect(client.unackedCount).toBe(0);
    expect(changesOf(host.sent)).toHaveLength(1);

    host.reply = async () => ({ status: "acked", revision: 12 });
    editor.type("y");
    expect(changesOf(host.sent).at(-1)).toMatchObject({ noteId: "n2", baseRevision: 11, revision: 12 });
  });

  test("requestChecksum replies with the SHA-256 of the editor text", async () => {
    const { host } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "ab😀漢", revision: 0, readOnly: false });
    host.deliver({ type: "requestChecksum", requestId: "r1" });
    // crypto.subtle.digest resolves on its own schedule: wait for the reply, bounded.
    await vi.waitFor(
      () =>
        expect(host.sent).toContainEqual({
          type: "checksum",
          requestId: "r1",
          noteId: "n1",
          // printf 'ab😀漢' | shasum -a 256
          sha256: "bfd2d858f97a0ce6c0c42db5409e9f0d41f23eff1e2ca47ec35f74d3765d0a54",
        }),
      { timeout: 2000, interval: 5 },
    );
  });

  test("the host's empty placeholder note loads locked; real notes never do", () => {
    const { host, editor } = connect(new StubHost());
    expect(placeholderLoad).toMatchObject({ type: "loadNote", readOnly: true });
    host.deliver(placeholderLoad);
    host.deliver({ type: "loadNote", noteId: "n1", text: "a", revision: 0, readOnly: true });
    expect(editor.loads.map((l) => l.locked ?? false)).toEqual([true, false]);
  });

  test("setSettings reaches the editor before and after loadNote, without reloading it", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "setSettings", hideMarkdown: false });
    host.deliver({ type: "loadNote", noteId: "n1", text: "abc", revision: 0, readOnly: false });
    host.deliver({ type: "setSettings", autoSortTodos: true, typography: { fontSize: 18 } });
    expect(editor.settings).toEqual([{ hideMarkdown: false }, { autoSortTodos: true, typography: { fontSize: 18 } }]);
    expect(editor.loads).toHaveLength(1);
  });

  test("selection moves are reported", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "hello", revision: 0, readOnly: false });
    editor.dispatch({ selection: { anchor: 1, head: 4 } });
    expect(host.sent).toContainEqual({ type: "selectionChanged", noteId: "n1", anchor: 1, head: 4 });
  });

  test("scrollToHeading reaches the editor only for the loaded note", () => {
    const { host, editor } = connect(new StubHost());
    const scrolled: number[] = [];
    editor.scrollToHeading = (index: number) => {
      scrolled.push(index);
      return true;
    };
    host.deliver({ type: "loadNote", noteId: "n1", text: "# A\n# B", revision: 0, readOnly: false });
    host.deliver({ type: "scrollToHeading", noteId: "other", index: 0 });
    host.deliver({ type: "scrollToHeading", noteId: "n1", index: 1 });
    expect(scrolled).toEqual([1]);
  });

  test("a badge click posts headingMenu with menuId, folded and rect for the loaded note", () => {
    const { host, client } = connect(new StubHost());
    const rect = { x: 4, y: 40, width: 24, height: 16 };
    client.headingMenu("m1", 1, 2, false, rect);
    expect(host.sent).toEqual([]);
    host.deliver({ type: "loadNote", noteId: "n1", text: "x\n## H", revision: 0, readOnly: false });
    client.headingMenu("m2", 2, 2, true, rect);
    expect(host.sent).toEqual([{ type: "headingMenu", noteId: "n1", menuId: "m2", line: 2, level: 2, folded: true, rect }]);
  });

  test("tableMenu, calloutMenu and foldState carry the loaded note's id; nothing before a note is loaded", () => {
    const { host, client } = connect(new StubHost());
    const rect = { x: 1, y: 2, width: 18, height: 18 };
    client.tableMenu("m1", 0, 1, 3, 3, rect);
    client.calloutMenu("m2", "tip", rect);
    client.foldState([{ line: 1, hash: "0a1b2c3d" }]);
    expect(host.sent).toEqual([]);
    host.deliver({ type: "loadNote", noteId: "n1", text: "x", revision: 0, readOnly: false });
    client.tableMenu("m3", 0, 1, 3, 3, rect);
    client.calloutMenu("m4", "tip", rect);
    client.foldState([{ line: 1, hash: "0a1b2c3d" }]);
    expect(host.sent).toEqual([
      { type: "tableMenu", noteId: "n1", menuId: "m3", row: 0, column: 1, rows: 3, columns: 3, rect },
      { type: "calloutMenu", noteId: "n1", menuId: "m4", calloutType: "tip", rect },
      { type: "foldState", noteId: "n1", folds: [{ line: 1, hash: "0a1b2c3d" }] },
    ]);
  });

  test("loadNote hands the stored foldState to the editor, and none when the host sent none", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "# A\nx", revision: 0, readOnly: false, foldState: [{ line: 1, hash: "0a1b2c3d" }] });
    host.deliver({ type: "loadNote", noteId: "n2", text: "y", revision: 0, readOnly: false });
    expect(editor.loads[0]!.foldState).toEqual([{ line: 1, hash: "0a1b2c3d" }]);
    expect("foldState" in editor.loads[1]!).toBe(false);
  });

  test("loadNote drops invalid fold entries and caps the rest instead of failing", () => {
    const { host, editor } = connect(new StubHost());
    const good = { line: 1, hash: "0a1b2c3d" };
    host.deliver({
      type: "loadNote", noteId: "n1", text: "# A", revision: 0, readOnly: false,
      foldState: [good, { line: 0, hash: "0a1b2c3d" }, { line: 2, hash: "XYZ" }] as never,
    });
    expect(editor.loads[0]!.foldState).toEqual([good]);
    const many = Array.from({ length: 10_050 }, (_, i) => ({ line: i + 1, hash: "0a1b2c3d" }));
    host.deliver({ type: "loadNote", noteId: "n2", text: "x", revision: 0, readOnly: false, foldState: many });
    expect(editor.loads[1]!.foldState).toHaveLength(10_000);
  });

  test("setSettings with typewriterMode reaches the editor's settings", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "setSettings", typewriterMode: true });
    expect(editor.settings).toEqual([{ typewriterMode: true }]);
  });

  test("selectRange selects the range of the loaded note only", () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "hello world", revision: 0, readOnly: false });
    host.deliver({ type: "selectRange", noteId: "other", anchor: 0, head: 5 });
    expect(editor.state.selection.main).toMatchObject({ anchor: 0, head: 0 });
    host.deliver({ type: "selectRange", noteId: "n1", anchor: 6, head: 11 });
    expect(editor.state.selection.main).toMatchObject({ anchor: 6, head: 11 });
    // Backwards ranges keep their direction; a range outside the document selects nothing.
    host.deliver({ type: "selectRange", noteId: "n1", anchor: 5, head: 0 });
    expect(editor.state.selection.main).toMatchObject({ anchor: 5, head: 0 });
    host.deliver({ type: "selectRange", noteId: "n1", anchor: 2, head: 12 });
    expect(editor.state.selection.main).toMatchObject({ anchor: 5, head: 0 });
  });

  test("selectRange is not an edit: nothing is sent to the host as changes", () => {
    const { host } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "hello", revision: 0, readOnly: true });
    host.deliver({ type: "selectRange", noteId: "n1", anchor: 1, head: 3 });
    expect(changesOf(host.sent)).toEqual([]);
  });

  test("openLink and editLinkRequest carry the loaded note's id; nothing before a note is loaded", () => {
    const { host, client } = connect(new StubHost());
    const rect = { x: 1, y: 2, width: 1, height: 15 };
    client.openLink({ kind: "url", target: "https://x.y", newWindow: false });
    client.editLinkRequest({ requestId: "r0", from: 0, to: 0, title: "", url: "", editing: false, caretRect: rect });
    expect(host.sent).toEqual([]);
    host.deliver({ type: "loadNote", noteId: "n1", text: "x", revision: 0, readOnly: false });
    client.openLink({ kind: "wiki", target: "Note", heading: "H", newWindow: true });
    client.editLinkRequest({ requestId: "r1", from: 0, to: 1, title: "x", url: "", editing: false, caretRect: rect });
    expect(host.sent).toEqual([
      { type: "openLink", noteId: "n1", kind: "wiki", target: "Note", heading: "H", newWindow: true },
      { type: "editLinkRequest", noteId: "n1", requestId: "r1", from: 0, to: 1, title: "x", url: "", editing: false, caretRect: rect },
    ]);
  });

  test("Copy Code posts copyText with the exact text (the host writes the pasteboard), read-only notes too", () => {
    const { host, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "x", revision: 0, readOnly: true });
    client.copyText("let a = 1\n\tb ");
    expect(host.sent).toEqual([{ type: "copyText", text: "let a = 1\n\tb " }]);
  });

  test("copyText carries the html of a rich copy", () => {
    const { host, client } = connect(new StubHost());
    client.copyText("<table></table>", "<table></table>");
    expect(host.sent).toEqual([{ type: "copyText", text: "<table></table>", html: "<table></table>" }]);
  });
});

describe("BridgeClient: one note in two windows (M4 Task 9)", () => {
  /** Swift's NoteSession for two editors: applies a transaction, acks it, forwards it to the other. */
  function sharedNote(text: string) {
    const note = { text: Text.of(text.split("\n")), revision: 0 };
    const editors = [connect(new StubHost()), connect(new StubHost())];
    for (const self of editors) {
      self.host.reply = async () => {
        const msg = changesOf(self.host.sent).at(-1);
        if (msg?.type !== "changes") return;
        if (msg.baseRevision !== note.revision) return { status: "needsFullText", currentRevision: note.revision };
        note.text = ChangeSet.fromJSON(msg.changeSet).apply(note.text);
        note.revision += 1;
        for (const other of editors) {
          if (other === self) continue;
          other.host.deliver({ type: "applyExternalChange", noteId: "n1", revision: note.revision, changeSet: msg.changeSet });
        }
        return { status: "acked", revision: note.revision };
      };
      self.host.deliver({ type: "loadNote", noteId: "n1", text, revision: 0, readOnly: false });
    }
    return { note, a: editors[0]!, b: editors[1]! };
  }

  test("undo in editor B reverts B's own edit, never A's forwarded one (R9)", async () => {
    const { note, a, b } = sharedNote("one two");
    b.editor.dispatch({ selection: { anchor: 7 } });
    b.editor.type("?");
    await flush();
    a.editor.dispatch({ selection: { anchor: 0 } });
    a.editor.type("> ");
    await flush();
    expect(a.editor.text).toBe("> one two?");
    expect(b.editor.text).toBe("> one two?");

    undo({ state: b.editor.state, dispatch: (tr) => b.editor.dispatch(tr) });
    await flush();
    expect(b.editor.text).toBe("> one two");
    expect(note.text.toString()).toBe("> one two");
    expect(a.editor.text).toBe("> one two");
    // A's edit is not in B's history: nothing more to undo there.
    expect(undo({ state: b.editor.state, dispatch: (tr) => b.editor.dispatch(tr) })).toBe(false);
    expect(b.editor.text).toBe("> one two");
    expect([a, b].flatMap(({ host }) => host.sent).some((m) => m.type === "error")).toBe(false);
  });
});

describe("BridgeClient commands and format state", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  const formatStates = (sent: EditorToHost[]) => sent.filter((m) => m.type === "formatState");

  test("applyCommand runs the named command; its edit is sent like typing", async () => {
    const { host, editor } = connect(new MockHost({ text: "ab" }));
    host.loadNote();
    host.deliver({ type: "applyCommand", name: "heading", args: { level: 2 } });
    host.deliver({ type: "applyCommand", name: "insertText", args: { text: "!" } });
    expect(editor.commands).toEqual([{ name: "heading", args: { level: 2 } }, { name: "insertText", args: { text: "!" } }]);
    await vi.advanceTimersByTimeAsync(0);
    expect(host.text).toBe("!ab");
  });

  test("formatState is posted 50 ms after loadNote and after selection or document changes, debounced", async () => {
    const { host, editor } = connect(new StubHost());
    editor.dispatch({});
    await vi.advanceTimersByTimeAsync(100);
    expect(formatStates(host.sent)).toEqual([]); // no note yet

    host.deliver({ type: "loadNote", noteId: "n1", text: "hello", revision: 0, readOnly: false });
    await vi.advanceTimersByTimeAsync(49);
    expect(formatStates(host.sent)).toEqual([]);
    await vi.advanceTimersByTimeAsync(1);
    expect(formatStates(host.sent)).toEqual([
      { type: "formatState", noteId: "n1", active: [], inTodo: false, inCode: false, canIndent: false },
    ]);

    for (const anchor of [1, 2, 3]) {
      editor.dispatch({ selection: { anchor } });
      await vi.advanceTimersByTimeAsync(20);
    }
    expect(formatStates(host.sent)).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(50);
    expect(formatStates(host.sent)).toHaveLength(2);
    expect(formatStates(host.sent)[1]).toMatchObject({ noteId: "n1", active: ["bold"] });
  });

  test("an external change reschedules the format state (minor 4)", async () => {
    const host = new MockHost({ text: "hello" });
    const { editor } = connect(host);
    host.loadNote();
    await vi.advanceTimersByTimeAsync(50);
    editor.dispatch({ selection: { anchor: 5 } });
    await vi.advanceTimersByTimeAsync(50);
    const before = formatStates(host.sent).length;
    expect(formatStates(host.sent).at(-1)).toMatchObject({ active: ["bold"] });
    host.externalEdit({ from: 0, to: 5 });
    await vi.advanceTimersByTimeAsync(50);
    // The external delete moved the caret to 0: not bold in the fake state any more.
    expect(formatStates(host.sent).length).toBe(before + 1);
    expect(formatStates(host.sent).at(-1)).toMatchObject({ active: [] });
  });

  test("an unchanged format state is not posted again, except after a new loadNote", async () => {
    const { host, editor } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "hello", revision: 0, readOnly: false });
    await vi.advanceTimersByTimeAsync(50);
    editor.dispatch({ selection: { anchor: 2 } });
    await vi.advanceTimersByTimeAsync(50);
    editor.dispatch({ selection: { anchor: 3 } });
    await vi.advanceTimersByTimeAsync(50);
    expect(formatStates(host.sent)).toHaveLength(2);
    host.deliver({ type: "loadNote", noteId: "n2", text: "hello", revision: 0, readOnly: false });
    await vi.advanceTimersByTimeAsync(50);
    expect(formatStates(host.sent).map((m) => m.noteId)).toEqual(["n1", "n1", "n2"]);
  });
});

describe("BridgeClient resend and halt", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  const replies = (host: StubHost, ...seq: Array<() => Promise<ChangesReply | void>>) => {
    host.reply = () => (seq.shift() ?? (() => Promise.reject(new Error("unexpected send"))))();
  };
  const errorsOf = (sent: EditorToHost[]) => sent.filter((m) => m.type === "error");
  const load = (host: StubHost) =>
    host.deliver({ type: "loadNote", noteId: "n1", text: "", revision: 0, readOnly: false });

  test.each([
    ["rejected", () => Promise.reject(new Error("journal write failed"))],
    ["missing", () => Promise.resolve()],
    ["invalid", () => Promise.resolve({ status: "bogus" } as unknown as ChangesReply)],
  ])("a %s reply resends the unacked queue in order with the same txIds", async (_mode, failure) => {
    const { host, editor, client } = connect(new StubHost());
    load(host);
    replies(
      host,
      failure,
      async () => ({ status: "duplicate", revision: 1 }),
      async () => ({ status: "acked", revision: 2 }),
    );

    editor.type("a");
    await vi.advanceTimersByTimeAsync(0);
    editor.type("b"); // queued behind the failed message, not sent yet
    await vi.advanceTimersByTimeAsync(0);
    expect(changesOf(host.sent)).toHaveLength(1);

    await vi.advanceTimersByTimeAsync(100);
    const changes = changesOf(host.sent);
    expect(changes.map((m) => m.txId)).toEqual([changes[0]!.txId, changes[0]!.txId, changes[2]!.txId]);
    expect(changes.map((m) => m.revision)).toEqual([1, 1, 2]);
    expect(client.unackedCount).toBe(0);
    expect(errorsOf(host.sent)).toEqual([]);
    expect(editor.readOnly).toBe(false);

    replies(host, async () => ({ status: "acked", revision: 3 }));
    editor.type("c");
    await vi.advanceTimersByTimeAsync(0);
    expect(changesOf(host.sent).at(-1)).toMatchObject({ baseRevision: 2, revision: 3 });
  });

  test("needsFullText for a message after a failed one is retried, not fatal", async () => {
    const { host, editor, client } = connect(new StubHost());
    load(host);
    replies(
      host,
      () => Promise.reject(new Error("transient")),
      async () => ({ status: "needsFullText", currentRevision: 0 }),
      async () => ({ status: "acked", revision: 1 }),
      async () => ({ status: "acked", revision: 2 }),
    );
    editor.type("a");
    editor.type("b");
    await vi.advanceTimersByTimeAsync(100);
    expect(changesOf(host.sent)).toHaveLength(4);
    expect(client.unackedCount).toBe(0);
    expect(errorsOf(host.sent)).toEqual([]);
  });

  test("exhausted resends halt: one error, read-only until the next loadNote", async () => {
    const { host, editor, client } = connect(new StubHost());
    load(host);
    host.reply = () => Promise.reject(new Error("down"));

    editor.type("a");
    await vi.advanceTimersByTimeAsync(100 + 300 + 1000);
    expect(changesOf(host.sent)).toHaveLength(4);
    expect(errorsOf(host.sent)).toHaveLength(1);
    expect(editor.readOnly).toBe(true);

    editor.type("b");
    await vi.advanceTimersByTimeAsync(5000);
    expect(changesOf(host.sent)).toHaveLength(4);
    expect(errorsOf(host.sent)).toHaveLength(1);

    host.reply = async () => ({ status: "acked", revision: 4 });
    await host.deliver({ type: "loadNote", noteId: "n1", text: "a", revision: 3, readOnly: false });
    expect(editor.readOnly).toBe(false);
    expect(client.unackedCount).toBe(0);
    editor.type("c");
    await vi.advanceTimersByTimeAsync(0);
    expect(changesOf(host.sent).at(-1)).toMatchObject({ baseRevision: 3, revision: 4 });
  });

  test("invalidated session rejects every retry and halts without reloading or losing selectable text", async () => {
    const { host, editor, client } = connect(new StubHost());
    host.deliver({ type: "loadNote", noteId: "n1", text: "original", revision: 0, readOnly: false });
    // Use the production locked-document transaction filter after BridgeClient requests halt.
    editor.setReadOnly = (readOnly) => {
      editor.readOnly = readOnly;
      if (readOnly) editor.state = loadedState({ text: editor.text, readOnly: true, locked: true });
    };
    let release!: (error: Error) => void;
    host.reply = () => new Promise((_resolve, reject) => { release = reject; });
    editor.type("unsaved ");
    host.reply = () => Promise.reject(new Error("session invalidated"));
    release(new Error("session invalidated"));
    await vi.advanceTimersByTimeAsync(100 + 300 + 1000);
    expect(changesOf(host.sent)).toHaveLength(4);
    expect(errorsOf(host.sent)).toHaveLength(1);
    expect(client.unackedCount).toBe(1);
    expect(editor.readOnly).toBe(true);
    expect(editor.loads).toHaveLength(1); // initial load only
    expect(editor.text).toBe("unsaved original");
    editor.type("must not appear");
    expect(editor.text).toBe("unsaved original");
    editor.dispatch({ selection: { anchor: 0, head: editor.state.doc.length } });
    expect(editor.state.selection.main.from).toBe(0);
    expect(editor.state.selection.main.to).toBe(editor.state.doc.length);
  });

  test("halting for any reason makes the editor read-only", async () => {
    const { host, editor } = connect(new StubHost());
    load(host);
    host.deliver({ type: "applyExternalChange", noteId: "n1", revision: 1, changeSet: [5, [0, "x"]] });
    await vi.advanceTimersByTimeAsync(0);
    expect(editor.readOnly).toBe(true);
    expect(errorsOf(host.sent)).toHaveLength(1);
  });

  test("halt waits for composition before read-only", async () => {
    const { host, editor } = connect(new StubHost());
    load(host);
    let finish!: (value: boolean) => void;
    editor.commitOutcome = new Promise((resolve) => { finish = resolve; });
    host.deliver({ type: "applyExternalChange", noteId: "n1", revision: 1, changeSet: [5, [0, "x"]] });
    expect(editor.readOnly).toBe(false);
    editor.type("composition");
    finish(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(editor.readOnly).toBe(true);
    expect(editor.text).toContain("composition");
  });
});

describe("pending attachment inserts", () => {
  test("a rejected or unreadable upload drops its pending insert; copied links are reported", async () => {
    const editor = new FakeEditor();
    const host = new StubHost();
    const client = new BridgeClient(host, () => editor);
    editor.client = client;
    client.handleHostMessage({ type: "loadNote", noteId: "n1", text: "ab", revision: 0, readOnly: false });
    editor.state = EditorState.create({ doc: "ab", extensions: [pendingInserts] });
    editor.dispatch({ effects: [addPendingInsert.of({ id: "i1", from: 1, to: 1 }), addPendingInsert.of({ id: "i2", from: 1, to: 1 })] });

    // The host rejects the message (its decoder refused it).
    host.send = (msg) => {
      host.sent.push(msg);
      return Promise.reject(new Error("invalid bridge message"));
    };
    await client.insertAttachments("i1", [new File([new Uint8Array([1])], "a.png")]);
    expect(editor.state.field(pendingInserts).has("i1")).toBe(false);

    // A file that cannot be read.
    const unreadable = { name: "b.png", arrayBuffer: () => Promise.reject(new Error("gone")) } as unknown as File;
    await client.insertAttachments("i2", [unreadable]);
    expect(editor.state.field(pendingInserts).size).toBe(0);

    host.send = (msg) => {
      host.sent.push(msg);
      return Promise.resolve();
    };
    client.attachmentsCopied(["p.png"]);
    expect(host.sent.at(-1)).toEqual({ type: "cutAttachments", noteId: "n1", filenames: ["p.png"] });
  });
});


test("scroll restoration keeps each note identity during rapid switches", async () => {
  vi.useFakeTimers();
  try {
    const host = new StubHost();
    const editor = new FakeEditor();
    const client = new BridgeClient(host, () => editor);
    client.handleHostMessage({ type: "loadNote", noteId: "first", text: "a", revision: 0, readOnly: false });
    client.scrollChanged(120.5);
    client.scrollChanged(160.5);
    client.handleHostMessage({ type: "loadNote", noteId: "second", text: "b", revision: 0, readOnly: false });
    client.scrollChanged(20);
    await vi.advanceTimersByTimeAsync(101);
    expect(host.sent.filter((m) => m.type === "scrollChanged")).toEqual([
      { type: "scrollChanged", noteId: "first", scrollTop: 160.5 },
      { type: "scrollChanged", noteId: "second", scrollTop: 20 },
    ]);
  } finally { vi.useRealTimers(); }
});

// W1: the capture-close freeze/drain. The reply is the editor's word that nothing
// typed before it is still on its way and nothing more can be typed.
describe("BridgeClient freezeForClose", () => {
  type Frozen = Extract<EditorToHost, { type: "frozenForClose" }>;
  const replies = (sent: EditorToHost[]): Frozen[] => sent.filter((m): m is Frozen => m.type === "frozenForClose");
  const EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  // printf 'hi' | shasum -a 256
  const HI_SHA = "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4";

  function open(options: BridgeClientOptions = {}, text = "") {
    const c = connect(new StubHost(), options);
    c.host.reply = async () => ({ status: "acked", revision: 1 });
    c.host.deliver({ type: "loadNote", noteId: "n1", text, revision: 0, readOnly: false });
    return c;
  }
  const freeze = (host: StubHost, requestId = "f1", noteId = "n1") => host.deliver({ type: "freezeForClose", requestId, noteId });
  const waitForReply = (host: StubHost, count = 1) =>
    vi.waitFor(() => expect(replies(host.sent)).toHaveLength(count), { timeout: 1500, interval: 5 });

  test("an untouched document answers ok with editedSinceLoad false and the hash of its text", async () => {
    const { host, editor } = open();
    freeze(host);
    await waitForReply(host);
    expect(replies(host.sent)[0]).toEqual({
      type: "frozenForClose", requestId: "f1", noteId: "n1", ok: true, editedSinceLoad: false, sha256: EMPTY_SHA,
    });
    expect(editor.freezes).toBe(1);
  });

  test("a transaction sent before the freeze is acknowledged before the reply", async () => {
    const { host, editor } = open();
    let release: (reply: ChangesReply) => void = () => {};
    host.reply = () => new Promise<ChangesReply>((resolve) => { release = resolve; });
    editor.type("hi");
    const txId = changesOf(host.sent)[0]!.txId;

    freeze(host);
    await flush();
    await flush();
    expect(replies(host.sent)).toEqual([]);
    expect(editor.frozen).toBe(true); // nothing more can be typed while it drains

    release({ status: "acked", revision: 1 });
    await waitForReply(host);
    expect(replies(host.sent)[0]).toEqual({
      type: "frozenForClose", requestId: "f1", noteId: "n1", ok: true, editedSinceLoad: true, sha256: HI_SHA, lastAckedTxId: txId,
    });
  });

  test("a transaction that needs a resend is still waited for", async () => {
    const { host, editor } = open();
    let attempts = 0;
    host.reply = async () => {
      if (++attempts === 1) throw new Error("page hiccup");
      return { status: "acked", revision: 1 };
    };
    editor.type("hi");
    freeze(host);
    await waitForReply(host);
    expect(attempts).toBe(2);
    expect(replies(host.sent)[0]).toMatchObject({ ok: true, sha256: HI_SHA });
  });

  test("editedSinceLoad: false until a change touches the document, then true, also for the host's own change", async () => {
    const a = open();
    freeze(a.host);
    await waitForReply(a.host);
    expect(replies(a.host.sent)[0]!.editedSinceLoad).toBe(false);

    const b = open();
    b.editor.type("x");
    freeze(b.host);
    await waitForReply(b.host);
    expect(replies(b.host.sent)[0]!.editedSinceLoad).toBe(true);

    // Text that arrived from another window is not "untouched" either.
    const c = open();
    c.host.deliver({ type: "applyExternalChange", noteId: "n1", revision: 1, changeSet: ChangeSet.of({ from: 0, insert: "E" }, 0).toJSON() });
    freeze(c.host);
    await waitForReply(c.host);
    expect(replies(c.host.sent)[0]).toMatchObject({ editedSinceLoad: true, ok: true });
  });

  test("the flag survives a reload of the same note and starts over for another note", async () => {
    const { host, editor } = open();
    editor.type("x");
    await host.deliver({ type: "loadNote", noteId: "n1", text: "x", revision: 1, readOnly: false });
    freeze(host, "f1");
    await waitForReply(host);
    expect(replies(host.sent)[0]!.editedSinceLoad).toBe(true);

    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    await host.deliver({ type: "loadNote", noteId: "n2", text: "", revision: 0, readOnly: false });
    freeze(host, "f2", "n2");
    await waitForReply(host, 2);
    expect(replies(host.sent)[1]).toMatchObject({ noteId: "n2", ok: true, editedSinceLoad: false });
  });

  test("a host that never acknowledges gets ok:false after the timeout, and the editor stays frozen", async () => {
    const { host, editor, client } = open({ freezeTimeoutMs: 40 });
    host.reply = () => new Promise(() => {});
    editor.type("lost?");
    freeze(host);
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ requestId: "f1", noteId: "n1", ok: false, reason: "timeout", editedSinceLoad: true });
    expect(replies(host.sent)[0]!.sha256).toBeUndefined();
    expect(client.unackedCount).toBe(1);
    expect(editor.frozen).toBe(true);
  });

  test("an acknowledgement that comes after the timeout sends no second reply", async () => {
    const { host, editor } = open({ freezeTimeoutMs: 30 });
    let release: (reply: ChangesReply) => void = () => {};
    host.reply = () => new Promise<ChangesReply>((resolve) => { release = resolve; });
    editor.type("late");
    freeze(host);
    await waitForReply(host);
    release({ status: "acked", revision: 1 });
    await flush();
    await flush();
    expect(replies(host.sent)).toHaveLength(1);
    expect(replies(host.sent)[0]!.ok).toBe(false);
  });

  test("a halted bridge answers ok:false at once", async () => {
    const { host, editor } = open();
    host.reply = async () => ({ status: "needsFullText", currentRevision: 9 });
    editor.type("x");
    await flush();
    expect(host.sent.some((m) => m.type === "error")).toBe(true);
    freeze(host);
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ ok: false, reason: "halted" });
    expect(editor.freezes).toBe(0);
  });

  test("a halt while the freeze waits answers ok:false", async () => {
    const { host, editor } = open();
    let release: (reply: ChangesReply) => void = () => {};
    host.reply = () => new Promise<ChangesReply>((resolve) => { release = resolve; });
    editor.type("x");
    freeze(host);
    await flush();
    release({ status: "needsFullText", currentRevision: 9 });
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ ok: false, reason: "halted" });
  });

  test("a freeze for another note is refused and freezes nothing", async () => {
    const { host, editor } = open();
    freeze(host, "f1", "other");
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ requestId: "f1", noteId: "other", ok: false, reason: "notShown" });
    expect(editor.freezes).toBe(0);
  });

  test("a loadNote while the freeze waits answers ok:false and the new document is not frozen by it", async () => {
    const { host, editor } = open();
    host.reply = () => new Promise(() => {});
    editor.type("x");
    freeze(host);
    await flush();
    host.deliver({ type: "loadNote", noteId: "n2", text: "", revision: 0, readOnly: false });
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ noteId: "n1", ok: false, reason: "reloaded" });
    // The old request is gone: its unfreeze changes nothing.
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    expect(editor.unfreezes).toBe(0);
    expect(replies(host.sent)).toHaveLength(1);
  });

  test("a second request supersedes the first, which is answered ok:false", async () => {
    const { host, editor } = open();
    let release: (reply: ChangesReply) => void = () => {};
    host.reply = () => new Promise<ChangesReply>((resolve) => { release = resolve; });
    editor.type("hi");
    freeze(host, "f1");
    await flush();
    freeze(host, "f2");
    release({ status: "acked", revision: 1 });
    await waitForReply(host, 2);
    expect(replies(host.sent).map((r) => [r.requestId, r.ok, r.reason])).toEqual([
      ["f1", false, "superseded"],
      ["f2", true, undefined],
    ]);
  });

  test("a composition that has not ended by then keeps the note: ok:false, nothing frozen", async () => {
    const { host, editor } = open();
    editor.commitOutcome = false;
    freeze(host);
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ ok: false, reason: "composing" });
    expect(editor.frozen).toBe(false);
  });

  test("the editor freezes only after the composition ended, and the reply includes its text", async () => {
    const { host, editor } = open();
    let endComposition: (ended: boolean) => void = () => {};
    editor.commitOutcome = new Promise<boolean>((resolve) => { endComposition = resolve; });
    freeze(host);
    await flush();
    expect(editor.commits).toBe(1);
    expect(editor.frozen).toBe(false);
    editor.type("hi"); // the confirmed composition text
    endComposition(true);
    await waitForReply(host);
    expect(editor.frozen).toBe(true);
    expect(replies(host.sent)[0]).toMatchObject({ ok: true, sha256: HI_SHA, editedSinceLoad: true });
  });

  test("unfreeze with the request's ids restores; other ids change nothing", async () => {
    const { host, editor } = open();
    freeze(host);
    await waitForReply(host);
    host.deliver({ type: "unfreeze", requestId: "other", noteId: "n1" });
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "elsewhere" });
    expect(editor.unfreezes).toBe(0);
    expect(editor.frozen).toBe(true);
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    expect(editor.unfreezes).toBe(1);
    expect(editor.frozen).toBe(false);
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    expect(editor.unfreezes).toBe(1);
  });

  test("unfreeze while the request waits answers it ok:false", async () => {
    const { host, editor } = open();
    host.reply = () => new Promise(() => {});
    editor.type("x");
    freeze(host);
    await flush();
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    await waitForReply(host);
    expect(replies(host.sent)[0]).toMatchObject({ ok: false, reason: "unfrozen" });
  });

  test("after an unfreeze the same note can be frozen again", async () => {
    const { host, editor } = open();
    freeze(host, "f1");
    await waitForReply(host);
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    editor.type("more");
    freeze(host, "f2");
    await waitForReply(host, 2);
    expect(replies(host.sent)[1]).toMatchObject({ requestId: "f2", ok: true, editedSinceLoad: true });
    expect(editor.freezes).toBe(2);
  });

  // Fix round 1: the host's own changes are exempt from the editor's read-only filter, so the
  // client has to hold them while the freeze lasts.
  const external = (revision: number, insert: string, at: number) => ({
    type: "applyExternalChange" as const,
    noteId: "n1",
    revision,
    changeSet: ChangeSet.of({ from: at, insert }, at).toJSON(),
  });

  test("a host change that arrives while the editor is frozen waits for the unfreeze, in order", async () => {
    const { host, editor } = open();
    freeze(host);
    await waitForReply(host);

    host.deliver(external(1, "A", 0));
    host.deliver(external(2, "B", 1));
    expect(editor.text).toBe("");
    expect(replies(host.sent)).toHaveLength(1);

    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    expect(editor.text).toBe("AB");
    expect(host.sent.some((m) => m.type === "error")).toBe(false);
  });

  test("a host change that arrives while the freeze waits is held too, and the answer is for the document it drained", async () => {
    const { host, editor } = open();
    let release: (reply: ChangesReply) => void = () => {};
    host.reply = () => new Promise<ChangesReply>((resolve) => { release = resolve; });
    editor.type("hi");
    freeze(host);
    await flush();
    host.deliver(external(2, "!", 2)); // revision 2 follows the editor's own revision 1; it applies after the unfreeze
    release({ status: "acked", revision: 1 });
    await waitForReply(host);
    expect(editor.text).toBe("hi");
    expect(replies(host.sent)[0]).toMatchObject({ ok: true, sha256: HI_SHA });
  });

  test("held host changes are dropped by the next loadNote", async () => {
    const { host, editor } = open();
    freeze(host);
    await waitForReply(host);
    host.deliver(external(1, "A", 0));
    host.deliver({ type: "loadNote", noteId: "n1", text: "fresh", revision: 5, readOnly: false });
    host.deliver({ type: "unfreeze", requestId: "f1", noteId: "n1" });
    expect(editor.text).toBe("fresh");
  });

  test("without a freeze a host change applies at once", () => {
    const { host, editor } = open();
    host.deliver(external(1, "A", 0));
    expect(editor.text).toBe("A");
  });
});
