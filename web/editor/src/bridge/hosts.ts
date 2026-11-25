// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { ChangeSet, type ChangeSpec, Text } from "@codemirror/state";
import {
  type ChangesReply,
  type CompletionItem,
  type CompletionKind,
  type EditorToHost,
  type HostToEditor,
  isChangesReply,
  isHostToEditor,
} from "./protocol";
import { attachmentLink } from "../editor/features/attachments";

export interface Host {
  send(msg: EditorToHost): Promise<ChangesReply | void>;
  onMessage(cb: (msg: HostToEditor) => void | Promise<void>): void;
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { bridge?: { postMessage(msg: unknown): Promise<unknown> } } };
    __baerchen?: Record<string, unknown>;
  }
}

/** Adds entries to `window.__baerchen`, the Swift → JS entry point. */
export function exposeGlobal(entries: Record<string, unknown>): void {
  window.__baerchen = Object.assign(window.__baerchen ?? {}, entries);
}

/** Real host: JS → Swift via WKScriptMessageHandlerWithReply, Swift → JS via `window.__baerchen.receive(msg)`. */
export class WebKitHost implements Host {
  private cb: ((msg: HostToEditor) => void | Promise<void>) | null = null;

  constructor() {
    exposeGlobal({ receive: (msg: unknown) => this.receive(msg) });
  }

  static isAvailable(): boolean {
    return typeof window !== "undefined" && !!window.webkit?.messageHandlers?.bridge;
  }

  async send(msg: EditorToHost): Promise<ChangesReply | void> {
    const bridge = window.webkit?.messageHandlers?.bridge;
    if (!bridge) throw new Error("WebKit bridge unavailable");
    const reply = await bridge.postMessage(msg);
    if (msg.type !== "changes" && msg.type !== "recoveryText") return;
    if (!isChangesReply(reply)) throw new Error(`invalid changes reply: ${JSON.stringify(reply)}`);
    return reply;
  }

  onMessage(cb: (msg: HostToEditor) => void | Promise<void>): void {
    this.cb = cb;
  }

  private receive(msg: unknown): void | Promise<void> {
    if (!isHostToEditor(msg)) {
      void this.send({ type: "error", message: `invalid host message: ${JSON.stringify(msg)}` }).catch(() => {});
      return;
    }
    return this.cb?.(msg);
  }
}

/** In-memory stand-in for the Swift NoteSession (vitest and `index.html?mock`). */
export class MockHost implements Host {
  readonly recoveryCopies: { noteId: string; baseRevision: number; text: string }[] = [];
  readonly noteId: string;
  revision = 0;
  readonly sent: EditorToHost[] = [];
  /** When true, `changes` sends reject (simulates a failing Swift side). */
  offline = false;
  /**
   * What `requestCompletions` is answered with: the kind's items whose label contains the query
   * (case-insensitive), in order. Empty by default.
   */
  completions: Partial<Record<CompletionKind, CompletionItem[]>> = {};
  private doc: Text;
  private readonly seen = new Set<string>();
  private cb: ((msg: HostToEditor) => void | Promise<void>) | null = null;

  constructor(opts: { noteId?: string; text?: string } = {}) {
    this.noteId = opts.noteId ?? "mock-note";
    this.doc = Text.of((opts.text ?? "").split("\n"));
  }

  get text(): string {
    return this.doc.toString();
  }

  async send(msg: EditorToHost): Promise<ChangesReply | void> {
    this.sent.push(msg);
    if (msg.type === "ready") queueMicrotask(() => this.loadNote());
    if (msg.type === "insertAttachments" && msg.noteId === this.noteId) {
      // Like the Swift host: the files are stored under their names, the Markdown goes into the
      // pending insert.
      const text = msg.items.map((item) => attachmentLink(item.filename)).join("\n");
      this.deliver({ type: "applyCommand", name: "insertText", args: { text, insertId: msg.insertId } });
    }
    if (msg.type === "pasteAttachments" && msg.noteId === this.noteId) {
      // The mock has no files to collide with: the text goes in unchanged.
      this.deliver({ type: "applyCommand", name: "insertText", args: { text: msg.text, insertId: msg.insertId } });
    }
    if (msg.type === "requestCompletions") {
      const query = msg.query.toLowerCase();
      const items = (this.completions[msg.kind] ?? []).filter((item) => item.label.toLowerCase().includes(query));
      setTimeout(() => this.deliver({ type: "completionResults", requestId: msg.requestId, items }));
    }
    if (msg.type === "recoveryText") {
      if (this.offline) throw new Error("mock host offline");
      this.recoveryCopies.push({ noteId: msg.noteId, baseRevision: msg.baseRevision, text: msg.text });
      return { status: "acked", revision: msg.baseRevision };
    }
    if (msg.type !== "changes") return;
    if (this.offline) throw new Error("mock host offline");
    if (this.seen.has(msg.txId)) return { status: "duplicate", revision: this.revision };
    if (msg.noteId !== this.noteId || msg.baseRevision !== this.revision) {
      return { status: "needsFullText", currentRevision: this.revision };
    }
    this.doc = ChangeSet.fromJSON(msg.changeSet).apply(this.doc);
    this.seen.add(msg.txId);
    this.revision += 1;
    return { status: "acked", revision: this.revision };
  }

  onMessage(cb: (msg: HostToEditor) => void | Promise<void>): void {
    this.cb = cb;
  }

  deliver(msg: HostToEditor): void | Promise<void> {
    return this.cb?.(msg);
  }

  loadNote(): void {
    this.deliver({ type: "loadNote", noteId: this.noteId, text: this.text, revision: this.revision, readOnly: false });
  }

  /** Simulates a CLI/MCP edit while the note is open (R1: revision + 1). */
  externalEdit(spec: ChangeSpec): void {
    const changes = ChangeSet.of(spec, this.doc.length);
    this.doc = changes.apply(this.doc);
    this.revision += 1;
    this.deliver({ type: "applyExternalChange", noteId: this.noteId, revision: this.revision, changeSet: changes.toJSON() });
  }
}
