// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import GRDB
import PDFKit
import Testing
@testable import TheoNotes

/// M8 Task 12: one export run in every format. R34: the renderer-based formats use a hidden
/// `WKWebView`; check the screen lock before reading a failure
/// (`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`).
@MainActor
@Suite(.serialized) final class ExportJobTests {
    let root: URL
    let environment: AppEnvironment
    let out: URL
    let created = Date(timeIntervalSince1970: 1_760_000_000.25)
    let modified = Date(timeIntervalSince1970: 1_760_000_500.5)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BaerchenExportJob-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        out = root.appendingPathComponent("out", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func add(_ text: String, files: [(String, Data)] = [], _ offset: Double = 0) throws -> Note {
        try environment.store.importNote(ImportedNoteDraft(
            text: text, createdAt: created.addingTimeInterval(offset), modifiedAt: modified.addingTimeInterval(offset),
            attachments: files.map { ImportedAttachment(filename: $0.0, data: $0.1) }))
    }

    private func selection(_ notes: [Note]) throws -> ExportPlan.Result {
        ExportPlan.selection(try environment.store.exportCandidates(ids: notes.map(\.id)))
    }

    private func run(
        _ plan: ExportPlan.Result, _ settings: ExportSettings, renderer: NoteRenderer? = nil,
        isCancelled: () -> Bool = { false }, progress: (Int, Int) -> Void = { _, _ in }
    ) async -> ExportJobReport {
        let job = ExportJob(environment: environment, renderer: renderer ?? NoteRenderer(environment: environment))
        return await job.run(plan, settings: settings, destination: out, progress: progress, isCancelled: isCancelled)
    }

    private func contents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func dates(_ url: URL) throws -> (created: Date, modified: Date) {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (try #require(values.creationDate), try #require(values.contentModificationDate))
    }

    private func expectDates(_ url: URL, _ note: Note, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let d = try dates(url)
        #expect(abs(d.created.timeIntervalSince(note.createdAt)) < 0.002, "created of \(url.lastPathComponent)", sourceLocation: sourceLocation)
        #expect(abs(d.modified.timeIntervalSince(note.modifiedAt)) < 0.002, "modified of \(url.lastPathComponent)", sourceLocation: sourceLocation)
    }

    private static let png: Data = NoteRendererTests.redPNG() ?? Data([0x89, 0x50, 0x4E, 0x47])

    private static let everything = """
        Export Me

        This has **bold words** in it.

        - first item
        - second item

        ![](photo.png)

        [a.pdf](a.pdf)<!-- {"embed":"true"} -->
        """

    // MARK: - Every format

    @Test(arguments: ExportFormat.allCases)
    func everyFormatWritesItsFileWithTheNoteDates(_ format: ExportFormat) async throws {
        let note = try add(Self.everything, files: [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))])
        let report = await run(try selection([note]), ExportSettings(format: format, keepTags: true))
        #expect(report.errors == [])
        #expect(report.exported == 1)
        #expect(report.skippedLocked == 0)
        #expect(report.missingAttachments == [])
        #expect(report.destination == out)

        let file = out.appendingPathComponent("Export Me." + format.fileExtension)
        try expectDates(file, note)
        switch format {
        case .markdown:
            #expect(try text(file).contains("**bold words**"))
            #expect(contents(out) == ["Export Me", "Export Me.md"])
            try expectDates(out.appendingPathComponent("Export Me/photo.png"), note)
        case .textBundle:
            #expect(contents(file) == ["assets", "info.json", "text.md"])
            try expectDates(file.appendingPathComponent("text.md"), note)
        case .plainText:
            let plain = try text(file)
            #expect(plain.contains("bold words") && !plain.contains("**"))
        case .html:
            let html = try text(file)
            #expect(html.hasPrefix("<!doctype html>"))
            #expect(html.contains("<strong>bold words</strong>"))
            #expect(html.contains("src=\"Export%20Me/photo.png\""))
            #expect(contents(out) == ["Export Me", "Export Me.html"])
            #expect(contents(out.appendingPathComponent("Export Me")) == ["a.pdf", "photo.png"])
            try expectDates(out.appendingPathComponent("Export Me/photo.png"), note)
        case .pdf:
            let document = try #require(PDFDocument(url: file))
            #expect(document.pageCount >= 1)
            #expect((document.string ?? "").contains("bold words"))
            #expect(contents(out) == ["Export Me.pdf"])
        case .rtf:
            #expect(try text(file).hasPrefix("{\\rtf1"))
            #expect(contents(out) == ["Export Me.rtf"])
        case .docx:
            #expect(Array(try Data(contentsOf: file).prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
            #expect(contents(out) == ["Export Me.docx"])
        }
        // The stage is gone.
        #expect(!contents(out).contains { $0.hasPrefix(".") })
    }

    // MARK: - HTML

    @Test func htmlLinksBetweenNotesAreRelativeAcrossTagFolders() async throws {
        let a = try add("A\n\n#work/a\n\nSee [[B/Head]] and [[A/Mine]]\n\n## Mine\n", 1)
        let b = try add("B\n\n#work/b\n\n# Head\n\nBody.\n", 2)
        let plan = ExportPlan.tagTree(root: "work", notes: try environment.store.exportCandidates(tagTree: "work"))
        #expect(plan.items.count == 2)
        let report = await run(plan, ExportSettings(format: .html, keepTags: true, htmlLinksBetweenNotes: true))
        #expect(report.errors == [])
        #expect(report.exported == 2)
        let pageA = out.appendingPathComponent("work/a/A.html")
        let html = try text(pageA)
        #expect(html.contains("href=\"../b/B.html#h-1\""), "A.html: \(html.components(separatedBy: "<main").last ?? "")")
        #expect(html.contains("href=\"#h-1\""))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("work/b/B.html").path))
        try expectDates(pageA, a)
        try expectDates(out.appendingPathComponent("work/b/B.html"), b)

        // Without the option the links stay text.
        try FileManager.default.removeItem(at: out)
        let plain = await run(plan, ExportSettings(format: .html, keepTags: true))
        #expect(plain.errors == [])
        let plainHTML = try text(pageA)
        #expect(!plainHTML.contains("B.html"))
    }

    @Test func htmlEmbedImagesInlinesImagesOnly() async throws {
        let note = try add(Self.everything, files: [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))])
        let report = await run(try selection([note]), ExportSettings(format: .html, keepTags: true, htmlEmbedImages: true))
        #expect(report.errors == [])
        let html = try text(out.appendingPathComponent("Export Me.html"))
        #expect(html.contains("src=\"data:image/png;base64,"))
        #expect(!html.contains("Export%20Me/photo.png"))
        #expect(html.contains("Export%20Me/a.pdf"))
        #expect(contents(out.appendingPathComponent("Export Me")) == ["a.pdf"])

        // A note whose only attachment is an inlined image needs no folder at all.
        try FileManager.default.removeItem(at: out)
        let only = try add("Only Image\n\n![](photo.png)\n", files: [("photo.png", Self.png)], 5)
        let second = await run(try selection([only]), ExportSettings(format: .html, keepTags: true, htmlEmbedImages: true))
        #expect(second.errors == [])
        #expect(contents(out) == ["Only Image.html"])
    }

    // MARK: - Attachment choices (A9)

    @Test func leavingAttachmentsOutWritesOnlyTheFile() async throws {
        let files = [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))]
        let note = try add(Self.everything, files: files)
        for format in [ExportFormat.markdown, .html] {
            try? FileManager.default.removeItem(at: out)
            let report = await run(
                try selection([note]), ExportSettings(format: format, keepTags: true, includeAttachments: false))
            #expect(report.errors == [], "\(format)")
            #expect(report.missingAttachments == [], "\(format)")
            #expect(contents(out) == ["Export Me." + format.fileExtension], "\(format)")
        }
        try? FileManager.default.removeItem(at: out)
        _ = await run(try selection([note]), ExportSettings(format: .textBundle, keepTags: true, includeAttachments: false))
        #expect(contents(out.appendingPathComponent("Export Me.textbundle")) == ["info.json", "text.md"])
    }

    @Test func markdownCanPutImagesInsideTheFile() async throws {
        let note = try add(Self.everything, files: [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))])
        let report = await run(
            try selection([note]), ExportSettings(format: .markdown, keepTags: true, markdownEmbedImages: true))
        #expect(report.errors == [])
        #expect(try text(out.appendingPathComponent("Export Me.md")).contains("![](data:image/png;base64,"))
        #expect(contents(out.appendingPathComponent("Export Me")) == ["a.pdf"])
    }

    @Test func htmlReportsAMissingAttachmentFile() async throws {
        let note = try add("Gone\n\n[a.pdf](a.pdf)<!-- {\"embed\":\"true\"} -->\n", files: [("a.pdf", Data("%PDF-1.4".utf8))])
        try FileManager.default.removeItem(at: environment.paths.attachments.appendingPathComponent("\(note.id)/a.pdf"))
        let report = await run(try selection([note]), ExportSettings(format: .html, keepTags: true))
        #expect(report.errors == [])
        #expect(report.exported == 1)
        #expect(report.missingAttachments == ["\(note.id)/a.pdf"])
        #expect(contents(out) == ["Gone.html"])
    }

    // MARK: - Attachments left out

    @Test(arguments: [ExportFormat.markdown, .html])
    func anUnrelatedFolderDoesNotBlockAnExportWithoutAttachments(_ format: ExportFormat) async throws {
        let note = try add(Self.everything, files: [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))])
        try FileManager.default.createDirectory(at: out.appendingPathComponent("Export Me"), withIntermediateDirectories: true)
        var settings = ExportSettings(format: format, keepTags: true)
        settings.includeAttachments = false
        let report = await run(try selection([note]), settings)
        #expect(report.errors == [])
        #expect(report.exported == 1)
        #expect(contents(out) == ["Export Me", "Export Me." + format.fileExtension])
        // With attachments the folder would be ours to write, so it still blocks.
        try FileManager.default.removeItem(at: out.appendingPathComponent("Export Me." + format.fileExtension))
        let blocked = await run(try selection([note]), ExportSettings(format: format, keepTags: true))
        #expect(blocked.exported == 0 && blocked.errors.count == 1)
    }

    @Test func htmlWithoutAttachmentsDoesNotMarkPresentFilesAsMissing() async throws {
        let note = try add(Self.everything, files: [("photo.png", Self.png), ("a.pdf", Data("%PDF-1.4".utf8))])
        var settings = ExportSettings(format: .html, keepTags: true)
        settings.includeAttachments = false
        let report = await run(try selection([note]), settings)
        #expect(report.errors == [])
        let html = try text(out.appendingPathComponent("Export Me.html"))
        // The page's stylesheet names the class; only a card carrying it is wrong.
        #expect(html.range(of: #"class="bc-file[^"]*">"#, options: .regularExpression) != nil && html.contains("a.pdf"))
        #expect(html.range(of: #"class="[^"]*bc-missing"#, options: .regularExpression) == nil)
        #expect(contents(out) == ["Export Me.html"])
    }

    // MARK: - RTF

    @Test func rtfHasBoldAndAListAndNoImageData() async throws {
        let note = try add(
            "Rich\n\nSome **bold** text.\n\n- apples\n- pears\n\n![](photo.jpg)\n", files: [("photo.jpg", Self.png)])
        let report = await run(try selection([note]), ExportSettings(format: .rtf, keepTags: true))
        #expect(report.errors == [])
        let rtf = try text(out.appendingPathComponent("Rich.rtf"))
        #expect(rtf.hasPrefix("{\\rtf1"))
        #expect(rtf.range(of: "\\\\b(?![a-z0-9])", options: .regularExpression) != nil, "no \\b in the RTF")
        #expect(rtf.contains("\\listtable") && rtf.contains("\\listtext"))
        #expect(rtf.contains("apples") && rtf.contains("pears"))
        #expect(rtf.contains("[photo.jpg]"))
        #expect(!rtf.contains("\\pict") && !rtf.contains("\\NeXTGraphic") && !rtf.contains("89504e47"))
    }

    @Test func richTextBuildsFromAFragment() throws {
        let rtf = try RichText.rtfData(fromFragment: "<p><b>Hi</b> <i>there</i></p>")
        #expect(String(decoding: rtf, as: UTF8.self).hasPrefix("{\\rtf1"))
        let attributed = try RichText.attributed(fromFragment: "<p>Caf\u{e9} \u{2611}</p>")
        #expect(attributed.string.contains("Caf\u{e9} \u{2611}"))
    }

    // MARK: - Locked, failing, cancelled

    private func lock(_ note: Note) throws {
        try environment.database.pool.write { db in
            try db.execute(
                sql: "UPDATE note SET isLocked = 1, text = '', encryptedPayload = x'0102' WHERE id = ?", arguments: [note.id])
        }
    }

    @Test(arguments: [ExportFormat.markdown, .html, .pdf, .rtf, .docx])
    func lockedNotesAreSkippedAndCounted(_ format: ExportFormat) async throws {
        let open = try add("Open Note\n\nVisible.\n", 1)
        let locked = try add("Secret Note\n\nHidden.\n", 2)
        try lock(locked)
        let plan = try selection([open, locked])
        #expect(plan.skippedLocked == [locked.id])
        let report = await run(plan, ExportSettings(format: format, keepTags: true))
        #expect(report.errors == [])
        #expect(report.exported == 1)
        #expect(report.skippedLocked == 1)
        #expect(contents(out) == ["Open Note." + format.fileExtension])

        // A locked note that reaches the job anyway (a stale plan) is refused, not exported.
        try FileManager.default.removeItem(at: out)
        let stale = ExportPlan.Result(items: [ExportItem(noteId: locked.id, folder: [], stem: "Secret Note")])
        let refused = await run(stale, ExportSettings(format: format, keepTags: true))
        #expect(refused.exported == 0)
        #expect(refused.errors == [])
        #expect(refused.skippedLocked == 1)
        #expect(contents(out).isEmpty)
    }

    @Test(arguments: [ExportFormat.markdown, .html, .rtf, .docx])
    func aNoteLockedAfterPlanningIsSkippedAndCountedNotAnError(_ format: ExportFormat) async throws {
        let one = try add("First\n\nVisible.\n", 1)
        let two = try add("Second\n\nSoon locked.\n", 2)
        let three = try add("Third\n\nVisible too.\n", 3)
        let plan = try selection([one, two, three])
        try lock(two)
        let report = await run(plan, ExportSettings(format: format, keepTags: true))
        #expect(report.errors == [])
        #expect(report.exported == 2)
        #expect(report.skippedLocked == 1)
        #expect(contents(out) == ["First." + format.fileExtension, "Third." + format.fileExtension].sorted())
    }

    @Test(arguments: ExportFormat.allCases)
    func oneFailingNoteDoesNotStopTheRun(_ format: ExportFormat) async throws {
        let one = try add("One\n\nFirst.\n", 1)
        let two = try add("Two\n\nSecond.\n", 2)
        let three = try add("Three\n\nThird.\n", 3)
        var plan = try selection([one, two, three])
        // A note id that is not in the library, between two good ones.
        plan.items.insert(ExportItem(noteId: "no-such-note", folder: [], stem: "Ghost"), at: 1)
        // Two already exists in the destination and is never replaced.
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let existing = out.appendingPathComponent("Two." + format.fileExtension, isDirectory: format == .textBundle)
        if format == .textBundle {
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        } else {
            try Data("mine".utf8).write(to: existing)
        }
        var seen: [(Int, Int)] = []
        let report = await run(plan, ExportSettings(format: format, keepTags: true), progress: { seen.append(($0, $1)) })
        #expect(report.exported == 2)
        #expect(report.errors.count == 2)
        #expect(report.errors.contains { $0.hasPrefix("Ghost: ") })
        #expect(report.errors.contains { $0 == "Two: 'Two.\(format.fileExtension)' already exists" })
        #expect(report.errors.allSatisfy { !$0.contains("Second") })
        let names = contents(out)
        #expect(names.contains("One." + format.fileExtension))
        #expect(names.contains("Three." + format.fileExtension))
        if format != .textBundle { #expect(try text(existing) == "mine") }
        #expect(!names.contains { $0.hasPrefix(".") })
        #expect(seen.first! == (0, 4) && seen.last! == (4, 4))
    }

    @Test(arguments: [ExportFormat.markdown, .html, .pdf])
    func cancelStopsBetweenNotes(_ format: ExportFormat) async throws {
        let notes = try (1...3).map { try add("Note \($0)\n\nBody \($0).\n", Double($0)) }
        var cancelNow = false
        var finished: [Int] = []
        let report = await run(try selection(notes), ExportSettings(format: format, keepTags: true), isCancelled: { cancelNow }, progress: { done, _ in
            finished.append(done)
            if done == 1 { cancelNow = true }
        })
        // Only the first note was built; the run was cancelled before the second, and a cancelled
        // run leaves nothing in the destination, not even the stage.
        #expect(finished == [0, 1])
        #expect(report.exported == 0)
        #expect(report.errors == [])
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test(arguments: [ExportFormat.markdown, .rtf])
    func cancelDuringPlacementTakesBackTheItemsAlreadyPlaced(_ format: ExportFormat) async throws {
        try add("Note 1\n\n#work/a\n\nBody.\n", 1)
        try add("Note 2\n\n#work/b\n\nBody.\n", 2)
        try add("Note 3\n\n#work/b\n\nBody.\n", 3)
        let plan = ExportPlan.tagTree(root: "work", notes: try environment.store.exportCandidates(tagTree: "work"))
        #expect(plan.items.count == 3)
        // Items are built in the stage first; the first file appearing under `out` means the
        // placement has begun. The run is cancelled then, before the next item is placed.
        let firstPlaced = { () -> Bool in
            let work = self.out.appendingPathComponent("work")
            return ((try? FileManager.default.subpathsOfDirectory(atPath: work.path)) ?? [])
                .contains { $0.hasSuffix("." + format.fileExtension) && !$0.contains(".baerchen-export") }
        }
        let report = await run(plan, ExportSettings(format: format, keepTags: true), isCancelled: firstPlaced)
        #expect(report.exported == 0)
        #expect(report.missingAttachments == [])
        #expect(report.errors == [])
        // Nothing from the run remains: no file, no tag folder, not even the destination it created.
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test(arguments: [ExportFormat.markdown, .html])
    func tagFoldersTheRunCreatesGetTheOldestCreatedAndNewestModifiedDate(_ format: ExportFormat) async throws {
        let a = try add("A\n\n#work/a\n\nBody.\n", 10)
        let b = try add("B\n\n#work/b/deep\n\nBody.\n", 5)
        let c = try add("C\n\n#work/b\n\nBody.\n", 20)
        let plan = ExportPlan.tagTree(root: "work", notes: try environment.store.exportCandidates(tagTree: "work"))
        let report = await run(plan, ExportSettings(format: format, keepTags: true))
        #expect(report.errors == [])
        #expect(report.exported == 3)

        let folderA = try dates(out.appendingPathComponent("work/a"))
        #expect(abs(folderA.created.timeIntervalSince(a.createdAt)) < 0.002)
        #expect(abs(folderA.modified.timeIntervalSince(a.modifiedAt)) < 0.002)
        let deep = try dates(out.appendingPathComponent("work/b/deep"))
        #expect(abs(deep.created.timeIntervalSince(b.createdAt)) < 0.002)
        #expect(abs(deep.modified.timeIntervalSince(b.modifiedAt)) < 0.002)
        let folderB = try dates(out.appendingPathComponent("work/b"))
        #expect(abs(folderB.created.timeIntervalSince(b.createdAt)) < 0.002)
        #expect(abs(folderB.modified.timeIntervalSince(c.modifiedAt)) < 0.002)
        // `work` was created by the run: the oldest createdAt (B) and the newest modifiedAt (C) below it.
        let work = try dates(out.appendingPathComponent("work"))
        #expect(abs(work.created.timeIntervalSince(b.createdAt)) < 0.002)
        #expect(abs(work.modified.timeIntervalSince(c.modifiedAt)) < 0.002)
    }

    @Test func aFolderThatWasAlreadyThereIsNotRedated() async throws {
        let a = try add("A\n\n#work/a\n\nBody.\n", 10)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let existing = out.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.creationDate = old
        var existingURL = existing
        try existingURL.setResourceValues(values)
        let plan = ExportPlan.tagTree(root: "work", notes: try environment.store.exportCandidates(tagTree: "work"))
        let report = await run(plan, ExportSettings(format: .markdown, keepTags: true))
        #expect(report.errors == [])
        #expect(abs(try dates(existing).created.timeIntervalSince(old)) < 0.002)
        #expect(abs(try dates(existing.appendingPathComponent("a")).created.timeIntervalSince(a.createdAt)) < 0.002)
    }

    @Test func aCancelledRunKeepsWhatWasAlreadyThere() async throws {
        let notes = try (1...2).map { try add("Keep \($0)\n\nBody.\n", Double($0)) }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: out.appendingPathComponent("old.txt"))
        let report = await run(try selection(notes), ExportSettings(format: .rtf, keepTags: true), isCancelled: { true })
        #expect(report.exported == 0)
        #expect(contents(out) == ["old.txt"])
    }

    @Test func aLinkedFolderInTheWayIsRefusedAndNothingIsWrittenThroughIt() async throws {
        try add("Linked\n\n#work/a\n\nBody.\n")
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("work"), withDestinationURL: elsewhere)
        let plan = ExportPlan.tagTree(root: "work", notes: try environment.store.exportCandidates(tagTree: "work"))
        let report = await run(plan, ExportSettings(format: .html, keepTags: true))
        #expect(report.exported == 0)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.hasPrefix("Linked: ") == true)
        #expect(contents(elsewhere).isEmpty)
        #expect(contents(out) == ["work"])
    }

    @Test func aNoteUnderTwoTagsIsWrittenIntoBothFoldersAndLinksToTheNearerCopy() async throws {
        try add("Hub\n\n#a/x #a/y\n\nSee [[Other]]\n", 1)
        try add("Other\n\n#a/y\n\nSee [[Hub]]\n", 2)
        let plan = ExportPlan.tagTree(root: "a", notes: try environment.store.exportCandidates(tagTree: "a"))
        let report = await run(plan, ExportSettings(format: .html, keepTags: true, htmlLinksBetweenNotes: true))
        #expect(report.errors == [])
        #expect(report.exported == 3)
        // Other links to the Hub copy in its own folder; Hub in a/x reaches Other through a/y.
        #expect(try text(out.appendingPathComponent("a/y/Other.html")).contains("href=\"Hub.html\""))
        #expect(try text(out.appendingPathComponent("a/y/Hub.html")).contains("href=\"Other.html\""))
        #expect(try text(out.appendingPathComponent("a/x/Hub.html")).contains("href=\"../y/Other.html\""))
    }

    @Test func keepTagsOffDropsTagsInRendererFormats() async throws {
        let note = try add("Tagged\n\nBody #secrettag here\n")
        let kept = await run(try selection([note]), ExportSettings(format: .html, keepTags: true))
        #expect(kept.errors == [])
        #expect(try text(out.appendingPathComponent("Tagged.html")).contains("secrettag"))
        try FileManager.default.removeItem(at: out)
        let dropped = await run(try selection([note]), ExportSettings(format: .html, keepTags: false))
        #expect(dropped.errors == [])
        #expect(!(try text(out.appendingPathComponent("Tagged.html"))).contains("secrettag"))
    }

    @Test func formatsHaveTitlesAndExtensions() {
        #expect(ExportFormat.allCases.map(\.title) == ["Markdown", "TextBundle", "HTML", "PDF", "Rich Text (RTF)", "Plain Text", "Word (DOCX)"])
        #expect(ExportFormat.allCases.map(\.fileExtension) == ["md", "textbundle", "html", "pdf", "rtf", "txt", "docx"])
        #expect(ExportFormat.allCases.map(\.id) == ExportFormat.allCases.map(\.rawValue))
    }
}
