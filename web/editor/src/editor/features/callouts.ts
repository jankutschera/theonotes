// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Callouts (M6 Task 10): a blockquote whose first line starts, right after its quote mark,
// with `[!TYPE]` (letters, any case) is a callout box: tinted lines per type (theme variables
// `--bc-color-callout-<type>-*`), an icon that opens the native type menu, and a title (the text
// after the marker, else the type's default). An unknown type renders as NOTE. A nested quote with
// its own marker is a nested box. The marker is hidden markup (it stays in the DOM) unless the
// caret is on its line; the icon and the default title have no text nodes (F8: innerText is the
// document).

import {
  type ChangeSpec,
  EditorSelection,
  EditorState,
  type Extension,
  type Range as Ranged,
  type TransactionSpec,
} from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import { isolateHistory } from "@codemirror/commands";
import { CALLOUT_TYPES, type CalloutType, type CaretRect } from "../../bridge/protocol";
import type { CommandArgs } from "../../bridge/protocol";
import { hiddenMark, hidingUpdatePlan } from "./hiding";
import { lineInCode } from "./lists";
import { resolveMenuTarget } from "./menu-targets";
import type { CommandTarget } from "./commands";

type Range = { from: number; to: number };
type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

export type Callout = {
  type: CalloutType;
  known: boolean;
  markerFrom: number;
  markerTo: number;
  /** The title shown: the text after the marker, else the type's default. */
  title: string;
  /** Whether `title` is the text after the marker (not the default). */
  custom: boolean;
};

const MARKER = /^\[!([A-Za-z]+)\]/;
const DEFAULT_TITLES: Record<CalloutType, string> = {
  note: "Note",
  tip: "Tip",
  important: "Important",
  warning: "Warning",
  caution: "Caution",
};
const isType = (s: string): s is CalloutType => (CALLOUT_TYPES as readonly string[]).includes(s);

function calloutOf(state: EditorState, quote: SyntaxNode): Callout | null {
  const mark = quote.firstChild;
  if (!mark || mark.name !== "QuoteMark") return null;
  const line = state.doc.lineAt(mark.from);
  let at = mark.to;
  const space = state.doc.sliceString(at, at + 1);
  if (space === " " || space === "\t") at++;
  const m = MARKER.exec(state.doc.sliceString(at, line.to));
  if (!m) return null;
  const name = m[1]!.toLowerCase();
  const known = isType(name);
  const type: CalloutType = known ? name : "note";
  const markerTo = at + m[0].length;
  const rest = state.doc.sliceString(markerTo, line.to).trim();
  return { type, known, markerFrom: at, markerTo, title: rest || DEFAULT_TITLES[type], custom: rest !== "" };
}

function quoteAt(state: EditorState, quoteFrom: number): SyntaxNode | null {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(quoteFrom, 1); n; n = n.parent) {
    if (n.name === "Blockquote" && n.from === quoteFrom) return n;
  }
  return null;
}

/** The callout of the blockquote starting at `quoteFrom`, or null (no blockquote, no marker). */
export function calloutAt(state: EditorState, quoteFrom: number): Callout | null {
  const quote = quoteAt(state, quoteFrom);
  return quote ? calloutOf(state, quote) : null;
}

/** The innermost callout whose blockquote holds `pos` (its node and callout). */
function innermostCallout(state: EditorState, pos: number): { quote: SyntaxNode; callout: Callout } | null {
  for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); n; n = n.parent) {
    if (n.name !== "Blockquote") continue;
    const callout = calloutOf(state, n);
    if (callout) return { quote: n, callout };
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Layout (pure, for the view plugin and tests)

export type CalloutLayout = {
  /** Line classes by line start. */
  lines: Map<number, string>;
  /** Marker text to hide (the caret is not on its line). */
  hidden: Range[];
  /** Icon widgets: before the marker, opening the type menu of the callout at `quoteFrom`. */
  icons: { pos: number; type: CalloutType; quoteFrom: number }[];
  /** Default-title widgets (no custom title, marker hidden), after the marker. */
  titles: { pos: number; title: string }[];
};

/** The callout layout of the lines in `within` (default: the whole document). */
export function calloutLayout(state: EditorState, within?: readonly Range[]): CalloutLayout {
  const { doc } = state;
  const sel = state.selection.ranges;
  const tree = syntaxTree(state);
  const layout: CalloutLayout = { lines: new Map(), hidden: [], icons: [], titles: [] };
  const lineClasses = new Map<number, { type: CalloutType; parent: CalloutType | null; depth: number; first: boolean; last: boolean }>();
  const seen = new Set<number>();
  for (const span of within ?? [{ from: 0, to: doc.length }]) {
    tree.iterate({
      from: span.from,
      to: span.to,
      enter(ref) {
        if (ref.name !== "Blockquote" || seen.has(ref.from)) return;
        seen.add(ref.from);
        const callout = calloutOf(state, ref.node);
        if (!callout) return;
        let depth = 1;
        let parent: CalloutType | null = null;
        for (let p = ref.node.parent; p; p = p.parent) {
          const outer = p.name === "Blockquote" ? calloutOf(state, p) : null;
          if (!outer) continue;
          depth++;
          parent ??= outer.type;
        }
        const first = doc.lineAt(ref.from);
        const last = doc.lineAt(ref.to);
        // Outer callouts come first in the walk: an inner one overwrites the lines it holds.
        for (let n = first.number; n <= last.number; n++) {
          lineClasses.set(doc.line(n).from, { type: callout.type, parent, depth, first: n === first.number, last: n === last.number });
        }
        const onLine = sel.some((r) => r.from <= first.to && r.to >= first.from);
        layout.icons.push({ pos: callout.markerFrom, type: callout.type, quoteFrom: ref.from });
        if (!onLine) {
          const after = doc.sliceString(callout.markerTo, callout.markerTo + 1);
          const hideTo = callout.custom && (after === " " || after === "\t") ? callout.markerTo + 1 : callout.markerTo;
          layout.hidden.push({ from: callout.markerFrom, to: hideTo });
          if (!callout.custom) layout.titles.push({ pos: callout.markerTo, title: callout.title });
        }
      },
    });
  }
  for (const [from, c] of lineClasses) {
    const classes = ["cm-bc-callout", `cm-bc-callout-${c.type}`, `cm-bc-callout-depth-${c.depth}`];
    // The box around a nested one keeps its edge and tint beside it.
    if (c.parent) classes.push(`cm-bc-callout-in-${c.parent}`);
    if (c.first) classes.push("cm-bc-callout-first");
    if (c.last) classes.push("cm-bc-callout-last");
    layout.lines.set(from, classes.join(" "));
  }
  return layout;
}

// ---------------------------------------------------------------------------------------------
// Commands

const FORMAT_EVENT = "input.format";
const edit = (state: EditorState, spec: TransactionSpec) =>
  state.update({ scrollIntoView: true, ...spec, userEvent: FORMAT_EVENT, annotations: isolateHistory.of("full") });

const typeArg = (args: CommandArgs | undefined): CalloutType | null => {
  const t = args?.type;
  return typeof t === "string" && isType(t) ? t : null;
};

/** The selected lines (a range ending at a line start leaves that line out). */
function selectedLines(state: EditorState) {
  const numbers = new Set<number>();
  for (const r of state.selection.ranges) {
    const last = r.empty || r.to > state.doc.lineAt(r.to).from ? r.to : r.to - 1;
    for (let n = state.doc.lineAt(r.from).number; n <= state.doc.lineAt(last).number; n++) numbers.add(n);
  }
  return [...numbers].sort((a, b) => a - b).map((n) => state.doc.line(n));
}

/**
 * Format ▸ Callout `{type?}` (default NOTE): on an empty line `> [!NOTE] ` with the caret at the
 * end; otherwise a `> [!NOTE]` line above each run of selected lines, each of which gets `> `.
 * One undo step; refused in read-only notes and in code.
 */
export function calloutCommand({ state, dispatch }: CommandTarget, args?: CommandArgs): boolean {
  if (state.readOnly) return false;
  const marker = `[!${(typeArg(args) ?? "note").toUpperCase()}]`;
  const lines = selectedLines(state);
  if (lines.some((line) => lineInCode(state, line))) return false;
  const first = lines[0]!;
  if (lines.length === 1 && /^\s*$/.test(first.text)) {
    const insert = `> ${marker} `;
    dispatch(edit(state, { changes: { from: first.from, to: first.to, insert }, selection: EditorSelection.cursor(first.from + insert.length) }));
    return true;
  }
  // One callout per run of adjacent lines (disjoint cursors make several).
  const specs: ChangeSpec[] = [];
  lines.forEach((line, i) => {
    if (i === 0 || lines[i - 1]!.number !== line.number - 1) specs.push({ from: line.from, insert: `> ${marker}\n` });
    specs.push({ from: line.from, insert: /\S/.test(line.text) ? "> " : ">" });
  });
  const changes = state.changes(specs);
  dispatch(edit(state, { changes, selection: state.selection.map(changes, 1) }));
  return true;
}

/**
 * The type menu's command `{type, menuId?}`: rewrites the marker of the callout at the menu's
 * target (else the innermost callout around the caret) as `[!TYPE]`, nothing else.
 */
export function setCalloutTypeCommand({ state, dispatch }: CommandTarget, args?: CommandArgs): boolean {
  if (state.readOnly) return false;
  const type = typeArg(args);
  if (!type) return false;
  const target = resolveMenuTarget(state, args);
  if (target.kind === "dead") return false;
  const pos = target.kind === "target" ? target.pos : state.selection.main.head;
  let found: Callout | null = null;
  if (target.kind === "target") {
    // The menu target is the callout's first line start: the callout whose marker is on that line.
    const line = state.doc.lineAt(pos);
    for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(line.to, -1); n; n = n.parent) {
      if (n.name !== "Blockquote") continue;
      const c = calloutOf(state, n);
      if (c && c.markerFrom >= line.from && c.markerTo <= line.to) found = c;
    }
  } else {
    found = innermostCallout(state, pos)?.callout ?? null;
  }
  if (!found) return false;
  const insert = `[!${type.toUpperCase()}]`;
  if (state.doc.sliceString(found.markerFrom, found.markerTo) === insert) return true;
  dispatch(edit(state, { changes: { from: found.markerFrom, to: found.markerTo, insert }, scrollIntoView: false }));
  return true;
}

// ---------------------------------------------------------------------------------------------
// View

export const CALLOUT_MENU_EVENT = "baerchen-callout-menu";
export type CalloutMenuDetail = { quoteFrom: number; calloutType: CalloutType; rect: CaretRect };

class CalloutIcon extends WidgetType {
  constructor(readonly type: CalloutType, readonly quoteFrom: number) {
    super();
  }
  override eq(other: CalloutIcon) {
    return other.type === this.type && other.quoteFrom === this.quoteFrom;
  }
  override toDOM(view: EditorView) {
    const el = document.createElement("span");
    el.className = `cm-bc-callout-icon cm-bc-callout-icon-${this.type}`;
    el.setAttribute("aria-hidden", "true");
    el.addEventListener("mousedown", (event) => event.preventDefault());
    el.addEventListener("click", (event) => {
      event.preventDefault();
      const r = el.getBoundingClientRect();
      const detail: CalloutMenuDetail = {
        quoteFrom: this.quoteFrom,
        calloutType: this.type,
        rect: { x: r.left, y: r.top, width: Math.max(1, r.width), height: r.height },
      };
      view.dom.dispatchEvent(new CustomEvent(CALLOUT_MENU_EVENT, { bubbles: true, detail }));
    });
    return el;
  }
  override ignoreEvent() {
    return true;
  }
}

class CalloutTitle extends WidgetType {
  constructor(readonly title: string) {
    super();
  }
  override eq(other: CalloutTitle) {
    return other.title === this.title;
  }
  override toDOM() {
    const el = document.createElement("span");
    el.className = "cm-bc-callout-default-title";
    // A pseudo-element shows it: no text node, so innerText stays the document.
    el.dataset.title = this.title;
    el.setAttribute("aria-hidden", "true");
    return el;
  }
}

function calloutDecorations(view: EditorView): DecorationSet {
  const layout = calloutLayout(view.state, view.visibleRanges);
  const ranges: Ranged<Decoration>[] = [];
  for (const [from, cls] of layout.lines) ranges.push(Decoration.line({ class: cls }).range(from));
  for (const icon of layout.icons) {
    ranges.push(Decoration.widget({ widget: new CalloutIcon(icon.type, icon.quoteFrom), side: -1 }).range(icon.pos));
  }
  for (const r of layout.hidden) ranges.push(hiddenMark.range(r.from, r.to));
  for (const t of layout.titles) ranges.push(Decoration.widget({ widget: new CalloutTitle(t.title), side: 1 }).range(t.pos));
  return Decoration.set(ranges, true);
}

const calloutPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    stale = false;
    constructor(view: EditorView) {
      this.decorations = calloutDecorations(view);
    }
    update(update: ViewUpdate) {
      const changed =
        update.docChanged ||
        update.viewportChanged ||
        update.selectionSet ||
        syntaxTree(update.startState) !== syntaxTree(update.state);
      // Never rebuilt while composing (global constraint): kept aligned, rebuilt afterwards.
      const plan = hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale });
      if (plan === "rebuild") {
        this.decorations = calloutDecorations(update.view);
        this.stale = false;
        return;
      }
      if (update.docChanged) this.decorations = this.decorations.map(update.changes);
      if (plan === "map") this.stale ||= changed;
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

// 16×16 outline icons drawn with CSS masks (currentColor = the type's icon colour).
const svg = (body: string) =>
  `url("data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='none' stroke='black' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'>${body}</svg>`,
  )}")`;
const ICONS: Record<CalloutType, string> = {
  note: svg("<circle cx='8' cy='8' r='6.25'/><path d='M8 7.25v4'/><path d='M8 4.75v.01'/>"),
  tip: svg("<path d='M5.5 10.5a4.25 4.25 0 1 1 5 0c-.6.45-.9 1-.9 1.75h-3.2c0-.75-.3-1.3-.9-1.75z'/><path d='M6.5 14.25h3'/>"),
  important: svg("<path d='M2.25 3.5a1.25 1.25 0 0 1 1.25-1.25h9a1.25 1.25 0 0 1 1.25 1.25v6.5a1.25 1.25 0 0 1-1.25 1.25H7l-3 2.5v-2.5h-.5a1.25 1.25 0 0 1-1.25-1.25z'/><path d='M8 4.75v3'/><path d='M8 9.5v.01'/>"),
  warning: svg("<path d='M7.13 2.5a1 1 0 0 1 1.74 0l5.5 9.75a1 1 0 0 1-.87 1.5H2.5a1 1 0 0 1-.87-1.5z'/><path d='M8 6.25v3'/><path d='M8 11.25v.01'/>"),
  caution: svg("<path d='M5.4 1.75h5.2l3.65 3.65v5.2l-3.65 3.65H5.4L1.75 10.6V5.4z'/><path d='M8 5v3.5'/><path d='M8 10.75v.01'/>"),
};

const typeStyles = Object.fromEntries(
  CALLOUT_TYPES.flatMap((t) => [
    [
      `.cm-line.cm-bc-callout-${t}`,
      {
        "--bc-callout-bg": `var(--bc-color-callout-${t}-bg)`,
        "--bc-callout-border": `var(--bc-color-callout-${t}-border)`,
        "--bc-callout-icon": `var(--bc-color-callout-${t}-icon)`,
        "--bc-callout-title": `var(--bc-color-callout-${t}-title)`,
      },
    ],
    [`.cm-bc-callout-icon-${t}`, { maskImage: ICONS[t], WebkitMaskImage: ICONS[t] }],
    [
      `.cm-line.cm-bc-callout-in-${t}`,
      { "--bc-callout-outer-bg": `var(--bc-color-callout-${t}-bg)`, "--bc-callout-outer-border": `var(--bc-color-callout-${t}-border)` },
    ],
  ]),
);

const calloutTheme = EditorView.baseTheme({
  ...typeStyles,
  ".cm-line.cm-bc-callout": {
    backgroundColor: "var(--bc-callout-bg)",
    borderLeft: "3px solid var(--bc-callout-border)",
    color: "inherit",
  },
  ".cm-line.cm-bc-callout-first": {
    borderTopRightRadius: "6px",
    paddingTop: "4px",
    fontWeight: "600",
    color: "var(--bc-callout-title)",
  },
  ".cm-line.cm-bc-callout-last": { borderBottomRightRadius: "6px", paddingBottom: "4px" },
  // A nested box: indented by one step per level inside its parent's tinted edge (deeper levels
  // show their direct parent's edge only).
  ...Object.fromEntries(
    [2, 3, 4, 5, 6].map((d) => {
      const inset = `${(d - 1) * 1.25}em`;
      return [
        `.cm-line.cm-bc-callout-depth-${d}`,
        {
          borderLeft: "3px solid var(--bc-callout-outer-border)",
          // Through the quote padding, which list lines in a quote build on (typography.ts).
          "--bc-quote-pad": `calc(6px + 0.6em + ${inset})`,
          backgroundImage: `linear-gradient(to right, var(--bc-callout-outer-bg) 0 calc(${inset} - 3px), var(--bc-callout-border) calc(${inset} - 3px) ${inset}, var(--bc-callout-bg) ${inset})`,
          backgroundColor: "transparent",
        },
      ];
    }),
  ),
  ".cm-bc-callout-icon": {
    display: "inline-block",
    width: "1em",
    height: "1em",
    marginRight: "0.4em",
    verticalAlign: "-0.15em",
    backgroundColor: "var(--bc-callout-icon)",
    maskRepeat: "no-repeat",
    WebkitMaskRepeat: "no-repeat",
    maskSize: "contain",
    WebkitMaskSize: "contain",
    cursor: "pointer",
  },
  ".cm-bc-callout-default-title::after": { content: "attr(data-title)" },
});

export const callouts: Extension = [calloutPlugin, calloutTheme];
