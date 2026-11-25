// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Editor settings (bridge `setSettings`): each one lives in its own Compartment, so a change
// reconfigures the editor in place: no reload, the document, selection and undo history stay. A
// loaded note gets the current settings (`loadDocument` passes `currentSettings` on).
//
// Typography and theme are CSS variables on the editor element (inline style beats the theme
// classes in theme.ts / typography.ts, which define the defaults). The appearance is the editor's
// dark flag (`EditorView.darkTheme`) plus `color-scheme`; Reduce Motion is a class on the editor.

import { Compartment, type EditorState, type Extension, Facet, type StateEffect, type TransactionSpec } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import type { EditorAppearance, EditorSettings, EditorTypography } from "../../bridge/protocol";
import { hideMarkdown } from "./hiding";
import { autoSortTodos } from "./todos";
import { FONT_STACKS, showHeadingLevels } from "./typography";

export type ResolvedSettings = {
  hideMarkdown: boolean;
  autoSortTodos: boolean;
  showHeadingLevels: boolean;
  /** Typewriter mode (typewriter.ts reads `typewriterModeSetting`). */
  typewriterMode: boolean;
  typography: EditorTypography;
  theme: Record<string, string>;
  appearance: EditorAppearance;
  reduceMotion: boolean;
};

export const DEFAULT_SETTINGS: ResolvedSettings = {
  hideMarkdown: true,
  autoSortTodos: false,
  showHeadingLevels: true,
  typewriterMode: false,
  typography: {},
  theme: {},
  appearance: "light",
  reduceMotion: false,
};

export const typewriterModeSetting = Facet.define<boolean, boolean>({ combine: (values) => values[0] ?? false });
const typographyFacet = Facet.define<EditorTypography, EditorTypography>({ combine: (values) => values[0] ?? {} });
const themeFacet = Facet.define<Record<string, string>, Record<string, string>>({ combine: (values) => values[0] ?? {} });
const appearanceFacet = Facet.define<EditorAppearance, EditorAppearance>({ combine: (values) => values[0] ?? "light" });
const reduceMotionFacet = Facet.define<boolean, boolean>({ combine: (values) => values[0] ?? false });

/** The class Reduce Motion puts on the editor element. */
export const REDUCE_MOTION_CLASS = "cm-bc-reduce-motion";

const noMotion = { transition: "none !important", animation: "none !important", scrollBehavior: "auto !important" };
const scoped = (selector: string) => ["", " *", " *::before", " *::after"].map((suffix) => `&${selector}${suffix}`).join(", ");

/**
 * Reduce Motion: no transition or animation anywhere in the editor (the code block's Copy fade,
 * later widgets) and no smooth scrolling. The host sends the system setting as `reduceMotion`;
 * the media query applies the same rule on its own, before the host has said anything. (Inside
 * an at-rule StyleModule cannot expand `&`, so the media rule names the descendants only.)
 */
const reduceMotionTheme = EditorView.theme({
  [scoped(`.${REDUCE_MOTION_CLASS}`)]: noMotion,
  "@media (prefers-reduced-motion: reduce)": { "*, *::before, *::after": noMotion },
});

const compartments = {
  hideMarkdown: new Compartment(),
  autoSortTodos: new Compartment(),
  showHeadingLevels: new Compartment(),
  typewriterMode: new Compartment(),
  typography: new Compartment(),
  theme: new Compartment(),
  appearance: new Compartment(),
  reduceMotion: new Compartment(),
};

/** Number fields → CSS variable (typography.ts defines the defaults). */
const typographyVars = {
  fontSize: (v: number) => ["--bc-size", `${v}px`],
  lineHeight: (v: number) => ["--bc-line-height", `${v}`],
  lineWidth: (v: number) => ["--bc-line-width", `${v}px`],
  paragraphSpacing: (v: number) => ["--bc-paragraph-spacing", `${v}em`],
  paragraphIndent: (v: number) => ["--bc-paragraph-indent", `${v}em`],
} as const;

/** A family goes in front of the default stack, so a glyph it lacks still falls back. The protocol allows no `"` in a family. */
const withFallback = (family: string, stack: string) => `"${family}", ${stack}`;

export function typographyDeclarations(t: EditorTypography): string[] {
  const declarations = (Object.keys(typographyVars) as (keyof typeof typographyVars)[])
    .filter((key) => t[key] !== undefined)
    .map((key) => typographyVars[key](t[key]!).join(": "));
  if (t.fontText !== undefined) declarations.push(`--bc-font-text: ${withFallback(t.fontText, FONT_STACKS.text)}`);
  // Headings: their own family, else the text family, else the default heading stack.
  const headingFamily = t.fontHeading ?? t.fontText;
  if (headingFamily !== undefined) declarations.push(`--bc-font-heading: ${withFallback(headingFamily, FONT_STACKS.heading)}`);
  if (t.fontCode !== undefined) declarations.push(`--bc-font-code: ${withFallback(t.fontCode, FONT_STACKS.code)}`);
  return declarations;
}

/** The protocol validated the tokens (schema `--bc-*` names, no `;{}<>\`), so they are safe in a style. */
const themeDeclarations = (tokens: Record<string, string>) => Object.entries(tokens).map(([k, v]) => `${k}: ${v}`);

const appearanceDeclarations = (a: EditorAppearance) => [`color-scheme: ${a}`];

const styled = (declarations: string[]): Extension =>
  declarations.length ? EditorView.editorAttributes.of({ style: declarations.join("; ") }) : [];

const extensionsFor = {
  hideMarkdown: (v: boolean): Extension => hideMarkdown.of(v),
  autoSortTodos: (v: boolean): Extension => autoSortTodos.of(v),
  showHeadingLevels: (v: boolean): Extension => showHeadingLevels.of(v),
  typewriterMode: (v: boolean): Extension => typewriterModeSetting.of(v),
  typography: (t: EditorTypography): Extension => [typographyFacet.of(t), styled(typographyDeclarations(t))],
  theme: (tokens: Record<string, string>): Extension => [themeFacet.of(tokens), styled(themeDeclarations(tokens))],
  appearance: (a: EditorAppearance): Extension => [
    appearanceFacet.of(a),
    EditorView.darkTheme.of(a === "dark"),
    styled(appearanceDeclarations(a)),
  ],
  reduceMotion: (on: boolean): Extension => [
    reduceMotionFacet.of(on),
    on ? EditorView.editorAttributes.of({ class: REDUCE_MOTION_CLASS }) : [],
  ],
};

/** The settings compartments, for a new state. */
export function settingsExtensions(settings: ResolvedSettings = DEFAULT_SETTINGS): Extension[] {
  return [
    compartments.hideMarkdown.of(extensionsFor.hideMarkdown(settings.hideMarkdown)),
    compartments.autoSortTodos.of(extensionsFor.autoSortTodos(settings.autoSortTodos)),
    compartments.showHeadingLevels.of(extensionsFor.showHeadingLevels(settings.showHeadingLevels)),
    compartments.typewriterMode.of(extensionsFor.typewriterMode(settings.typewriterMode)),
    compartments.typography.of(extensionsFor.typography(settings.typography)),
    compartments.theme.of(extensionsFor.theme(settings.theme)),
    compartments.appearance.of(extensionsFor.appearance(settings.appearance)),
    compartments.reduceMotion.of(extensionsFor.reduceMotion(settings.reduceMotion)),
    reduceMotionTheme,
  ];
}

export function currentSettings(state: EditorState): ResolvedSettings {
  return {
    hideMarkdown: state.facet(hideMarkdown),
    autoSortTodos: state.facet(autoSortTodos),
    showHeadingLevels: state.facet(showHeadingLevels),
    typewriterMode: state.facet(typewriterModeSetting),
    typography: state.facet(typographyFacet),
    theme: state.facet(themeFacet),
    appearance: state.facet(appearanceFacet),
    reduceMotion: state.facet(reduceMotionFacet),
  };
}

/** The style the settings put on the editor element (tests, diagnostics). */
export function settingsStyle(state: EditorState): string {
  const s = currentSettings(state);
  return [...typographyDeclarations(s.typography), ...themeDeclarations(s.theme), ...appearanceDeclarations(s.appearance)].join("; ");
}

const sameRecord = (a: object, b: object) => JSON.stringify(a) === JSON.stringify(b);

/**
 * The reconfiguration for `patch` (only the fields that change), or null when nothing changes.
 * `autocomplete` belongs to the completion feature (M3 Task 7), not here.
 */
export function settingsTransaction(state: EditorState, patch: EditorSettings): TransactionSpec | null {
  const current = currentSettings(state);
  const effects: StateEffect<unknown>[] = [];
  if (patch.hideMarkdown !== undefined && patch.hideMarkdown !== current.hideMarkdown) {
    effects.push(compartments.hideMarkdown.reconfigure(extensionsFor.hideMarkdown(patch.hideMarkdown)));
  }
  if (patch.autoSortTodos !== undefined && patch.autoSortTodos !== current.autoSortTodos) {
    effects.push(compartments.autoSortTodos.reconfigure(extensionsFor.autoSortTodos(patch.autoSortTodos)));
  }
  if (patch.showHeadingLevels !== undefined && patch.showHeadingLevels !== current.showHeadingLevels) {
    effects.push(compartments.showHeadingLevels.reconfigure(extensionsFor.showHeadingLevels(patch.showHeadingLevels)));
  }
  if (patch.typewriterMode !== undefined && patch.typewriterMode !== current.typewriterMode) {
    effects.push(compartments.typewriterMode.reconfigure(extensionsFor.typewriterMode(patch.typewriterMode)));
  }
  if (patch.typography !== undefined && !sameRecord(patch.typography, current.typography)) {
    effects.push(compartments.typography.reconfigure(extensionsFor.typography({ ...patch.typography })));
  }
  if (patch.theme !== undefined && !sameRecord(patch.theme, current.theme)) {
    effects.push(compartments.theme.reconfigure(extensionsFor.theme({ ...patch.theme })));
  }
  if (patch.appearance !== undefined && patch.appearance !== current.appearance) {
    effects.push(compartments.appearance.reconfigure(extensionsFor.appearance(patch.appearance)));
  }
  if (patch.reduceMotion !== undefined && patch.reduceMotion !== current.reduceMotion) {
    effects.push(compartments.reduceMotion.reconfigure(extensionsFor.reduceMotion(patch.reduceMotion)));
  }
  return effects.length ? { effects } : null;
}
