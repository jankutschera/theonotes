// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { afterComposition } from "../composition";
import { type EditorState, type Extension, Facet, type Range as Ranged, RangeSet, type SelectionRange } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  gutter,
  GutterMarker,
  ViewPlugin,
  type ViewUpdate,
  WidgetType,
} from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";
import type { CaretRect } from "../../bridge/protocol";
import { codePointAt } from "../dialect-grammar";
import { highlightColors } from "../dialect";
import { hiddenMark, hidingUpdatePlan, isAttachmentLinkAt, type Range } from "./hiding";
import { type ListLayout, listLayout } from "./lists";
import { foldChevronGutter } from "./folding";

// Bear-like presentation: typography variables, heading sizes with a level badge in the gutter,
// inline bullets, quote bars, hairline rules, code backgrounds, tag pills and link colors.
// Presentation only: every character stays in the DOM (finding F8). Markers that give way to a
// widget are collapsed with the hidden mark and the widget is added next to them, aria-hidden.
// Outer marks must not partially overlap a hidden range: CodeMirror would split the hidden span
// at their boundaries (the link target class covers exactly the hidden `](url)`).
//
// Lists (lists.ts decides what a list line is): the indentation is collapsed and
// shown as padding, one step (~1.5em) per nesting level; the marker sits in a box of a fixed
// width per kind (bullet, todo, ordered by digit count), widget or raw text alike, so the text
// never jumps when the caret reaches the marker; wrapped rows hang at the item text.

/** Dispatched (bubbling) on the editor DOM when a heading badge is clicked. */
export const HEADING_MENU_EVENT = "baerchen-heading-menu";
export type HeadingMenuDetail = { line: number; level: number; rect: CaretRect };

/** What a badge click reports: the heading and the badge's own viewport rect (the native menu opens under it). */
export const headingMenuDetail = (
  line: number,
  level: number,
  box: Pick<DOMRect, "left" | "top" | "width" | "height">,
): HeadingMenuDetail => ({ line, level, rect: { x: box.left, y: box.top, width: box.width, height: box.height } });

type SyntaxNode = ReturnType<typeof syntaxTree>["topNode"];

const BULLET_GLYPHS = ["•", "◦", "▪"] as const;

/** The `•` (nested: `◦`, `▪`, then again `•`) drawn in place of a collapsed `-`, `*` or `+`. */
export class BulletWidget extends WidgetType {
  constructor(readonly level: number) {
    super();
  }

  get glyph(): string {
    return BULLET_GLYPHS[(this.level - 1) % BULLET_GLYPHS.length]!;
  }

  override eq(other: BulletWidget) {
    return other.level === this.level;
  }

  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-bc-bullet";
    // Drawn by CSS, so the line's text (and the accessibility text) stays the document text.
    el.dataset.glyph = this.glyph;
    el.setAttribute("aria-hidden", "true");
    return el;
  }
}

/** The number drawn in place of a collapsed ordered marker (`1.`, `12)`). */
export class OrderedMarkerWidget extends WidgetType {
  constructor(readonly marker: string) {
    super();
  }

  override eq(other: OrderedMarkerWidget) {
    return other.marker === this.marker;
  }

  toDOM() {
    const el = document.createElement("span");
    el.className = "cm-bc-olmark";
    // Drawn by CSS, so the accessibility text stays the (hidden) document text.
    el.dataset.marker = this.marker;
    el.setAttribute("aria-hidden", "true");
    return el;
  }
}

/**
 * The small "H1"…"H6" badge in the heading gutter: a button that opens the heading menu
 * ("Heading level N"; M7 Task 11 adds `aria-haspopup`). It sits outside `.cm-content`,
 * so the content text stays the document.
 */
export class HeadingBadge extends GutterMarker {
  constructor(readonly level: number) {
    super();
  }

  override eq(other: HeadingBadge) {
    return other.level === this.level;
  }

  override toDOM() {
    const el = document.createElement("button");
    el.type = "button";
    el.className = `cm-bc-hbadge cm-bc-hbadge-${this.level}`;
    el.dataset.level = String(this.level);
    el.setAttribute("role", "button");
    el.setAttribute("aria-label", `Heading level ${this.level}`);
    // A click opens the native heading menu (M6 Task 9); only now that the badge is exposed.
    el.setAttribute("aria-haspopup", "menu");
    const label = el.appendChild(document.createElement("span"));
    label.textContent = `H${this.level}`;
    return el;
  }
}

const cache = <T>(make: (key: string) => T) => {
  const map = new Map<string, T>();
  return (key: string) => {
    let value = map.get(key);
    if (value === undefined) map.set(key, (value = make(key)));
    return value;
  };
};
const markDeco = cache((cls) => Decoration.mark({ class: cls }));
// Heading lines carry their role for VoiceOver's heading rotor (M7 Task 11); attributes only, no
// text, so the content text still equals the document (F8). The key is the class list, so the
// level comes from its `cm-h<N>` class and decorations stay shared.
const lineDeco = cache((cls) => {
  const level = /(?:^| )cm-h(\d)(?: |$)/.exec(cls)?.[1];
  return Decoration.line(level ? { class: cls, attributes: { role: "heading", "aria-level": level } } : { class: cls });
});
const bulletDecos = new Map<number, Decoration>();
const bulletDeco = (level: number) => {
  let deco = bulletDecos.get(level);
  if (!deco) bulletDecos.set(level, (deco = Decoration.widget({ widget: new BulletWidget(level), side: 1 })));
  return deco;
};
const orderedDeco = cache((marker) => Decoration.widget({ widget: new OrderedMarkerWidget(marker), side: 1 }));
const styleDeco = cache((style) => Decoration.line({ attributes: { style } }));
const badges = Array.from({ length: 7 }, (_, level) => new HeadingBadge(level));

/** The marker box width of a list line (CSS, theme variables). */
function markWidth(layout: ListLayout): string {
  if (layout.kind === "todo") return "var(--bc-li-todo)";
  if (layout.kind === "bullet") return "var(--bc-li-bullet)";
  return `calc(${layout.marker.length - 1} * var(--bc-li-digit) + var(--bc-li-ordered))`;
}

/** Inline element → class. */
const inlineClasses: Record<string, string> = {
  StrongEmphasis: "cm-bc-strong",
  Emphasis: "cm-bc-em",
  Strikethrough: "cm-bc-strike",
  Underline: "cm-bc-underline",
  InlineCode: "cm-bc-code",
  Tag: "cm-bc-tag",
  WikiLink: "cm-bc-wikilink",
  Autolink: "cm-bc-link",
};

const touches = (sel: readonly SelectionRange[], from: number, to: number) =>
  sel.some((r) => r.from <= to && r.to >= from);

export type TypographySets = {
  /** Marks and line classes; wrap everything else (`EditorView.outerDecorations`). */
  outer: DecorationSet;
  /** Collapsed markers and the widgets shown in their place. */
  inner: DecorationSet;
  /** Gutter badges at the start of heading lines. */
  headings: RangeSet<HeadingBadge>;
};

/**
 * Typography decorations for `within` (default: the whole document; the plugin passes the
 * visible ranges). Pure. Block markers give way to their widget unless the selection is on the
 * line (quote marks, rules) or touches the marker itself (bullets, so the bullet stays while
 * typing the item).
 */
export function typographyDecorations(state: EditorState, within?: readonly Range[]): TypographySets {
  const tree = syntaxTree(state);
  const doc = state.doc;
  const sel = state.selection.ranges;
  const spans = within ?? [{ from: 0, to: doc.length }];
  const outer: Ranged<Decoration>[] = [];
  const inner: Ranged<Decoration>[] = [];
  const headings: Ranged<HeadingBadge>[] = [];
  const lineClasses = new Map<number, string[]>();

  const addLineClass = (lineFrom: number, cls: string) => {
    const list = lineClasses.get(lineFrom);
    if (!list) lineClasses.set(lineFrom, [cls]);
    else if (!list.includes(cls)) list.push(cls);
  };
  const selectionOnLine = (pos: number) => {
    const line = doc.lineAt(pos);
    return touches(sel, line.from, line.to);
  };
  const mark = (cls: string, from: number, to: number) => {
    if (to > from) outer.push(markDeco(cls).range(from, to));
  };
  const seenLines = new Set<number>();
  const listLine = (line: { from: number; to: number; text: string; number: number }) => {
    const layout = listLayout(state, line);
    if (!layout) return;
    addLineClass(line.from, layout.first ? "cm-bc-li" : "cm-bc-li-cont");
    outer.push(styleDeco(`--bc-li-level:${layout.level - 1};--bc-li-mark:${markWidth(layout)}`).range(line.from));
    if (layout.textFrom > layout.indentFrom) inner.push(hiddenMark.range(layout.indentFrom, layout.textFrom));
    // Todo items get their checkbox from todos.ts.
    if (!layout.first || layout.kind === "todo") return;
    const ordered = layout.kind === "ordered";
    if (touches(sel, layout.textFrom, layout.markerTo)) {
      return mark(ordered ? "cm-bc-li-raw cm-bc-ordered-marker" : "cm-bc-li-raw", layout.textFrom, layout.contentFrom);
    }
    const widget = ordered ? orderedDeco(layout.marker) : bulletDeco(layout.level);
    inner.push(widget.range(layout.textFrom), hiddenMark.range(layout.textFrom, layout.contentFrom));
  };

  let seenTo = -1;
  for (const span of spans) {
    const seen = seenTo;
    tree.iterate({
      from: span.from,
      to: span.to,
      enter(ref) {
        const name = ref.name;
        // Block nodes: classes on their lines inside this span (spans may split a block).
        if (name === "FencedCode" || name === "Blockquote") {
          const first = doc.lineAt(ref.from).number;
          const last = doc.lineAt(ref.to).number;
          const from = Math.max(first, doc.lineAt(Math.max(ref.from, span.from)).number);
          const to = Math.min(last, doc.lineAt(Math.min(ref.to, span.to)).number);
          for (let n = from; n <= to; n++) {
            const line = doc.line(n);
            if (name === "Blockquote") {
              addLineClass(line.from, "cm-bc-quote");
              continue;
            }
            addLineClass(line.from, "cm-bc-codeblock");
            if (n === first) addLineClass(line.from, "cm-bc-codeblock-first");
            if (n === last) addLineClass(line.from, "cm-bc-codeblock-last");
          }
          return;
        }
        // Every table line, in each span it reaches (M7's paragraph indent does not apply).
        if (name === "Table") {
          const from = doc.lineAt(Math.max(ref.from, span.from)).number;
          const to = doc.lineAt(Math.min(ref.to, span.to)).number;
          for (let n = from; n <= to; n++) addLineClass(doc.line(n).from, "cm-bc-table-line");
        }
        // Everything else is decorated once, by the first span that reaches it.
        if (ref.from < seen) return;

        const heading = /^ATXHeading(\d)$/.exec(name);
        if (heading) {
          const level = Number(heading[1]);
          const lineFrom = doc.lineAt(ref.from).from;
          addLineClass(lineFrom, "cm-bc-heading");
          addLineClass(lineFrom, `cm-h${level}`);
          headings.push(badges[level]!.range(lineFrom));
          return;
        }

        switch (name) {
          case "TableHeader":
            addLineClass(doc.lineAt(ref.from).from, "cm-bc-table-header");
            return;
          case "TableDelimiter":
            // A cell pipe, or the whole delimiter row: dimmed like revealed markup (Bear).
            mark("cm-bc-markup", ref.from, ref.to);
            return;
          case "QuoteMark": {
            if (selectionOnLine(ref.from)) return;
            const next = doc.sliceString(ref.to, ref.to + 1);
            inner.push(hiddenMark.range(ref.from, ref.to + (next === " " || next === "\t" ? 1 : 0)));
            return;
          }
          case "HorizontalRule": {
            if (selectionOnLine(ref.from)) return;
            addLineClass(doc.lineAt(ref.from).from, "cm-bc-hr");
            inner.push(hiddenMark.range(ref.from, ref.to));
            return;
          }
          case "Highlight": {
            const color = ref.node.getChild("HighlightColor");
            const name = color && highlightColors[codePointAt(doc.sliceString(color.from, color.to), 0)];
            mark(name ? `cm-bc-highlight cm-bc-highlight-${name}` : "cm-bc-highlight", ref.from, ref.to);
            return;
          }
          case "Link": {
            const link = ref.node;
            const [open, close] = link.getChildren("LinkMark");
            // A file attachment is one collapsed card (attachments.ts): no marks may cut it.
            if (!link.getChild("URL") || !open || !close || isAttachmentLinkAt(state, link.from)) return;
            mark("cm-bc-link", open.to, close.from);
            mark("cm-bc-link-target", close.from, link.to);
            return;
          }
          case "URL": {
            const parent = ref.node.parent?.name;
            if (parent !== "Link" && parent !== "Image" && parent !== "Autolink") mark("cm-bc-link", ref.from, ref.to);
            return;
          }
        }
        const cls = inlineClasses[name];
        if (cls) mark(cls, ref.from, ref.to);
      },
    });
    seenTo = span.to;
    for (let pos = span.from; pos <= span.to; ) {
      const line = doc.lineAt(pos);
      if (!seenLines.has(line.from)) {
        seenLines.add(line.from);
        listLine(line);
      }
      pos = line.to + 1;
    }
  }

  for (const [lineFrom, classes] of lineClasses) outer.push(lineDeco(classes.join(" ")).range(lineFrom));
  return {
    outer: Decoration.set(outer, true),
    inner: Decoration.set(inner, true),
    headings: RangeSet.of(headings, true),
  };
}

const typographyPlugin = ViewPlugin.fromClass(
  class {
    sets: TypographySets;
    stale = false;

    constructor(view: EditorView) {
      this.sets = typographyDecorations(view.state, view.visibleRanges);
    }

    update(update: ViewUpdate) {
      const changed =
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        syntaxTree(update.startState) !== syntaxTree(update.state);
      switch (hidingUpdatePlan({ changed, composing: update.view.composing, stale: this.stale })) {
        case "map": {
          // Never touch the DOM around an IME composition; catch up when it ends.
          const { outer, inner, headings } = this.sets;
          this.sets = { outer: outer.map(update.changes), inner: inner.map(update.changes), headings: headings.map(update.changes) };
          this.stale ||= changed;
          return;
        }
        case "rebuild":
          this.sets = typographyDecorations(update.view.state, update.view.visibleRanges);
          this.stale = false;
          return;
        case "keep":
          return;
      }
    }
  },
  {
    eventHandlers: {
      compositionend(_event, view) {
        afterComposition(() => {
          if (this.stale && !view.composing) view.dispatch({});
        });
      },
    },
  },
);

const badgeAt = (event: Event) =>
  event.target instanceof Element ? event.target.closest<HTMLElement>(".cm-bc-hbadge") : null;

/** Whether the heading gutter shows its H1…H6 badges (setting `showHeadingLevels`, default on). */
export const showHeadingLevels = Facet.define<boolean, boolean>({ combine: (values) => values[0] ?? true });

/**
 * The badges the gutter shows: none when the setting is off. The gutter itself stays (its width
 * is fixed by the theme), so the text column does not move.
 */
export const headingBadgeMarkers = (state: EditorState, headings: RangeSet<HeadingBadge>): RangeSet<HeadingBadge> =>
  state.facet(showHeadingLevels) ? headings : RangeSet.empty;

const headingGutter = gutter({
  class: "cm-bc-heading-gutter",
  markers: (view) => headingBadgeMarkers(view.state, view.plugin(typographyPlugin)?.sets.headings ?? RangeSet.empty),
  lineMarkerChange: (update) => update.startState.facet(showHeadingLevels) !== update.state.facet(showHeadingLevels),
  domEventHandlers: {
    // Keep the caret and focus where they are.
    mousedown(_view, _line, event) {
      if (!badgeAt(event)) return false;
      event.preventDefault();
      return true;
    },
    click(view, line, event) {
      const badge = badgeAt(event);
      if (!badge) return false;
      const detail = headingMenuDetail(view.state.doc.lineAt(line.from).number, Number(badge.dataset.level), badge.getBoundingClientRect());
      view.dom.dispatchEvent(new CustomEvent(HEADING_MENU_EVENT, { bubbles: true, detail }));
      return true;
    },
  },
});

/**
 * The typography the editor starts with (the CSS variables below); `setSettings.typography`
 * replaces them. Fixtures/themes/typography-defaults.json holds the same numbers for the host.
 */
export const TYPOGRAPHY_DEFAULTS = { fontSize: 16, lineHeight: 1.6, lineWidth: 720, paragraphSpacing: 0.4, paragraphIndent: 0 } as const;

/** The default font stacks; `setSettings` fonts go in front of them (settings.ts), so a missing glyph still falls back. */
export const FONT_STACKS = {
  text: '-apple-system, "SF Pro Text", system-ui, sans-serif',
  heading: '-apple-system, "SF Pro Display", "SF Pro Text", system-ui, sans-serif',
  code: 'ui-monospace, "SF Mono", Menlo, monospace',
} as const;

/** Code blocks are set in this fraction of the text size. */
const CODE_SCALE = 0.875;

/**
 * CodeMirror marks its gutter container `aria-hidden`; ours holds controls (the heading badges and
 * the fold chevrons, each a labelled `role="button"`), so it is exposed. The gutters hold nothing
 * else that reads (no line numbers), and they are outside `.cm-content` (finding F8 holds).
 */
const exposeGutters = ViewPlugin.define((view) => {
  const expose = () => {
    // The scroller's own children only (a handful), never a search of the content.
    for (const child of view.scrollDOM.children) if (child.classList.contains("cm-gutters")) child.removeAttribute("aria-hidden");
  };
  // The gutter view builds its DOM in the same plugin pass as this one.
  queueMicrotask(expose);
  return { update: expose };
});

/** Heading scale (em of the text size); the gutter badge box uses the same, so it lines up. */
const headingScale = [1.6, 1.4, 1.25, 1.1, 1, 1] as const;
const HEADING_LINE_HEIGHT = "1.3";
const HEADING_PADDING_TOP = "0.5em";

type StyleSpec = Record<string, Record<string, string>>;

/**
 * Inline markup (bold, italic, code, tags, links, highlights): the editor theme and the table
 * grid's shadow root (tables.ts) share these rules, so they exist once.
 */
const inlineMarkupStyles: StyleSpec = {
  ".cm-bc-strong": { fontWeight: "700" },
  ".cm-bc-em": { fontStyle: "italic" },
  ".cm-bc-strike": { textDecoration: "line-through", color: "var(--bc-color-secondary)" },
  ".cm-bc-underline": { textDecoration: "underline", textUnderlineOffset: "0.15em" },
  ".cm-bc-code": {
    fontFamily: "var(--bc-font-code)",
    fontSize: "0.875em",
    backgroundColor: "var(--bc-color-code-bg)",
    borderRadius: "3px",
    // Visual padding without moving the text (caret geometry stays exact).
    boxShadow: "0 0 0 0.15em var(--bc-color-code-bg)",
  },
  ".cm-bc-tag": {
    color: "var(--bc-color-tag)",
    backgroundColor: "var(--bc-color-tag-bg)",
    borderRadius: "4px",
    boxShadow: "0 0 0 0.12em var(--bc-color-tag-bg)",
  },
  ".cm-bc-link, .cm-bc-wikilink": { color: "var(--bc-color-link)", cursor: "pointer" },
  ".cm-bc-link:hover, .cm-bc-wikilink:hover": { textDecoration: "underline" },
  ".cm-bc-link-target": { color: "var(--bc-color-secondary)" },

  ".cm-bc-highlight": { backgroundColor: "var(--bc-highlight)", borderRadius: "3px" },
  ...Object.fromEntries(
    ["green", "red", "blue", "yellow", "purple"].map((c) => [`.cm-bc-highlight-${c}`, { backgroundColor: `var(--bc-highlight-${c})` }]),
  ),
};

/** CSS text of a style spec (camelCase properties, `Webkit…` → `-webkit-…`). */
export function cssText(spec: StyleSpec): string {
  return Object.entries(spec)
    .map(([selector, props]) => {
      const body = Object.entries(props)
        .map(([prop, value]) => `${prop.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}: ${value};`)
        .join(" ");
      return `${selector} { ${body} }`;
    })
    .join("\n");
}

/** The inline markup rules as CSS text, for widget shadow roots. */
export const INLINE_MARKUP_CSS = cssText(inlineMarkupStyles);

const typographyTheme = EditorView.theme({
  "&": {
    "--bc-font-text": FONT_STACKS.text,
    "--bc-font-heading": FONT_STACKS.heading,
    "--bc-font-code": FONT_STACKS.code,
    "--bc-size": `${TYPOGRAPHY_DEFAULTS.fontSize}px`,
    "--bc-line-height": `${TYPOGRAPHY_DEFAULTS.lineHeight}`,
    "--bc-line-width": `${TYPOGRAPHY_DEFAULTS.lineWidth}px`,
    "--bc-paragraph-spacing": `${TYPOGRAPHY_DEFAULTS.paragraphSpacing}em`,
    "--bc-paragraph-indent": `${TYPOGRAPHY_DEFAULTS.paragraphIndent}em`,
    "--bc-gutter-width": "52px",
    // The fold gutter (chevrons) takes the left part of the gutter width, the heading gutter the rest.
    "--bc-fold-gutter-width": "16px",
    // Lists: one nesting step and the marker box widths.
    "--bc-li-step": "1.5em",
    "--bc-li-bullet": "1.2em",
    "--bc-li-todo": "1.4em",
    "--bc-li-digit": "0.6em",
    "--bc-li-ordered": "0.75em",
    fontSize: "var(--bc-size)",
  },
  // [auto][gutter][content][auto] with the gutter's width mirrored on the right: the text
  // column is centered and the heading badges sit right next to it.
  ".cm-scroller": {
    fontFamily: "var(--bc-font-text)",
    lineHeight: "var(--bc-line-height)",
    paddingRight: "var(--bc-gutter-width)",
  },
  ".cm-content": {
    maxWidth: "var(--bc-line-width)",
    marginRight: "auto",
    // Over-scroll: the last line can be scrolled up to the middle of the window.
    padding: "32px 0 50vh",
  },
  ".cm-gutters": {
    marginLeft: "auto",
    width: "var(--bc-gutter-width)",
    backgroundColor: "transparent",
    border: "none",
    color: "var(--bc-color-secondary)",
  },
  ".cm-bc-heading-gutter": { width: "calc(var(--bc-gutter-width) - var(--bc-fold-gutter-width))" },
  // Paragraph indent (first row of a prose line; wrapped rows stay). The lines that are not
  // prose reset it; list lines set their own hanging indent below. Inline-block widgets (marker
  // boxes, attachments, icons) would inherit it, so descendants reset it too.
  ".cm-line": { paddingBottom: "var(--bc-paragraph-spacing)", textIndent: "var(--bc-paragraph-indent)" },
  ".cm-line *": { textIndent: "0" },
  ".cm-bc-li-cont, .cm-bc-heading, .cm-bc-quote, .cm-bc-codeblock, .cm-bc-hr": { textIndent: "0" },
  ".cm-line.cm-bc-table-line": { textIndent: "0" },

  ".cm-bc-heading": {
    fontFamily: "var(--bc-font-heading)",
    fontWeight: "700",
    lineHeight: HEADING_LINE_HEIGHT,
    paddingTop: HEADING_PADDING_TOP,
  },
  ...Object.fromEntries(headingScale.map((em, i) => [`.cm-h${i + 1}`, { fontSize: `${em}em` }])),
  ".cm-bc-hbadge": {
    border: "none", background: "transparent", color: "inherit", padding: "0", fontFamily: "inherit", width: "100%",
    display: "flex",
    justifyContent: "flex-end",
    alignItems: "center",
    height: `${HEADING_LINE_HEIGHT}em`,
    lineHeight: HEADING_LINE_HEIGHT,
    paddingTop: HEADING_PADDING_TOP,
    paddingRight: "6px",
    cursor: "pointer",
  },
  ...Object.fromEntries(headingScale.map((em, i) => [`.cm-bc-hbadge-${i + 1}`, { fontSize: `${em}em` }])),
  // A heading's fold chevron lines up with its first row like the badge.
  ".cm-bc-fold-chevron.cm-bc-fold-heading": {
    height: `${HEADING_LINE_HEIGHT}em`,
    lineHeight: HEADING_LINE_HEIGHT,
    paddingTop: HEADING_PADDING_TOP,
  },
  ...Object.fromEntries(headingScale.map((em, i) => [`.cm-bc-fold-h${i + 1}`, { fontSize: `${em}em` }])),
  ".cm-bc-hbadge > span": {
    fontFamily: "var(--bc-font-text)",
    fontSize: "calc(var(--bc-size) * 0.8)",
    fontWeight: "600",
    fontVariantCaps: "all-small-caps",
    letterSpacing: "0.03em",
    lineHeight: "1",
    padding: "2px 3px",
    borderRadius: "3px",
    color: "var(--bc-color-secondary)",
  },
  ".cm-bc-hbadge:hover > span": { color: "var(--bc-color-accent)", backgroundColor: "var(--bc-color-tag-bg)" },

  ...inlineMarkupStyles,
  // Table source (M6 Task 4): the top row is always bold (Bear); pipes are dimmed markup.
  ".cm-bc-table-header": { fontWeight: "700" },


  ".cm-bc-bullet": {
    display: "inline-block",
    width: "var(--bc-li-mark)",
    color: "var(--bc-color-accent)",
    fontWeight: "normal",
    fontStyle: "normal",
  },
  // Scaled up without layout effects (the system font's bullet glyphs are small).
  ".cm-bc-bullet::before": { content: "attr(data-glyph)", display: "inline-block", transform: "scale(1.6)" },
  ".cm-bc-olmark": {
    display: "inline-block",
    minWidth: "var(--bc-li-mark)",
    color: "var(--bc-color-accent)",
    fontWeight: "normal",
    fontStyle: "normal",
    fontVariantNumeric: "tabular-nums",
  },
  ".cm-bc-olmark::before": { content: "attr(data-marker)" },
  // The raw marker (caret on it) takes the same box as its widget.
  ".cm-bc-li-raw": { display: "inline-block", minWidth: "var(--bc-li-mark)" },
  ".cm-bc-ordered-marker": { color: "var(--bc-color-accent)", fontVariantNumeric: "tabular-nums" },

  ".cm-bc-quote": {
    "--bc-quote-pad": "calc(6px + 0.6em)",
    borderLeft: "3px solid var(--bc-color-quote-bar)",
    paddingLeft: "var(--bc-quote-pad)",
    color: "var(--bc-color-quote)",
  },
  // After the quote rule: a list line in a quote keeps the quote's padding (6px: CodeMirror's).
  ".cm-bc-li, .cm-bc-li-cont": {
    paddingLeft: "calc(var(--bc-quote-pad, 6px) + var(--bc-li-level) * var(--bc-li-step) + var(--bc-li-mark))",
  },
  // Hanging indent: the first row starts at the marker, wrapped rows at the item text.
  ".cm-bc-li": { textIndent: "calc(-1 * var(--bc-li-mark))" },
  // text-indent is inherited; inline blocks (marker boxes, widgets) would indent their content.
  ".cm-bc-li *": { textIndent: "0" },
  ".cm-bc-hr": { position: "relative" },
  ".cm-bc-hr::after": {
    content: '""',
    position: "absolute",
    left: "6px",
    right: "2px",
    top: "calc((100% - var(--bc-paragraph-spacing)) / 2)",
    borderTop: "1px solid var(--bc-color-rule)",
  },

  ".cm-bc-codeblock": {
    fontFamily: "var(--bc-font-code)",
    fontSize: `${CODE_SCALE}em`,
    backgroundColor: "var(--bc-color-code-bg)",
    paddingLeft: "14px",
    paddingRight: "14px",
    paddingBottom: "0",
  },
  ".cm-bc-codeblock-first": { borderTopLeftRadius: "6px", borderTopRightRadius: "6px", paddingTop: "8px" },
  ".cm-bc-codeblock-last": {
    borderBottomLeftRadius: "6px",
    borderBottomRightRadius: "6px",
    paddingBottom: "8px",
    // The paragraph gap after the block, outside its background (no margins on lines). The em
    // of the paragraph spacing is the code block's smaller one, so it is scaled back.
    borderBottom: `calc(var(--bc-paragraph-spacing) / ${CODE_SCALE}) solid transparent`,
    backgroundClip: "padding-box",
  },

});

export const typography: Extension = [
  typographyPlugin,
  EditorView.outerDecorations.of((view) => view.plugin(typographyPlugin)?.sets.outer ?? Decoration.none),
  EditorView.decorations.of((view) => view.plugin(typographyPlugin)?.sets.inner ?? Decoration.none),
  // Left of the heading gutter (gutters line up in extension order).
  foldChevronGutter,
  headingGutter,
  exposeGutters,
  typographyTheme,
];
