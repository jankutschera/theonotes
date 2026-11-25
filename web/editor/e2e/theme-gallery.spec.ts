// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { test, type Page } from "@playwright/test";
import { typographyNote } from "./fixtures/typography-note";
import baerchenRed from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-baerchen-red.json" with { type: "json" };
import baerchenDark from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-baerchen-dark.json" with { type: "json" };
import highContrast from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-high-contrast.json" with { type: "json" };
import oledBlack from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-oled-black.json" with { type: "json" };
import solarizedLight from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-solarized-light.json" with { type: "json" };
import solarizedDark from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-solarized-dark.json" with { type: "json" };
import nord from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-nord.json" with { type: "json" };
import nordLight from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-nord-light.json" with { type: "json" };
import dracula from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-dracula.json" with { type: "json" };
import gruvbox from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-gruvbox.json" with { type: "json" };
import catppuccinLatte from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-catppuccin-latte.json" with { type: "json" };
import catppuccinMacchiato from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-catppuccin-macchiato.json" with { type: "json" };
import tokyoNight from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-tokyo-night.json" with { type: "json" };
import tokyoNightLight from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-tokyo-night-light.json" with { type: "json" };
import rosePine from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-rose-pine.json" with { type: "json" };
import rosePineDawn from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-rose-pine-dawn.json" with { type: "json" };
import everforestLight from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-everforest-light.json" with { type: "json" };
import everforestDark from "../../../Packages/TheoNotesCore/Sources/TheoNotesCore/Resources/theme-everforest-dark.json" with { type: "json" };

// Theme gallery (M7 Task 14): renders one fixture note per bundled theme through the same `setSettings`
// path the app uses and writes docs/m7/themes/<id>.png. Runs only with BAERCHEN_GALLERY=1 so the normal
// suites never rewrite committed images. Run from web/editor: PNG paths are relative to that directory.

declare const process: { env: Record<string, string | undefined> };

type Theme = { id: string; appearance: "light" | "dark"; editor: Record<string, string> };
const themes: Theme[] = [
  baerchenRed, baerchenDark, highContrast, oledBlack, solarizedLight, solarizedDark, nord, nordLight, dracula,
  gruvbox, catppuccinLatte, catppuccinMacchiato, tokyoNight, tokyoNightLight, rosePine, rosePineDawn,
  everforestLight, everforestDark,
] as Theme[];

type Hooks = {
  debugInsert(text: string): void;
  debugView(): { dispatch(spec: unknown): void };
  mock: { deliver(msg: unknown): void };
};

// The typography note, then the blocks that carry their own theme tokens: callouts, a table, todos.
const extras = [
  "> [!NOTE]",
  "> Useful information users should know.",
  "",
  "> [!WARNING]",
  "> Urgent info that needs immediate attention.",
  "",
  "| Item | Qty | Notes |",
  "|:--|:-:|---|",
  "| Apples | 3 | from the market |",
  "| Bread | 1 | #food |",
  "",
  "- [ ] An open todo",
  "- [x] A finished todo",
  "",
  "",
];
const note = typographyNote.trimEnd() + "\n\n" + extras.join("\n");

async function render(page: Page, theme: Theme) {
  await page.goto("/index.html?mock");
  const content = page.locator(".cm-content");
  await content.waitFor();
  await content.click();
  await page.evaluate(
    ([doc, theme]) => {
      const api = (window as unknown as { __baerchen: Hooks }).__baerchen;
      api.debugInsert(doc as string);
      api.debugView().dispatch({ selection: { anchor: (doc as string).length } });
      const variables: Record<string, string> = {};
      for (const [token, value] of Object.entries((theme as Theme).editor)) variables["--bc-" + token] = value;
      api.mock.deliver({ type: "setSettings", appearance: (theme as Theme).appearance, theme: variables });
    },
    [note, theme] as const,
  );
  await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 150)))));
}

test.describe("theme gallery", () => {
  test.skip(process.env.BAERCHEN_GALLERY !== "1", "set BAERCHEN_GALLERY=1 to regenerate docs/m7/themes");
  test.use({ viewport: { width: 900, height: 1500 } });

  for (const theme of themes) {
    test(`gallery: ${theme.id}`, async ({ page }) => {
      await render(page, theme);
      await page.screenshot({ path: `../../docs/m7/themes/${theme.id}.png` });
    });
  }
});
