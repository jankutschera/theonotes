// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import { describe, expect, test } from "vitest";
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import { ensureSyntaxTree } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { bearMarkdown } from "../src/editor/dialect";
import {
  attachmentAt,
  attachmentDecorationSpecs,
  attachmentLink,
  attachmentNote,
  attachmentsIn,
  attachmentURL,
  encodeFilename,
  formatBytes,
  resizeSpec,
  addPendingInsert,
  attachmentsInText,
  checkUploadSizes,
  copiedAttachments,
  pendingInserts,
  removePendingInsert,
  selectAttachmentSpec,
  selectedAttachment,
  selectedAttachmentRange,
  settingMetadata,
} from "../src/editor/features/attachments";
import { computeHiddenRanges } from "../src/editor/features/hiding";
import { MockHost } from "../src/bridge/hosts";

type Fixture = {
  name: string;
  input: string;
  expected: { filename: string; isImage: boolean; metadata: Record<string, string> }[];
};
const fixtures = Object.values(
  import.meta.glob("../../../Fixtures/dialect/attachments.json", { eager: true, import: "default" }),
)[0] as Fixture[];

function parsed(state: EditorState): EditorState {
  if (!ensureSyntaxTree(state, state.doc.length, 5000)) throw new Error("parse timed out");
  return state.update({}).state;
}

function stateWith(doc: string, anchor = doc.length, head = anchor, extensions: Extension[] = []): EditorState {
  return parsed(
    EditorState.create({
      doc,
      selection: EditorSelection.single(anchor, head),
      extensions: [markdown({ base: bearMarkdown }), attachmentNote.of("N1"), ...extensions],
    }),
  );
}

describe("attachment recognition", () => {
  test.each(fixtures)("Fixtures/dialect/attachments.json: $name", ({ input, expected }) => {
    const state = stateWith(input, 0);
    const seen = new Set<string>();
    const found = attachmentsIn(state)
      .filter((a) => !seen.has(a.filename) && seen.add(a.filename))
      .map(({ filename, isImage, metadata }) => ({ filename, isImage, metadata }));
    expect(found).toEqual(expected);
  });

  test("ranges cover the link and its metadata comment, kinds follow the extension", () => {
    const doc = 'a ![](x.png) b [r.pdf](r.pdf) <!-- {"embed":"true"} --> c [z](z.zip)<!-- {"embed":"true"} -->';
    const found = attachmentsIn(stateWith(doc, 0));
    expect(found.map((a) => [doc.slice(a.from, a.to), a.kind])).toEqual([
      ["![](x.png)", "image"],
      ['[r.pdf](r.pdf) <!-- {"embed":"true"} -->', "pdf"],
      ['[z](z.zip)<!-- {"embed":"true"} -->', "file"],
    ]);
    expect(attachmentAt(stateWith(doc, 0), 3)?.filename).toBe("x.png");
    expect(attachmentAt(stateWith(doc, 0), 1)).toBeNull();
  });
});

describe("attachment Markdown (mirrors AttachmentMarkdown.swift)", () => {
  test("new attachments are written in Bear format", () => {
    expect(attachmentLink("image.png")).toBe("![](image.png)");
    expect(attachmentLink("photo 2.JPG")).toBe("![](photo%202.JPG)");
    expect(attachmentLink("Report (final).pdf")).toBe(
      '[Report (final).pdf](Report%20%28final%29.pdf)<!-- {"preview":"true","embed":"true"} -->',
    );
    expect(attachmentLink("data.zip")).toBe('[data.zip](data.zip)<!-- {"embed":"true"} -->');
    expect(attachmentLink("[x].txt")).toBe('[\\[x\\].txt](%5Bx%5D.txt)<!-- {"embed":"true"} -->');
    expect(encodeFilename("a!'*~.png")).toBe("a%21%27%2A~.png");
  });

  test("what is written reads back as the same attachment", () => {
    for (const name of ["image.png", "photo 2.JPG", "Report (final).pdf", "data.zip", "[x].txt", "日本 100%.pdf"]) {
      expect(attachmentsIn(stateWith(attachmentLink(name), 0)).map((a) => a.filename)).toEqual([name]);
    }
  });

  test("metadata is merged in place, keys keep their order", () => {
    expect(settingMetadata('[a.pdf](a.pdf)<!-- {"preview":"true","embed":"true"} -->', "preview", "false")).toBe(
      '[a.pdf](a.pdf)<!-- {"preview":"false","embed":"true"} -->',
    );
    expect(settingMetadata("![](a.png)", "width", "320")).toBe('![](a.png)<!-- {"width":"320"} -->');
    expect(settingMetadata('![](a.png) <!-- {"width":"100"} -->', "width", "320")).toBe('![](a.png) <!-- {"width":"320"} -->');
    expect(settingMetadata('![](a.png)<!-- {"width":"100"} -->', "width", null)).toBe("![](a.png)");
    expect(settingMetadata("not a link", "width", "1")).toBeNull();
  });

  test("URLs go through the asset scheme, percent-encoded", () => {
    expect(attachmentURL("N1", "photo 2.jpg")).toBe("baerchen-asset://attachment/N1/photo%202.jpg");
    expect(attachmentURL("N1", "a.pdf", "thumbnail")).toBe("baerchen-asset://thumbnail/N1/a.pdf");
  });

  test("file sizes read like Finder", () => {
    expect(formatBytes(512)).toBe("512 bytes");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(5 * 1024 * 1024)).toBe("5 MB");
  });
});

describe("attachment presentation", () => {
  test("the whole source is collapsed (kept in the DOM) and a widget is drawn at its start", () => {
    const doc = 'x ![](a.png)<!-- {"width":"200"} --> y [d.pdf](d.pdf)<!-- {"preview":"false","embed":"true"} -->';
    const specs = attachmentDecorationSpecs(stateWith(doc, 0));
    expect(specs.map((s) => [doc.slice(s.from, s.to), s.widget])).toEqual([
      ['![](a.png)<!-- {"width":"200"} -->', { kind: "image", noteId: "N1", filename: "a.png", width: 200, preview: true, selected: false }],
      [
        '[d.pdf](d.pdf)<!-- {"preview":"false","embed":"true"} -->',
        { kind: "pdf", noteId: "N1", filename: "d.pdf", preview: false, selected: false },
      ],
    ]);
  });

  test("the selected attachment is drawn selected until an edit or the caret leaves it", () => {
    const doc = "![](a.png) ![](b.png)";
    const start = stateWith(doc, 0, 0, [selectedAttachmentRange]);
    const selected = start.update(selectAttachmentSpec({ from: 0, to: 10 })).state;
    expect(selected.selection.main.head).toBe(10);
    expect(attachmentDecorationSpecs(selected).map((s) => s.widget.selected)).toEqual([true, false]);
    expect(selectedAttachment(selected)?.filename).toBe("a.png");
    // The caret on its other edge keeps it; moving on or typing does not.
    expect(selectedAttachment(selected.update({ selection: { anchor: 0 } }).state)?.filename).toBe("a.png");
    expect(selectedAttachment(selected.update({ selection: { anchor: 11 } }).state)).toBeNull();
    expect(selectedAttachment(selected.update({ changes: { from: 21, insert: "x" } }).state)).toBeNull();
  });

  test("hiding leaves file attachment links to the attachment widgets", () => {
    const doc = '[d.pdf](d.pdf)<!-- {"embed":"true"} --> and [site](https://x.y)';
    const hidden = computeHiddenRanges(stateWith(doc, doc.length)).map((r) => doc.slice(r.from, r.to));
    expect(hidden).toEqual(["[", "](https://x.y)"]);
  });

  test("hiding and the widgets agree on what is an attachment (one recognizer, minor M4)", () => {
    const variants = [
      '[a.pdf](a.pdf "t")<!-- {} --> x',
      '[a.pdf](a.pdf) <!-- {"embed":"true"} --> x',
      "[a.pdf](<a b.pdf>)<!-- {} --> x",
      "[a.pdf](a.pdf)<!-- note --> x",
      "[a.pdf](a.pdf) x",
      "[a](#top)<!-- {} --> x",
      "[a](https://x.y/a.pdf)<!-- {} --> x",
      "[a](a%20b.zip)<!-- {} --> x",
    ];
    for (const doc of variants) {
      const state = stateWith(doc, doc.length);
      const card = attachmentsIn(state).length > 0;
      const linkHidden = computeHiddenRanges(state).some((r) => r.from === 0);
      expect(card !== linkHidden, doc).toBe(true);
    }
  });

  test("resizing writes the width into the metadata comment, one change", () => {
    const doc = 'a ![](a.png)<!-- {"embed":"true"} --> b';
    const state = stateWith(doc, 0);
    const attachment = attachmentsIn(state)[0]!;
    const next = state.update(resizeSpec(state, attachment, 321.6)).state;
    expect(next.doc.toString()).toBe('a ![](a.png)<!-- {"embed":"true","width":"322"} --> b');
  });
});

describe("mock host attachments", () => {
  test("insertAttachments answers like the Swift host: insertText with Bear Markdown for the pending insert", async () => {
    const host = new MockHost({ text: "ab" });
    const received: unknown[] = [];
    host.onMessage((m) => { received.push(m); });
    await host.send({ type: "insertAttachments", noteId: "mock-note", insertId: "i1", items: [{ filename: "image.png", dataBase64: "iVBORw0K" }, { filename: "d.pdf", dataBase64: "" }] });
    expect(received).toEqual([
      {
        type: "applyCommand",
        name: "insertText",
        args: { text: '![](image.png)\n[d.pdf](d.pdf)<!-- {"preview":"true","embed":"true"} -->', insertId: "i1" },
      },
    ]);
  });
});

describe("drops and pastes", () => {
  test("a pending insert follows the edits until the host answers, then is used once", () => {
    const start = stateWith("ab", 1, 1, [pendingInserts]);
    let state = start.update({ effects: addPendingInsert.of({ id: "p", from: 1, to: 1 }) }).state;
    // Typing before and at the drop point moves it; typing after does not.
    state = state.update({ changes: { from: 0, insert: "xx" } }).state;
    state = state.update({ changes: { from: 3, insert: "T" } }).state;
    expect(state.field(pendingInserts).get("p")).toEqual({ from: 3, to: 3 });
    const pasted = state.update({ changes: { from: 0, to: 0, insert: "" } }).state;
    expect(pasted.field(pendingInserts).get("p")).toEqual({ from: 3, to: 3 });
    const cleared = state.update({ effects: removePendingInsert.of("p") }).state;
    expect(cleared.field(pendingInserts).size).toBe(0);
  });

  test("files over 50 MB, or 100 MB together, are refused before they are read", () => {
    const mb = 1024 * 1024;
    expect(checkUploadSizes([{ name: "a.png", size: 49 * mb }])).toEqual({ ok: true });
    expect(checkUploadSizes([{ name: "big.mov", size: 51 * mb }, { name: "a.png", size: 1 }])).toEqual({ ok: false, filenames: ["big.mov"] });
    expect(checkUploadSizes([{ name: "a", size: 40 * mb }, { name: "b", size: 40 * mb }, { name: "c", size: 40 * mb }])).toEqual({
      ok: false,
      filenames: ["a", "b", "c"],
    });
  });

  test("copying a selection with attachments puts their files on the clipboard too", () => {
    const doc = 'x ![](a.png) [r.pdf](r.pdf)<!-- {"embed":"true"} --> y';
    const copied = copiedAttachments(stateWith(doc, 0, doc.length));
    expect(copied).toEqual({ text: doc, ranges: [{ from: 0, to: doc.length }], payload: JSON.stringify({ noteId: "N1", filenames: ["a.png", "r.pdf"] }) });
    // Only links entirely inside the selection; plain text gets the default copy.
    expect(copiedAttachments(stateWith(doc, 0, 5))).toBeNull();
    expect(copiedAttachments(stateWith("plain", 0, 5))).toBeNull();
    // A selected attachment (caret after it) copies that attachment.
    const selected = stateWith(doc, 0, 0, [selectedAttachmentRange]).update(selectAttachmentSpec({ from: 2, to: 12 })).state;
    expect(copiedAttachments(selected)?.text).toBe("![](a.png)");
  });

  test("pasted text is parsed on its own for its attachment links", () => {
    expect(attachmentsInText('see ![](a%20b.png) and `![](no.png)`').map(({ from, to, filename }) => ({ from, to, filename }))).toEqual([
      { from: 4, to: 18, filename: "a b.png" },
    ]);
  });
});
