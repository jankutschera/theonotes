// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import {
  Annotation,
  ChangeSet,
  EditorSelection,
  type EditorState,
  Transaction,
  type TransactionSpec,
} from "@codemirror/state";
import { isolateHistory } from "@codemirror/commands";
import { searchHighlightTransaction } from "../editor/features/search-highlight";
import { revealEffects } from "../editor/features/folding";
import { removePendingInsert } from "../editor/features/attachments";
import { type CompletionBridge, tagIconsChanged } from "../editor/features/autocomplete";
import type { Host } from "./hosts";
import {
  type AttachmentUpload,
  type CalloutType,
  type CaretRect,
  type CommandArgs,
  type CommandName,
  type CompletionItem,
  type CompletionKind,
  type EditLinkFields,
  type EditorSettings,
  type EditorToHost,
  type FoldEntry,
  type FormatStateFields,
  type FreezeFailure,
  type HostToEditor,
  isChangesReply,
  MAX_FOLDS,
  type OpenLinkFields,
  sanitizeFolds,
  type SelectionRange,
} from "./protocol";

/**
 * The host's "no note" document (EditorBridgeController.placeholderLoad): loaded locked. Both
 * sides pin it to Fixtures/bridge/messages-loadNote-placeholder.json.
 */
export const PLACEHOLDER_NOTE_ID = "";

/** Marks transactions that came from the host so they are not echoed back. */
export const externalChange = Annotation.define<boolean>();

export type LoadedDocument = {
  /** The note shown (attachment URLs); absent in tests that need none. */
  noteId?: string;
  text: string;
  readOnly: boolean;
  /** No note at all (the host's empty placeholder, `noteId` ""): not even focusable. */
  locked?: boolean;
  selection?: SelectionRange;
  scrollTop?: number;
  /** The note's stored folds (M6 Task 8 applies them). */
  foldState?: FoldEntry[];
};

/** The slice of the editor the client needs; `viewHandle()` adapts an EditorView. */
export interface EditorHandle {
  readonly state: EditorState;
  dispatch(spec: TransactionSpec): void;
  load(doc: LoadedDocument): void;
  setReadOnly(readOnly: boolean): void;
  focus(): void;
  /** Runs a registry command (commands.ts); false when it did nothing. */
  command(name: CommandName, args?: CommandArgs): boolean;
  /** Caret onto the `index`-th heading (NoteParser order), scrolled into view; false if there is none. */
  scrollToHeading(index: number): boolean;
  /** Closes the completion popup, if open. */
  closeCompletion?(): void;
  /** `setSettings`, applied in place (no reload); missing fields keep their value. */
  applySettings(settings: EditorSettings): void;
  /**
   * Ends an active IME composition so that its text is part of the document, like any edit (a
   * composition cannot be cancelled once the editor is read-only). Resolves true when none is
   * active or it ended, false when it was still going on after the wait.
   */
  commitComposition(): Promise<boolean>;
  /** Capture close: the read-only compartment goes to "locked"; the mode it had is remembered. */
  freeze(): void;
  /** Undoes `freeze`: the remembered mode comes back (a read-only note stays read-only). */
  unfreeze(): void;
}

export type BridgeClientOptions = {
  /** Computes the Format menu state; without it no `formatState` is posted. */
  formatState?: (state: EditorState) => FormatStateFields;
  /** How long a `freezeForClose` may take, composition and drain together (default FREEZE_TIMEOUT_MS). */
  freezeTimeoutMs?: number;
};

/** A `freezeForClose` that has not drained by then is answered ok:false (the host keeps the note). */
export const FREEZE_TIMEOUT_MS = 2000;

/** One `freezeForClose` from the host, from its request to its `unfreeze` or the next `loadNote`. */
type Freeze = {
  requestId: string;
  noteId: string;
  /** The compartment has been switched (a failed or superseded request may leave it unswitched). */
  frozen: boolean;
  /** The reply has been sent (once, ok or not). */
  replied: boolean;
  timer: ReturnType<typeof setTimeout> | null;
};

/** `formatState` is posted this long after the last selection or document change. */
export const FORMAT_STATE_DELAY_MS = 50;

type ChangesMessage = Extract<EditorToHost, { type: "changes" }>;

/** A completion request the host has not answered by then counts as unanswered. */
export const COMPLETION_TIMEOUT_MS = 3000;

let completionSeq = 0;
const completionPrefix = Math.random().toString(36).slice(2, 8);

/** Delays before each resend round of the unacked queue; after the last one the client halts. */
export const RESEND_DELAYS_MS = [100, 300, 1000] as const;

type Outcome = { kind: "acked" } | { kind: "retry"; reason: string } | { kind: "fatal"; reason: string };

export class BridgeClient {
  private noteId: string | null = null;
  private revision = 0;
  /** Sent but not yet acknowledged, in send order. Resent verbatim (same txIds) after a failure. */
  private unacked: ChangesMessage[] = [];
  private recoveryPending = false;
  private halting = false;
  private haltTask: Promise<void> | null = null;
  private recoveryTask: Promise<void> | null = null;
  private recoveryLoad: Extract<HostToEditor, { type: "loadNote" }> | null = null;
  /** A send failed: new changes are only queued until a resend round drains the queue. */
  private blocked = false;
  private resending = false;
  private resendAttempt = 0;
  private resendTimer: ReturnType<typeof setTimeout> | null = null;
  /** Terminal: the editor is read-only until the next loadNote (R2/R14). */
  private halted = false;
  /** Bumped on every loadNote so replies for a previous load are ignored. */
  private generation = 0;
  private formatTimer: ReturnType<typeof setTimeout> | null = null;
  /** The last posted format state (JSON), so an unchanged one is not posted again. */
  private lastFormatState: string | null = null;
  /** The latest completion request; answers to any other request id are stale and ignored. */
  private pendingCompletion: { requestId: string; settle(items: readonly CompletionItem[] | null): void } | null = null;
  private autocompleteEnabled = true;
  private tagIconMap: ReadonlyMap<string, string> = new Map();
  /**
   * Any change (typed, programmatic or the host's own) has touched the shown note's document since
   * it was loaded. Starts over when a different note loads; a reload of the same note keeps it.
   */
  private editedSinceLoad = false;
  /** The latest transaction the host acknowledged since the last loadNote. */
  private lastAckedTxId: string | null = null;
  /** The freeze the host asked for (capture close), until its unfreeze or the next loadNote. */
  private freezeState: Freeze | null = null;
  /** The host's changes that arrived while the editor was frozen, applied in order at the unfreeze. */
  private heldExternal: { changeSet: unknown; revision: number }[] = [];

  /** The editor's completion source talks to the host through this (autocomplete.ts). */
  readonly completionBridge: CompletionBridge = {
    request: (kind, query, noteTitle) => this.requestCompletions(kind, query, noteTitle),
    enabled: () => this.autocompleteEnabled,
    tagIcons: () => this.tagIconMap,
  };

  constructor(
    private readonly host: Host,
    private readonly editor: () => EditorHandle,
    private readonly options: BridgeClientOptions = {},
  ) {}

  get unackedCount(): number {
    return this.unacked.length;
  }

  handleHostMessage(msg: HostToEditor): void | Promise<void> {
    switch (msg.type) {
      case "loadNote":
        if (this.halting) {
          this.recoveryLoad = msg;
          return this.haltTask ?? Promise.reject(new Error("editor halt is not ready"));
        }
        if (this.recoveryPending || this.unacked.length > 0 || this.halted) {
          this.recoveryLoad = msg;
          if (!this.recoveryPending) {
            this.recoveryTask = this.preserveBeforeLoad();
            void this.recoveryTask.catch(() => {});
          }
          return this.recoveryTask ?? Promise.reject(new Error("privacy recovery is in progress"));
        }
        this.dropFreeze("reloaded");
        if (msg.noteId !== this.noteId) this.editedSinceLoad = false;
        this.lastAckedTxId = null;
        this.generation++;
        this.noteId = msg.noteId;
        this.revision = msg.revision;
        this.unacked = [];
        this.blocked = false;
        this.resending = false;
        this.resendAttempt = 0;
        if (this.resendTimer !== null) clearTimeout(this.resendTimer);
        this.resendTimer = null;
        this.halted = false;
        this.pendingCompletion?.settle(null);
        this.editor().load({
          noteId: msg.noteId,
          text: msg.text,
          readOnly: msg.readOnly,
          ...(msg.noteId === PLACEHOLDER_NOTE_ID && { locked: true }),
          ...(msg.selection && { selection: msg.selection }),
          ...(msg.scrollTop !== undefined && { scrollTop: msg.scrollTop }),
          ...(msg.foldState && { foldState: sanitizeFolds(msg.foldState) }),
        });
        this.lastFormatState = null;
        this.scheduleFormatState();
        return;
      case "applyExternalChange":
        if (msg.noteId !== this.noteId) return;
        // The editor's read-only filter lets the host's own changes through, so a frozen document
        // is held still here: the answer to the freeze is about exactly the document it drained.
        if (this.freezeState?.frozen) this.heldExternal.push({ changeSet: msg.changeSet, revision: msg.revision });
        else this.applyExternalChange(msg.changeSet, msg.revision);
        return;
      case "setRevision":
        if (msg.noteId === this.noteId) this.revision = msg.revision;
        return;
      case "focus":
        this.editor().focus();
        return;
      case "requestChecksum":
        void this.sendChecksum(msg.requestId);
        return;
      case "searchHighlight":
        if (msg.noteId === this.noteId) this.editor().dispatch(searchHighlightTransaction(this.editor().state, msg.terms));
        return;
      case "applyCommand":
        this.editor().command(msg.name, msg.args);
        return;
      case "scrollToHeading":
        if (msg.noteId === this.noteId) this.editor().scrollToHeading(msg.index);
        return;
      case "selectRange":
        if (msg.noteId === this.noteId) this.selectRange(msg.anchor, msg.head);
        return;
      case "completionResults":
        if (this.pendingCompletion?.requestId === msg.requestId) this.pendingCompletion.settle(msg.items);
        return;
      case "tagIcons":
        this.tagIconMap = new Map(Object.entries(msg.icons));
        this.editor().dispatch({ effects: tagIconsChanged.of(null) });
        return;
      case "freezeForClose":
        this.beginFreeze(msg.requestId, msg.noteId);
        return;
      case "unfreeze":
        this.endFreeze(msg.requestId, msg.noteId);
        return;
      case "setSettings": {
        // Kept across loadNote (and before the first one), so not tied to a note. `autocomplete`
        // is the completion bridge's; the rest reconfigures the editor (settings.ts).
        const { type: _type, ...settings } = msg;
        if (settings.autocomplete !== undefined && settings.autocomplete !== this.autocompleteEnabled) {
          this.autocompleteEnabled = settings.autocomplete;
          if (!settings.autocomplete) {
            this.pendingCompletion?.settle(null);
            this.editor().closeCompletion?.();
          }
        }
        this.editor().applySettings(settings);
        return;
      }
    }
  }

  /**
   * Asks the host for completions. Resolves with its answer, or null when a newer request
   * supersedes this one, the note changes, the setting is off or no answer comes in time.
   */
  requestCompletions(kind: CompletionKind, query: string, noteTitle?: string): Promise<readonly CompletionItem[] | null> {
    this.pendingCompletion?.settle(null);
    const noteId = this.noteId;
    if (noteId === null || !this.autocompleteEnabled) return Promise.resolve(null);
    const requestId = `complete-${completionPrefix}-${++completionSeq}`;
    return new Promise((resolve) => {
      const entry = {
        requestId,
        settle: (items: readonly CompletionItem[] | null) => {
          clearTimeout(timer);
          if (this.pendingCompletion === entry) this.pendingCompletion = null;
          resolve(items);
        },
      };
      const timer = setTimeout(() => entry.settle(null), COMPLETION_TIMEOUT_MS);
      this.pendingCompletion = entry;
      void this.post({
        type: "requestCompletions",
        noteId,
        requestId,
        kind,
        query,
        ...(noteTitle !== undefined && { noteTitle }),
      });
    });
  }

  private scrollTimers = new Map<string, ReturnType<typeof setTimeout>>();

  scrollChanged(scrollTop: number): void {
    const noteId = this.noteId;
    if (!noteId || !Number.isFinite(scrollTop)) return;
    const previous = this.scrollTimers.get(noteId);
    if (previous !== undefined) clearTimeout(previous);
    this.scrollTimers.set(noteId, setTimeout(() => {
      this.scrollTimers.delete(noteId);
      void this.post({ type: "scrollChanged", noteId, scrollTop: Math.max(0, scrollTop) });
    }, 100));
  }

  onTransaction(tr: Transaction): void {
    if (this.noteId === null) return;
    if (tr.docChanged) this.editedSinceLoad = true;
    if (tr.annotation(externalChange)) return;
    if (tr.docChanged && !this.halted) this.queueChanges(tr);
    const selectionMoved = !!tr.selection && !tr.selection.main.eq(tr.startState.selection.main);
    if (selectionMoved) {
      const { anchor, head } = tr.state.selection.main;
      void this.post({ type: "selectionChanged", noteId: this.noteId, anchor, head });
    }
    if (tr.docChanged || selectionMoved) this.scheduleFormatState();
  }

  /** Posts the Format menu state once the selection rests for FORMAT_STATE_DELAY_MS. */
  private scheduleFormatState(): void {
    if (!this.options.formatState) return;
    if (this.formatTimer !== null) clearTimeout(this.formatTimer);
    this.formatTimer = setTimeout(() => {
      this.formatTimer = null;
      this.postFormatState();
    }, FORMAT_STATE_DELAY_MS);
  }

  private postFormatState(): void {
    const compute = this.options.formatState;
    if (!compute || this.noteId === null) return;
    let fields: FormatStateFields;
    try {
      fields = compute(this.editor().state);
    } catch (err) {
      return this.reportError("format state failed", err);
    }
    const msg: EditorToHost = { type: "formatState", noteId: this.noteId, ...fields };
    const json = JSON.stringify(msg);
    if (json === this.lastFormatState) return;
    this.lastFormatState = json;
    void this.post(msg);
  }

  /** `selectRange`: selects the range and scrolls it into view; a range outside the document does nothing. */
  private selectRange(anchor: number, head: number): void {
    const { state } = this.editor();
    if (anchor > state.doc.length || head > state.doc.length) return;
    // The folds the range reaches open.
    const effects = revealEffects(state, Math.min(anchor, head), Math.max(anchor, head));
    this.editor().dispatch({ selection: EditorSelection.single(anchor, head), effects, scrollIntoView: true, userEvent: "select" });
  }

  /** Asks the host for the heading menu of the heading on `line` (1-based); `menuId` names the remembered target. */
  headingMenu(menuId: string, line: number, level: number, folded: boolean, rect: CaretRect): void {
    if (this.noteId === null) return;
    void this.post({ type: "headingMenu", noteId: this.noteId, menuId, line, level, folded, rect });
  }

  /** The cell menu of a table: `row` 0 is the header. */
  tableMenu(menuId: string, row: number, column: number, rows: number, columns: number, rect: CaretRect): void {
    if (this.noteId === null) return;
    void this.post({ type: "tableMenu", noteId: this.noteId, menuId, row, column, rows, columns, rect });
  }

  /** The type menu of a callout. */
  calloutMenu(menuId: string, calloutType: CalloutType, rect: CaretRect): void {
    if (this.noteId === null) return;
    void this.post({ type: "calloutMenu", noteId: this.noteId, menuId, calloutType, rect });
  }

  /** The note's folds changed: the host stores them for the next `loadNote`. */
  foldState(folds: FoldEntry[]): void {
    if (this.noteId === null) return;
    void this.post({ type: "foldState", noteId: this.noteId, folds: folds.slice(0, MAX_FOLDS) });
  }

  /** A link to open (⌘-click, link icon, ⇧⌘K); the host decides what it opens. */
  openLink(link: OpenLinkFields): void {
    if (this.noteId === null) return;
    void this.post({ type: "openLink", noteId: this.noteId, ...link });
  }

  /** ⌘K: asks the host for its link panel. */
  editLinkRequest(request: EditLinkFields): void {
    if (this.noteId === null) return;
    void this.post({ type: "editLinkRequest", noteId: this.noteId, ...request });
  }

  /** Space / double click on an attachment: the host's Quick Look panel. */
  quickLook(filename: string): void {
    if (this.noteId === null) return;
    void this.post({ type: "quickLook", noteId: this.noteId, filename });
  }

  /** An explicit touch tap carries the exact source for safe attachment editing. */
  attachmentTap(filename: string, from: number, to: number, source: string): void {
    if (this.noteId === null) return;
    void this.post({ type: "attachmentTap", noteId: this.noteId, filename, from, to, source });
  }

  /** The host's context menu for the attachment at `[from, to)`. */
  attachmentMenu(filename: string, from: number, to: number, source: string): void {
    if (this.noteId === null) return;
    void this.post({ type: "attachmentMenu", noteId: this.noteId, filename, from, to, source });
  }

  /** Files over the size caps: the host tells the user (and points to ⇧⌘V). */
  attachmentsRefused(filenames: string[]): void {
    if (this.noteId === null || filenames.length === 0) return;
    void this.post({ type: "attachmentsRefused", noteId: this.noteId, reason: "tooLarge", filenames });
  }

  /** Attachment links copied or cut: the host keeps their files for the paste (R30). */
  attachmentsCopied(filenames: string[]): void {
    if (this.noteId === null || filenames.length === 0) return;
    void this.post({ type: "cutAttachments", noteId: this.noteId, filenames });
  }

  /** Attachment links pasted from another note (attachments.ts `pasteAttachmentLinks`). */
  pasteAttachments(insertId: string, sourceNoteId: string, text: string, items: { from: number; to: number; filename: string }[]): void {
    if (this.noteId === null) return;
    void this.sendInsert(insertId, { type: "pasteAttachments", noteId: this.noteId, insertId, sourceNoteId, text, items });
  }

  /** A pending insert the host will never answer (read failure, rejected message) is dropped. */
  private dropInsert(insertId: string): void {
    try {
      this.editor().dispatch({ effects: removePendingInsert.of(insertId) });
    } catch {
      // The editor was reloaded meanwhile: the insert is gone with its state.
    }
  }

  private async sendInsert(insertId: string, msg: EditorToHost): Promise<void> {
    try {
      await this.host.send(msg);
    } catch {
      this.dropInsert(insertId);
    }
  }

  /**
   * Sends dropped or pasted files to the host, which stores them and answers with the Markdown
   * for the pending insert `insertId`. Dropped when the note changed while the files were read.
   */
  async insertAttachments(insertId: string, files: readonly File[]): Promise<void> {
    const noteId = this.noteId;
    if (noteId === null || files.length === 0) return;
    let items: AttachmentUpload[];
    try {
      items = await Promise.all(files.map(async (file) => ({
        filename: uploadName(file),
        dataBase64: base64(new Uint8Array(await file.arrayBuffer())),
      })));
    } catch (err) {
      if (import.meta.env.DEV) console.warn("[baerchen] attachment not read", err);
      return this.dropInsert(insertId);
    }
    if (noteId !== this.noteId) return;
    await this.sendInsert(insertId, { type: "insertAttachments", noteId, insertId, items });
  }

  /** Copy Code / Copy Table As: the host writes `text` (and `html`, if given) to the pasteboard (also for read-only notes). */
  copyText(text: string, html?: string): void {
    void this.post({ type: "copyText", text, ...(html !== undefined && { html }) });
  }

  /** Privacy close may save the full browser document within its existing deadline. */
  async preserveForPrivacy(noteId: string): Promise<boolean> {
    if (this.noteId !== noteId || this.recoveryPending || this.halting) return false;
    const generation = this.generation;
    const baseRevision = this.unacked[0]?.baseRevision ?? this.revision;
    this.recoveryPending = true;
    this.halted = true;
    if (this.resendTimer !== null) clearTimeout(this.resendTimer);
    this.resendTimer = null;
    try {
      if (!await this.editor().commitComposition() || generation !== this.generation || this.noteId !== noteId) return false;
      this.editor().setReadOnly(true);
      const text = this.editor().state.doc.toString();
      const reply = await this.host.send({ type: "recoveryText", noteId, baseRevision, text });
      return isChangesReply(reply) && reply.status === "acked" && reply.revision === baseRevision &&
        generation === this.generation && this.noteId === noteId && this.editor().state.doc.toString() === text;
    } catch { return false; }
    finally { this.recoveryPending = false; }
  }

  private async preserveBeforeLoad(): Promise<void> {
    const noteId = this.noteId;
    const baseRevision = this.unacked[0]?.baseRevision ?? this.revision;
    if (noteId === null) {
      if (this.unacked.length > 0) throw new Error("unacknowledged edits have no source note");
      const load = this.recoveryLoad;
      this.recoveryLoad = null;
      this.halted = false;
      if (load) await this.handleHostMessage(load);
      return;
    }
    this.recoveryPending = true;
    this.halted = true;
    if (this.resendTimer !== null) clearTimeout(this.resendTimer);
    this.resendTimer = null;
    const generation = this.generation;
    try {
      if (!await this.editor().commitComposition()) throw new Error("composition is still active");
      if (generation !== this.generation || this.noteId !== noteId) throw new Error("the editor changed during composition");
      this.editor().setReadOnly(true);
      const text = this.editor().state.doc.toString();
      const reply = await this.host.send({ type: "recoveryText", noteId, baseRevision, text });
      if (!isChangesReply(reply) || reply.status !== "acked" || reply.revision !== baseRevision) {
        throw new Error("recovery copy was not acknowledged");
      }
      if (generation !== this.generation || this.noteId !== noteId || this.editor().state.doc.toString() !== text) {
        throw new Error("the browser document changed during recovery");
      }
      const load = this.recoveryLoad;
      this.recoveryLoad = null;
      this.recoveryPending = false;
      this.recoveryTask = null;
      this.unacked = [];
      this.halted = false;
      if (load) this.handleHostMessage(load);
    } catch (err) {
      this.recoveryPending = false;
      this.recoveryTask = null;
      this.recoveryLoad = null;
      this.reportError("Reload blocked: unsaved browser text could not be preserved. Keep this note open.", err);
      throw err;
    }
  }

  private queueChanges(tr: Transaction): void {
    const msg: ChangesMessage = {
      type: "changes",
      noteId: this.noteId!,
      txId: newTxId(),
      baseRevision: this.revision,
      revision: this.revision + 1,
      changeSet: tr.changes.toJSON(),
    };
    this.revision = msg.revision;
    this.unacked.push(msg);
    if (this.blocked) return; // the pending resend round will pick it up in order
    const generation = this.generation;
    this.exchange(msg).then((outcome) => {
      if (generation === this.generation) this.settle(msg, outcome);
    });
  }

  /** Sends one message and classifies the reply; never rejects. */
  private async exchange(msg: ChangesMessage): Promise<Outcome> {
    let reply: unknown;
    try {
      reply = await this.host.send(msg);
    } catch (err) {
      return { kind: "retry", reason: `changes ${msg.txId} failed${describe(err)}` };
    }
    if (!isChangesReply(reply)) return { kind: "retry", reason: `changes ${msg.txId} got no valid reply` };
    if (reply.status !== "needsFullText") return { kind: "acked" };
    // The host is behind this message: an earlier one failed and will be resent.
    if (reply.currentRevision < msg.baseRevision) {
      return { kind: "retry", reason: `host at revision ${reply.currentRevision} is behind ${msg.baseRevision}` };
    }
    return { kind: "fatal", reason: `host needs full text (host revision ${reply.currentRevision}, editor ${this.revision})` };
  }

  private settle(msg: ChangesMessage, outcome: Outcome): void {
    if (this.halted) return;
    if (outcome.kind === "acked") {
      this.unacked = this.unacked.filter((m) => m.txId !== msg.txId);
      this.lastAckedTxId = msg.txId;
      this.drainChecked();
    } else if (outcome.kind === "fatal") {
      this.halt(outcome.reason);
    } else {
      this.blocked = true;
      this.scheduleResend(outcome.reason);
    }
  }

  private scheduleResend(reason: string): void {
    if (this.halted || this.resending || this.resendTimer !== null) return;
    const delay = RESEND_DELAYS_MS[this.resendAttempt];
    if (delay === undefined) return this.halt(`giving up after ${this.resendAttempt} resends: ${reason}`);
    this.resendAttempt++;
    const generation = this.generation;
    this.resendTimer = setTimeout(() => {
      this.resendTimer = null;
      if (generation === this.generation) void this.resend(generation);
    }, delay);
  }

  /** Resends the unacked queue one message at a time, in order, with the original txIds. */
  private async resend(generation: number): Promise<void> {
    this.resending = true;
    for (;;) {
      const msg = this.unacked[0];
      if (!msg) break;
      const outcome = await this.exchange(msg);
      if (generation !== this.generation || this.halted) return;
      if (outcome.kind === "acked") {
        this.unacked = this.unacked.filter((m) => m.txId !== msg.txId);
        this.lastAckedTxId = msg.txId;
        this.drainChecked();
        continue;
      }
      this.resending = false;
      if (outcome.kind === "fatal") return this.halt(outcome.reason);
      return this.scheduleResend(outcome.reason);
    }
    this.resending = false;
    this.blocked = false;
    this.resendAttempt = 0;
  }

  private applyExternalChange(json: unknown, revision: number): void {
    // R1: the host bumps its revision by exactly one per external change, so
    // the change is based on revision - 1. If we are ahead (unacked local
    // edits the host has not applied), applying it would corrupt the doc;
    // halt and wait for the host to reload the note.
    if (this.halted) return;
    if (revision - 1 !== this.revision) {
      return this.halt(`external change for revision ${revision} does not follow editor revision ${this.revision}`);
    }
    try {
      // R9: never a CodeMirror undo step (store rewrites are undone through app-level undo
      // records); the history maps its events through the change.
      this.editor().dispatch({
        changes: ChangeSet.fromJSON(json),
        annotations: [
          externalChange.of(true),
          isolateHistory.of("full"),
          Transaction.addToHistory.of(false),
          Transaction.remote.of(true),
        ],
      });
      this.revision = revision;
      this.scheduleFormatState();
    } catch (err) {
      this.halt("could not apply external change", err);
    }
  }

  private async sendChecksum(requestId: string): Promise<void> {
    if (this.noteId === null) return;
    const noteId = this.noteId;
    try {
      const sha256 = await sha256Hex(this.editor().state.doc.toString());
      await this.post({ type: "checksum", requestId, noteId, sha256 });
    } catch (err) {
      this.reportError("checksum failed", err);
    }
  }

  /**
   * Terminal stop until the next loadNote: the editor becomes read-only so no
   * keystroke is accepted that cannot reach the host, and one error is posted
   * (the host answers with a fresh loadNote).
   */
  private halt(message: string, err?: unknown): void {
    if (this.halted || this.halting) return;
    this.halting = true;
    this.blocked = true;
    if (this.resendTimer !== null) clearTimeout(this.resendTimer);
    this.resendTimer = null;
    const freeze = this.freezeState;
    if (freeze) this.answerFreeze(freeze, "halted");
    const generation = this.generation;
    this.haltTask = (async () => {
      let ended = false;
      try { ended = await this.editor().commitComposition(); } catch { /* keep browser text */ }
      if (generation !== this.generation) return;
      this.halting = false;
      this.halted = true;
      if (!ended) {
        this.editor().setReadOnly(true);
        this.recoveryLoad = null;
        this.reportError("Reload blocked: unsaved browser text could not be preserved. Keep this note open.");
        throw new Error("composition could not be preserved");
      }
      this.editor().setReadOnly(true);
      this.reportError(message, err);
      const load = this.recoveryLoad;
      this.recoveryLoad = null;
      if (load) await this.handleHostMessage(load);
    })();
    void this.haltTask.catch(() => {});
  }

  // MARK: capture close (W1)

  /**
   * `freezeForClose`: ends an active composition, then switches the editor to read-only and waits
   * until every transaction sent so far is acknowledged. Answers once, with `frozenForClose`.
   */
  private beginFreeze(requestId: string, noteId: string): void {
    if (this.noteId === null || noteId !== this.noteId) {
      return this.postFrozen({ requestId, noteId, ok: false, editedSinceLoad: true, reason: "notShown" });
    }
    const previous = this.freezeState;
    if (previous?.requestId === requestId) return;
    if (previous) this.answerFreeze(previous, "superseded");
    if (this.halted || this.halting) {
      this.freezeState = null;
      return this.postFrozen({ requestId, noteId, ok: false, editedSinceLoad: this.editedSinceLoad, reason: "halted" });
    }
    const freeze: Freeze = { requestId, noteId, frozen: previous?.frozen ?? false, replied: false, timer: null };
    freeze.timer = setTimeout(() => this.answerFreeze(freeze, "timeout"), this.options.freezeTimeoutMs ?? FREEZE_TIMEOUT_MS);
    this.freezeState = freeze;
    void this.runFreeze(freeze);
  }

  private async runFreeze(freeze: Freeze): Promise<void> {
    let ended = false;
    try {
      ended = await this.editor().commitComposition();
    } catch {
      // A composition that cannot be ended counts as not ended.
    }
    if (this.freezeState !== freeze || freeze.replied) return;
    if (!ended) return this.answerFreeze(freeze, "composing");
    if (!freeze.frozen) {
      this.editor().freeze();
      freeze.frozen = true;
    }
    this.drainChecked();
  }

  /** The freeze answers ok once the editor is frozen and nothing it sent is unacknowledged. */
  private drainChecked(): void {
    const freeze = this.freezeState;
    if (freeze?.frozen && !freeze.replied && this.unacked.length === 0) this.answerFreeze(freeze, "ok");
  }

  private answerFreeze(freeze: Freeze, outcome: "ok" | FreezeFailure): void {
    if (freeze.replied) return;
    freeze.replied = true;
    if (freeze.timer !== null) clearTimeout(freeze.timer);
    freeze.timer = null;
    const { requestId, noteId } = freeze;
    if (outcome !== "ok") {
      return this.postFrozen({ requestId, noteId, ok: false, editedSinceLoad: this.editedSinceLoad, reason: outcome });
    }
    const lastAckedTxId = this.lastAckedTxId;
    void sha256Hex(this.editor().state.doc.toString()).then(
      (sha256) => {
        // A loadNote that came meanwhile replaced the document the hash is of.
        if (this.freezeState !== freeze) {
          return this.postFrozen({ requestId, noteId, ok: false, editedSinceLoad: this.editedSinceLoad, reason: "reloaded" });
        }
        this.postFrozen({
          requestId, noteId, ok: true, editedSinceLoad: this.editedSinceLoad, sha256,
          ...(lastAckedTxId !== null && { lastAckedTxId }),
        });
      },
      (err: unknown) => {
        this.reportError("freeze checksum failed", err);
        this.postFrozen({ requestId, noteId, ok: false, editedSinceLoad: this.editedSinceLoad, reason: "halted" });
      },
    );
  }

  private postFrozen(fields: Omit<Extract<EditorToHost, { type: "frozenForClose" }>, "type">): void {
    void this.post({ type: "frozenForClose", ...fields });
  }

  /** `unfreeze`: the request's own ids only; a pending request is answered ok:false first. */
  private endFreeze(requestId: string, noteId: string): void {
    const freeze = this.freezeState;
    if (!freeze || freeze.requestId !== requestId || freeze.noteId !== noteId) return;
    this.freezeState = null;
    this.answerFreeze(freeze, "unfrozen");
    if (freeze.frozen && !this.halted) this.editor().unfreeze();
    const held = this.heldExternal;
    this.heldExternal = [];
    for (const change of held) this.applyExternalChange(change.changeSet, change.revision);
  }

  /** A new document replaces the frozen one: the request is over, the new state is whatever loadNote says. */
  private dropFreeze(reason: FreezeFailure): void {
    const freeze = this.freezeState;
    if (!freeze) return;
    this.freezeState = null;
    this.heldExternal = [];
    this.answerFreeze(freeze, reason);
  }

  private reportError(message: string, err?: unknown): void {
    const detail = describe(err);
    const stack = err instanceof Error ? err.stack : undefined;
    void this.post({ type: "error", message: message + detail, ...(stack && { stack }) });
  }

  private post(msg: EditorToHost): Promise<unknown> {
    return this.host.send(msg).catch(() => {});
  }
}

/** A pasted image has no name: `image.png` (by its type). */
function uploadName(file: File): string {
  if (file.name) return file.name;
  const subtype = /^image\/([a-z0-9.+-]+)$/i.exec(file.type)?.[1]?.toLowerCase();
  return subtype ? `image.${subtype === "jpeg" ? "jpg" : subtype.replace(/\+.*/, "")}` : "file";
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function describe(err: unknown): string {
  return err instanceof Error ? `: ${err.message}` : err === undefined ? "" : `: ${String(err)}`;
}

function newTxId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  // randomUUID needs a secure context; fall back to an RFC 4122 v4 UUID.
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, "0")).join("");
}
