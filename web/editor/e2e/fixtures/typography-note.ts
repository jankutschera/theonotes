// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

// The fixture note of the typography screenshot test (e2e/__screenshots__/typography.png).
// Ends with empty lines; the caret sits on the last one, so no markup is revealed.
export const typographyNote = [
  "# Bärchen typography",
  "A calm paragraph with **bold**, _italic_, ~underline~, ~~strike~~, `inline code` and ==a highlight==. It runs long enough to wrap onto a second line in the centered column.",
  "## Colors and links",
  "Highlights: ==🟢green== ==🔴red== ==🔵blue== ==🟡yellow== ==🟣purple==",
  "Tags #work and #multi word tag# with a [link](https://example.com), a [[Wiki Note]], an [[Other Note|alias]] and https://example.com.",
  "### Lists",
  "- First bullet",
  "- Second bullet with **bold**",
  "  - Nested bullet",
  "    - Third level bullet",
  "      - Fourth level wraps around",
  "1. Ordered one",
  "2. Ordered two",
  "#### Quote and rule",
  "> A quote that runs long enough to wrap onto a second visual line in the centered column of the editor.",
  "> Second quote line.",
  "",
  "---",
  "##### Code",
  "```swift",
  "let greeting = \"Hello, Bärchen\"",
  "print(greeting)",
  "```",
  "###### Sixth level",
  "Last paragraph.",
  "",
  "",
].join("\n");
