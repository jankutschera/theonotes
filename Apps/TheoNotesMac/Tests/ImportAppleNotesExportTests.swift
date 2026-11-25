// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import TheoNotes

/// File ▸ Import From ▸ Apple Notes Export…: its open panel, the model path that reads the export
/// with `AppleNotesExportImporter` (and not the general file importer), and a real import on a
/// temp library.
@MainActor
@Suite struct ImportAppleNotesExportTests {
    /// Records which importer the model asked for.
    final class RecordingService: ImportService, @unchecked Sendable {
        let calls = Mutex<[String]>([])

        func bearPreview(executable: URL) throws -> BearLibraryPreview { BearLibraryPreview(total: 0, trashed: 0) }
        func pullFromBear(
            executable: URL, progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> BearImportReport { BearImportReport(total: 0) }
        func appleNotesPreview() throws -> AppleNotesPreview { AppleNotesPreview(total: 0, accounts: 0) }
        func importFromAppleNotes(
            progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> AppleNotesImportReport { AppleNotesImportReport(total: 0) }

        func importFiles(
            _ urls: [URL], options: FileImportOptions,
            progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> FileImportReport {
            calls.withLock { $0.append("files \(urls.count)") }
            return FileImportReport(created: 1)
        }

        func importAppleNotesExport(
            _ urls: [URL], options: FileImportOptions,
            progress: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool
        ) throws -> FileImportReport {
            calls.withLock { $0.append("export \(urls.count) keepDates=\(options.keepDates)") }
            progress(2, 2)
            return FileImportReport(created: 2, attachmentsCopied: 3, warnings: ["x: 1 file(s) not linked from any note, not imported"])
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 5 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func finished(_ model: ImportModel) -> ImportSummary? {
        if case .finished(let summary) = model.phase { return summary }
        return nil
    }

    // MARK: - The panel

    @Test func thePanelOffersFoldersZipsAndMarkdownNotEnex() throws {
        let panel = ImportPanel.makePanel(for: .appleNotesExport)
        let zip = try #require(UTType(filenameExtension: "zip"))
        let markdown = try #require(UTType(filenameExtension: "md"))
        let enex = try #require(UTType(filenameExtension: "enex"))

        #expect(panel.allowedContentTypes.contains(.folder))
        #expect(panel.allowedContentTypes.contains { zip.conforms(to: $0) })
        #expect(panel.allowedContentTypes.contains { markdown.conforms(to: $0) })
        #expect(!panel.allowedContentTypes.contains { enex.conforms(to: $0) })
        #expect(panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
        #expect(panel.message.contains("Apple Notes"))
        #expect(panel.message.contains("Markdown"))
    }

    // MARK: - The model

    @Test func theExportModeCallsTheExportImporterWithTheChosenOptions() async {
        let service = RecordingService()
        let model = ImportModel(service: service, bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: {})
        let urls = [URL(fileURLWithPath: "/tmp/Export")]

        model.showFileImport(urls, mode: .appleNotesExport)
        #expect(model.sheet == .files(urls))
        #expect(model.fileImportMode == .appleNotesExport)
        model.fileOptions.keepDates = false
        model.startFileImport()
        await waitUntil("finished") { finished(model) != nil }

        #expect(service.calls.withLock { $0 } == ["export 1 keepDates=false"])
        let summary = finished(model)
        #expect(summary?.title == "Import from Apple Notes export finished")
        #expect(summary?.rows.map(\.count) == [2, 0, 3])
        #expect(summary?.warnings.count == 1)
    }

    @Test func theGeneralImportStillUsesTheFileImporter() async {
        let service = RecordingService()
        let model = ImportModel(service: service, bearCLIPath: { "/x/bearcli" }, prepare: {}, didImport: {})

        model.showFileImport([URL(fileURLWithPath: "/tmp/a.md")])
        #expect(model.fileImportMode == .files)
        model.startFileImport()
        await waitUntil("finished") { finished(model) != nil }

        #expect(service.calls.withLock { $0 } == ["files 1"])
        #expect(finished(model)?.title == "Import finished")
    }

    @Test func theModeIsForgottenWhenAnotherSheetOpens() {
        let model = ImportModel(service: RecordingService(), bearCLIPath: { "/x" }, prepare: {}, didImport: {})
        model.showFileImport([URL(fileURLWithPath: "/tmp/Export")], mode: .appleNotesExport)
        model.dismissSheet()
        model.showFileImport([URL(fileURLWithPath: "/tmp/a.md")])

        #expect(model.fileImportMode == .files)
    }

    // MARK: - A real import

    @Test func aRealExportFolderBringsNotesPdfsAndTags() async throws {
        let env = try ImportIntegrationTests.Env(bearRecords: "[]")
        let export = env.root.appendingPathComponent("Pantry Export", isDirectory: true)
        let attachments = export.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try "# Jam\n\nSee [recipe.pdf](Attachments/recipe.pdf)\n"
            .write(to: export.appendingPathComponent("Jam.md"), atomically: true, encoding: .utf8)
        try Data("%PDF-1.4 synthetic".utf8).write(to: attachments.appendingPathComponent("recipe.pdf"))

        env.importer.showFileImport([export], mode: .appleNotesExport)
        env.importer.startFileImport()
        await waitUntil("import") { finished(env.importer) != nil }

        let summary = finished(env.importer)
        #expect(summary?.errors == [])
        #expect(summary?.rows.map(\.count) == [1, 0, 1])
        #expect(env.library.items.map(\.title) == ["Jam"])
        let note = try #require(try env.environment.store.note(id: env.library.items[0].id))
        #expect(note.text.contains("[recipe.pdf](recipe.pdf)"))
        #expect(NoteParser.metadata(for: note.text).tags == ["apple-notes/Pantry Export"])
    }
}
