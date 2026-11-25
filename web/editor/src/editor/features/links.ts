// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import {
  type ChangeSpec,
  EditorSelection,
  type EditorState,
  type Extension,
  Facet,
  RangeSetBuilder,
  StateEffect,
  StateField,
  type TransactionSpec,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { isolateHistory } from "@codemirror/commands";
import type { CaretRect, EditLinkFields, OpenLinkFields } from "../../bridge/protocol";
import { parseWikiLink, tagName } from "../dialect-grammar";
import { hidingUpdatePlan } from "./hiding";
import { footnotesIn } from "./footnotes";
import { codeAt, lineInCode } from "./lists";
import type { CommandTarget, EditorCommand } from "./commands";

// Links, wiki links and tags (spec §4.4, inventory §2.2.1): a plain click places the caret (the
// text stays editable), ⌘-click opens (⌥⌘-click: a wiki link in a new window), and an
// aria-hidden icon after an external link opens it; on a touch screen a tap opens (`touchTap`).
// ⇧⌘K / ⌥⇧⌘K open the link at the caret, ⌘K asks the host for its link panel (`editLinkRequest`, answered with `setLink`), ⌘D inserts a wiki
// link and ⇧⌘E a footnote. The editor only reports what a link points at; the host decides what
// it opens (only http, https and mailto leave the app).

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];
type Tree = ReturnType<typeof syntaxTree>;

/** A link without the window choice. */
export type LinkTarget = Omit<OpenLinkFields, "newWindow">;
export type LinkEditRange = Omit<EditLinkFields, "caretRect" | "requestId">;

/** Where links go: the bridge client in the app and in mock mode; nothing in plain tests. */
export type LinkHandlers = {
  openLink?: (link: OpenLinkFields) => void;
  editLink?: (request: EditLinkFields) => void;
};

type PendingRange = { from: number; to: number };

const addLinkRequest = StateEffect.define<{ id: string } & PendingRange>();
const takeLinkRequest = StateEffect.define<string>();
/** Open requests kept at most (a panel that never answered is forgotten eventually). */
const MAX_LINK_REQUESTS = 8;

/**
 * The ranges of open ⌘K requests by id, mapped through every transaction (typing, external
 * changes), so the panel's late answer replaces the text it was opened for. A range whose text was
 * deleted is dropped; `setLink` with an unknown id is refused.
 */
const linkRequests = StateField.define<ReadonlyMap<string, PendingRange>>({
  create: () => new Map(),
  update(value, tr) {
    let next: Map<string, PendingRange> | null = null;
    const edit = () => (next ??= new Map(value));
    if (tr.docChanged) {
      for (const [id, r] of value) {
        const from = tr.changes.mapPos(r.from, 1);
        const to = tr.changes.mapPos(r.to, -1);
        if (to < from || (r.to > r.from && to === from)) edit().delete(id);
        else edit().set(id, { from, to });
      }
    }
    for (const effect of tr.effects) {
      if (effect.is(addLinkRequest)) {
        const map = edit();
        map.set(effect.value.id, { from: effect.value.from, to: effect.value.to });
        while (map.size > MAX_LINK_REQUESTS) map.delete(map.keys().next().value!);
      } else if (effect.is(takeLinkRequest)) edit().delete(effect.value);
    }
    return next ?? value;
  },
});

export const linkHandlers = Facet.define<LinkHandlers, LinkHandlers>({
  combine: (values) => values[0] ?? {},
  enables: linkRequests,
});

let requestSeq = 0;
const requestPrefix = Math.random().toString(36).slice(2, 8);
const newRequestId = () => `link-${requestPrefix}-${++requestSeq}`;

function treeFor(state: EditorState, pos: number): Tree {
  return ensureSyntaxTree(state, Math.min(state.doc.length, pos + 2000), 50) ?? syntaxTree(state);
}

function edit(state: EditorState, spec: TransactionSpec, userEvent = "input.format") {
  return state.update({ scrollIntoView: true, ...spec, userEvent, annotations: isolateHistory.of("full") });
}

/** A URL node of a link, image or autolink belongs to that element. */
const URL_PARENTS = new Set(["Link", "Image", "Autolink"]);
const CONSTRUCTS = new Set(["Link", "Image", "Autolink", "URL", "WikiLink", "Tag"]);

const isConstruct = (n: { name: string; node: SyntaxNode }) =>
  CONSTRUCTS.has(n.name) && !(n.name === "URL" && URL_PARENTS.has(n.node.parent?.name ?? ""));

/** The innermost link-like element around `pos`: strictly inside, or edges included. */
function constructAt(tree: Tree, pos: number, inclusive: boolean): SyntaxNode | null {
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(pos, side); n; n = n.parent) {
      if (!isConstruct(n)) continue;
      if (inclusive ? n.from <= pos && pos <= n.to : n.from < pos && pos < n.to) return n;
    }
  }
  return null;
}

const SCHEME = /^[a-z][a-z0-9+.-]*:/i;

function hrefTarget(raw: string): LinkTarget | null {
  let href = raw.trim();
  if (href.startsWith("<") && href.endsWith(">")) href = href.slice(1, -1).trim();
  if (!href) return null;
  if (/^bear:/i.test(href)) return { kind: "bearURL", target: href };
  return { kind: SCHEME.test(href) ? "url" : "attachment", target: href };
}

function targetOf(state: EditorState, node: SyntaxNode): LinkTarget | null {
  const text = (from: number, to: number) => state.doc.sliceString(from, to);
  switch (node.name) {
    case "WikiLink": {
      const wiki = parseWikiLink(text(node.from, node.to), 0);
      if (!wiki) return null;
      return { kind: "wiki", target: wiki.target, ...(wiki.heading !== null && { heading: wiki.heading }) };
    }
    case "Tag":
      return { kind: "tag", target: tagName(text(node.from, node.to)) };
    case "Autolink":
      return hrefTarget(text(node.from + 1, node.to - 1));
    case "URL":
      return hrefTarget(text(node.from, node.to));
    case "Link":
    case "Image": {
      const url = node.getChild("URL");
      return url ? hrefTarget(text(url.from, url.to)) : null;
    }
    default:
      return null;
  }
}

/** What the link, wiki link or tag at `pos` points at (`inclusive`: its edges count too). */
export function linkTargetAt(state: EditorState, pos: number, inclusive = false): LinkTarget | null {
  const node = constructAt(treeFor(state, pos), pos, inclusive);
  return node ? targetOf(state, node) : null;
}

// ---------------------------------------------------------------------------------------------
// ⌘K

const LOOKS_LIKE_URL = /^(?:[a-z][a-z0-9+.-]*:\/\/\S+|mailto:\S+)$/i;

/**
 * What the link panel edits for the main selection: the link the caret is in, or that the
 * selection holds or touches (edited instead of nested); else a new link over the selection. A
 * triple-click selection's trailing newline is left out. Null: several lines, code, a wiki link
 * or image, two links, read-only.
 */
export function linkEditRequest(state: EditorState): LinkEditRange | null {
  if (state.readOnly) return null;
  const { doc } = state;
  const r = state.selection.main;
  let { from, to } = r;
  if (to > from && to === doc.lineAt(to).from) to--;
  if (doc.lineAt(from).number !== doc.lineAt(to).number) return null;
  const tree = treeFor(state, to);
  if (codeAt(tree, from) || codeAt(tree, to)) return null;
  const found: SyntaxNode[] = [];
  if (from === to) {
    const node = constructAt(tree, from, false);
    if (node) found.push(node);
  } else {
    tree.iterate({
      from,
      to,
      enter(ref) {
        if (!isConstruct(ref) || ref.name === "Tag") return;
        if (ref.to <= from || ref.from >= to) return false;
        found.push(ref.node);
        return false;
      },
    });
  }
  if (found.length > 1) return null;
  const node = found[0];
  const text = (a: number, b: number) => doc.sliceString(a, b);
  if (!node || node.name === "Tag") {
    const selected = text(from, to);
    return { from, to, title: selected, url: LOOKS_LIKE_URL.test(selected) ? selected : "", editing: false };
  }
  switch (node.name) {
    case "Link": {
      const marks = node.getChildren("LinkMark");
      const [open, close] = marks;
      const url = node.getChild("URL");
      return {
        from: node.from,
        to: node.to,
        title: text(open?.to ?? node.from, close?.from ?? node.to),
        url: url ? text(url.from, url.to) : "",
        // Only an inline `[title](url)` (its `(`…`)` marks) is edited; `[foo]` / `[foo][bar]` are not.
        editing: marks.length >= 4,
      };
    }
    case "Autolink": {
      const url = text(node.from + 1, node.to - 1);
      return { from: node.from, to: node.to, title: url, url, editing: false };
    }
    case "URL": {
      const url = text(node.from, node.to);
      return { from: node.from, to: node.to, title: url, url, editing: false };
    }
    default:
      return null; // wiki links and images are not edited in the link panel
  }
}

const NO_RECT: CaretRect = { x: 0, y: 0, width: 0, height: 0 };

/** The caret's viewport rect when the target is a view (state-only targets in tests: zeros). */
function caretRectOf(target: CommandTarget, pos: number): CaretRect {
  const view = target as Partial<EditorView>;
  if (typeof view.coordsAtPos !== "function") return NO_RECT;
  const c = view.coordsAtPos(pos, -1) ?? view.coordsAtPos(pos, 1);
  if (!c) return NO_RECT;
  return { x: c.left, y: c.top, width: Math.max(1, c.right - c.left), height: c.bottom - c.top };
}

/**
 * ⌘K: remembers the range under a new request id (no edit, no undo step) and asks the host for the
 * link panel; the text changes only with the panel's `setLink`.
 */
export const linkCommand: EditorCommand = (target) => {
  const { state } = target;
  const handler = state.facet(linkHandlers).editLink;
  const request = handler ? linkEditRequest(state) : null;
  if (!handler || !request) return false;
  const requestId = newRequestId();
  const head = state.selection.main.head;
  const caretRect = caretRectOf(target, Math.min(Math.max(head, request.from), request.to));
  target.dispatch(state.update({ effects: addLinkRequest.of({ id: requestId, from: request.from, to: request.to }) }));
  handler({ requestId, ...request, caretRect });
  return true;
};

/** Characters a link destination keeps as they are (RFC 3986 unreserved + reserved, minus parentheses). */
const URL_KEEP = /^[A-Za-z0-9\-._~:/?#[\]@!$&'*+,;=]$/;
const utf8 = new TextEncoder();

/** Percent-encodes what would break `[title](url)` (blanks, parentheses, non-ASCII, …); `%XX` escapes stay. */
export function encodeLinkUrl(url: string): string {
  let out = "";
  for (let i = 0; i < url.length; ) {
    const ch = String.fromCodePoint(url.codePointAt(i)!);
    i += ch.length;
    if (ch === "%" && /^[0-9A-Fa-f]{2}$/.test(url.slice(i, i + 2))) out += ch;
    else if (URL_KEEP.test(ch)) out += ch;
    else for (const byte of utf8.encode(ch)) out += `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

/** Unescaped brackets of `text` pair up. */
function bracketsBalanced(text: string): boolean {
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "\\") i++;
    else if (c === "[") depth++;
    else if (c === "]" && --depth < 0) return false;
  }
  return depth === 0;
}

const linkTitle = (title: string) => {
  const text = title.replace(/\r\n?|\n/g, " ");
  const escaped = bracketsBalanced(text)
    ? text
    : text.replace(/(\\.)|([[\]])/g, (_m, pair: string | undefined, bracket: string) => pair ?? `\\${bracket}`);
  // An odd run of backslashes at the end would escape the closing `]`.
  const trailing = /\\+$/.exec(escaped)?.[0].length ?? 0;
  return trailing % 2 === 1 ? `${escaped}\\` : escaped;
};

const uint = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

/**
 * The link panel's answer to the ⌘K request `requestId`: `[title](url)` replaces the request's
 * range (as mapped since) with the URL percent-encoded; an empty title shows the URL, an empty URL
 * leaves the plain title (removes the link), both empty keep the text. One undo step; each request
 * is answered once. Refused for an unknown id or a range whose text was deleted.
 */
export const setLink: EditorCommand = ({ state, dispatch }, args) => {
  const { requestId, title, url } = args ?? {};
  if (state.readOnly || typeof requestId !== "string" || typeof title !== "string" || typeof url !== "string") return false;
  const range = state.field(linkRequests, false)?.get(requestId);
  if (!range || range.to > state.doc.length) return false;
  const href = url.trim();
  const text = title.replace(/\r\n?|\n/g, " ");
  if (!href && !text) return false;
  const insert = href ? `[${linkTitle(text || href)}](${encodeLinkUrl(href)})` : text;
  const { from, to } = range;
  dispatch(
    edit(state, {
      changes: { from, to, insert },
      selection: EditorSelection.cursor(from + insert.length),
      effects: takeLinkRequest.of(requestId),
    }),
  );
  return true;
};

// ---------------------------------------------------------------------------------------------
// ⇧⌘K, ⌘D, ⇧⌘E

/** ⇧⌘K opens the link at the caret (edges included); ⌥⇧⌘K (`window: "new"`) in a new window. */
export const openLinkCommand: EditorCommand = ({ state }, args) => {
  const handler = state.facet(linkHandlers).openLink;
  if (!handler) return false;
  const head = state.selection.main.head;
  const link = linkTargetAt(state, head) ?? linkTargetAt(state, head, true);
  if (!link) return false;
  handler({ ...link, newWindow: args?.window === "new" });
  return true;
};

function wikiLinkAt(tree: Tree, pos: number): boolean {
  for (const side of [1, -1] as const) {
    for (let n: SyntaxNode | null = tree.resolveInner(pos, side); n; n = n.parent) {
      if (n.name === "WikiLink" && n.from < pos && pos < n.to) return true;
    }
  }
  return false;
}

const isBlank = (c: string) => c === " " || c === "\t";

/**
 * ⌘D: `[[]]` with the caret inside, or the selection wrapped (blanks stay outside, caret after
 * `]]`). Refused over several lines, in code, inside a wiki link, or when the selection holds
 * `[[` / `]]`.
 */
export const wikiLink: EditorCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const { doc } = state;
  let { from, to } = state.selection.main;
  if (to > from && to === doc.lineAt(to).from) to--;
  if (doc.lineAt(from).number !== doc.lineAt(to).number) return false;
  const tree = treeFor(state, to);
  if (codeAt(tree, from) || codeAt(tree, to) || wikiLinkAt(tree, from) || wikiLinkAt(tree, to)) return false;
  while (from < to && isBlank(doc.sliceString(from, from + 1))) from++;
  while (to > from && isBlank(doc.sliceString(to - 1, to))) to--;
  if (/\[\[|\]\]/.test(doc.sliceString(from, to))) return false;
  if (from === to) {
    dispatch(edit(state, { changes: { from, insert: "[[]]" }, selection: EditorSelection.cursor(from + 2) }));
    return true;
  }
  const changes = state.changes([
    { from, insert: "[[" },
    { from: to, insert: "]]" },
  ]);
  dispatch(edit(state, { changes, selection: EditorSelection.cursor(to + 4) }));
  return true;
};

const DEFINITION = /^\[\^[^\]\s]+\]:/;

const NEW_FOOTNOTE = "\u0000new";
const isNumber = (label: string) => /^\d+$/.test(label);

/**
 * ⇧⌘E (inventory §2.2.1): a numbered reference after the selection and its definition at the end
 * of the note, caret in the definition. Numbered labels follow the order of their references, so
 * inserting before others renumbers those (references and definitions). Named labels and code stay.
 */
export const footnote: EditorCommand = ({ state, dispatch }) => {
  if (state.readOnly) return false;
  const { doc } = state;
  const tree = ensureSyntaxTree(state, doc.length, 200) ?? syntaxTree(state);
  let pos = state.selection.main.to;
  if (codeAt(tree, pos) || lineInCode(state, doc.lineAt(pos), tree)) return false;
  const marks = footnotesIn(state, undefined, tree).map((f) => ({
    start: f.from, end: f.to, labelFrom: f.labelFrom, label: f.label, definition: f.kind === "def",
  }));
  // Never inside an existing `[^label]`.
  for (const m of marks) if (m.start < pos && pos < m.end) pos = m.end;

  const order: string[] = [];
  for (const m of marks) {
    if (m.definition) continue;
    if (!order.includes(NEW_FOOTNOTE) && m.start >= pos) order.push(NEW_FOOTNOTE);
    if (isNumber(m.label) && !order.includes(m.label)) order.push(m.label);
  }
  if (!order.includes(NEW_FOOTNOTE)) order.push(NEW_FOOTNOTE);
  const numbers = new Map(order.map((label, i) => [label, i + 1]));
  for (const m of marks) if (m.definition && isNumber(m.label) && !numbers.has(m.label)) numbers.set(m.label, numbers.size + 1);

  const specs: ChangeSpec[] = [];
  for (const m of marks) {
    const n = isNumber(m.label) ? String(numbers.get(m.label)) : m.label;
    if (n !== m.label) specs.push({ from: m.labelFrom, to: m.labelFrom + m.label.length, insert: n });
  }
  const ref = `[^${numbers.get(NEW_FOOTNOTE)}]`;
  specs.push({ from: pos, insert: ref });
  // Definitions stay together: right below a definition, else after a blank line.
  const after = doc.sliceString(0, pos) + ref + doc.sliceString(pos);
  const lastLine = after.trimEnd().split("\n").at(-1) ?? "";
  let separator = DEFINITION.test(lastLine) ? "\n" : "\n\n";
  if (after.endsWith("\n")) separator = separator.slice(1);
  specs.push({ from: doc.length, insert: `${separator}${ref}: ` });
  const changes = state.changes(specs);
  dispatch(edit(state, { changes, selection: EditorSelection.cursor(changes.newLength) }, "input"));
  return true;
};

// ---------------------------------------------------------------------------------------------
// Inline styles over link markup (commands.ts)

/** Elements a style must take whole when a selection reaches into them. */
const WHOLE = new Set(["Autolink", "WikiLink", "URL"]);

/**
 * A styled segment never splits link markup: one that crosses a link's or image's boundary, or
 * reaches into its URL, grows to the whole element (inside the link text it stays, but images
 * nested there count); autolinks, bare URLs and wiki links are always taken whole.
 */
export function expandOverLinks(tree: Tree, seg: { from: number; to: number }): { from: number; to: number } {
  let { from, to } = seg;
  for (let round = 0; round < 8; round++) {
    const before = { from, to };
    tree.iterate({
      from,
      to,
      enter(ref) {
        if (ref.to <= from || ref.from >= to) return false;
        if (ref.name === "Link" || ref.name === "Image") {
          const marks = ref.node.getChildren("LinkMark");
          const textFrom = marks[0]?.to ?? ref.from;
          const textTo = marks[1]?.from ?? ref.to;
          if (from >= textFrom && to <= textTo) return; // inside the text: look at what it holds
          from = Math.min(from, ref.from);
          to = Math.max(to, ref.to);
          return false;
        }
        if (WHOLE.has(ref.name) && isConstruct(ref)) {
          from = Math.min(from, ref.from);
          to = Math.max(to, ref.to);
          return false;
        }
        return;
      },
    });
    if (from === before.from && to === before.to) break;
  }
  return { from, to };
}

// ---------------------------------------------------------------------------------------------
// The view: ⌘-click and the external-link icon

const EXTERNAL = /^(?:https?|mailto):/i;

class OpenLinkIcon extends WidgetType {
  constructor(readonly href: string) {
    super();
  }

  override eq(other: OpenLinkIcon) {
    return other.href === this.href;
  }

  toDOM(view: EditorView) {
    const el = document.createElement("span");
    el.className = "cm-bc-link-open";
    el.setAttribute("aria-hidden", "true");
    // Keep focus and selection where they are; the click opens.
    el.addEventListener("mousedown", (event) => event.preventDefault());
    el.addEventListener("click", (event) => {
      event.preventDefault();
      view.state.facet(linkHandlers).openLink?.({ kind: "url", target: this.href, newWindow: false });
    });
    return el;
  }

  override ignoreEvent() {
    return true;
  }
}

/** An open icon after every external `[title](url)` link in the visible ranges. */
function linkIcons(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const tree = syntaxTree(view.state);
  let last = -1;
  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(ref) {
        if (ref.name !== "Link") return;
        const url = ref.node.getChild("URL");
        const target = url && hrefTarget(view.state.doc.sliceString(url.from, url.to));
        if (target && target.kind === "url" && EXTERNAL.test(target.target) && ref.to > last) {
          builder.add(ref.to, ref.to, Decoration.widget({ widget: new OpenLinkIcon(target.target), side: 1 }));
          last = ref.to;
        }
        return false;
      },
    });
  }
  return builder.finish();
}

const iconPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    stale = false;

    constructor(view: EditorView) {
      this.decorations = linkIcons(view);
    }

    update(update: ViewUpdate) {
      const changed = update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state);
      // Never rebuilt while composing (global constraint): kept aligned, rebuilt afterwards.
      const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
      if (plan === "rebuild") {
        this.decorations = linkIcons(update.view);
        this.stale = false;
        return;
      }
      if (update.docChanged) this.decorations = this.decorations.map(update.changes);
      if (plan === "map") this.stale ||= changed;
    }
  },
  {
    decorations: (plugin) => plugin.decorations,
    eventHandlers: {
      compositionend(_event, view) {
        afterComposition(() => {
          if (this.stale && !view.composing) view.dispatch({});
        });
      },
    },
  },
);

const LINK_STYLED = ".cm-bc-link, .cm-bc-link-target, .cm-bc-wikilink, .cm-bc-tag";

/** ⌘-click opens the link, wiki link or tag under the pointer (⌥⌘: a wiki link in a new window). */
const metaClick = EditorView.domEventHandlers({
  mousedown(event, view) {
    if (!event.metaKey || event.button !== 0) return false;
    // A rendered block widget (a table grid) handles its own links (blocks.ts `click`).
    if (event.target instanceof Element && event.target.closest(".cm-bc-block")) return false;
    const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
    if (pos === null) return false;
    const onStyledLink = event.target instanceof Element && event.target.closest(LINK_STYLED) !== null;
    const link = linkTargetAt(view.state, pos) ?? (onStyledLink ? linkTargetAt(view.state, pos, true) : null);
    if (!link) return false;
    event.preventDefault();
    view.state.facet(linkHandlers).openLink?.({ ...link, newWindow: event.altKey });
    return true;
  },
});

/** A tap moves less than this (px) and ends before the system's long press (ms). */
const TAP_SLOP = 10;
const LONG_PRESS = 500;

/**
 * Touch screens (LINK-TAP-R1): a one-finger tap on a link's, wiki link's or tag's text opens it
 * like ⌘-click. A scroll, a long press, a second finger or a tap while text is selected stays
 * the system's (caret, edit menu, selection); the cancelled `touchend` keeps the caret and
 * keyboard where they were. Mouse and trackpad clicks never get here.
 */
const touchTap = ViewPlugin.fromClass(
  class {
    start: { x: number; y: number; time: number } | null = null;
  },
  {
    eventObservers: {
      touchstart(event, view) {
        const t = event.touches.length === 1 ? event.touches[0] : undefined;
        const selecting = view.hasFocus && !view.state.selection.main.empty;
        this.start = t && !selecting ? { x: t.clientX, y: t.clientY, time: event.timeStamp } : null;
      },
      touchmove(event) {
        const t = event.touches[0];
        if (this.start && (!t || Math.hypot(t.clientX - this.start.x, t.clientY - this.start.y) > TAP_SLOP)) this.start = null;
      },
      touchcancel() {
        this.start = null;
      },
    },
    eventHandlers: {
      touchend(event, view) {
        const start = this.start;
        this.start = null;
        const t = event.changedTouches[0];
        if (!start || !t || view.composing) return false;
        if (event.timeStamp - start.time >= LONG_PRESS || Math.hypot(t.clientX - start.x, t.clientY - start.y) > TAP_SLOP) return false;
        const el = event.target instanceof Element ? event.target : null;
        // A rendered block widget (a table grid) handles its own links (blocks.ts `click`).
        if (!el?.closest(LINK_STYLED) || el.closest(".cm-bc-block")) return false;
        const pos = view.posAtCoords({ x: t.clientX, y: t.clientY });
        const link = pos === null ? null : linkTargetAt(view.state, pos) ?? linkTargetAt(view.state, pos, true);
        if (!link) return false;
        view.state.facet(linkHandlers).openLink?.({ ...link, newWindow: false });
        return true;
      },
    },
  },
);

// An up-right arrow (stroke only), drawn in the link color through a mask.
const ICON =
  "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M6 3.5h6.5V10M12.5 3.5 4 12' fill='none' stroke='black' stroke-width='1.7' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\")";

const linkTheme = EditorView.baseTheme({
  ".cm-bc-link-open": {
    display: "inline-block",
    width: "0.75em",
    height: "0.75em",
    margin: "0 0.1em 0 0.15em",
    verticalAlign: "baseline",
    backgroundColor: "var(--bc-color-link)",
    maskImage: ICON,
    maskSize: "contain",
    maskRepeat: "no-repeat",
    WebkitMaskImage: ICON,
    WebkitMaskSize: "contain",
    WebkitMaskRepeat: "no-repeat",
    cursor: "pointer",
  },
});

export const links: Extension = [iconPlugin, metaClick, touchTap, linkTheme];
