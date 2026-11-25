// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { headingsInDocument, tableRowLines, tagsInDocument, todoCounts, urlsInDocument, wikiLinksInDocument } from "../src/editor/conformance";

// Shared dialect conformance suite (format: Packages/TheoNotesCore/Tests/TheoNotesCoreTests/
// NoteParserFixtureTests.swift). The Swift parser passes the same files.

type Case = { name: string; input: string; expected: unknown };

const files = import.meta.glob("../../../Fixtures/dialect/*.json", { eager: true, import: "default" }) as Record<
  string,
  Case[]
>;

function cases(file: string): Case[] {
  const found = Object.entries(files).find(([path]) => path.endsWith(`/${file}`));
  if (!found) throw new Error(`missing fixture ${file}`);
  return found[1];
}

const suites: [string, (text: string) => unknown][] = [
  ["tags.json", tagsInDocument],
  ["wikilinks.json", wikiLinksInDocument],
  ["todos.json", todoCounts],
  ["headings.json", headingsInDocument],
  ["tables.json", tableRowLines],
  ["urls.json", urlsInDocument],
];

describe.each(suites)("%s", (file, actual) => {
  const all = cases(file);

  test("has enough unique cases", () => {
    expect(all.length).toBeGreaterThanOrEqual(15);
    expect(new Set(all.map((c) => c.name)).size).toBe(all.length);
  });

  test.each(all.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    expect(actual(c.input)).toEqual(c.expected);
  });
});
