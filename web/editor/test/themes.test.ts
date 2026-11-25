// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import schemaJson from "../../../Fixtures/themes/theme-schema.json";
import { bearchenRed } from "../src/editor/theme";
import { CALLOUT_TYPES } from "../src/bridge/protocol";
import {
  checkPairs,
  composite,
  contrastRatio,
  editorVariables,
  hue,
  nudgeToContrast,
  parseHex,
  validateSchema,
  validateTheme,
  type ThemeFile,
  type ThemeSchema,
} from "../src/editor/theme-tokens";

const schema = schemaJson as unknown as ThemeSchema;
const themeModules = import.meta.glob("../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-*.json", {
  eager: true,
  import: "default",
}) as Record<string, ThemeFile>;
const files = Object.entries(themeModules).map(([path, theme]) => ({ path, theme }));
const themes = files.map((f) => f.theme);
const sources = import.meta.glob("../src/**/*.ts", { eager: true, query: "?raw", import: "default" }) as Record<string, string>;

const report = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env.THEME_REPORT;
const pairName = (p: { fg: string; bg: string[] }) => `${p.fg} on ${p.bg.join(" over ")}`;

describe("colour maths", () => {
  test("parseHex reads #rrggbb and #rrggbbaa", () => {
    expect(parseHex("#d9534f")).toEqual({ r: 217, g: 83, b: 79, a: 1 });
    expect(parseHex("#d9534f1c")?.a).toBeCloseTo(28 / 255, 5);
    expect(parseHex("d9534f")).toBeNull();
    expect(parseHex("#fff")).toBeNull();
  });

  test("composite blends top over bottom and returns an opaque colour", () => {
    expect(composite(["#00000080", "#ffffff"])).toBe("#7f7f7f");
    expect(composite(["#ffffff00", "#123456"])).toBe("#123456");
    expect(composite(["#ff000080", "#00ff0080", "#0000ff"])).toBe("#80403f");
  });

  test("contrastRatio matches known WCAG values", () => {
    expect(contrastRatio("#000000", ["#ffffff"])).toBeCloseTo(21, 2);
    expect(contrastRatio("#777777", ["#ffffff"])).toBeCloseTo(4.48, 2);
    expect(contrastRatio("#767676", ["#ffffff"])).toBeCloseTo(4.54, 2);
    expect(contrastRatio("#ffffff", ["#ffffff00", "#000000"])).toBeCloseTo(21, 2); // transparent top
  });

  test("contrastRatio composites in floats, without rounding to 8 bits", () => {
    // #1c1c1c at 20 % over white is 209.6 per channel (composite() rounds to 210).
    const lin = (v: number) => ((v / 255 + 0.055) / 1.055) ** 2.4;
    const expected = 1.05 / (lin(0.2 * 28 + 0.8 * 255) + 0.05);
    expect(contrastRatio("#1c1c1c33", ["#ffffff"])).toBeCloseTo(expected, 6);
    expect(composite(["#1c1c1c33", "#ffffff"])).toBe("#d2d2d2");
  });

  test("nudgeToContrast passes and keeps the hue", () => {
    const out = nudgeToContrast("#8a8a8a", ["#ffffff"], 4.5);
    expect(contrastRatio(out, ["#ffffff"])).toBeGreaterThanOrEqual(4.5);
    expect(hue(out)).toBeCloseTo(hue("#8a8a8a"), 0);
    const red = nudgeToContrast("#d9534f", ["#ffffff"], 4.5);
    expect(contrastRatio(red, ["#ffffff"])).toBeGreaterThanOrEqual(4.5);
    expect(Math.abs(hue(red) - hue("#d9534f"))).toBeLessThan(1);
  });

  test("nudgeToContrast lightens on a dark background and leaves a passing colour alone", () => {
    const out = nudgeToContrast("#555555", ["#101010"], 4.5);
    expect(contrastRatio(out, ["#101010"])).toBeGreaterThanOrEqual(4.5);
    expect(out > "#555555").toBe(true);
    expect(nudgeToContrast("#000000", ["#ffffff"], 4.5)).toBe("#000000");
  });
});

describe("validateTheme", () => {
  const red = themes.find((t) => t.id === "baerchen-red")!;

  test("reports a missing token, a bad value, an unknown token and a translucent base", () => {
    const broken = structuredClone(red);
    delete broken.editor["color-text"];
    broken.editor["color-link"] = "#D9534F";
    broken.editor["color-nonsense"] = "#000000";
    broken.editor["color-bg"] = "#ffffff80";
    delete broken.shell["accent"];
    const problems = validateTheme(broken, schema).join("\n");
    expect(problems).toContain("editor.color-text is missing");
    expect(problems).toContain("editor.color-link is not a lowercase");
    expect(problems).toContain("editor.color-nonsense is not in the schema");
    expect(problems).toContain("editor.color-bg is the base of a background stack and must be opaque");
    expect(problems).toContain("shell.accent is missing");
  });
});

describe("schema consistency", () => {
  test("every pair token and decorative entry is a schema token", () => {
    expect(validateSchema(schema)).toEqual([]);
  });

  test("the red has a pair over every tint, and on-accent has its pair on the accent (M7-R9)", () => {
    const tints = [
      "color-selection",
      "highlight",
      "highlight-green",
      "highlight-red",
      "highlight-blue",
      "highlight-yellow",
      "highlight-purple",
      "color-search-match",
      "color-search-match-current",
    ];
    const has = (fg: string, bg: string[], kind: "text" | "nonText") =>
      schema.pairs.some((p) => p.fg === fg && p.kind === kind && p.bg.join(" ") === bg.join(" "));
    const missing: string[] = [];
    for (const fg of ["color-link", "color-accent", "color-tag"]) {
      for (const tint of tints) {
        if (!has(`editor.${fg}`, [`editor.${tint}`, "editor.color-bg"], "text")) missing.push(`${fg} on ${tint}`);
      }
    }
    if (!has("shell.on-accent", ["shell.accent"], "text")) missing.push("shell.on-accent on shell.accent");
    expect(missing).toEqual([]);
  });

  test("every code colour has a pair on the code background over every callout tint (M8)", () => {
    const codeTokens = ["keyword", "string", "number", "comment", "type", "function", "property", "tag", "meta"];
    const missing: string[] = [];
    let count = 0;
    for (const type of CALLOUT_TYPES) {
      for (const k of codeTokens) {
        const bg = ["editor.color-code-bg", `editor.color-callout-${type}-bg`, "editor.color-bg"].join(" ");
        const found = schema.pairs.some((p) => p.fg === `editor.color-code-${k}` && p.kind === "text" && p.bg.join(" ") === bg);
        if (found) count++;
        else missing.push(`color-code-${k} on code-bg over callout-${type}`);
      }
    }
    expect(missing).toEqual([]);
    expect(count).toBe(45);
  });

  test("a typo'd pair or decorative entry is reported", () => {
    const typo = structuredClone(schema);
    typo.pairs[0]!.fg = "editor.color-txt";
    typo.pairs[1]!.bg = ["editor.color-bgg"];
    typo.decorative.push("shell.seperator");
    typo.pairs.push({ fg: "colour-text", bg: ["editor.color-bg"], kind: "text" });
    const problems = validateSchema(typo).join("\n");
    expect(problems).toContain("editor.color-txt");
    expect(problems).toContain("editor.color-bgg");
    expect(problems).toContain("shell.seperator");
    expect(problems).toContain("colour-text");
  });

  test("checkPairs returns one result per schema pair for every valid theme", () => {
    for (const t of themes) expect(checkPairs(t, schema), t.id).toHaveLength(schema.pairs.length);
  });

  test("a pair whose token is missing from the theme fails instead of vanishing", () => {
    const red = structuredClone(themes.find((t) => t.id === "baerchen-red")!);
    delete red.editor["color-secondary"];
    const results = checkPairs(red, schema);
    expect(results).toHaveLength(schema.pairs.length);
    expect(results.filter((r) => !r.pass).length).toBeGreaterThan(0);
  });
});

describe("theme files", () => {
  test("at least Theo Red exists", () => {
    expect(themes.map((t) => t.id)).toContain("baerchen-red");
  });

  test("every theme file is valid against schema v1", () => {
    for (const t of themes) expect(validateTheme(t, schema), t.id).toEqual([]);
  });

  test("every theme passes its contrast pairs", () => {
    const failures: string[] = [];
    for (const t of themes) {
      for (const r of checkPairs(t, schema)) {
        const line = `${t.id}: ${pairName(r.pair)} (${r.pair.kind}) = ${r.ratio.toFixed(2)}:1, needs ${r.min}`;
        if (report) {
          const bg = r.pair.bg.map((b) => lookup(t, b));
          const fix = r.pass ? "" : `  -> try ${nudgeToContrast(lookup(t, r.pair.fg), bg, r.min)}`;
          console.log(`${r.pass ? "ok  " : "FAIL"} ${line}${fix}`);
        }
        if (!r.pass) failures.push(line);
      }
    }
    expect(failures).toEqual([]);
  });

  test("deviations keep the hue and name the palette value", () => {
    for (const t of themes) {
      for (const d of t.deviations) {
        const [group, ...rest] = d.token.split(".");
        const token = rest.join(".");
        const known = group === "editor" ? schema.editorTokens : group === "shell" ? schema.shellTokens : [];
        expect(known, `${t.id}: ${d.token} is a schema token`).toContain(token);
        expect(d.palette.toLowerCase(), `${t.id}: ${d.token} palette differs from value`).not.toBe(d.value.toLowerCase());
        expect(Math.abs(hue(d.palette) - hue(d.value)), `${t.id}: ${d.token} hue`).toBeLessThanOrEqual(1);
        expect(lookup(t, d.token), `${t.id}: ${d.token} value`).toBe(d.value);
        expect(d.reason, `${t.id}: ${d.token} reason`).not.toBe("");
      }
    }
  });

  test("each deviation has its own reason with the old and the new ratio", () => {
    for (const t of themes) {
      const reasons = t.deviations.map((d) => d.reason);
      expect(new Set(reasons).size, `${t.id}: reasons are unique`).toBe(reasons.length);
      for (const d of t.deviations) {
        expect(d.reason.match(/\d+\.\d{2}:1/g)?.length ?? 0, `${t.id}: ${d.token} names two ratios`).toBeGreaterThanOrEqual(2);
      }
    }
  });

  test("ids are unique, file name is theme-<id>.json, order is unique", () => {
    const ids = themes.map((t) => t.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const { path, theme } of files) expect(path.split("/").pop(), theme.id).toBe(`theme-${theme.id}.json`);
    const orders = themes.map((t) => t.order);
    expect(new Set(orders).size).toBe(orders.length);
  });

  test("theme.ts defaults equal theme-baerchen-red.json", () => {
    const json = themes.find((t) => t.id === "baerchen-red")!;
    expect(bearchenRed).toEqual(editorVariables(json));
  });
});

describe("own themes", () => {
  const own = {
    "baerchen-red": { order: 10, appearance: "light", contrast: "standard" },
    "baerchen-dark": { order: 11, appearance: "dark", contrast: "standard" },
    "high-contrast": { order: 20, appearance: "light", contrast: "high" },
    "oled-black": { order: 21, appearance: "dark", contrast: "high" },
  } as const;
  const byId = (id: string) => themes.find((t) => t.id === id)!;
  const hueDistance = (a: string, b: string) => {
    const d = Math.abs(hue(a) - hue(b)) % 360;
    return Math.min(d, 360 - d);
  };

  test("the four own themes exist with their slot, order and contrast level", () => {
    for (const [id, want] of Object.entries(own)) {
      const t = byId(id);
      expect(t, id).toBeDefined();
      expect({ order: t.order, appearance: t.appearance, contrast: t.contrast }, id).toEqual(want);
      expect(t.source.license, id).toBe("LicenseRef-TrueBrewBirdie");
      expect(t.source.copyright, id).toBe("Copyright (c) 2026 True Brew Birdie Ltd.");
    }
  });

  test("only Theo Red records deviations (the others have no upstream palette)", () => {
    for (const id of ["baerchen-dark", "high-contrast", "oled-black"]) expect(byId(id).deviations, id).toEqual([]);
  });

  test("OLED Black is pure black; Theo Dark is a warm graphite, not black", () => {
    expect(byId("oled-black").editor["color-bg"]).toBe("#000000");
    expect(byId("oled-black").shell["background"]).toBe("#000000");
    const dark = parseHex(byId("baerchen-dark").editor["color-bg"]!)!;
    expect(dark.r + dark.g + dark.b).toBeGreaterThan(3 * 0x18);
    expect(dark.r).toBeGreaterThan(dark.b); // warm cast
  });

  test("High Contrast is black on white", () => {
    const hc = byId("high-contrast");
    expect([hc.editor["color-text"], hc.editor["color-bg"], hc.shell["text"], hc.shell["background"]]).toEqual([
      "#000000",
      "#ffffff",
      "#000000",
      "#ffffff",
    ]);
  });

  test("one Theo red per theme: accent, link, tag and the shell accent are the same colour (M7-R7)", () => {
    for (const id of Object.keys(own)) {
      const t = byId(id);
      expect(t.editor["color-link"], id).toBe(t.editor["color-accent"]);
      expect(t.editor["color-tag"], id).toBe(t.editor["color-accent"]);
      expect(t.shell["accent"], id).toBe(t.editor["color-accent"]);
    }
  });

  test("the red and the tints made from it keep Theo Red's hue in every own theme", () => {
    const red = byId("baerchen-red").editor["color-accent"]!;
    for (const id of Object.keys(own)) {
      const t = byId(id);
      for (const [token, value] of [
        ["color-accent", t.editor["color-accent"]],
        ["color-tag", t.editor["color-tag"]],
        ["color-tag-bg", t.editor["color-tag-bg"]],
        ["highlight-dot-red", t.editor["highlight-dot-red"]],
        ["shell.selection", t.shell["selection"]],
      ] as const) {
        expect(hueDistance(value!, red), `${id} ${token}`).toBeLessThanOrEqual(3);
      }
    }
  });

  test("text on the accent fill (shell.on-accent) is white on the light reds and dark on the dark ones", () => {
    const lum = (hex: string) => contrastRatio(hex, ["#000000"]);
    for (const id of Object.keys(own)) {
      const t = byId(id);
      const onAccentIsLighter = lum(t.shell["on-accent"]!) > lum(t.shell["accent"]!);
      expect(onAccentIsLighter, id).toBe(t.appearance === "light");
    }
  });

  test("highlight colours keep their hue across own themes; saturation and lightness adapt", () => {
    const red = byId("baerchen-red");
    const tokens = schema.editorTokens.filter((t) => t.startsWith("highlight") || t.startsWith("color-callout-"));
    for (const id of ["baerchen-dark", "high-contrast", "oled-black"]) {
      for (const token of tokens) {
        expect(hueDistance(byId(id).editor[token]!, red.editor[token]!), `${id} ${token}`).toBeLessThanOrEqual(3);
      }
    }
  });
});

// CIEDE2000 (Sharma, Wu, Dalal 2005) on sRGB (D65) colours.
function deltaE2000(hexA: string, hexB: string): number {
  const lab = (hex: string): [number, number, number] => {
    const c = parseHex(hex)!;
    const lin = (v: number) => {
      const s = v / 255;
      return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
    };
    const [r, g, b] = [lin(c.r), lin(c.g), lin(c.b)];
    const x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
    const y = 0.2126729 * r + 0.7151522 * g + 0.072175 * b;
    const z = (0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883;
    const f = (v: number) => (v > 216 / 24389 ? Math.cbrt(v) : ((24389 / 27) * v + 16) / 116);
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
  };
  const rad = (d: number) => (d * Math.PI) / 180;
  const deg = (r: number) => ((r * 180) / Math.PI + 360) % 360;
  const [L1, a1, b1] = lab(hexA);
  const [L2, a2, b2] = lab(hexB);
  const C1 = Math.hypot(a1, b1);
  const C2 = Math.hypot(a2, b2);
  const Cb = (C1 + C2) / 2;
  const G = 0.5 * (1 - Math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)));
  const a1p = (1 + G) * a1;
  const a2p = (1 + G) * a2;
  const C1p = Math.hypot(a1p, b1);
  const C2p = Math.hypot(a2p, b2);
  const h1p = deg(Math.atan2(b1, a1p));
  const h2p = deg(Math.atan2(b2, a2p));
  const dLp = L2 - L1;
  const dCp = C2p - C1p;
  let dhp = 0;
  if (C1p * C2p !== 0) {
    dhp = h2p - h1p;
    if (dhp > 180) dhp -= 360;
    else if (dhp < -180) dhp += 360;
  }
  const dHp = 2 * Math.sqrt(C1p * C2p) * Math.sin(rad(dhp / 2));
  const Lbp = (L1 + L2) / 2;
  const Cbp = (C1p + C2p) / 2;
  let hbp: number;
  if (C1p * C2p === 0) hbp = h1p + h2p;
  else if (Math.abs(h1p - h2p) <= 180) hbp = (h1p + h2p) / 2;
  else hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  const T =
    1 - 0.17 * Math.cos(rad(hbp - 30)) + 0.24 * Math.cos(rad(2 * hbp)) + 0.32 * Math.cos(rad(3 * hbp + 6)) - 0.2 * Math.cos(rad(4 * hbp - 63));
  const dTh = 30 * Math.exp(-(((hbp - 275) / 25) ** 2));
  const Rc = 2 * Math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7));
  const Sl = 1 + (0.015 * (Lbp - 50) ** 2) / Math.sqrt(20 + (Lbp - 50) ** 2);
  const Sc = 1 + 0.045 * Cbp;
  const Sh = 1 + 0.015 * Cbp * T;
  const Rt = -Math.sin(rad(2 * dTh)) * Rc;
  return Math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh));
}

describe("public palette tints (M7-R13)", () => {
  // The tint tokens M7-R13 covers, with the page each one is painted over.
  const editorTints = [
    "highlight",
    "highlight-green",
    "highlight-red",
    "highlight-blue",
    "highlight-yellow",
    "highlight-purple",
    "color-selection",
    "color-search-match",
    "color-search-match-current",
    "color-tag-bg",
    "color-math-error-bg",
    "color-callout-note-bg",
    "color-callout-tip-bg",
    "color-callout-important-bg",
    "color-callout-warning-bg",
    "color-callout-caution-bg",
  ];
  const shellTints = ["search-highlight", "selection"];
  // All 18 themes, the app's own four included (M7-R23: the call-out note background of Theo Red and High
  // Contrast was ΔE 5.7 and is raised; no theme is exempt from the visibility floor).
  const covered = themes;

  test("deltaE2000 matches reference values", () => {
    expect(deltaE2000("#ffffff", "#000000")).toBeCloseTo(100, 3);
    expect(deltaE2000("#282a36", "#44475a")).toBeCloseTo(9.9347, 3);
    expect(deltaE2000("#fdf6e3", "#eee8d5")).toBeCloseTo(3.019, 3);
    expect(deltaE2000("#2e3440", "#3b4252")).toBeCloseTo(4.9173, 3);
    expect(deltaE2000("#faf4ed", "#b4637a")).toBeCloseTo(40.4437, 3);
    expect(deltaE2000("#123456", "#123456")).toBe(0);
  });

  test("the 14 public palette themes are covered", () => {
    const publicIds = covered.filter((t) => t.source.license === "MIT").map((t) => t.id);
    expect(publicIds).toHaveLength(14);
  });

  test("every tint is at least ΔE2000 6 from its page (8-bit composite)", () => {
    const tooFaint: string[] = [];
    for (const t of covered) {
      const check = (qualified: string, tint: string | undefined, page: string | undefined) => {
        if (!tint || !page) return void tooFaint.push(`${t.id}: ${qualified} is missing`);
        const de = deltaE2000(composite([tint, page]), page);
        if (de < 6) tooFaint.push(`${t.id}: ${qualified} ${tint} over ${page} is ΔE ${de.toFixed(1)}`);
      };
      for (const k of editorTints) check(`editor.${k}`, t.editor[k], t.editor["color-bg"]);
      for (const k of shellTints) check(`shell.${k}`, t.shell[k], t.shell["background"]);
    }
    expect(tooFaint).toEqual([]);
  });
});

describe("token coverage", () => {
  test("every colour variable used in src is a schema token", () => {
    const highlightNames = ["green", "red", "blue", "yellow", "purple"];
    const used = new Set<string>();
    for (const [path, source] of Object.entries(sources)) {
      if (path.endsWith("/theme.ts") || path.endsWith("/theme-tokens.ts")) continue;
      for (const m of source.matchAll(/var\(--bc-((?:color|highlight)[a-z0-9-]*)(?:\$\{[^}]+\}([a-z0-9-]*))?/g)) {
        const name = m[1]!;
        // A name ending in "-" is a template prefix: `var(--bc-highlight-${name})`, and the callout
        // tokens `var(--bc-color-callout-${type}-bg|border|icon|title)` (callouts.ts).
        if (name === "color-callout-") {
          for (const t of CALLOUT_TYPES) for (const part of ["bg", "border", "icon", "title"]) used.add(`${name}${t}-${part}`);
        } else if (name.endsWith("-")) for (const c of highlightNames) used.add(name + c);
        else used.add(name);
      }
    }
    expect(used.size).toBeGreaterThan(10);
    const unknown = [...used].filter((n) => !schema.editorTokens.includes(n));
    expect(unknown).toEqual([]);
  });

  test("no source file hard-codes a colour (hex, rgb(), hsl(), named)", () => {
    const named = [
      "aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood",
      "cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod",
      "darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon",
      "darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray",
      "dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green",
      "greenyellow grey honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon",
      "lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon",
      "lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen",
      "magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue",
      "mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy",
      "oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred",
      "papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown",
      "salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen",
      "steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen",
    ]
      .join(" ")
      .split(" ");
    // A named colour only counts as the value of a colour-ish CSS property.
    const property = /(?:colou?r|background|border|outline|fill|stroke|shadow)[\w-]*["']?\s*:\s*["'`]?([^;,}"'`]*)/gi;
    const functions = /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\(/;
    const hex = /(?<![\w&])#[0-9a-fA-F]{3,8}\b/;
    const offenders: string[] = [];
    for (const [path, source] of Object.entries(sources)) {
      // theme.ts holds the default values; theme-tokens.ts parses colours; the font is base64.
      if (path.endsWith("/editor/theme.ts") || path.endsWith("/theme-tokens.ts") || path.includes("hidden-font")) continue;
      for (const [i, line] of source.split("\n").entries()) {
        if (/^\s*(\*|\/\*|\/\/)/.test(line)) continue;
        const code = line.replace(/\s\/\/\s.*$/, "");
        const hasNamed = [...code.matchAll(property)].some((m) => m[1]!.split(/[\s(]+/).some((w) => named.includes(w.toLowerCase())));
        if (hex.test(code) || functions.test(code) || hasNamed) offenders.push(`${path}:${i + 1}: ${line.trim()}`);
      }
    }
    expect(offenders).toEqual([]);
  });
});

function lookup(theme: ThemeFile, qualified: string): string {
  const [group, ...rest] = qualified.split(".");
  const token = rest.join(".");
  return (group === "editor" ? theme.editor : theme.shell)[token]!;
}
