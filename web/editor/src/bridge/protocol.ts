// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Bridge protocol between the Swift host and the editor. Mirrored in Swift by
// EditorBridgeProtocol.swift; Fixtures/bridge/messages-*.json pin the wire format.
// All positions are UTF-16 code-unit offsets.
//
// v3 (M6 Task 2) declares every wire change of the rich blocks: table / callout / heading menus
// (`menuId`), fold state, rich copy, typewriter mode and `selectRange`.
// v4 (M7 Task 6) adds the editor appearance to `setSettings`: `appearance`, `reduceMotion`, the
// three font families and `paragraphIndent`, and limits the theme tokens to the schema's.
// v5 (integration merge 2026-10-26): the union of Baerchen's v4 (M6/M8) and ios-iphone-ipad's v4,
// which added `scrollChanged` without a bump; one number above both, so a stale bundle is refused.

import { editorTokens } from "../../../../Fixtures/themes/theme-schema.json";

export const BRIDGE_VERSION = 5;

/** Editor commands the host can run with `applyCommand` (Fixtures/bridge/command-names.json). */
export const COMMAND_NAMES = [
  "bold",
  "italic",
  "underline",
  "strike",
  "highlight",
  "inlineCode",
  "codeBlock",
  "heading",
  "bulletList",
  "orderedList",
  "todo",
  "toggleTodo",
  "moveCheckedToBottom",
  "quote",
  "link",
  "setLink",
  "horizontalRule",
  "insertDate",
  "indent",
  "outdent",
  "moveLineUp",
  "moveLineDown",
  "toggleFold",
  "selectAll",
  "insertText",
  "findNext",
  "findPrevious",
  "find",
  "findAndReplace",
  "wikiLink",
  "footnote",
  "openLink",
  "insertFile",
  "replaceRange",
  "pasteCode",
  // Tables (M6 Tasks 5-6). Row and column commands take an optional `menuId` (the cell the menu
  // was opened on); `tableMoveRow` {direction: "up" | "down"}, `tableMoveColumn` {direction:
  // "left" | "right"}, `copyTable` {format: "csv" | "html" | "markdown", menuId?}.
  "createTable",
  "tableAddRow",
  "tableAddColumn",
  "tableDeleteRow",
  "tableDeleteColumn",
  "tableMoveRow",
  "tableMoveColumn",
  "copyTable",
  // Callouts (M6 Task 10): `callout` {type?}, `setCalloutType` {type, menuId?}.
  "callout",
  "setCalloutType",
  // Math (M6 Task 11): `insertMath` {display: boolean}.
  "insertMath",
  // Folding (M6 Task 7): Fold All / Unfold All. `toggleFold` takes an optional `menuId` (a heading line).
  "foldAll",
  "unfoldAll",
] as const;

export type CommandName = (typeof COMMAND_NAMES)[number];

/**
 * Command arguments (`heading` {level, menuId?}, `highlight` {color?}, `insertDate` {style}, …);
 * each command validates its own. `menuId` (on the table commands, `toggleFold`, `heading` and
 * `setCalloutType`): the position a native menu remembered when it was opened (menu-targets.ts
 * `resolveMenuTarget`). Without a `menuId` the command acts at the main selection; with one that
 * no longer resolves (its text was deleted, or the id is unknown) it does nothing, and never
 * falls back to the selection.
 */
export type CommandArgs = Record<string, unknown>;

export type SelectionRange = { anchor: number; head: number };

/** Bear's callout types (`> [!NOTE]`); the wire uses the lowercase names. */
export const CALLOUT_TYPES = ["note", "tip", "important", "warning", "caution"] as const;
export type CalloutType = (typeof CALLOUT_TYPES)[number];

/**
 * One folded block of a note, persisted by the host (`note_ui_state.foldState`): `line` is the
 * 1-based line of the fold's first (heading or list item) line; `hash` its text's FNV-1a 32-bit
 * hash as 8 lowercase hex characters, so a fold whose line changed while the note was closed is
 * dropped instead of folding the wrong section.
 */
export type FoldEntry = { line: number; hash: string };

/** No note carries more folds than this; longer arrays are cut, never rejected. */
export const MAX_FOLDS = 10_000;

/**
 * The valid entries of a fold list (`loadNote.foldState`, `foldState.folds`), at most `MAX_FOLDS`.
 * Invalid entries are dropped one by one: a damaged stored fold must not stop the note from loading.
 */
export function sanitizeFolds(v: unknown): FoldEntry[] {
  if (!Array.isArray(v)) return [];
  const out: FoldEntry[] = [];
  for (const entry of v) {
    if (out.length >= MAX_FOLDS) break;
    if (foldEntry(entry)) out.push(entry as FoldEntry);
  }
  return out;
}

/** One dropped or pasted file for `insertAttachments` (bytes base64-encoded). */
export type AttachmentUpload = { filename: string; dataBase64: string };

/** What the native Format menu shows for the main selection (checkmarks, enabled items). */
export type FormatStateFields = {
  /** The styles/blocks the selection has (`heading` with `headingLevel`). */
  active: CommandName[];
  headingLevel?: number;
  inTodo: boolean;
  /** Inside a code block or an inline code span: inline styles are disabled. */
  inCode: boolean;
  /** Tab would indent a list item. */
  canIndent: boolean;
};

/**
 * What a clicked (⌘-click, link icon) or ⇧⌘K-opened link points at. `url`: any URL with a scheme
 * (the host opens only http, https and mailto); `bearURL`: a `bear://` URL; `attachment`: a link
 * without a scheme (a file next to the note); `wiki`: `target` is the note title (empty for
 * `[[/Heading]]`, the same note), `heading` the heading text; `tag`: the tag path without `#`.
 */
export const LINK_KINDS = ["url", "wiki", "tag", "attachment", "bearURL"] as const;
export type LinkKind = (typeof LINK_KINDS)[number];

export type OpenLinkFields = { kind: LinkKind; target: string; heading?: string; newWindow: boolean };

/** Viewport coordinates (CSS px) of the caret, for anchoring the native link panel. */
export type CaretRect = { x: number; y: number; width: number; height: number };

/**
 * ⌘K: the link's current title and URL and the range the panel's answer replaces. The editor keeps
 * that range (mapped through every later edit) under `requestId`, which `setLink` sends back.
 * `editing`: an existing `[title](url)` link (the panel offers Remove Link), else a new one.
 */
export type EditLinkFields = {
  requestId: string;
  from: number;
  to: number;
  title: string;
  url: string;
  editing: boolean;
  caretRect: CaretRect;
};

/** What the editor completes: `#` tags, `[[` note titles, `[[Title/` headings, `:` emoji. */
export const COMPLETION_KINDS = ["tag", "note", "heading", "emoji"] as const;
export type CompletionKind = (typeof COMPLETION_KINDS)[number];

/**
 * One completion from the host: `label` is listed, `insert` replaces the typed query (`#wo` →
 * `#work `, `:cat` → `🐈`, the text after `[[` / `[[Title/`). `icon`: a TagCon (SF Symbol name).
 */
export type CompletionItem = { label: string; insert: string; detail?: string; icon?: string };

/**
 * `setSettings` typography: sizes in CSS px, `lineHeight` a multiple of the size, `paragraphSpacing`
 * and `paragraphIndent` (0-4) in em. A font is a family name (1-100 characters, none of `;{}<>\"`
 * or a line break); the editor puts its default font stack behind it.
 */
export type EditorTypography = {
  fontSize?: number;
  lineHeight?: number;
  lineWidth?: number;
  paragraphSpacing?: number;
  paragraphIndent?: number;
  fontText?: string;
  fontHeading?: string;
  fontCode?: string;
};

/** The editor's own light or dark look (`setSettings.appearance`, default light). */
export const APPEARANCES = ["light", "dark"] as const;
export type EditorAppearance = (typeof APPEARANCES)[number];

/**
 * `setSettings`: editor settings, applied without reloading the note. A missing field keeps its
 * current value; a present one replaces it (a `typography` or `theme` object as a whole).
 */
export type EditorSettings = {
  /** Hide markup unless the caret is inside the element (default on). Off: all markup shows, dimmed. */
  hideMarkdown?: boolean;
  /** Checked todos move to the end of their checklist (default off). */
  autoSortTodos?: boolean;
  /** Show the H1…H6 level badges in the left margin (default on). Off: no badges, same text column. */
  showHeadingLevels?: boolean;
  /** Tag, note, heading and emoji completion (M3 Task 7's autocomplete). */
  autocomplete?: boolean;
  /** Typewriter mode (M6 Task 14, default off): the caret line stays at the vertical centre while typing. */
  typewriterMode?: boolean;
  typography?: EditorTypography;
  /** Theme tokens: `--bc-<schema editor token>` CSS variable → value, over the default theme (`{}`: the default). */
  theme?: Record<string, string>;
  /** `dark` makes CodeMirror's own parts (and the browser's controls and scrollbars) dark (default light). */
  appearance?: EditorAppearance;
  /** No transitions or animations (default off; the host sends the system's Reduce Motion). */
  reduceMotion?: boolean;
};

export type HostToEditor =
  /**
   * `readOnly`: Trash, Archive and read-only notes (edits refused; selection, copy, find work).
   * `noteId` "" is the host's empty placeholder (no note shown): the editor is locked.
   */
  | {
      type: "loadNote";
      noteId: string;
      text: string;
      revision: number;
      readOnly: boolean;
      selection?: SelectionRange;
      scrollTop?: number;
      /** The note's stored folds (M6 Task 8); entries whose line no longer matches `hash` are dropped. */
      foldState?: FoldEntry[];
    }
  | { type: "applyExternalChange"; noteId: string; revision: number; changeSet: unknown }
  | { type: "setRevision"; noteId: string; revision: number }
  | { type: "focus" }
  | { type: "requestChecksum"; requestId: string }
  /**
   * The note `noteId` was opened from the note-list search: highlight every match of `terms`
   * (the search's highlight strings) and scroll to the first, without moving the selection;
   * empty `terms` clear. Dropped for another note. `query` is the raw search text.
   */
  | { type: "searchHighlight"; noteId: string; query: string; terms: string[] }
  /** Runs a command (native menu / shortcut); one undo step. */
  | { type: "applyCommand"; name: CommandName; args?: CommandArgs }
  /** Puts the caret on the note's `index`-th heading (0-based, NoteParser order) and scrolls to it. */
  | { type: "scrollToHeading"; noteId: string; index: number }
  /** The answer to `requestCompletions` `requestId`, ranked; answers to older requests are ignored. */
  | { type: "completionResults"; requestId: string; items: CompletionItem[] }
  /**
   * Tag path key (canonicalKey of the path) → TagCon symbol, for every tag; replaces the previous
   * map. Shown next to tag pills, loaded from `baerchen-asset://tagcon/v2/<symbol>.png`.
   */
  | { type: "tagIcons"; icons: Record<string, string> }
  | ({ type: "setSettings" } & EditorSettings)
  /**
   * Selects the UTF-16 range `anchor`...`head` (`anchor` > `head`: a backwards selection; equal: a
   * caret) of the note `noteId` and scrolls it into view. Dropped for another note and for a range
   * outside the document. Not an edit, so also in read-only notes (M5 `app open`).
   */
  | { type: "selectRange"; noteId: string; anchor: number; head: number }
  /**
   * Capture close (W1, docs/editor-bridge-capture-close.md): freeze the editor for `noteId`, wait
   * until everything it sent before is acknowledged, then answer with `frozenForClose`.
   */
  | { type: "freezeForClose"; requestId: string; noteId: string }
  /** Ends the freeze `requestId` started and gives the editor back the state it had. */
  | { type: "unfreeze"; requestId: string; noteId: string };

/** Why a `frozenForClose` is not ok. The host only needs "not ok"; the codes are for logs and tests. */
export const FREEZE_FAILURES = ["timeout", "halted", "notShown", "composing", "superseded", "reloaded", "unfrozen"] as const;
export type FreezeFailure = (typeof FREEZE_FAILURES)[number];

export type EditorToHost =
  | { type: "ready"; version: number }
  | { type: "recoveryText"; noteId: string; baseRevision: number; text: string }
  | {
      type: "changes";
      noteId: string;
      txId: string;
      baseRevision: number;
      revision: number;
      changeSet: unknown;
    }
  | { type: "scrollChanged"; noteId: string; scrollTop: number }
  | { type: "selectionChanged"; noteId: string; anchor: number; head: number }
  | { type: "checksum"; requestId: string; noteId: string; sha256: string }
  | { type: "error"; message: string; stack?: string }
  /**
   * The answer to `freezeForClose`. `ok`: the editor is frozen and every transaction it sent
   * before has been acknowledged (`lastAckedTxId` is the latest, absent if none was), `sha256`
   * is the hash of its document. Not ok: `reason` says why, the host must keep the note.
   * `editedSinceLoad`: any change has touched this note's document since it was loaded.
   */
  | {
      type: "frozenForClose";
      requestId: string;
      noteId: string;
      ok: boolean;
      editedSinceLoad: boolean;
      sha256?: string;
      lastAckedTxId?: string;
      reason?: FreezeFailure;
    }
  /**
   * The heading badge in the gutter was clicked: the host shows the heading menu at `rect` and
   * answers with `applyCommand {..., menuId}`. `line` is 1-based, `level` 1–6, `folded` whether the
   * heading is folded now.
   */
  | { type: "headingMenu"; noteId: string; menuId: string; line: number; level: number; folded: boolean; rect: CaretRect }
  /**
   * The cell button of a table: `row` 0 is the header, `rows` / `columns` count the header row and
   * every column, so `row` < `rows` and `column` < `columns`.
   */
  | { type: "tableMenu"; noteId: string; menuId: string; row: number; column: number; rows: number; columns: number; rect: CaretRect }
  /** The type button of a callout. */
  | { type: "calloutMenu"; noteId: string; menuId: string; calloutType: CalloutType; rect: CaretRect }
  /** The note's folds changed (debounced by the editor); the host stores them for the next `loadNote`. */
  | { type: "foldState"; noteId: string; folds: FoldEntry[] }
  /** Debounced (50 ms) after selection and document changes, and after every loadNote. */
  | ({ type: "formatState"; noteId: string } & FormatStateFields)
  /** ⌘-click on a link, wiki link or tag, the external-link icon, ⇧⌘K / ⌥⇧⌘K. */
  | ({ type: "openLink"; noteId: string } & OpenLinkFields)
  /** ⌘K: the host shows its link panel and answers with `applyCommand` `setLink`. */
  | ({ type: "editLinkRequest"; noteId: string } & EditLinkFields)
  /**
   * Files dropped (at the drop point) or pasted (at the selection): the host copies them into the
   * note's attachments and answers with `applyCommand insertText {text, insertId}`.
   */
  | { type: "insertAttachments"; noteId: string; insertId: string; items: AttachmentUpload[] }
  /**
   * Attachment links pasted from note `sourceNoteId`: the host copies those files into this note
   * and answers with `insertText {text, insertId}`, the links in `text` renamed where needed.
   * `items` are the links' UTF-16 ranges in `text`.
   */
  | {
      type: "pasteAttachments";
      noteId: string;
      insertId: string;
      sourceNoteId: string;
      text: string;
      items: { from: number; to: number; filename: string }[];
    }
  /**
   * Attachment links copied or cut (ruling R30): the host keeps these files of the note until the
   * pasteboard changes, so a cut survives switching notes before the paste.
   */
  | { type: "cutAttachments"; noteId: string; filenames: string[] }
  /** Dropped or pasted files over the size caps; the host explains (and points to ⇧⌘V). */
  | { type: "attachmentsRefused"; noteId: string; reason: "tooLarge"; filenames: string[] }
  /** Space or double click on an attachment. */
  | { type: "quickLook"; noteId: string; filename: string }
  /** Context menu of an attachment; `source` is the document text of `[from, to)`. */
  | { type: "attachmentMenu"; noteId: string; filename: string; from: number; to: number; source: string }
  | { type: "attachmentTap"; noteId: string; filename: string; from: number; to: number; source: string }
  /**
   * Copy Code / Copy Table As: the host puts `text` on the general pasteboard as plain text and,
   * when `html` is given, as HTML too (a rich paste gives a table).
   */
  | { type: "copyText"; text: string; html?: string }
  /** Asks for completions (`noteTitle`: headings of that note; empty: this note); answered with `completionResults`. */
  | { type: "requestCompletions"; noteId: string; requestId: string; kind: CompletionKind; query: string; noteTitle?: string };

export type ChangesReply =
  | { status: "acked" | "duplicate"; revision: number }
  | { status: "needsFullText"; currentRevision: number };

type Obj = Record<string, unknown>;
type Check = (v: unknown) => boolean;

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const str: Check = (v) => typeof v === "string";
const bool: Check = (v) => typeof v === "boolean";
const uint: Check = (v) => Number.isSafeInteger(v) && (v as number) >= 0;
const lineNumber: Check = (v) => Number.isSafeInteger(v) && (v as number) >= 1;
const headingLevel: Check = (v) => Number.isInteger(v) && (v as number) >= 1 && (v as number) <= 6;
const num: Check = (v) => typeof v === "number" && Number.isFinite(v);
const selection: Check = (v) => shape(v, { anchor: uint, head: uint });
const strings: Check = (v) => Array.isArray(v) && v.every(str);
const commandNames: ReadonlySet<string> = new Set(COMMAND_NAMES);
const commandName: Check = (v) => typeof v === "string" && commandNames.has(v);
const commandList: Check = (v) => Array.isArray(v) && v.every(commandName);
const linkKinds: ReadonlySet<string> = new Set(LINK_KINDS);
const linkKind: Check = (v) => typeof v === "string" && linkKinds.has(v);
const caretRect: Check = (v) => shape(v, { x: num, y: num, width: num, height: num });
const calloutTypes: ReadonlySet<string> = new Set(CALLOUT_TYPES);
const calloutType: Check = (v) => typeof v === "string" && calloutTypes.has(v);
const foldEntry: Check = (v) => shape(v, { line: lineNumber, hash: (h) => typeof h === "string" && /^[0-9a-f]{8}$/.test(h) });
/** Any array: the entries are checked one by one by `sanitizeFolds`, never as a whole. */
const foldEntries: Check = (v) => Array.isArray(v);
const between = (min: number, max: number): Check => (v) => num(v) && (v as number) >= min && (v as number) <= max;
/** A font family name, put between double quotes in a declaration: nothing that could end the string or the declaration. */
const fontFamily: Check = (v) => typeof v === "string" && v.length <= 100 && /^[^;{}<>\\"\n\r]+$/.test(v);
const typography: Check = (v) =>
  shape(
    v,
    {},
    {
      fontSize: between(8, 72),
      lineHeight: between(1, 3),
      lineWidth: between(320, 4000),
      paragraphSpacing: between(0, 3),
      paragraphIndent: between(0, 4),
      fontText: fontFamily,
      fontHeading: fontFamily,
      fontCode: fontFamily,
    },
  );
const appearances: ReadonlySet<string> = new Set(APPEARANCES);
const appearance: Check = (v) => typeof v === "string" && appearances.has(v);
/** The `--bc-<token>` variables of the schema's editor tokens (Fixtures/themes/theme-schema.json). */
const themeVariables: ReadonlySet<string> = new Set(editorTokens.map((token) => `--bc-${token}`));
/** A theme colour: `#rrggbb` or `#rrggbbaa`, the same rule as Swift's `ThemeSchema.sanitize`. */
const hexColor: Check = (v) => typeof v === "string" && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(v);
/** Theme tokens: the schema's `--bc-*` names only, with hex colour values. */
const themeTokens: Check = (v) => isObj(v) && Object.entries(v).every(([key, value]) => themeVariables.has(key) && hexColor(value));
/** The same checks `setSettings` applies, for the export page's render request (M8 Task 10). */
export const isEditorTypography = (v: unknown): v is EditorTypography => typography(v);
export const isEditorAppearance = (v: unknown): v is EditorAppearance => appearance(v);
export const isThemeTokens = (v: unknown): v is Record<string, string> => themeTokens(v);
const editLink: Check = (v) => isObj(v) && (v.from as number) <= (v.to as number);
const nonEmpty: Check = (v) => typeof v === "string" && v.length > 0;
const base64: Check = (v) => typeof v === "string" && /^[A-Za-z0-9+/]*={0,2}$/.test(v);
const spans: Check = (v) =>
  Array.isArray(v) && v.length > 0 &&
  v.every((item) => shape(item, { from: uint, to: uint, filename: nonEmpty }) && (item as { from: number; to: number }).from <= (item as { to: number }).to);
const names: Check = (v) => Array.isArray(v) && v.length > 0 && v.every(nonEmpty);
const uploads: Check = (v) =>
  Array.isArray(v) && v.length > 0 && v.every((item) => shape(item, { filename: nonEmpty, dataBase64: base64 }));
const sha256Hex: Check = (v) => typeof v === "string" && /^[0-9a-f]{64}$/.test(v);
const freezeFailures: ReadonlySet<string> = new Set(FREEZE_FAILURES);
const freezeFailure: Check = (v) => typeof v === "string" && freezeFailures.has(v);
const completionKinds: ReadonlySet<string> = new Set(COMPLETION_KINDS);
const completionKind: Check = (v) => typeof v === "string" && completionKinds.has(v);
const completionItem: Check = (v) => shape(v, { label: str, insert: str }, { detail: str, icon: str });
const completionItems: Check = (v) => Array.isArray(v) && v.every(completionItem);
const stringMap: Check = (v) => isObj(v) && Object.values(v).every(str);

/** ChangeSet.toJSON(): numbers are retained lengths, arrays are [deletedLength, ...insertedLines]. */
const changeSetJSON: Check = (v) =>
  Array.isArray(v) &&
  v.every((part) => uint(part) || (Array.isArray(part) && part.length >= 1 && uint(part[0]) && part.slice(1).every(str)));

/** Exact-key check: required keys must pass, optional keys may be absent, nothing else allowed. */
function shape(v: unknown, required: Record<string, Check>, optional: Record<string, Check> = {}): boolean {
  if (!isObj(v)) return false;
  for (const key of Object.keys(v)) if (!(key in required) && !(key in optional)) return false;
  for (const [key, check] of Object.entries(required)) if (!(key in v) || !check(v[key])) return false;
  for (const [key, check] of Object.entries(optional)) if (key in v && !check(v[key])) return false;
  return true;
}

const lit = (value: string): Check => (v) => v === value;

type Spec = [required: Record<string, Check>, optional?: Record<string, Check>];

const hostToEditor: Record<HostToEditor["type"], Spec> = {
  loadNote: [
    { type: lit("loadNote"), noteId: str, text: str, revision: uint, readOnly: bool },
    { selection, scrollTop: num, foldState: foldEntries },
  ],
  applyExternalChange: [
    { type: lit("applyExternalChange"), noteId: str, revision: uint, changeSet: changeSetJSON },
  ],
  setRevision: [{ type: lit("setRevision"), noteId: str, revision: uint }],
  focus: [{ type: lit("focus") }],
  requestChecksum: [{ type: lit("requestChecksum"), requestId: str }],
  searchHighlight: [{ type: lit("searchHighlight"), noteId: str, query: str, terms: strings }],
  applyCommand: [{ type: lit("applyCommand"), name: commandName }, { args: isObj }],
  scrollToHeading: [{ type: lit("scrollToHeading"), noteId: str, index: uint }],
  completionResults: [{ type: lit("completionResults"), requestId: str, items: completionItems }],
  tagIcons: [{ type: lit("tagIcons"), icons: stringMap }],
  setSettings: [
    { type: lit("setSettings") },
    { hideMarkdown: bool, autoSortTodos: bool, showHeadingLevels: bool, autocomplete: bool, typewriterMode: bool, typography, theme: themeTokens, appearance, reduceMotion: bool },
  ],
  selectRange: [{ type: lit("selectRange"), noteId: str, anchor: uint, head: uint }],
  freezeForClose: [{ type: lit("freezeForClose"), requestId: nonEmpty, noteId: str }],
  unfreeze: [{ type: lit("unfreeze"), requestId: nonEmpty, noteId: str }],
};

const editorToHost: Record<EditorToHost["type"], Spec> = {
  ready: [{ type: lit("ready"), version: uint }],
  recoveryText: [{ type: lit("recoveryText"), noteId: nonEmpty, baseRevision: uint, text: str }],
  changes: [
    {
      type: lit("changes"),
      noteId: str,
      txId: str,
      baseRevision: uint,
      revision: uint,
      changeSet: changeSetJSON,
    },
  ],
  scrollChanged: [{ type: lit("scrollChanged"), noteId: str, scrollTop: (v) => num(v) && (v as number) >= 0 }],
  selectionChanged: [{ type: lit("selectionChanged"), noteId: str, anchor: uint, head: uint }],
  checksum: [{ type: lit("checksum"), requestId: str, noteId: str, sha256: (v) => /^[0-9a-f]{64}$/.test(String(v)) }],
  error: [{ type: lit("error"), message: str }, { stack: str }],
  frozenForClose: [
    { type: lit("frozenForClose"), requestId: nonEmpty, noteId: str, ok: bool, editedSinceLoad: bool },
    { sha256: sha256Hex, lastAckedTxId: nonEmpty, reason: freezeFailure },
  ],
  headingMenu: [
    { type: lit("headingMenu"), noteId: str, menuId: nonEmpty, line: lineNumber, level: headingLevel, folded: bool, rect: caretRect },
  ],
  tableMenu: [
    { type: lit("tableMenu"), noteId: str, menuId: nonEmpty, row: uint, column: uint, rows: lineNumber, columns: lineNumber, rect: caretRect },
  ],
  calloutMenu: [{ type: lit("calloutMenu"), noteId: str, menuId: nonEmpty, calloutType, rect: caretRect }],
  foldState: [{ type: lit("foldState"), noteId: str, folds: foldEntries }],
  formatState: [
    { type: lit("formatState"), noteId: str, active: commandList, inTodo: bool, inCode: bool, canIndent: bool },
    { headingLevel },
  ],
  openLink: [{ type: lit("openLink"), noteId: str, kind: linkKind, target: str, newWindow: bool }, { heading: str }],
  editLinkRequest: [
    { type: lit("editLinkRequest"), noteId: str, requestId: str, from: uint, to: uint, title: str, url: str, editing: bool, caretRect },
  ],
  insertAttachments: [{ type: lit("insertAttachments"), noteId: str, insertId: nonEmpty, items: uploads }],
  pasteAttachments: [{ type: lit("pasteAttachments"), noteId: str, insertId: nonEmpty, sourceNoteId: nonEmpty, text: str, items: spans }],
  cutAttachments: [{ type: lit("cutAttachments"), noteId: str, filenames: names }],
  attachmentsRefused: [{ type: lit("attachmentsRefused"), noteId: str, reason: lit("tooLarge"), filenames: names }],
  quickLook: [{ type: lit("quickLook"), noteId: str, filename: nonEmpty }],
  attachmentMenu: [{ type: lit("attachmentMenu"), noteId: str, filename: nonEmpty, from: uint, to: uint, source: str }],
  attachmentTap: [{ type: lit("attachmentTap"), noteId: str, filename: nonEmpty, from: uint, to: uint, source: str }],
  copyText: [{ type: lit("copyText"), text: str }, { html: str }],
  requestCompletions: [
    { type: lit("requestCompletions"), noteId: str, requestId: str, kind: completionKind, query: str },
    { noteTitle: str },
  ],
};

/** Checks across fields, after the shape. */
const tableCell: Check = (v) => isObj(v) && (v.row as number) < (v.rows as number) && (v.column as number) < (v.columns as number);
/** An ok freeze carries the document hash and no reason; a failed one carries a reason and no hash. */
const frozenReply: Check = (v) => isObj(v) && (v.ok === true ? "sha256" in v && !("reason" in v) : "reason" in v && !("sha256" in v));
const extraChecks: Partial<Record<string, Check>> = { editLinkRequest: editLink, tableMenu: tableCell, frozenForClose: frozenReply };

function matches(v: unknown, table: Record<string, Spec>): boolean {
  if (!isObj(v) || typeof v.type !== "string" || !Object.hasOwn(table, v.type)) return false;
  const [required, optional] = table[v.type]!;
  return shape(v, required, optional) && (extraChecks[v.type]?.(v) ?? true);
}

export function isHostToEditor(v: unknown): v is HostToEditor {
  return matches(v, hostToEditor);
}

export function isEditorToHost(v: unknown): v is EditorToHost {
  return matches(v, editorToHost);
}

export function isChangesReply(v: unknown): v is ChangesReply {
  return (
    shape(v, { status: (s) => s === "acked" || s === "duplicate", revision: uint }) ||
    shape(v, { status: lit("needsFullText"), currentRevision: uint })
  );
}
