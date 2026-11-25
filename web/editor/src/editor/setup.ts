// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "./composition";
import { Compartment, EditorSelection, EditorState, type Extension, Facet, Prec, Text, type Transaction } from "@codemirror/state";
import { EditorView, type KeyBinding, keymap } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { closeCompletion } from "@codemirror/autocomplete";
import { bearMarkdown } from "./dialect";
import { autocomplete, type CompletionBridge, completionBridge } from "./features/autocomplete";
import { headingsInDocument } from "./conformance";
import { commandKeymap, iosCommandKeymap, menuOwnsShortcuts, runHostCommand, selectAllKeymap } from "./features/commands";
import { attachmentNote, attachments } from "./features/attachments";
import { type BlockRenderer, blockRenderers, blocks } from "./features/blocks";
import { type CodeBlockHandlers, codeBlockHandlers, codeBlocks } from "./features/codeblocks";
import { callouts } from "./features/callouts";
import { math } from "./features/math";
import { mermaid } from "./features/mermaid";
import { footnotes } from "./features/footnotes";
import { applyFoldEntries, folding, foldStateSink, type FoldStateSink, revealEffects, storedFolds } from "./features/folding";
import { hiding } from "./features/hiding";
import { type LinkHandlers, linkHandlers, links } from "./features/links";
import { smartPasteHandler } from "./features/paste";
import { lists } from "./features/lists";
import { menuTargets } from "./features/menu-targets";
import { findAndReplace } from "./features/search";
import { searchHighlight } from "./features/search-highlight";
import { currentSettings, type ResolvedSettings, settingsExtensions, settingsTransaction } from "./features/settings";
import { tables } from "./features/tables";
import { todos } from "./features/todos";
import { typewriter } from "./features/typewriter";
import { typography } from "./features/typography";
import { theme } from "./theme";
import { type EditorHandle, externalChange, type LoadedDocument } from "../bridge/client";
import type { EditorSettings, FoldEntry } from "../bridge/protocol";

/**
 * CodeMirror's default + history keymaps without Mod-[ / Mod-] (indent less/more): in Bear those
 * are Go Back / Go Forward (host menu, M4 Task 9), and WebKit hands key equivalents to the page
 * first. Indenting stays on Tab / Shift-Tab.
 */
export const baseKeymap: readonly KeyBinding[] = [...defaultKeymap, ...historyKeymap].filter(
  (b) => b.key !== "Mod-[" && b.key !== "Mod-]",
);

/**
 * `editable`: a normal note. `readOnly`: a Trash, Archive or read-only note: edits are refused but
 * the text stays focusable, so selection, keyboard navigation, copy, find and folding work.
 * `locked`: no note yet, or the bridge halted: nothing is accepted at all (not contenteditable).
 */
export type EditMode = "editable" | "readOnly" | "locked";

/**
 * Read-only notes keep `contenteditable` (CodeMirror reverts DOM changes while `readOnly`); typed,
 * dictated and pasted input is cancelled before WebKit changes the DOM. IME composition cannot be
 * cancelled; CodeMirror reverts it when it ends.
 */
const refuseInput = EditorView.domEventHandlers({
  beforeinput(event, view) {
    if (!view.state.readOnly) return false;
    event.preventDefault();
    return true;
  },
});

/**
 * The one place that keeps a read-only (or locked) document unchanged: every document change that
 * is not the host's (`externalChange`) is dropped, whatever produced it: keymap commands that do
 * not check `readOnly` (hiding's Backspace/Delete over hidden markup, Tab), Writing Tools,
 * spellcheck replacements. Loading a note replaces the state and is no transaction.
 */
const refuseChanges = EditorState.transactionFilter.of((tr) =>
  tr.docChanged && !tr.annotation(externalChange) ? [] : tr,
);

const readOnlyMode = new Compartment();

/** The mode the compartment holds, so a freeze can hand it back (W1). */
const editModeFacet = Facet.define<EditMode, EditMode>({ combine: (values) => values[0] ?? "editable" });

const readOnlyExtensions = (mode: EditMode): Extension => [
  editModeFacet.of(mode),
  mode === "editable"
    ? []
    : mode === "readOnly"
      ? [EditorState.readOnly.of(true), refuseInput, refuseChanges]
      : [EditorState.readOnly.of(true), EditorView.editable.of(false), refuseChanges],
];

/** A view frozen for a capture close, with the mode to give back. */
const frozenViews = new WeakMap<EditorView, { previous: EditMode }>();

/** How long `commitComposition` waits for the composition to end after the editor lost focus. */
export const COMPOSITION_END_TIMEOUT_MS = 600;

/**
 * Ends an active IME composition the way the platform does when focus leaves (the keyboard
 * confirms its candidate), and resolves once CodeMirror has read the result. False if the
 * composition is still going on after `COMPOSITION_END_TIMEOUT_MS`. Needed before the editor goes
 * read-only: CodeMirror reverts the rest of a composition that ends in a read-only editor.
 */
export function commitComposition(view: EditorView, timeoutMs = COMPOSITION_END_TIMEOUT_MS): Promise<boolean> {
  if (!view.composing) return Promise.resolve(true);
  return new Promise((resolve) => {
    const finish = () => {
      clearTimeout(timer);
      view.contentDOM.removeEventListener("compositionend", onEnd);
      resolve(!view.composing);
    };
    // After the frame that reads the composition's last DOM change (composition.ts).
    const onEnd = () => afterComposition(finish);
    const timer = setTimeout(finish, timeoutMs);
    view.contentDOM.addEventListener("compositionend", onEnd, { once: true });
    view.contentDOM.blur();
  });
}

/** Capture close: the read-only compartment goes to "locked" (what `setReadOnly(true)` uses). */
export function freezeView(view: EditorView): void {
  if (frozenViews.has(view)) return;
  frozenViews.set(view, { previous: view.state.facet(editModeFacet) });
  view.dispatch({ effects: readOnlyMode.reconfigure(readOnlyExtensions("locked")) });
}

/** Gives back the mode `freezeView` replaced (a read-only note stays read-only). Focus is the host's (`focus`). */
export function unfreezeView(view: EditorView): void {
  const frozen = frozenViews.get(view);
  if (!frozen) return;
  frozenViews.delete(view);
  view.dispatch({ effects: readOnlyMode.reconfigure(readOnlyExtensions(frozen.previous)) });
}

/**
 * Who handles the Format shortcuts (⌘B, ⌘1…): the native menu in the app ("menu"), the editor's
 * own keymap without one (mock / dev / e2e, and tests: "editor").
 */
export type ShortcutOwner = "menu" | "editor" | "ios";

const shortcutOwner = Facet.define<ShortcutOwner, ShortcutOwner>({ combine: (values) => values[0] ?? "editor" });

/** The `blockRenderers` option, so a loaded note's state carries it over. */
const extraBlockRenderers = Facet.define<readonly BlockRenderer[], readonly BlockRenderer[]>({
  combine: (values) => values[0] ?? [],
});

/**
 * `links`: where opened links and ⌘K panel requests go; `code`: where Copy Code goes;
 * `completion`: where completions come from (all the bridge client; without a completion bridge
 * nothing completes); `settings`: the `setSettings` values (a loaded note keeps the current ones);
 * `noteId`: the note shown (attachment URLs); `blockRenderers`: extra block renderers (dev/e2e
 * `?testBlocks`; the real ones come with their features); `foldState`: where changed folds go.
 */
export type EditorOptions = {
  mode?: EditMode;
  shortcuts?: ShortcutOwner;
  links?: LinkHandlers;
  code?: CodeBlockHandlers;
  completion?: CompletionBridge;
  settings?: ResolvedSettings;
  noteId?: string;
  blockRenderers?: readonly BlockRenderer[];
  foldState?: FoldStateSink;
  storedFolds?: readonly FoldEntry[];
};

/** What a loaded note's state carries over from the editor (the host's handlers and settings). */
export type CarriedOptions = Omit<EditorOptions, "mode" | "noteId" | "storedFolds">;

export function editorExtensions(opts: EditorOptions = {}): Extension[] {
  const mode = opts.mode ?? "editable";
  const shortcuts = opts.shortcuts ?? "editor";
  return [
    shortcutOwner.of(shortcuts),
    linkHandlers.of(opts.links ?? {}),
    attachmentNote.of(opts.noteId ?? ""),
    codeBlockHandlers.of(opts.code ?? {}),
    ...(opts.completion ? [completionBridge.of(opts.completion)] : []),
    ...(opts.foldState ? [foldStateSink.of(opts.foldState)] : []),
    ...(opts.storedFolds?.length ? [storedFolds.of(opts.storedFolds)] : []),
    shortcuts === "menu" ? menuOwnsShortcuts : shortcuts === "ios" ? iosCommandKeymap : commandKeymap,
    selectAllKeymap,
    // No HTML tag completion; code languages are highlighted by codeblocks.ts.
    markdown({ base: bearMarkdown, addKeymap: false, completeHTMLTags: false }),
    // Smart lists replace the markdown keymap's Enter/Backspace (see lists.ts); before hiding's
    // Backspace, both Prec.high.
    lists,
    history(),
    keymap.of(baseKeymap),
    EditorView.lineWrapping,
    EditorView.contentAttributes.of({
      spellcheck: "true",
      autocorrect: "on",
      autocapitalize: "sentences",
      writingsuggestions: "true",
      // VoiceOver names the text area (M7 Task 11); a read-only note says so.
      "aria-label": "Note text",
    }),
    EditorView.contentAttributes.compute([EditorState.readOnly], (state): Record<string, string> =>
      state.facet(EditorState.readOnly) ? { "aria-readonly": "true" } : {},
    ),
    EditorView.perLineTextDirection.of(true),
    readOnlyMode.of(readOnlyExtensions(mode)),
    settingsExtensions(opts.settings),
    typewriter,
    hiding,
    // Before typography: its fold gutter (also part of typography) sits left of the heading gutter.
    folding,
    typography,
    codeBlocks,
    todos,
    searchHighlight,
    findAndReplace,
    links,
    footnotes,
    attachments,
    callouts,
    math,
    mermaid,
    blocks,
    tables,
    extraBlockRenderers.of(opts.blockRenderers ?? []),
    // Before the features' own renderers (dev/e2e `?testBlocks` stands in for `$$` math).
    ...(opts.blockRenderers ?? []).map((renderer) => Prec.highest(blockRenderers.of(renderer))),
    smartPasteHandler,
    autocomplete,
    menuTargets,
    theme,
  ];
}

/** Creates the editor. It stays read-only and empty until a note is loaded. */
export function createEditor(
  parent: HTMLElement,
  opts: { onTransaction(tr: Transaction): void } & CarriedOptions,
): EditorView {
  const extensions = editorExtensions({
    mode: "locked",
    shortcuts: opts.shortcuts ?? "editor",
    links: opts.links ?? {},
    code: opts.code ?? {},
    ...(opts.completion && { completion: opts.completion }),
    ...(opts.blockRenderers && { blockRenderers: opts.blockRenderers }),
    ...(opts.foldState && { foldState: opts.foldState }),
  });
  return new EditorView({
    parent,
    state: EditorState.create({ extensions }),
    dispatchTransactions(trs, view) {
      view.update(trs);
      for (const tr of trs) opts.onTransaction(tr);
    },
  });
}

/** The state a loaded note starts with: fresh undo history, the host's selection (clamped). */
export function loadedState(
  doc: LoadedDocument,
  carried: CarriedOptions = {},
): EditorState {
  // Split like EditorState does, so the clamp uses the length of the document CodeMirror holds.
  const text = Text.of(doc.text.split(/\r\n?|\n/));
  const clamp = (n: number) => Math.min(Math.max(0, n), text.length);
  const selection = doc.selection
    ? EditorSelection.single(clamp(doc.selection.anchor), clamp(doc.selection.head))
    : undefined;
  const mode: EditMode = doc.locked ? "locked" : doc.readOnly ? "readOnly" : "editable";
  let state = EditorState.create({
    doc: text,
    selection,
    extensions: editorExtensions({
      ...carried,
      mode,
      ...(doc.noteId !== undefined && { noteId: doc.noteId }),
      ...(doc.foldState && { storedFolds: doc.foldState }),
    }),
  });
  const restored = applyFoldEntries(state, doc.foldState ?? []);
  if (restored) state = state.update(restored).state;
  return state;
}

/** Replaces the whole editor state (fresh undo history) without dispatching a transaction. */
export function loadDocument(view: EditorView, doc: LoadedDocument): void {
  const { state } = view;
  frozenViews.delete(view);
  view.setState(loadedState(doc, {
    shortcuts: state.facet(shortcutOwner),
    links: state.facet(linkHandlers),
    code: state.facet(codeBlockHandlers),
    completion: state.facet(completionBridge),
    settings: currentSettings(state),
    blockRenderers: state.facet(extraBlockRenderers),
    ...(state.facet(foldStateSink) && { foldState: state.facet(foldStateSink)! }),
  }));
  // The stored folds, once the new state is in place (a fold that would hide the caret is dropped).
  const folds = doc.foldState?.length ? applyFoldEntries(view.state, doc.foldState) : null;
  if (folds) view.dispatch(folds);
  if (doc.scrollTop !== undefined) {
    const top = doc.scrollTop;
    view.requestMeasure({ read: () => {}, write: () => { view.scrollDOM.scrollTop = top; } });
  }
}

export function viewHandle(view: EditorView): EditorHandle {
  return {
    get state() {
      return view.state;
    },
    dispatch: (spec) => view.dispatch(spec),
    load: (doc) => loadDocument(view, doc),
    setReadOnly: (readOnly) => {
      // An explicit mode (the bridge halting) outranks a freeze's memory of the old one.
      frozenViews.delete(view);
      view.dispatch({ effects: readOnlyMode.reconfigure(readOnlyExtensions(readOnly ? "locked" : "editable")) });
    },
    commitComposition: () => commitComposition(view),
    freeze: () => freezeView(view),
    unfreeze: () => unfreezeView(view),
    applySettings: (settings) => applySettings(view, settings),
    focus: () => view.focus(),
    command: (name, args) => runHostCommand(view, name, args),
    scrollToHeading: (index) => scrollToHeading(view, index),
    closeCompletion: () => void closeCompletion(view),
  };
}

/**
 * `setSettings`: reconfigures in place (document, selection, undo history and scroll stay). During
 * an IME composition the change waits until it ends (decorations must not change mid-composition).
 */
export function applySettings(view: EditorView, settings: EditorSettings): void {
  if (view.composing) {
    view.contentDOM.addEventListener("compositionend", () => afterComposition(() => applySettings(view, settings)), { once: true });
    return;
  }
  const spec = settingsTransaction(view.state, settings);
  if (spec) view.dispatch(spec);
}

/**
 * Caret at the end of the note's `index`-th heading (the indexer's order), scrolled to the top.
 * The folds that contain the heading open first; the heading's own fold stays as it is (M6-R28).
 */
export function scrollToHeading(view: EditorView, index: number): boolean {
  const heading = headingsInDocument(view.state.doc.toString())[index];
  if (!heading || heading.line > view.state.doc.lines) return false;
  const { state } = view;
  const line = state.doc.line(heading.line);
  view.dispatch({
    selection: EditorSelection.cursor(line.to),
    effects: [...revealEffects(state, line.from, line.to), EditorView.scrollIntoView(line.from, { y: "start", yMargin: 24 })],
    userEvent: "select",
  });
  view.focus();
  return true;
}
