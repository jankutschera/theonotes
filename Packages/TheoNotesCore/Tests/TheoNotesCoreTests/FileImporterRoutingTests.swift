// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// `FileImporter` hands `.enex` files to `EvernoteImporter` and Notion exports (zip, multi-part
/// zip, unpacked folder) to `NotionImporter`; every other zip or folder stays generic. `.enex`
/// files below a chosen folder or generic archive go to `EvernoteImporter` too.
/// Sources are the synthetic fixtures in `Fixtures/import`.
@Suite struct FileImporterRoutingTests {
    let tmp: TempPaths
    let scratch: Scratch
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        scratch = try Scratch()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/import", isDirectory: true)

    private var evernote: URL { Self.fixtures.appendingPathComponent("evernote", isDirectory: true) }
    private var notion: URL { Self.fixtures.appendingPathComponent("notion", isDirectory: true) }

    private func run(
        _ urls: [URL], progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try FileImporter(store: store, paths: tmp.paths, temporaryDirectory: scratch.temp)
            .importItems(urls, progress: progress, isCancelled: isCancelled)
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
    }

    private func titles() throws -> [String] { try allNotes().map(\.title).sorted() }

    private func makeZip(_ tree: URL, _ entries: [String], to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-q", "-r", "-X", archive.path] + entries
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func notionZip() throws -> URL {
        let archive = scratch.url.appendingPathComponent("Export-markdown.zip")
        try makeZip(notion.appendingPathComponent("markdown-export"), ["Private & Shared"], to: archive)
        return archive
    }

    /// An export that arrives as one zip of `Part-N.zip` archives.
    private func multiPartZip() throws -> URL {
        let parts = notion.appendingPathComponent("parts")
        let outer = try scratch.dir("outer")
        try makeZip(parts.appendingPathComponent("Part-1"), ["."], to: outer.appendingPathComponent("Export-ccc-Part-1.zip"))
        try makeZip(parts.appendingPathComponent("Part-2"), ["."], to: outer.appendingPathComponent("Export-ccc-Part-2.zip"))
        let archive = scratch.url.appendingPathComponent("Export-ccc.zip")
        try makeZip(outer, ["Export-ccc-Part-1.zip", "Export-ccc-Part-2.zip"], to: archive)
        return archive
    }

    @Test func anEnexFileGoesToTheEvernoteImporter() throws {
        let report = try run([evernote.appendingPathComponent("Travel.enex")])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 2)
        #expect(try titles().contains("Packing list"))
        let packing = try #require(try allNotes().first { $0.title == "Packing list" })
        #expect(packing.text.hasSuffix("#evernote/Travel"))
    }

    @Test func theEnexExtensionIsMatchedWhateverItsCase() throws {
        let copy = try scratch.write("Trip.ENEX", try Data(contentsOf: evernote.appendingPathComponent("Travel.enex")))

        let report = try run([copy])

        #expect(report.created == 2)
        #expect(report.skipped == 0)
        #expect(report.warnings.isEmpty)
    }

    @Test func aNotionZipGoesToTheNotionImporter() throws {
        let report = try run([try notionZip()])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 7)
        let hub = try #require(try allNotes().first { $0.title == "Project Hub" })
        #expect(hub.text.hasPrefix("# Project Hub\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func aMultiPartNotionZipIsRecognisedByItsFileNames() throws {
        let archive = try multiPartZip()
        #expect(NotionImporter.looksLikeNotionExport(archive))

        let report = try run([archive])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 4)
        #expect(try titles() == ["Alpha", "Beta", "Gamma", "Workspace"])
    }

    @Test func anUnpackedNotionFolderGoesToTheNotionImporter() throws {
        let report = try run([notion.appendingPathComponent("markdown-export")])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 7)
        #expect(try titles().contains("Kickoff Plan"))
    }

    @Test func aZipOfPlainMarkdownStaysGeneric() throws {
        try scratch.write("plain/Alpha.md", "# Alpha\n\nbody\n")
        try scratch.write("plain/Beta.md", "# Beta\n\nbody\n")
        let archive = scratch.url.appendingPathComponent("vault.zip")
        try makeZip(scratch.url.appendingPathComponent("plain"), ["."], to: archive)
        #expect(!NotionImporter.looksLikeNotionExport(archive))

        let report = try run([archive])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 2)
        #expect(try titles() == ["Alpha", "Beta"])
        let alpha = try #require(try allNotes().first { $0.title == "Alpha" })
        #expect(!alpha.text.contains("#notion"))
    }

    @Test func aFolderOfPlainMarkdownStaysGeneric() throws {
        try scratch.write("vault/One.md", "# One\n\nbody\n")
        try scratch.write("vault/sub/Two.md", "# Two\n\nbody\n")

        let report = try run([scratch.url.appendingPathComponent("vault")])

        #expect(report.created == 2)
        #expect(try titles() == ["One", "Two"])
    }

    @Test func anEnexFileInsideAFolderIsImportedThroughTheEvernoteImporter() throws {
        try scratch.write("vault/One.md", "# One\n\nbody\n")
        try scratch.write("vault/books/Travel.enex", try Data(contentsOf: evernote.appendingPathComponent("Travel.enex")))

        let report = try run([scratch.url.appendingPathComponent("vault")])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 3)
        let packing = try #require(try allNotes().first { $0.title == "Packing list" })
        #expect(packing.text.hasSuffix("#evernote/Travel"))
        #expect(try titles().contains("One"))
    }

    @Test func anEnexFileInsideAGenericZipIsImportedToo() throws {
        try scratch.write("pack/One.md", "# One\n\nbody\n")
        try scratch.write("pack/Travel.enex", try Data(contentsOf: evernote.appendingPathComponent("Travel.enex")))
        let archive = scratch.url.appendingPathComponent("pack.zip")
        try makeZip(scratch.url.appendingPathComponent("pack"), ["."], to: archive)

        let report = try run([archive])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 3)
    }

    @Test func aZipOfZipsNamedExportIsNotTakenForANotionExport() throws {
        // Only `Part-N.zip` names mark a multi-part Notion export; any other `Export-*.zip` is generic.
        let inner = try scratch.dir("inner")
        try scratch.write("inner/pics/One.md", "# One\n\nbody\n")
        try makeZip(inner, ["."], to: scratch.url.appendingPathComponent("Export-photos.zip"))
        let outer = try scratch.dir("outer2")
        try FileManager.default.copyItem(
            at: scratch.url.appendingPathComponent("Export-photos.zip"), to: outer.appendingPathComponent("Export-photos.zip"))
        let archive = scratch.url.appendingPathComponent("holiday.zip")
        try makeZip(outer, ["Export-photos.zip"], to: archive)

        #expect(!NotionImporter.looksLikeNotionExport(archive))
        #expect(!NotionImporter.looksLikeNotionExport(outer))
        let report = try run([archive])

        #expect(!(try allNotes().contains { $0.text.contains("#notion") }))
        #expect(report.errors.isEmpty, "\(report.errors)")
    }

    @Test func aPlainZipNamedExportStaysGeneric() throws {
        try scratch.write("plain/Alpha.md", "# Alpha\n\nbody\n")
        let archive = scratch.url.appendingPathComponent("Export-photos.zip")
        try makeZip(scratch.url.appendingPathComponent("plain"), ["."], to: archive)

        #expect(!NotionImporter.looksLikeNotionExport(archive))
        let report = try run([archive])

        #expect(report.created == 1)
        #expect(try titles() == ["Alpha"])
    }

    @Test func severalSourcesInOneRunAreAllImportedAndProgressCounts() throws {
        try scratch.write("loose/Own note.md", "# Own note\n\nbody\n")
        var steps: [(Int, Int)] = []

        let report = try run(
            [scratch.url.appendingPathComponent("loose/Own note.md"), evernote.appendingPathComponent("Travel.enex"),
             try notionZip()],
            progress: { steps.append(($0, $1)) })

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 1 + 2 + 7)
        #expect(try allNotes().count == 10)
        #expect(steps.first?.0 == 0)
        let last = try #require(steps.last)
        #expect(last.0 == last.1, "the run ends at 100 percent: \(last)")
        #expect(last.1 == 10)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 }, "done never goes back")
        #expect(steps.allSatisfy { $0.0 <= $0.1 })
    }

    @Test func cancellingStopsInsideAForeignImporterAndTheRest() throws {
        try scratch.write("loose/After.md", "# After\n\nbody\n")
        var done = 0

        let report = try run(
            [try notionZip(), scratch.url.appendingPathComponent("loose/After.md")],
            progress: { finished, _ in done = finished }, isCancelled: { done >= 2 })

        #expect(report.wasCancelled)
        #expect(report.created >= 2 && report.created < 8)
        #expect(!(try titles().contains("After")))
    }

    @Test func aBrokenEnexIsReportedAndTheNextSourceStillImports() throws {
        let broken = try scratch.write("Broken.enex", "this is not xml at all")
        try scratch.write("loose/Fine.md", "# Fine\n\nbody\n")

        let report = try run([broken, scratch.url.appendingPathComponent("loose/Fine.md")])

        #expect(report.created == 1)
        #expect(report.errors.contains { $0.hasPrefix("Broken.enex") }, "\(report.errors)")
        #expect(try titles() == ["Fine"])
    }

    @Test func aMissingEnexIsReportedNotThrown() throws {
        let report = try run([scratch.url.appendingPathComponent("Gone.enex")])

        #expect(report.errors == ["Gone.enex: not found"])
        #expect(report.created == 0)
    }
}

// MARK: - IMP-C1: a zip of `*-Part-N.zip` files that is not a Notion export

extension FileImporterRoutingTests {
    /// `photos.zip` holds `photos-Part-1.zip`, which holds plain Markdown without Notion's ids.
    private func plainPartsZip(_ pages: [String: String]) throws -> URL {
        for (name, text) in pages { try scratch.write("inner/\(name)", text) }
        let outer = try scratch.dir("outer")
        try makeZip(scratch.url.appendingPathComponent("inner"), ["."], to: outer.appendingPathComponent("photos-Part-1.zip"))
        let archive = scratch.url.appendingPathComponent("photos.zip")
        try makeZip(outer, ["photos-Part-1.zip"], to: archive)
        return archive
    }

    @Test func aZipOfPartsHoldingPlainMarkdownIsImportedGenerically() throws {
        let archive = try plainPartsZip([
            "Alpha.md": "# Alpha\n\nbody one\n",
            "Beta.md": "# Beta\n\nbody two #topic\n",
            "sub/Gamma.md": "# Gamma\n\nbody three\n",
        ])
        #expect(NotionImporter.looksLikeNotionExport(archive), "the names alone route it to the Notion importer")

        let report = try run([archive])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 3)
        #expect(try titles() == ["Alpha", "Beta", "Gamma"])
        let notes = try allNotes()
        // The generic importer keeps the text as written: no title rewrite, no notion/ tag.
        #expect(Set(notes.map(\.text)) == ["# Alpha\n\nbody one\n", "# Beta\n\nbody two #topic\n", "# Gamma\n\nbody three\n"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func aMinorityOfIdSuffixedFilesDoesNotMakeItANotionExport() throws {
        let archive = try plainPartsZip([
            "Plain one.md": "# Plain one\n",
            "Plain two.md": "# Plain two\n",
            "Named aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01.md": "# Named aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01\n",
        ])

        let report = try run([archive])

        #expect(report.created == 3)
        #expect(try allNotes().contains { $0.text == "# Named aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01\n" }, "no id stripping")
        #expect(try allNotes().allSatisfy { !$0.text.contains("#notion") })
    }

    @Test func aZipOfPartsHoldingIdSuffixedPagesStaysANotionImport() throws {
        let report = try run([try multiPartZip()])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(try titles() == ["Alpha", "Beta", "Gamma", "Workspace"])
        let gamma = try #require(try allNotes().first { $0.title == "Gamma" })
        #expect(gamma.text.contains("#notion/Workspace"))
    }
}
