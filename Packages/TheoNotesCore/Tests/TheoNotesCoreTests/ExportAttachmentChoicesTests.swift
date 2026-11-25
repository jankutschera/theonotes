// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// A9: the attachment choices of a Markdown / TextBundle export. The defaults are today's behaviour.
@Suite struct ExportAttachmentChoicesTests {
    let lib: ExportRoundTripTests.Library
    let out: URL
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let pdf = Data("%PDF-1.4 x".utf8)

    init() throws {
        lib = try ExportRoundTripTests.Library()
        out = lib.tmp.paths.root.appendingPathComponent("choices-out")
    }

    private func note(_ text: String = "Trip\n\n![](photo.png)\n\n[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->\n") throws -> Note {
        try lib.store.importNote(ImportedNoteDraft(
            text: text, createdAt: Date(), modifiedAt: Date(),
            attachments: [ImportedAttachment(filename: "photo.png", data: png), ImportedAttachment(filename: "a.pdf", data: pdf)]))
    }

    private func export(_ note: Note, _ format: FileExportFormat, _ options: ExportOptions) throws -> ExportedFiles {
        let item = try #require(ExportPlan.selection(try lib.store.exportCandidates(ids: [note.id])).items.first)
        return try NoteExporter(store: lib.store, paths: lib.tmp.paths).write(item, format: format, under: out, options: options)
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func defaultsKeepTodaysBehaviour() throws {
        let files = try export(try note(), .markdown, ExportOptions())
        let text = try String(contentsOf: files.primary, encoding: .utf8)
        #expect(text.contains("![](Trip/photo.png)") && text.contains("[a.pdf](Trip/a.pdf)"))
        #expect(names(out.appendingPathComponent("Trip")) == ["a.pdf", "photo.png"])
    }

    @Test func leavingAttachmentsOutCopiesNothingAndKeepsTheLinksAsWritten() throws {
        let files = try export(try note(), .markdown, ExportOptions(includeAttachments: false))
        let text = try String(contentsOf: files.primary, encoding: .utf8)
        #expect(text.contains("![](photo.png)") && text.contains("[a.pdf](a.pdf)"))
        #expect(files.attachmentsFolder == nil)
        #expect(names(out) == ["Trip.md"])
    }

    @Test func leavingAttachmentsOutAppliesToATextBundleToo() throws {
        let files = try export(try note(), .textBundle, ExportOptions(includeAttachments: false))
        #expect(names(files.primary) == ["info.json", "text.md"])
        #expect(try String(contentsOf: files.primary.appendingPathComponent("text.md"), encoding: .utf8).contains("![](photo.png)"))
    }

    @Test func embeddedImagesGoIntoTheFileAndOtherFilesStayInTheFolder() throws {
        let files = try export(try note(), .markdown, ExportOptions(embedImages: true))
        let text = try String(contentsOf: files.primary, encoding: .utf8)
        #expect(text.contains("![](data:image/png;base64,\(png.base64EncodedString()))"))
        #expect(text.contains("[a.pdf](Trip/a.pdf)"))
        #expect(names(out.appendingPathComponent("Trip")) == ["a.pdf"])
    }

    @Test func embeddingWithOnlyImagesLeavesNoFolder() throws {
        let note = try lib.store.importNote(ImportedNoteDraft(
            text: "Pic\n\n![](photo.png)\n", createdAt: Date(), modifiedAt: Date(),
            attachments: [ImportedAttachment(filename: "photo.png", data: png)]))
        let files = try export(note, .markdown, ExportOptions(embedImages: true))
        #expect(files.attachmentsFolder == nil)
        #expect(names(out) == ["Pic.md"])
    }

    @Test func embeddingDoesNothingWhileAttachmentsAreLeftOut() throws {
        let files = try export(try note(), .markdown, ExportOptions(includeAttachments: false, embedImages: true))
        #expect(try String(contentsOf: files.primary, encoding: .utf8).contains("![](photo.png)"))
        #expect(!(try String(contentsOf: files.primary, encoding: .utf8)).contains("data:"))
    }

    @Test func linksInsideCodeAreNotEmbedded() throws {
        let note = try note("Code\n\n`![](photo.png)`\n\n![](photo.png)\n")
        let text = try String(contentsOf: try export(note, .markdown, ExportOptions(embedImages: true)).primary, encoding: .utf8)
        #expect(text.contains("`![](photo.png)`"))
        #expect(text.components(separatedBy: "data:image/png").count == 2)
    }
}
