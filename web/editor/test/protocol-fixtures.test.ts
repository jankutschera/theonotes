// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { ChangeSet, Text } from "@codemirror/state";
import { RENDER_VERSION, parseRenderRequest } from "../src/export/protocol";
import { BRIDGE_VERSION, CALLOUT_TYPES, COMMAND_NAMES, MAX_FOLDS, sanitizeFolds, isChangesReply, isEditorToHost, isHostToEditor } from "../src/bridge/protocol";

const commandNames = Object.values(
  import.meta.glob("../../../Fixtures/bridge/command-names.json", { eager: true, import: "default" }),
)[0] as string[];

const messages = import.meta.glob("../../../Fixtures/bridge/messages-*.json", {
  eager: true,
  import: "default",
}) as Record<string, unknown>;

const changesets = import.meta.glob("../../../Fixtures/bridge/changeset-*.json", {
  eager: true,
  import: "default",
}) as Record<string, { before: string; changeset: unknown; after: string }>;

function kindOf(msg: unknown): string | null {
  if (isHostToEditor(msg)) return `host:${msg.type}`;
  if (isEditorToHost(msg)) return `editor:${msg.type}`;
  if (isChangesReply(msg)) return `reply:${msg.status}`;
  return null;
}

const rect = { x: 1, y: 2, width: 3, height: 4 };

describe("bridge message fixtures", () => {
  test.each(Object.entries(messages))("%s is a valid protocol message", (_path, msg) => {
    expect(kindOf(msg)).not.toBeNull();
  });

  test("cover every message type in both directions and every reply status", () => {
    const kinds = new Set(Object.values(messages).map(kindOf));
    expect([...kinds].sort()).toEqual(
      [
        "host:loadNote",
        "host:applyExternalChange",
        "host:setRevision",
        "host:focus",
        "host:requestChecksum",
        "host:searchHighlight",
        "host:applyCommand",
        "host:scrollToHeading",
        "host:completionResults",
        "host:tagIcons",
        "host:setSettings",
        "host:selectRange",
        "host:freezeForClose",
        "host:unfreeze",
        "editor:frozenForClose",
        "editor:requestCompletions",
        "editor:openLink",
        "editor:editLinkRequest",
        "editor:ready",
        "editor:changes",
        "editor:selectionChanged",
        "editor:scrollChanged",
        "editor:checksum",
        "editor:error",
        "editor:headingMenu",
        "editor:tableMenu",
        "editor:calloutMenu",
        "editor:foldState",
        "editor:formatState",
        "editor:insertAttachments",
        "editor:quickLook",
        "editor:attachmentMenu",
        "editor:pasteAttachments",
        "editor:attachmentsRefused",
        "editor:cutAttachments",
        "editor:copyText",
        "reply:acked",
        "reply:duplicate",
        "reply:needsFullText",
      ].sort(),
    );
  });

  test("type guards reject malformed messages", () => {
    expect(isHostToEditor({ type: "loadNote", noteId: "n", text: "", revision: -1, readOnly: false })).toBe(false);
    expect(isHostToEditor({ type: "focus", extra: 1 })).toBe(false);
    expect(isEditorToHost({ type: "changes", noteId: "n", txId: "t", baseRevision: 0, revision: 1, changeSet: [1, ["x"]] })).toBe(false);
    expect(isEditorToHost({ type: "ready", version: "1" })).toBe(false);
    expect(isEditorToHost({ type: "scrollChanged", noteId: "n", scrollTop: -1 })).toBe(false);
    // Heading lines are 1-based (CodeMirror line numbers, NoteParser HeadingRef.line); levels 1–6.
    const heading = { type: "headingMenu", noteId: "n", menuId: "m", line: 1, level: 2, folded: false, rect };
    expect(isEditorToHost(heading)).toBe(true);
    expect(isEditorToHost({ ...heading, line: 0 })).toBe(false);
    expect(isEditorToHost({ ...heading, level: 7 })).toBe(false);
    expect(isEditorToHost({ ...heading, level: 1.5 })).toBe(false);
    expect(isEditorToHost({ ...heading, menuId: "" })).toBe(false);
    expect(isEditorToHost({ ...heading, folded: "no" })).toBe(false);
    // The v2 shape (no menuId, folded, rect) is gone.
    expect(isEditorToHost({ type: "headingMenu", noteId: "n", line: 1, level: 2 })).toBe(false);
    const { rect: _rect, ...noRect } = heading;
    expect(isEditorToHost(noRect)).toBe(false);
    expect(isEditorToHost({ ...heading, rect: { x: 0, y: 0 } })).toBe(false);
    const table = { type: "tableMenu", noteId: "n", menuId: "m", row: 0, column: 2, rows: 3, columns: 3, rect };
    expect(isEditorToHost(table)).toBe(true);
    expect(isEditorToHost({ ...table, row: 3 })).toBe(false); // row 0 = header, so rows 0…rows-1
    expect(isEditorToHost({ ...table, column: 3 })).toBe(false);
    expect(isEditorToHost({ ...table, rows: 0, row: 0 })).toBe(false);
    expect(isEditorToHost({ ...table, row: -1 })).toBe(false);
    expect(isEditorToHost({ ...table, menuId: undefined })).toBe(false);
    const callout = { type: "calloutMenu", noteId: "n", menuId: "m", calloutType: "tip", rect };
    expect(isEditorToHost(callout)).toBe(true);
    expect(isEditorToHost({ ...callout, calloutType: "info" })).toBe(false);
    expect(isEditorToHost({ ...callout, calloutType: "NOTE" })).toBe(false);
    const folds = { type: "foldState", noteId: "n", folds: [{ line: 1, hash: "0a1b2c3d" }] };
    expect(isEditorToHost(folds)).toBe(true);
    expect(isEditorToHost({ ...folds, folds: [] })).toBe(true);
    expect(isEditorToHost({ ...folds, folds: "no" })).toBe(false);
    // Invalid entries never reject a message: `sanitizeFolds` drops them (and caps the array).
    expect(isHostToEditor({ type: "loadNote", noteId: "n", text: "", revision: 0, readOnly: false, foldState: folds.folds })).toBe(true);
    expect(isHostToEditor({ type: "loadNote", noteId: "n", text: "", revision: 0, readOnly: false, foldState: [{ line: 1 }, 3] })).toBe(true);
    expect(isHostToEditor({ type: "loadNote", noteId: "n", text: "", revision: 0, readOnly: false, foldState: "no" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typewriterMode: true })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", typewriterMode: 1 })).toBe(false);
    const select = { type: "selectRange", noteId: "n", anchor: 2, head: 5 };
    expect(isHostToEditor(select)).toBe(true);
    expect(isHostToEditor({ ...select, head: 1 })).toBe(true); // backwards selections
    expect(isHostToEditor({ ...select, anchor: -1 })).toBe(false);
    expect(isHostToEditor({ ...select, noteId: undefined })).toBe(false);
    expect(isHostToEditor({ type: "selectRange", noteId: "n", from: 1, to: 2 })).toBe(false);
    expect(isHostToEditor({ type: "searchHighlight", noteId: "n", query: "a", terms: ["a", 1] })).toBe(false);
    expect(isHostToEditor({ type: "searchHighlight", noteId: "n", terms: ["a"] })).toBe(false);
    expect(isHostToEditor({ type: "searchHighlight", query: "a", terms: ["a"] })).toBe(false);
    expect(isHostToEditor({ type: "find", query: "a", terms: ["a"] })).toBe(false);
    expect(isHostToEditor({ type: "applyCommand", name: "nope" })).toBe(false);
    expect(isHostToEditor({ type: "applyCommand", name: "bold", args: [] })).toBe(false);
    expect(isHostToEditor({ type: "applyCommand", name: "bold", args: null })).toBe(false);
    expect(isEditorToHost({ type: "formatState", noteId: "n", active: ["nope"], inTodo: false, inCode: false, canIndent: false })).toBe(false);
    expect(isEditorToHost({ type: "formatState", noteId: "n", active: [], headingLevel: 7, inTodo: false, inCode: false, canIndent: false })).toBe(false);
    expect(isEditorToHost({ type: "formatState", noteId: "n", active: [], inTodo: false, inCode: false })).toBe(false);
    const open = { type: "openLink", noteId: "n", kind: "wiki", target: "T", newWindow: false };
    expect(isEditorToHost(open)).toBe(true);
    expect(isEditorToHost({ ...open, kind: "file" })).toBe(false);
    expect(isEditorToHost({ ...open, newWindow: "no" })).toBe(false);
    expect(isEditorToHost({ ...open, heading: 3 })).toBe(false);
    const edit = { type: "editLinkRequest", noteId: "n", requestId: "r", from: 2, to: 5, title: "t", url: "", editing: true, caretRect: { x: 0, y: 0, width: 1, height: 15 } };
    expect(isEditorToHost(edit)).toBe(true);
    expect(isEditorToHost({ ...edit, from: 6 })).toBe(false);
    expect(isEditorToHost({ ...edit, from: -1 })).toBe(false);
    expect(isEditorToHost({ ...edit, caretRect: { x: 0, y: 0 } })).toBe(false);
    expect(isEditorToHost({ ...edit, requestId: 3 })).toBe(false);
    const { editing: _editing, ...noMode } = edit;
    expect(isEditorToHost(noMode)).toBe(false);
    expect(isHostToEditor({ type: "scrollToHeading", noteId: "n", index: -1 })).toBe(false);
    expect(isEditorToHost({ type: "copyText", text: "" })).toBe(true);
    expect(isEditorToHost({ type: "copyText", text: 1 })).toBe(false);
    expect(isEditorToHost({ type: "copyText", text: "x", noteId: "n" })).toBe(false);
    expect(isEditorToHost({ type: "copyText", text: "<b>x</b>", html: "<b>x</b>" })).toBe(true);
    expect(isEditorToHost({ type: "copyText", text: "x", html: 1 })).toBe(false);
    expect(isEditorToHost({ type: "copyText" })).toBe(false);
    const request = { type: "requestCompletions", noteId: "n", requestId: "r", kind: "tag", query: "wo" };
    expect(isEditorToHost(request)).toBe(true);
    expect(isEditorToHost({ ...request, noteTitle: "T" })).toBe(true);
    expect(isEditorToHost({ ...request, kind: "file" })).toBe(false);
    expect(isEditorToHost({ ...request, noteTitle: 1 })).toBe(false);
    const results = { type: "completionResults", requestId: "r", items: [{ label: "work", insert: "#work " }] };
    expect(isHostToEditor(results)).toBe(true);
    expect(isHostToEditor({ ...results, items: [{ label: "work" }] })).toBe(false);
    expect(isHostToEditor({ ...results, items: [{ label: "w", insert: "w", icon: 3 }] })).toBe(false);
    expect(isHostToEditor({ ...results, items: [{ label: "w", insert: "w", extra: "x" }] })).toBe(false);
    expect(isHostToEditor({ type: "tagIcons", icons: { work: "briefcase" } })).toBe(true);
    expect(isHostToEditor({ type: "tagIcons", icons: { work: 1 } })).toBe(false);
    expect(isHostToEditor({ type: "tagIcons", icons: ["briefcase"] })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", autocomplete: "no" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings" })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", autocomplete: false })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", hideMarkdown: "no" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", autoSortTodos: 1 })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", showHeadingLevels: false })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", showHeadingLevels: "no" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { fontSize: 18 } })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", typography: { fontSize: 2 } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { lineHeight: 9 } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { font: "x" } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", theme: {} })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", theme: { color: "red" } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", theme: { "--bc-color-bg": "red;} body{x:y" } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", theme: { "--bc-color-bg": 3 } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", other: true })).toBe(false);
    // v4 (M7 Task 6): appearance, reduceMotion, fonts and the paragraph indent.
    expect(isHostToEditor({ type: "setSettings", appearance: "dark", reduceMotion: true })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", appearance: "sepia" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", appearance: "Dark" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", reduceMotion: "yes" })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { paragraphIndent: 4 } })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", typography: { paragraphIndent: 0 } })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", typography: { paragraphIndent: 5 } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { paragraphIndent: -1 } })).toBe(false);
    expect(isHostToEditor({ type: "setSettings", typography: { fontText: "Iowan Old Style", fontHeading: "A", fontCode: "SF Mono" } })).toBe(true);
    expect(isHostToEditor({ type: "setSettings", typography: { fontText: 12 } })).toBe(false);
    expect(isChangesReply({ status: "acked" })).toBe(false);
    expect(isChangesReply({ status: "needsFullText", revision: 3 })).toBe(false);
  });

  test("font families that could leave the declaration are rejected", () => {
    for (const field of ["fontText", "fontHeading", "fontCode"]) {
      for (const bad of ['A"B', "A;color:red", "A}", "A{", "A<b>", "A\\B", "A\nB", "A\rB", "x".repeat(101), ""]) {
        expect(isHostToEditor({ type: "setSettings", typography: { [field]: bad } }), `${field}: ${JSON.stringify(bad)}`).toBe(false);
      }
      expect(isHostToEditor({ type: "setSettings", typography: { [field]: "x".repeat(100) } })).toBe(true);
      expect(isHostToEditor({ type: "setSettings", typography: { [field]: "Helvetica Neue" } })).toBe(true);
    }
  });

  test("theme values are #rrggbb or #rrggbbaa, like Swift's sanitiser", () => {
    for (const ok of ["#ffffff", "#FFFFFF", "#1e1e1eff", "#4A8ef0"]) {
      expect(isHostToEditor({ type: "setSettings", theme: { "--bc-color-bg": ok } }), ok).toBe(true);
    }
    for (const bad of ["#fff", "#ffff", "#fffff", "#fffffff", "#fffffffff", "ffffff", "red", "rgb(1, 2, 3)", "#ggggggg", "#ffffff ", " #ffffff", "var(--x)", ""]) {
      expect(isHostToEditor({ type: "setSettings", theme: { "--bc-color-bg": bad } }), JSON.stringify(bad)).toBe(false);
    }
  });

  test("theme tokens are the schema's: an unknown --bc-* variable is rejected (M7-R4)", () => {
    expect(isHostToEditor({ type: "setSettings", theme: { "--bc-color-bg": "#ffffff", "--bc-highlight-dot-blue": "#4a8ef0" } })).toBe(true);
    for (const key of ["--bc-nonsense", "--bc-size", "--bc-font-text", "--bc-color-", "--bc-color-bg-extra", "color-bg", "--bc-color-bg "]) {
      expect(isHostToEditor({ type: "setSettings", theme: { [key]: "#ffffff" } }), key).toBe(false);
    }
  });
});

describe("sanitizeFolds", () => {
  const good = { line: 3, hash: "0a1b2c3d" };

  test("keeps valid entries in order and drops the rest", () => {
    expect(
      sanitizeFolds([
        good,
        { line: 0, hash: "0a1b2c3d" },
        { line: 1.5, hash: "0a1b2c3d" },
        { line: 1, hash: "0A1B2C3D" },
        { line: 1, hash: "0a1b2c3" },
        { line: 1, hash: "0a1b2c3d4" },
        { line: 1, hash: "0a1b2c3d", extra: 1 },
        { line: "2", hash: "0a1b2c3d" },
        null,
        7,
        "x",
        { line: 9, hash: "ffffffff" },
      ]),
    ).toEqual([good, { line: 9, hash: "ffffffff" }]);
  });

  test("caps the array", () => {
    expect(MAX_FOLDS).toBe(10_000);
    const many = Array.from({ length: MAX_FOLDS + 50 }, (_, i) => ({ line: i + 1, hash: "0a1b2c3d" }));
    const out = sanitizeFolds(many);
    expect(out).toHaveLength(MAX_FOLDS);
    expect(out[MAX_FOLDS - 1]!.line).toBe(MAX_FOLDS);
  });

  test("anything that is not an array is empty", () => {
    expect(sanitizeFolds(undefined)).toEqual([]);
    expect(sanitizeFolds("no")).toEqual([]);
  });
});

describe("bridge v4", () => {
  test("the version is 4", () => {
    expect(BRIDGE_VERSION).toBe(5);
  });

  test("setSettings-all carries every setting, and the v4 fixtures are setSettings messages", () => {
    const all = messages["../../../Fixtures/bridge/messages-setSettings-all.json"] as Record<string, unknown>;
    expect(Object.keys(all).sort()).toEqual(
      ["type", "hideMarkdown", "autoSortTodos", "showHeadingLevels", "autocomplete", "typewriterMode", "typography", "theme", "appearance", "reduceMotion"].sort(),
    );
    expect(Object.keys(all.typography as object).sort()).toEqual(
      ["fontSize", "lineHeight", "lineWidth", "paragraphSpacing", "paragraphIndent", "fontText", "fontHeading", "fontCode"].sort(),
    );
    for (const name of ["appearance", "fonts"]) {
      expect(kindOf(messages[`../../../Fixtures/bridge/messages-setSettings-${name}.json`])).toBe("host:setSettings");
    }
  });

  test("the callout types are Bear's five", () => {
    expect([...CALLOUT_TYPES]).toEqual(["note", "tip", "important", "warning", "caution"]);
  });

  test("the command names are the ones in Fixtures/bridge/command-names.json, in order", () => {
    expect([...COMMAND_NAMES]).toEqual(commandNames);
  });
});

describe("capture-close messages (W1)", () => {
  const fixture = (name: string) => messages[`../../../Fixtures/bridge/messages-${name}.json`] as Record<string, unknown>;

  test("the fixtures are the freeze, unfreeze and the three kinds of reply", () => {
    expect(kindOf(fixture("freezeForClose"))).toBe("host:freezeForClose");
    expect(kindOf(fixture("unfreeze"))).toBe("host:unfreeze");
    for (const name of ["frozenForClose", "frozenForClose-untouched", "frozenForClose-failed"]) {
      expect(kindOf(fixture(name)), name).toBe("editor:frozenForClose");
    }
  });

  test("an ok reply carries the hash and no reason; a failed one a reason and no hash", () => {
    const ok = fixture("frozenForClose");
    expect(isEditorToHost(ok)).toBe(true);
    expect(isEditorToHost({ ...ok, reason: "timeout" })).toBe(false);
    const { sha256: _sha, ...noHash } = ok;
    expect(isEditorToHost(noHash)).toBe(false);
    expect(isEditorToHost({ ...ok, sha256: "ABC" })).toBe(false);
    expect(isEditorToHost({ ...ok, lastAckedTxId: "" })).toBe(false);

    const failed = fixture("frozenForClose-failed");
    expect(isEditorToHost(failed)).toBe(true);
    expect(isEditorToHost({ ...failed, sha256: ok.sha256 })).toBe(false);
    const { reason: _reason, ...noReason } = failed;
    expect(isEditorToHost(noReason)).toBe(false);
    expect(isEditorToHost({ ...failed, reason: "because" })).toBe(false);
    expect(isEditorToHost({ ...ok, editedSinceLoad: undefined })).toBe(false);
    expect(isEditorToHost({ ...ok, ok: "yes" })).toBe(false);
  });

  test("freeze and unfreeze need a request id and a note id, and nothing else", () => {
    for (const name of ["freezeForClose", "unfreeze"]) {
      const msg = fixture(name);
      expect(isHostToEditor(msg), name).toBe(true);
      expect(isHostToEditor({ ...msg, requestId: "" }), name).toBe(false);
      expect(isHostToEditor({ ...msg, extra: 1 }), name).toBe(false);
      const { noteId: _noteId, ...noNote } = msg;
      expect(isHostToEditor(noNote), name).toBe(false);
    }
  });
});

describe("Swift changeset fixtures", () => {
  test("there are changeset fixtures", () => {
    expect(Object.keys(changesets).length).toBeGreaterThanOrEqual(3);
  });

  test.each(Object.entries(changesets))("%s applies identically in CodeMirror", (_path, fx) => {
    const result = ChangeSet.fromJSON(fx.changeset).apply(Text.of(fx.before.split("\n")));
    expect(result.toString()).toBe(fx.after);
  });
});

describe("render request fixture (M8 Task 10)", () => {
  const fixture = Object.values(
    import.meta.glob("../../../Fixtures/bridge/render-request.json", { eager: true, import: "default" }),
  )[0] as Record<string, unknown>;

  test("render-request.json parses; other versions and hostile theme variables or fonts are rejected", () => {
    expect(RENDER_VERSION).toBe(1);
    const request = parseRenderRequest(fixture);
    expect(request).not.toBeNull();
    expect(request!.mode).toBe("document");
    expect(request!.wikiLinks).toEqual([{ href: "Other%20note.html#h-2" }, null]);
    expect(request!.attachmentSizes).toEqual({ "photo 2.jpg": 20480, "report.pdf": 1048576 });

    expect(parseRenderRequest({ ...fixture, v: 2 })).toBeNull();
    expect(parseRenderRequest({ ...fixture, v: "1" })).toBeNull();
    expect(parseRenderRequest({ ...fixture, extra: 1 })).toBeNull();
    expect(parseRenderRequest(null)).toBeNull();
    expect(parseRenderRequest("x")).toBeNull();
    const without = (key: string) => Object.fromEntries(Object.entries(fixture).filter(([k]) => k !== key));
    for (const key of ["noteId", "title", "text", "mode", "theme", "appearance", "typography", "attachmentSources", "wikiLinks"]) {
      expect(parseRenderRequest(without(key)), key).toBeNull();
    }
    // The size map is optional.
    expect(parseRenderRequest(without("attachmentSizes"))).not.toBeNull();

    for (const theme of [
      { "--bc-nonsense": "#ffffff" },
      { color: "red" },
      { "--bc-color-bg": "red;} body{x:y" },
      { "--bc-color-bg": "url(https://attacker.example/x)" },
    ]) {
      expect(parseRenderRequest({ ...fixture, theme }), JSON.stringify(theme)).toBeNull();
    }
    for (const bad of ['A"B', "A;color:red", "A}", "A{", "A<b>", "A\\B", "A\nB", "x".repeat(101), ""]) {
      expect(parseRenderRequest({ ...fixture, typography: { fontText: bad } }), JSON.stringify(bad)).toBeNull();
    }
    expect(parseRenderRequest({ ...fixture, typography: { fontSize: 2 } })).toBeNull();
    expect(parseRenderRequest({ ...fixture, mode: "pdf" })).toBeNull();
    expect(parseRenderRequest({ ...fixture, appearance: "sepia" })).toBeNull();
    expect(parseRenderRequest({ ...fixture, attachmentSources: { "a.png": 1 } })).toBeNull();
    expect(parseRenderRequest({ ...fixture, attachmentSizes: { "a.png": -1 } })).toBeNull();
    expect(parseRenderRequest({ ...fixture, attachmentSizes: { "a.png": "9" } })).toBeNull();
    expect(parseRenderRequest({ ...fixture, wikiLinks: [{ href: 3 }] })).toBeNull();
    expect(parseRenderRequest({ ...fixture, wikiLinks: [{ href: "a", extra: 1 }] })).toBeNull();
    expect(parseRenderRequest({ ...fixture, wikiLinks: "no" })).toBeNull();
    expect(parseRenderRequest({ ...fixture, attachmentSizes: { "a.png": 1.5 } })).toBeNull();
  });

  // The same cases run against the Swift decoder (RenderProtocolTests.swiftAndTypeScriptAgreeOnEveryCase).
  const { cases } = Object.values(
    import.meta.glob("../../../Fixtures/bridge/render-request-cases.json", { eager: true, import: "default" }),
  )[0] as { cases: { name: string; set?: Record<string, unknown>; remove?: string[]; accepts: boolean }[] };

  test.each(cases.map((c) => [c.name, c] as const))("shared case: %s", (_name, c) => {
    const patched: Record<string, unknown> = { ...fixture, ...c.set };
    for (const key of c.remove ?? []) delete patched[key];
    expect(parseRenderRequest(patched) !== null).toBe(c.accepts);
  });
});
