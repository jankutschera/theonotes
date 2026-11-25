// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// A9 on the shared batch/TextBundle path (the iPhone and iPad export).
struct NoteExportAttachmentChoicesTests {
    private let text = "Trip\n![](photo.png)\n[a.pdf](a.pdf)<!-- {\"preview\":\"true\"} -->\n[[Other]]"
    private func note() -> Note {
        Note(id: "1", text: text, title: "Trip", titleKey: TitleKey.make("Trip"), createdAt: .now, modifiedAt: .now)
    }
    private func files(_ root: URL) throws -> (String) -> URL? {
        try Data("PNGDATA".utf8).write(to: root.appendingPathComponent("photo.png"))
        try Data("PDFDATA".utf8).write(to: root.appendingPathComponent("a.pdf"))
        return { root.appendingPathComponent($0) }
    }
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func defaultsKeepTodaysFolderAndLinks() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try files(root)
        let out = try #require(NoteExport.batch(notes: [note()], format: .markdown) { _, name in url(name) }.fileWrappers)
        #expect(Set(out.keys) == ["Trip.md", "Trip.assets"])
        let source = String(decoding: try #require(out["Trip.md"]?.regularFileContents), as: UTF8.self)
        #expect(source.contains("(Trip.assets/photo.png)") && source.contains("(Trip.assets/a.pdf)"), Comment(rawValue: source))
    }

    @Test func attachmentsOffWritesNoFolderAndLeavesLinksAsWritten() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try files(root)
        let out = try #require(NoteExport.batch(notes: [note()], format: .markdown, options: ExportOptions(includeAttachments: false)) { _, name in url(name) }.fileWrappers)
        #expect(Set(out.keys) == ["Trip.md"])
        #expect(String(decoding: try #require(out["Trip.md"]?.regularFileContents), as: UTF8.self) == text)
    }

    @Test func attachmentsOffNeverAsksForTheFiles() throws {
        let out = try NoteExport.batch(notes: [note()], format: .markdown, options: ExportOptions(includeAttachments: false)) { _, _ in
            Issue.record("a file was requested"); return nil
        }
        #expect(out.fileWrappers?.count == 1)
    }

    @Test func embeddingPutsImagesInTheTextAndOtherFilesStayInTheFolder() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try files(root)
        let out = try #require(NoteExport.batch(notes: [note()], format: .markdown, options: ExportOptions(embedImages: true)) { _, name in url(name) }.fileWrappers)
        #expect(Set(out.keys) == ["Trip.md", "Trip.assets"])
        let source = String(decoding: try #require(out["Trip.md"]?.regularFileContents), as: UTF8.self)
        #expect(source.contains("![](data:image/png;base64,\(Data("PNGDATA".utf8).base64EncodedString()))"))
        #expect(source.contains("(Trip.assets/a.pdf)"))
        #expect(Set(try #require(out["Trip.assets"]?.fileWrappers).keys) == ["a.pdf"])
    }

    @Test func aNoteWithOnlyImagesGetsNoFolderWhenEmbedded() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try files(root)
        let only = Note(id: "1", text: "Trip\n![](photo.png)", title: "Trip", titleKey: TitleKey.make("Trip"), createdAt: .now, modifiedAt: .now)
        let out = try #require(NoteExport.batch(notes: [only], format: .markdown, options: ExportOptions(embedImages: true)) { _, name in url(name) }.fileWrappers)
        #expect(Set(out.keys) == ["Trip.md"])
    }

    @Test func anImageOverTheLimitStaysInTheFolder() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 10 * 1024 * 1024 + 1).write(to: root.appendingPathComponent("photo.png"))
        let only = Note(id: "1", text: "Trip\n![](photo.png)", title: "Trip", titleKey: TitleKey.make("Trip"), createdAt: .now, modifiedAt: .now)
        let out = try #require(NoteExport.batch(notes: [only], format: .markdown, options: ExportOptions(embedImages: true)) { _, name in root.appendingPathComponent(name) }.fileWrappers)
        #expect(Set(out.keys) == ["Trip.md", "Trip.assets"])
    }

    @Test func textBundleWithoutAttachmentsHasNoAssetsAndKeepsLinks() throws {
        let one = try NoteExport.textBundle(note: note(), includeAttachments: false) { _ in Issue.record("a file was requested"); return nil }
        #expect(Set(try #require(one.fileWrappers).keys) == ["text.md", "info.json"])
        #expect(String(decoding: try #require(one.fileWrappers?["text.md"]?.regularFileContents), as: UTF8.self) == text)
        let batch = try NoteExport.batch(notes: [note()], format: .textBundle, options: ExportOptions(includeAttachments: false)) { _, _ in nil }
        let bundle = try #require(batch.fileWrappers?["Trip.textbundle"]?.fileWrappers)
        #expect(Set(bundle.keys) == ["text.md", "info.json"])
    }
}
