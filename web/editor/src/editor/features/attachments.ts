// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { EditorSelection, EditorState, type Extension, Facet, Prec, StateEffect, StateField, type TransactionSpec } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../dialect";
import { Decoration, type DecorationSet, EditorView, keymap, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { getSearchQuery, searchPanelOpen } from "@codemirror/search";
import { type AttachmentSpan, scanInline } from "../dialect-grammar";
import { hiddenMark, hidingUpdatePlan, type Range } from "./hiding";
import { lineInCode } from "./lists";

// Attachments (spec D4, §4.4; inventory §2.12): images, PDFs and other files a note links in
// Bear's format — `![](name.png)`, `[name.pdf](name.pdf)<!-- {"preview":"true","embed":"true"} -->`,
// `[name.zip](name.zip)<!-- {"embed":"true"} -->` — recognized with the same rules as the Swift
// indexer (dialect-grammar.ts, Fixtures/dialect/attachments.json).
//
// Presentation (finding F8): the link and its metadata comment stay in the DOM, collapsed by the
// shared hidden mark and atomic for the caret; an aria-hidden widget draws the image or card at
// the start of the range. Bytes come from the host through `baerchen-asset://attachment/…`
// (previews and file icons: `baerchen-asset://thumbnail/…`).
//
// Interaction: a click selects the attachment (selected style), Space or a double click asks the
// host for Quick Look, the context menu is the host's (Open, Show in Finder, Rename, Save As,
// Delete, PDF preview), the lower-right handle of an image writes `width` into the metadata, a GIF
// stays still until clicked. Files dropped or pasted into the editor go to the host
// (`insertAttachments`), which copies them and inserts the Markdown.

/** Dispatched (bubbling) on the editor DOM; main.ts forwards it to the bridge. */
export const ATTACHMENT_EVENT = "baerchen-attachment";
export type AttachmentEventDetail =
  | { kind: "quickLook"; filename: string }
  | { kind: "tap"; filename: string; from: number; to: number; source: string }
  | { kind: "menu"; filename: string; from: number; to: number; source: string }
  | { kind: "upload"; insertId: string; files: File[] }
  | { kind: "refused"; filenames: string[] }
  /** Attachment links copied or cut: the host keeps their files until the pasteboard changes (R30). */
  | { kind: "copied"; filenames: string[] }
  | { kind: "pasteAttachments"; insertId: string; sourceNoteId: string; text: string; items: { from: number; to: number; filename: string }[] };

/** Per dropped or pasted file (the host refuses more; larger files go through ⇧⌘V). */
export const MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;
/** Per drop or paste. */
export const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;

/** The web clipboard type that marks copied attachment links: `{noteId, filenames}`. */
export const ATTACHMENT_CLIPBOARD_TYPE = "application/x-baerchen-attachments";

// ---------------------------------------------------------------------------------------------
// Pending inserts: where the host's answer to a drop or paste goes. The range is mapped through
// every change until the answer (`insertText {text, insertId}`) arrives; a reload drops it, and
// an unknown id inserts nothing.

export const addPendingInsert = StateEffect.define<{ id: string } & Range>();
export const removePendingInsert = StateEffect.define<string>();

export const pendingInserts = StateField.define<ReadonlyMap<string, Range>>({
  create: () => new Map(),
  update(value, tr) {
    let next = value;
    if (tr.docChanged && value.size > 0) {
      next = new Map(Array.from(value, ([id, r]) => {
        // A drop point stays before text typed at it; a pasted-over range does not grow.
        if (r.from === r.to) {
          const at = tr.changes.mapPos(r.from, -1);
          return [id, { from: at, to: at }];
        }
        const from = tr.changes.mapPos(r.from, 1);
        return [id, { from, to: Math.max(from, tr.changes.mapPos(r.to, -1)) }];
      }));
    }
    for (const effect of tr.effects) {
      if (effect.is(addPendingInsert)) next = new Map(next).set(effect.value.id, { from: effect.value.from, to: effect.value.to });
      else if (effect.is(removePendingInsert) && next.has(effect.value)) {
        const copy = new Map(next);
        copy.delete(effect.value);
        next = copy;
      }
    }
    return next;
  },
});

let insertCounter = 0;
const newInsertId = () => `ins-${Date.now().toString(36)}-${(insertCounter++).toString(36)}`;

/** The id of the note the editor shows (attachment URLs). */
export const attachmentNote = Facet.define<string, string>({ combine: (values) => values[0] ?? "" });

export type AttachmentKind = "image" | "pdf" | "file";
export type Attachment = AttachmentSpan & { kind: AttachmentKind };

const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "avif"]);

const extensionOf = (name: string) => {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
};

function kindOf(span: AttachmentSpan): AttachmentKind {
  if (span.isImage) return "image";
  return extensionOf(span.filename) === "pdf" ? "pdf" : "file";
}

/** Attachment links on the lines touching `ranges` (default: the whole document), in order. */
export function attachmentsIn(state: EditorState, ranges?: readonly Range[]): Attachment[] {
  const out: Attachment[] = [];
  const spans = ranges ?? [{ from: 0, to: state.doc.length }];
  let lastLine = -1;
  for (const span of spans) {
    let line = state.doc.lineAt(span.from);
    for (;;) {
      if (line.number > lastLine) {
        lastLine = line.number;
        if (line.text.length > 0 && !lineInCode(state, line)) {
          for (const a of scanInline(line.text).attachments) {
            out.push({ ...a, from: line.from + a.from, to: line.from + a.to, linkEnd: line.from + a.linkEnd, kind: kindOf(a) });
          }
        }
      }
      if (line.to >= span.to || line.number >= state.doc.lines) break;
      line = state.doc.line(line.number + 1);
    }
  }
  return out;
}

/** The attachment whose range contains `pos` (its edges included). */
export function attachmentAt(state: EditorState, pos: number): Attachment | null {
  const line = state.doc.lineAt(pos);
  return attachmentsIn(state, [{ from: line.from, to: line.to }]).find((a) => a.from <= pos && pos <= a.to) ?? null;
}

/**
 * The selected attachment (Bear: "selected attachments look selected"). A field, not a range
 * selection: WebKit moves a range end that sits after collapsed, non-editable text, so the caret
 * goes after the attachment and this remembers which one is selected. Any edit or caret move
 * away from its edges deselects it.
 */
export const selectAttachment = StateEffect.define<Range | null>();

export const selectedAttachmentRange = StateField.define<Range | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(selectAttachment)) return effect.value;
    if (!value || tr.docChanged) return null;
    if (tr.selection) {
      const main = tr.selection.main;
      if (!main.empty || (main.head !== value.from && main.head !== value.to)) return null;
    }
    return value;
  },
});

/** The selected attachment, if it is still one. */
export function selectedAttachment(state: EditorState): Attachment | null {
  const range = state.field(selectedAttachmentRange, false);
  if (!range) return null;
  const found = attachmentAt(state, range.from);
  return found && found.from === range.from && found.to === range.to ? found : null;
}

/** Selects attachment `a`: the caret after it, the widget drawn selected. */
export function selectAttachmentSpec(a: Range): TransactionSpec {
  return { selection: EditorSelection.cursor(a.to), effects: selectAttachment.of({ from: a.from, to: a.to }), userEvent: "select.pointer" };
}

// ---------------------------------------------------------------------------------------------
// Markdown (mirrors AttachmentMarkdown.swift)

/** Percent-encodes everything but RFC 3986 unreserved characters (AttachmentLinkRewriter.encode). */
export function encodeFilename(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

const escapeTitle = (text: string) => text.replace(/\\/g, "\\\\").replace(/\[/g, "\\[").replace(/\]/g, "\\]");

/** The Markdown for a newly inserted attachment. */
export function attachmentLink(filename: string): string {
  const destination = encodeFilename(filename);
  const ext = extensionOf(filename);
  if (IMAGE_EXTENSIONS.has(ext)) return `![](${destination})`;
  const comment = ext === "pdf" ? '<!-- {"preview":"true","embed":"true"} -->' : '<!-- {"embed":"true"} -->';
  return `[${escapeTitle(filename)}](${destination})${comment}`;
}

// The same shape as AttachmentMarkdown.swift `pattern`, `<…>` destinations included.
const SOURCE = /^(!?\[(?:\\.|[^\\\]])*\]\((?:[^()\s<>]+|<[^<>\n]*>)\))(?:([ \t]*)<!--\s*(\{.*\})\s*-->)?$/s;

/**
 * Sets (`value`) or removes (`null`) one metadata key of an attachment's source, keeping the
 * other keys in their order; adds the comment when there is none. Null for anything else.
 */
export function settingMetadata(source: string, key: string, value: string | null): string | null {
  const m = SOURCE.exec(source);
  if (!m) return null;
  const [, link, gap = "", json] = m;
  let entries: [string, string][] = [];
  if (json) {
    try {
      const parsed: unknown = JSON.parse(json);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        entries = Object.entries(parsed).map(([k, v]) => [k, typeof v === "string" ? v : String(v)]);
      }
    } catch {
      entries = [];
    }
  }
  const index = entries.findIndex(([k]) => k === key);
  if (value === null) {
    if (index >= 0) entries.splice(index, 1);
  } else if (index >= 0) entries[index]![1] = value;
  else entries.push([key, value]);
  if (entries.length === 0) return link!;
  return `${link}${gap}<!-- ${JSON.stringify(Object.fromEntries(entries))} -->`;
}

/** The change an image resize makes: `width` (whole CSS pixels) merged into the metadata. */
export function resizeSpec(state: EditorState, attachment: Attachment, width: number): TransactionSpec {
  const source = state.doc.sliceString(attachment.from, attachment.to);
  const insert = settingMetadata(source, "width", String(Math.max(1, Math.round(width)))) ?? source;
  return { changes: { from: attachment.from, to: attachment.to, insert }, userEvent: "input.attachment" };
}

export function attachmentURL(noteId: string, filename: string, endpoint: "attachment" | "thumbnail" = "attachment"): string {
  return `baerchen-asset://${endpoint}/${encodeURIComponent(noteId)}/${encodeFilename(filename)}`;
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = n / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${Math.round(value * 10) / 10} ${units[unit]}`;
}

// ---------------------------------------------------------------------------------------------
// Widgets

export type AttachmentWidgetSpec = {
  kind: AttachmentKind;
  noteId: string;
  filename: string;
  /** Image width from the metadata (CSS pixels). */
  width?: number;
  /** PDF first-page preview (metadata `preview`, on unless "false"). */
  preview: boolean;
  selected: boolean;
  /** Find & replace (M3 Task 10) while its panel is open: a match lies in the link; `current`: the selected one. */
  findMatch?: "match" | "current";
};

export type AttachmentDecorationSpec = { from: number; to: number; widget: AttachmentWidgetSpec };

/**
 * The find panel's matches inside `[from, to)`: the widget hides the text CodeMirror would mark, so
 * it carries the highlight itself (`current` when the selection is one of them).
 */
function findMatchIn(state: EditorState, from: number, to: number): AttachmentWidgetSpec["findMatch"] {
  if (!searchPanelOpen(state)) return undefined;
  const query = getSearchQuery(state);
  if (!query.valid) return undefined;
  const { main } = state.selection;
  let found: AttachmentWidgetSpec["findMatch"];
  const cursor = query.getCursor(state, from, to);
  for (let m = cursor.next(); !m.done; m = cursor.next()) {
    if (m.value.from === main.from && m.value.to === main.to) return "current";
    found = "match";
  }
  return found;
}

/** What the plugin draws for the attachments touching `ranges` (pure, for tests). */
export function attachmentDecorationSpecs(state: EditorState, ranges?: readonly Range[]): AttachmentDecorationSpec[] {
  const noteId = state.facet(attachmentNote);
  const selected = state.field(selectedAttachmentRange, false) ?? null;
  return attachmentsIn(state, ranges).map((a) => {
    const width = Number.parseInt(a.metadata.width ?? "", 10);
    const findMatch = findMatchIn(state, a.from, a.to);
    return {
      from: a.from,
      to: a.to,
      widget: {
        kind: a.kind,
        noteId,
        filename: a.filename,
        ...(a.kind === "image" && Number.isFinite(width) && width > 0 && { width }),
        preview: a.metadata.preview !== "false",
        selected: selected?.from === a.from && selected.to === a.to,
        ...(findMatch && { findMatch }),
      },
    };
  });
}

function emit(view: EditorView, detail: AttachmentEventDetail): void {
  view.dom.dispatchEvent(new CustomEvent(ATTACHMENT_EVENT, { bubbles: true, detail }));
}

/** The attachment a widget DOM node draws (positions move with edits, so looked up on use). */
function attachmentOf(view: EditorView, dom: HTMLElement): Attachment | null {
  const pos = view.posAtDOM(dom);
  return attachmentAt(view.state, pos);
}

function select(view: EditorView, a: Attachment): void {
  view.dispatch(selectAttachmentSpec(a));
  view.focus();
}

const attachmentTouchCleanup = new WeakMap<HTMLElement, () => void>();

export class AttachmentWidget extends WidgetType {
  constructor(readonly spec: AttachmentWidgetSpec) {
    super();
  }

  override eq(other: AttachmentWidget): boolean {
    const a = this.spec;
    const b = other.spec;
    return a.kind === b.kind && a.noteId === b.noteId && a.filename === b.filename && a.width === b.width &&
      a.preview === b.preview && a.selected === b.selected && a.findMatch === b.findMatch;
  }

  override ignoreEvent(): boolean {
    return true;
  }

  toDOM(view: EditorView): HTMLElement {
    const { kind, filename, selected, findMatch } = this.spec;
    const root = document.createElement("span");
    root.className = `cm-bc-attachment cm-bc-attachment-${kind}` + (selected ? " cm-bc-attachment-selected" : "") +
      // The find panel's match classes (search.ts theme).
      (findMatch ? " cm-searchMatch" : "") + (findMatch === "current" ? " cm-searchMatch-selected" : "");
    root.dataset.filename = filename;
    root.setAttribute("aria-hidden", "true");
    root.draggable = false;
    if (kind === "image") this.image(view, root);
    else this.card(root);

    root.addEventListener("mousedown", (event) => {
      if (event.button !== 0 || (event.target as HTMLElement).classList.contains("cm-bc-attachment-resize")) return;
      event.preventDefault();
      const a = attachmentOf(view, root);
      if (a) select(view, a);
    });
    root.addEventListener("dblclick", (event) => {
      event.preventDefault();
      emit(view, { kind: "quickLook", filename: this.spec.filename });
    });
    const menu = () => {
      const a = attachmentOf(view, root);
      if (!a) return;
      const source = view.state.doc.sliceString(a.from, a.to);
      select(view, a);
      emit(view, { kind: "menu", filename: a.filename, from: a.from, to: a.to, source });
    };
    root.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      menu();
    });
    // Touch users need a visible, accessible action rather than a hover resize handle.
    // The empty button adds no source text; media/card contents remain AX-hidden.
    if (navigator.maxTouchPoints > 0) {
      root.removeAttribute("aria-hidden");
      root.classList.add("cm-bc-attachment-touch");
      root.style.setProperty("-webkit-touch-callout", "none");
      for (const child of root.children) child.setAttribute("aria-hidden", "true");
      const actions = document.createElement("button");
      actions.type = "button";
      actions.className = "cm-bc-attachment-actions";
      actions.setAttribute("aria-label", `Attachment actions: ${filename}`);
      actions.setAttribute("aria-haspopup", "dialog");
      actions.addEventListener("mousedown", (event) => { event.preventDefault(); event.stopPropagation(); });
      actions.addEventListener("click", (event) => { event.preventDefault(); event.stopPropagation(); menu(); });
      root.append(actions);
      let timer: ReturnType<typeof setTimeout> | undefined;
      let x = 0, y = 0;
      const cancel = () => { if (timer !== undefined) clearTimeout(timer); timer = undefined; };
      root.addEventListener("pointerdown", (event) => {
        if (event.pointerType !== "touch" || (event.target as HTMLElement).closest(".cm-bc-attachment-actions")) return;
        cancel(); x = event.clientX; y = event.clientY;
        timer = setTimeout(() => { timer = undefined; if (root.isConnected) menu(); }, 600);
      });
      root.addEventListener("pointermove", (event) => { if (Math.hypot(event.clientX - x, event.clientY - y) > 10) cancel(); });
      root.addEventListener("pointerup", (event) => {
        if (event.pointerType !== "touch" || timer === undefined) return;
        cancel();
        const a = attachmentOf(view, root);
        if (a) emit(view, { kind: "tap", filename: a.filename, from: a.from, to: a.to,
          source: view.state.doc.sliceString(a.from, a.to) });
      });
      root.addEventListener("pointercancel", cancel);
      attachmentTouchCleanup.set(root, cancel);
    }
    return root;
  }

  /**
   * Every image, SVG included, is an `<img>` (R25): SVG never becomes inline DOM, an `<object>`
   * or an `<iframe>`, so a script inside it cannot run. The host serves it as `image/svg+xml`
   * under the attachment CSP.
   */
  override destroy(dom: HTMLElement) {
    attachmentTouchCleanup.get(dom)?.();
    attachmentTouchCleanup.delete(dom);
  }

  private image(view: EditorView, root: HTMLElement): void {
    const { noteId, filename, width } = this.spec;
    const img = document.createElement("img");
    img.className = "cm-bc-attachment-img";
    img.loading = "lazy";
    img.decoding = "async";
    img.alt = "";
    img.draggable = false;
    img.src = attachmentURL(noteId, filename);
    if (width) img.style.width = `${width}px`;
    root.append(img);

    if (extensionOf(filename) === "gif") {
      // Still until clicked (Bear): the first frame on a canvas, the animation on click.
      const still = document.createElement("canvas");
      still.className = "cm-bc-attachment-img cm-bc-attachment-still";
      root.classList.add("cm-bc-attachment-gif");
      img.addEventListener("load", () => {
        still.width = img.naturalWidth;
        still.height = img.naturalHeight;
        still.getContext("2d")?.drawImage(img, 0, 0);
        if (width) still.style.width = `${width}px`;
      }, { once: true });
      root.prepend(still);
      root.addEventListener("click", () => root.classList.toggle("cm-bc-attachment-playing"));
    }

    const handle = document.createElement("span");
    handle.className = "cm-bc-attachment-resize";
    handle.addEventListener("mousedown", (event) => {
      if (event.button !== 0 || view.state.readOnly) return;
      event.preventDefault();
      event.stopPropagation();
      const media = Array.from(root.querySelectorAll<HTMLElement>(".cm-bc-attachment-img"))
        .find((el) => el.getBoundingClientRect().width > 0) ?? img;
      const startX = event.clientX;
      const startWidth = media.getBoundingClientRect().width;
      const maxWidth = view.contentDOM.clientWidth;
      let current = startWidth;
      const move = (e: MouseEvent) => {
        current = Math.min(maxWidth, Math.max(16, startWidth + e.clientX - startX));
        for (const el of root.querySelectorAll<HTMLElement>(".cm-bc-attachment-img")) el.style.width = `${current}px`;
      };
      const up = () => {
        window.removeEventListener("mousemove", move);
        window.removeEventListener("mouseup", up);
        const a = attachmentOf(view, root);
        if (a && Math.round(current) !== Math.round(startWidth)) view.dispatch(resizeSpec(view.state, a, current));
      };
      window.addEventListener("mousemove", move);
      window.addEventListener("mouseup", up);
    });
    root.append(handle);
  }

  private card(root: HTMLElement): void {
    const { kind, noteId, filename, preview } = this.spec;
    if (kind === "pdf" && preview) {
      root.classList.add("cm-bc-attachment-preview");
      const page = document.createElement("img");
      page.className = "cm-bc-attachment-page";
      page.loading = "lazy";
      page.alt = "";
      page.draggable = false;
      page.src = attachmentURL(noteId, filename, "thumbnail");
      root.append(page);
    }
    const info = document.createElement("span");
    info.className = "cm-bc-attachment-card";
    const icon = document.createElement("img");
    icon.className = "cm-bc-attachment-icon";
    icon.alt = "";
    icon.draggable = false;
    icon.src = attachmentURL(noteId, filename, "thumbnail") + "?icon";
    const name = document.createElement("span");
    name.className = "cm-bc-attachment-name";
    name.textContent = filename;
    const meta = document.createElement("span");
    meta.className = "cm-bc-attachment-meta";
    info.append(icon, name, meta);
    root.append(info);
    // Size and date from the host's response headers (no body).
    if (typeof fetch === "function") {
      fetch(attachmentURL(noteId, filename), { method: "HEAD" })
        .then((response) => {
          if (!response.ok) return;
          const size = Number(response.headers.get("Content-Length"));
          const modified = response.headers.get("Last-Modified");
          const parts = [Number.isFinite(size) && size >= 0 ? formatBytes(size) : null,
            modified ? new Date(modified).toLocaleDateString() : null].filter(Boolean);
          meta.textContent = parts.join(" · ");
        })
        .catch(() => {});
    }
  }
}

function buildDecorations(view: EditorView): { decorations: DecorationSet; atomic: DecorationSet } {
  const specs = attachmentDecorationSpecs(view.state, view.visibleRanges);
  const ranges = specs.flatMap((s) => [
    Decoration.widget({ widget: new AttachmentWidget(s.widget), side: 1 }).range(s.from),
    hiddenMark.range(s.from, s.to),
  ]);
  return {
    decorations: Decoration.set(ranges, true),
    atomic: Decoration.set(specs.map((s) => hiddenMark.range(s.from, s.to)), true),
  };
}

const attachmentPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    atomic: DecorationSet;
    stale = false;

    constructor(view: EditorView) {
      ({ decorations: this.decorations, atomic: this.atomic } = buildDecorations(view));
    }

    update(update: ViewUpdate) {
      const changed = update.docChanged || update.selectionSet || update.viewportChanged ||
        update.startState.field(selectedAttachmentRange, false) !== update.state.field(selectedAttachmentRange, false) ||
        update.startState.facet(attachmentNote) !== update.state.facet(attachmentNote) ||
        syntaxTree(update.startState) !== syntaxTree(update.state) ||
        searchPanelOpen(update.startState) !== searchPanelOpen(update.state) ||
        !getSearchQuery(update.startState).eq(getSearchQuery(update.state));
      switch (hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale })) {
        case "map":
          this.decorations = this.decorations.map(update.changes);
          this.atomic = this.atomic.map(update.changes);
          this.stale ||= changed;
          return;
        case "rebuild":
          ({ decorations: this.decorations, atomic: this.atomic } = buildDecorations(update.view));
          this.stale = false;
          return;
        case "keep":
          return;
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

/** Removes the selected attachment's link (one undo step; the file follows with the cleanup). */
function deleteSelected(view: EditorView): boolean {
  const a = selectedAttachment(view.state);
  if (!a || view.state.readOnly) return false;
  view.dispatch({ changes: { from: a.from, to: a.to }, selection: EditorSelection.cursor(a.from), userEvent: "delete.attachment" });
  return true;
}

/** Space on a selected attachment: Quick Look (the host's panel). Backspace/Delete remove it. */
const selectionKeys = Prec.high(keymap.of([
  {
    key: "Space",
    run: (view) => {
      const a = selectedAttachment(view.state);
      if (!a) return false;
      emit(view, { kind: "quickLook", filename: a.filename });
      return true;
    },
  },
  { key: "Backspace", run: deleteSelected },
  { key: "Delete", run: deleteSelected },
  {
    key: "Escape",
    run: (view) => {
      if (!view.state.field(selectedAttachmentRange, false)) return false;
      view.dispatch({ effects: selectAttachment.of(null) });
      return true;
    },
  },
]));

function hasFiles(data: DataTransfer | null): boolean {
  return !!data && (data.files.length > 0 || Array.from(data.types ?? []).includes("Files"));
}

/** The files a drop or paste may send, or the names of those over the caps. */
export function checkUploadSizes(files: readonly { name: string; size: number }[]): { ok: true } | { ok: false; filenames: string[] } {
  const large = files.filter((f) => f.size > MAX_ATTACHMENT_BYTES).map((f) => f.name || "file");
  if (large.length > 0) return { ok: false, filenames: large };
  const total = files.reduce((sum, f) => sum + f.size, 0);
  return total > MAX_UPLOAD_BYTES ? { ok: false, filenames: files.map((f) => f.name || "file") } : { ok: true };
}

/** Sends `files` to the host for `[from, to)` (a drop point or the pasted-over selection). */
function upload(view: EditorView, files: File[], from: number, to: number): void {
  const sizes = checkUploadSizes(files);
  if (!sizes.ok) return emit(view, { kind: "refused", filenames: sizes.filenames });
  const insertId = newInsertId();
  view.dispatch({ effects: addPendingInsert.of({ id: insertId, from, to }) });
  emit(view, { kind: "upload", insertId, files });
}

/** The attachments a text holds (pasted text, parsed on its own). */
export function attachmentsInText(text: string): Attachment[] {
  const state = EditorState.create({ doc: text, extensions: [markdown({ base: bearMarkdown })] });
  ensureSyntaxTree(state, state.doc.length, 1000);
  return attachmentsIn(state);
}

/** What ⌘C / ⌘X put on the clipboard: the text, plus the attachment files it links. */
export function copiedAttachments(state: EditorState): { text: string; ranges: Range[]; payload: string } | null {
  let ranges: Range[] = state.selection.ranges.filter((r) => !r.empty).map((r) => ({ from: r.from, to: r.to }));
  if (ranges.length === 0) {
    const selected = selectedAttachment(state);
    if (selected) ranges = [{ from: selected.from, to: selected.to }];
  }
  const filenames = [...new Set(ranges.flatMap((r) =>
    attachmentsIn(state, [r]).filter((a) => a.from >= r.from && a.to <= r.to).map((a) => a.filename)))];
  if (filenames.length === 0) return null;
  return {
    text: ranges.map((r) => state.sliceDoc(r.from, r.to)).join(state.lineBreak),
    ranges,
    payload: JSON.stringify({ noteId: state.facet(attachmentNote), filenames }),
  };
}

function copy(event: ClipboardEvent, view: EditorView, cut: boolean): boolean {
  const data = event.clipboardData;
  const copied = data && copiedAttachments(view.state);
  if (!data || !copied) return false;
  event.preventDefault();
  data.clearData();
  data.setData("text/plain", copied.text);
  data.setData(ATTACHMENT_CLIPBOARD_TYPE, copied.payload);
  emit(view, { kind: "copied", filenames: (JSON.parse(copied.payload) as { filenames: string[] }).filenames });
  if (cut && !view.state.readOnly) {
    view.dispatch({ changes: copied.ranges, scrollIntoView: true, userEvent: "delete.cut" });
  }
  return true;
}

/**
 * Attachment links copied from another note: the host copies their files into this note (Bear
 * copies on paste) and inserts the text, links renamed where a name was taken. Within the same
 * note the default paste keeps the links as they are.
 */
function pasteAttachmentLinks(event: ClipboardEvent, view: EditorView): boolean {
  const data = event.clipboardData;
  const raw = data?.getData(ATTACHMENT_CLIPBOARD_TYPE);
  if (!data || !raw) return false;
  let source: { noteId?: unknown; filenames?: unknown };
  try {
    source = JSON.parse(raw) as typeof source;
  } catch {
    return false;
  }
  const noteId = view.state.facet(attachmentNote);
  if (typeof source.noteId !== "string" || source.noteId === noteId || !Array.isArray(source.filenames)) return false;
  const names = new Set(source.filenames.filter((n): n is string => typeof n === "string"));
  const text = data.getData("text/plain");
  const items = attachmentsInText(text).filter((a) => names.has(a.filename)).map(({ from, to, filename }) => ({ from, to, filename }));
  if (items.length === 0) return false;
  event.preventDefault();
  if (view.state.readOnly) return true;
  const { from, to } = view.state.selection.main;
  const insertId = newInsertId();
  view.dispatch({ effects: addPendingInsert.of({ id: insertId, from, to }) });
  emit(view, { kind: "pasteAttachments", insertId, sourceNoteId: source.noteId, text, items });
  return true;
}

/** Files dropped or pasted into the editor go to the host (drop: at the drop point). */
const fileInput = Prec.high(EditorView.domEventHandlers({
  dragover(event) {
    if (!hasFiles(event.dataTransfer)) return false;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
    return true;
  },
  drop(event, view) {
    const files = Array.from(event.dataTransfer?.files ?? []);
    if (files.length === 0) return false;
    event.preventDefault();
    if (view.state.readOnly) return true;
    const at = view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.head;
    view.dispatch({ selection: { anchor: at }, userEvent: "select.pointer" });
    upload(view, files, at, at);
    return true;
  },
  paste(event, view) {
    const files = Array.from(event.clipboardData?.files ?? []);
    if (files.length === 0) return pasteAttachmentLinks(event, view);
    event.preventDefault();
    if (view.state.readOnly) return true;
    const { from, to } = view.state.selection.main;
    upload(view, files, from, to);
    return true;
  },
  copy: (event, view) => copy(event, view, false),
  cut: (event, view) => copy(event, view, true),
}));

const attachmentTheme = EditorView.baseTheme({
  // The widget sits inside the collapsed range: undo the hidden-text styles for it.
  ".cm-content .cm-bc-attachment, .cm-content .cm-bc-attachment *": {
    fontFamily: "-apple-system, system-ui, sans-serif",
    fontSize: "13px",
    lineHeight: "1.3",
    color: "var(--bc-color-text)",
    letterSpacing: "normal",
    wordSpacing: "normal",
  },
  ".cm-bc-attachment": {
    position: "relative",
    display: "inline-block",
    maxWidth: "100%",
    verticalAlign: "bottom",
    borderRadius: "6px",
    cursor: "default",
    userSelect: "none",
  },
  ".cm-bc-attachment-selected": { outline: "3px solid var(--bc-color-accent)", outlineOffset: "1px" },
  ".cm-bc-attachment-img": { display: "block", maxWidth: "100%", height: "auto", borderRadius: "4px" },
  ".cm-bc-attachment-gif > img.cm-bc-attachment-img": { display: "none" },
  ".cm-bc-attachment-gif.cm-bc-attachment-playing > img.cm-bc-attachment-img": { display: "block" },
  ".cm-bc-attachment-gif.cm-bc-attachment-playing > canvas": { display: "none" },
  ".cm-bc-attachment-touch": { minWidth: "44px", minHeight: "44px" },
  ".cm-bc-attachment-actions": {
    position: "absolute", right: "0", top: "0", width: "44px", height: "44px",
    border: "1px solid currentColor", borderRadius: "8px", padding: "0",
    background: "var(--bc-color-bg)", color: "var(--bc-color-text)", cursor: "pointer",
  },
  ".cm-bc-attachment-actions::before": { content: '"⋯"', fontSize: "24px" },
  ".cm-bc-attachment-touch .cm-bc-attachment-resize": { display: "none" },
  ".cm-bc-attachment-resize": {
    position: "absolute",
    right: "2px",
    bottom: "2px",
    width: "12px",
    height: "12px",
    borderRight: "3px solid var(--bc-color-secondary)",
    borderBottom: "3px solid var(--bc-color-secondary)",
    borderRadius: "0 0 3px 0",
    cursor: "nwse-resize",
    opacity: "0",
  },
  ".cm-bc-attachment:hover .cm-bc-attachment-resize": { opacity: "1" },
  ".cm-bc-attachment-card": {
    display: "inline-grid",
    gridTemplateColumns: "32px auto",
    gridTemplateRows: "auto auto",
    columnGap: "8px",
    alignItems: "center",
    padding: "6px 10px 6px 6px",
    border: "1px solid var(--bc-color-rule)",
    borderRadius: "6px",
    backgroundColor: "var(--bc-color-code-bg)",
    maxWidth: "100%",
  },
  ".cm-bc-attachment-icon": { gridRow: "1 / span 2", width: "32px", height: "32px" },
  ".cm-bc-attachment-name": { fontWeight: "600", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  ".cm-content .cm-bc-attachment .cm-bc-attachment-meta": { color: "var(--bc-color-secondary)", fontSize: "11px" },
  ".cm-bc-attachment-preview": { display: "inline-flex", flexDirection: "column", gap: "4px" },
  ".cm-bc-attachment-page": {
    display: "block",
    maxWidth: "min(100%, 420px)",
    border: "1px solid var(--bc-color-rule)",
    borderRadius: "4px",
  },
});

export const attachments: Extension = [
  selectedAttachmentRange,
  pendingInserts,
  attachmentPlugin,
  EditorView.atomicRanges.of((view) => view.plugin(attachmentPlugin)?.atomic ?? Decoration.none),
  selectionKeys,
  fileInput,
  attachmentTheme,
];
