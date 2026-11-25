// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// Theme token schema v1 (spec §4.7): the types of a theme file, WCAG contrast maths and the
// validator that every `theme-*.json` must pass. Pure functions, no DOM: the unit tests use them
// and so do the theme tasks that nudge palette colours (hue stays, lightness moves).

export type Rgba = { r: number; g: number; b: number; a: number };

export type ThemeDeviation = { token: string; palette: string; value: string; reason: string };

export type ThemeFile = {
  schemaVersion: number;
  id: string;
  name: string;
  order: number;
  appearance: "light" | "dark";
  contrast: "standard" | "high";
  source: { project: string; url: string; license: string; copyright: string };
  deviations: ThemeDeviation[];
  editor: Record<string, string>;
  shell: Record<string, string>;
};

export type ThemePair = { fg: string; bg: string[]; kind: "text" | "nonText" };

export type ThemeSchema = {
  schemaVersion: number;
  editorTokens: string[];
  shellTokens: string[];
  decorative: string[];
  minimums: Record<"standard" | "high", { text: number; nonText: number }>;
  pairs: ThemePair[];
};

const HEX = /^#(?:[0-9a-f]{6}|[0-9a-f]{8})$/;

export function parseHex(hex: string): Rgba | null {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})?$/i.exec(hex);
  if (!m) return null;
  const byte = (s: string) => parseInt(s, 16);
  return { r: byte(m[1]!), g: byte(m[2]!), b: byte(m[3]!), a: m[4] === undefined ? 1 : byte(m[4]) / 255 };
}

const toHex = (r: number, g: number, b: number) =>
  "#" + [r, g, b].map((v) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0")).join("");

function mustParse(hex: string): Rgba {
  const c = parseHex(hex);
  if (!c) throw new Error(`not a #rrggbb[aa] colour: ${hex}`);
  return c;
}

type Channels = [number, number, number];

/** Composites a stack (top first, last entry opaque) in sRGB without rounding. */
function blend(stack: string[]): Channels {
  if (stack.length === 0) throw new Error("empty colour stack");
  const base = mustParse(stack[stack.length - 1]!);
  let [r, g, b] = [base.r, base.g, base.b];
  for (let i = stack.length - 2; i >= 0; i--) {
    const top = mustParse(stack[i]!);
    r = top.a * top.r + (1 - top.a) * r;
    g = top.a * top.g + (1 - top.a) * g;
    b = top.a * top.b + (1 - top.a) * b;
  }
  return [r, g, b];
}

/**
 * Composites a stack of colours, top first, in sRGB (`c = a·top + (1−a)·bottom`). The last entry
 * is the opaque base: its alpha is ignored. Returns an opaque `#rrggbb` (rounded to 8 bits; the
 * contrast maths itself works on the unrounded channels).
 */
export function composite(stack: string[]): string {
  return toHex(...blend(stack));
}

function luminanceOf([r, g, b]: Channels): number {
  const lin = (v: number) => {
    const s = v / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

/** WCAG 2.x contrast ratio of `fg` (composited over the stack when translucent) against the stack. */
export function contrastRatio(fg: string, bgStack: string[]): number {
  const bg = blend(bgStack);
  const top = mustParse(fg);
  const [r, g, b] = bg;
  const fgChannels: Channels = [
    top.a * top.r + (1 - top.a) * r,
    top.a * top.g + (1 - top.a) * g,
    top.a * top.b + (1 - top.a) * b,
  ];
  const [hi, lo] = [luminanceOf(fgChannels), luminanceOf(bg)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

function toHsl({ r, g, b }: Rgba): { h: number; s: number; l: number } {
  const [rn, gn, bn] = [r / 255, g / 255, b / 255];
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  let h: number;
  if (max === rn) h = ((gn - bn) / d) % 6;
  else if (max === gn) h = (bn - rn) / d + 2;
  else h = (rn - gn) / d + 4;
  return { h: (h * 60 + 360) % 360, s, l };
}

function fromHsl(h: number, s: number, l: number): [number, number, number] {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = l - c / 2;
  const sector = Math.floor(h / 60) % 6;
  const [r, g, b] = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]][sector]! as [number, number, number];
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}

/** HSL hue in degrees (0 for greys). */
export function hue(hex: string): number {
  return toHsl(mustParse(hex)).h;
}

/**
 * Moves the HSL lightness of `fg` in 0.5 % steps away from the background's luminance until the
 * pair reaches `min`; hue and saturation stay. If the end of the scale is reached first, that end
 * colour comes back (the caller sees the failure in the ratio).
 */
export function nudgeToContrast(fg: string, bgStack: string[], min: number): string {
  const c = mustParse(fg);
  const alpha = fg.length === 9 ? fg.slice(7) : "";
  const { h, s, l } = toHsl(c);
  const darken = luminanceOf(blend([fg, composite(bgStack)])) <= luminanceOf(blend(bgStack));
  const dir = darken ? -1 : 1;
  let best = fg.toLowerCase();
  for (let i = 0; i <= 200; i++) {
    const nl = l + dir * 0.005 * i;
    if (nl < 0 || nl > 1) break;
    const candidate = toHex(...fromHsl(h, s, nl)) + alpha;
    best = candidate;
    if (contrastRatio(candidate, bgStack) >= min) return candidate;
  }
  return best;
}

/** CSS variables of the editor (`.cm-editor`) for a theme: `"--bc-" + token`. */
export function editorVariables(theme: ThemeFile): Record<string, string> {
  return Object.fromEntries(Object.entries(theme.editor).map(([token, value]) => [`--bc-${token}`, value]));
}

function lookup(theme: ThemeFile, qualified: string): string | undefined {
  const dot = qualified.indexOf(".");
  const group = qualified.slice(0, dot);
  const token = qualified.slice(dot + 1);
  if (group === "editor") return theme.editor[token];
  if (group === "shell") return theme.shell[token];
  return undefined;
}

export type PairResult = { pair: ThemePair; ratio: number; min: number; pass: boolean };

/**
 * One result per schema pair, in schema order. A pair whose token is missing or not a colour
 * gets ratio 0 and fails, so a broken theme can never pass by losing a pair.
 */
export function checkPairs(theme: ThemeFile, schema: ThemeSchema): PairResult[] {
  return schema.pairs.map((pair) => {
    const min = schema.minimums[theme.contrast]?.[pair.kind] ?? Infinity;
    const fg = lookup(theme, pair.fg);
    const bg = pair.bg.map((b) => lookup(theme, b));
    if (fg === undefined || bg.some((b) => b === undefined) || !HEX.test(fg) || bg.some((b) => !HEX.test(b!))) {
      return { pair, ratio: 0, min, pass: false };
    }
    const ratio = contrastRatio(fg, bg as string[]);
    return { pair, ratio, min, pass: ratio >= min };
  });
}

/** Problems in the schema itself: a pair or decorative entry naming a token that does not exist. */
export function validateSchema(schema: ThemeSchema): string[] {
  const problems: string[] = [];
  const known = new Set([...schema.editorTokens.map((t) => `editor.${t}`), ...schema.shellTokens.map((t) => `shell.${t}`)]);
  const dup = (list: string[], what: string) => {
    for (const t of new Set(list.filter((x, i) => list.indexOf(x) !== i))) problems.push(`${what} ${t} is listed twice`);
  };
  dup(schema.editorTokens, "editor token");
  dup(schema.shellTokens, "shell token");
  for (const d of schema.decorative) if (!known.has(d)) problems.push(`decorative entry ${d} is not a schema token`);
  for (const [i, pair] of schema.pairs.entries()) {
    if (!known.has(pair.fg)) problems.push(`pairs[${i}].fg ${pair.fg} is not a schema token`);
    if (pair.bg.length === 0) problems.push(`pairs[${i}] has no background`);
    for (const b of pair.bg) if (!known.has(b)) problems.push(`pairs[${i}].bg ${b} is not a schema token`);
    if (pair.kind !== "text" && pair.kind !== "nonText") problems.push(`pairs[${i}].kind ${pair.kind} is unknown`);
    if (schema.decorative.includes(pair.fg)) problems.push(`pairs[${i}].fg ${pair.fg} is decorative and cannot have a pair`);
  }
  return problems;
}

/** Problems with a theme file against the schema; an empty list means valid. */
export function validateTheme(theme: ThemeFile, schema: ThemeSchema): string[] {
  const problems: string[] = [];
  const tag = `${theme.id ?? "?"}:`;
  if (theme.schemaVersion !== schema.schemaVersion) problems.push(`${tag} schemaVersion ${theme.schemaVersion} != ${schema.schemaVersion}`);
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(theme.id ?? "")) problems.push(`${tag} id must be kebab-case`);
  if (!theme.name) problems.push(`${tag} name is empty`);
  if (!Number.isInteger(theme.order)) problems.push(`${tag} order must be an integer`);
  if (theme.appearance !== "light" && theme.appearance !== "dark") problems.push(`${tag} appearance must be light or dark`);
  if (theme.contrast !== "standard" && theme.contrast !== "high") problems.push(`${tag} contrast must be standard or high`);
  for (const key of ["project", "license", "copyright"] as const) {
    if (!theme.source?.[key]) problems.push(`${tag} source.${key} is empty`);
  }
  if (typeof theme.source?.url !== "string") problems.push(`${tag} source.url must be a string`);

  const groups: [string, string[], Record<string, string> | undefined][] = [
    ["editor", schema.editorTokens, theme.editor],
    ["shell", schema.shellTokens, theme.shell],
  ];
  for (const [group, tokens, values] of groups) {
    if (!values) {
      problems.push(`${tag} ${group} is missing`);
      continue;
    }
    for (const token of tokens) {
      const value = values[token];
      if (value === undefined) problems.push(`${tag} ${group}.${token} is missing`);
      else if (!HEX.test(value)) problems.push(`${tag} ${group}.${token} is not a lowercase #rrggbb[aa]: ${value}`);
    }
    for (const token of Object.keys(values)) {
      if (!tokens.includes(token)) problems.push(`${tag} ${group}.${token} is not in the schema`);
    }
  }

  // Each background stack ends in an opaque colour.
  const seen = new Set<string>();
  for (const pair of schema.pairs) {
    const base = pair.bg[pair.bg.length - 1];
    if (!base || seen.has(base)) continue;
    seen.add(base);
    const value = lookup(theme, base);
    if (value && HEX.test(value) && value.length === 9 && value.slice(7) !== "ff") {
      problems.push(`${tag} ${base} is the base of a background stack and must be opaque: ${value}`);
    }
  }

  for (const d of theme.deviations ?? []) {
    if (!d.token || !d.palette || !d.value || !d.reason) problems.push(`${tag} deviation for ${d.token ?? "?"} is incomplete`);
  }
  return problems;
}
