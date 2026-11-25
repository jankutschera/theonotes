// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Notion export trees are synthetic (`Fixtures/import/notion`); the tests zip them at runtime.
@Suite struct NotionImporterTests {
    let tmp: TempPaths
    let scratch: Scratch
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400)

    init() throws {
        tmp = try TempPaths()
        scratch = try Scratch()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/import", isDirectory: true)

    private var notion: URL { Self.fixtures.appendingPathComponent("notion", isDirectory: true) }

    private func importer(budget: NotionImporter.ArchiveBudget = .standard) -> NotionImporter {
        NotionImporter(
            store: store, paths: tmp.paths, now: { [now] in now }, temporaryDirectory: scratch.temp, budget: budget)
    }

    @discardableResult
    private func run(
        _ url: URL, _ options: FileImportOptions = FileImportOptions(),
        budget: NotionImporter.ArchiveBudget = .standard,
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try importer(budget: budget).importFile(url, options: options, progress: progress, isCancelled: isCancelled)
    }

    private func zip(_ tree: URL, _ entries: [String], to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-q", "-r", "-X", archive.path] + entries
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func markdownZip() throws -> URL {
        let archive = scratch.url.appendingPathComponent("Export-markdown.zip")
        try zip(notion.appendingPathComponent("markdown-export"), ["Private & Shared"], to: archive)
        return archive
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
    }

    private func note(titled title: String) throws -> Note {
        try #require(try allNotes().first { $0.title == title })
    }

    private func tags(_ note: Note) -> [String] { NoteParser.metadata(for: note.text).tags }

    private func attachmentNames(_ note: Note) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private let allTitles = [
        "Book One", "Kickoff Plan", "Meeting Notes", "Meeting Notes (2)", "Project Hub", "Reading List",
        "Risks and Mitigations",
    ]

    // MARK: - Pages and titles

    @Test func testPageIdsAreStrippedFromTitles() throws {
        let report = try run(try markdownZip())

        #expect(report.errors.isEmpty)
        #expect(report.created == 7)
        #expect(try allNotes().map(\.title).sorted() == allTitles)
        let hub = try note(titled: "Project Hub")
        #expect(hub.text.hasPrefix("# Project Hub\n"))
        let hex = try Regex("[0-9a-f]{32}")
        #expect(!hub.text.contains(hex))
    }

    @Test func testAFolderImportsLikeItsZip() throws {
        let report = try run(notion.appendingPathComponent("markdown-export"))

        #expect(report.errors.isEmpty)
        #expect(try allNotes().map(\.title).sorted() == allTitles)
    }

    @Test func testAPageWithoutAHeadingGetsItsNameAsTitle() throws {
        let id = String(repeating: "d", count: 30) + "01"
        let tree = try scratch.dir("flat")
        try scratch.write("flat/Loose Page \(id).md", "Just a paragraph.\n")
        try scratch.write("flat/Second Page \(String(repeating: "d", count: 30) + "02").md", "# Second Page\n\nBody\n")

        let report = try run(tree)

        #expect(report.errors.isEmpty)
        let loose = try note(titled: "Loose Page")
        #expect(loose.text.hasPrefix("# Loose Page\n\nJust a paragraph."))
    }

    @Test func testDatesFollowTheFilesUnlessTurnedOff() throws {
        let id = String(repeating: "d", count: 30) + "01"
        let file = try scratch.write("flat/Dated \(id).md", "# Dated\n")
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        try run(scratch.url.appendingPathComponent("flat"))
        let kept = try note(titled: "Dated")
        #expect(abs(kept.modifiedAt.timeIntervalSince(modified)) < 1)

        let other = try Scratch()
        let again = try other.write("flat/Dated \(id).md", "# Dated\n")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: again.path)
        try importer().importFile(
            other.url.appendingPathComponent("flat"), options: FileImportOptions(keepDates: false))
        let stamped = try allNotes().last
        #expect(abs((stamped?.modifiedAt.timeIntervalSince(now)) ?? 1e9) < 1)
    }

    // MARK: - Hierarchy tags

    @Test func testParentPagesBecomeNestedTags() throws {
        try run(try markdownZip())

        #expect(tags(try note(titled: "Project Hub")) == ["notion"])
        #expect(tags(try note(titled: "Kickoff Plan")) == ["notion/Project Hub"])
        #expect(tags(try note(titled: "Risks and Mitigations")) == ["notion/Project Hub/Kickoff Plan"])
        #expect(tags(try note(titled: "Book One")) == ["notion/Reading List"])
        #expect(try note(titled: "Risks and Mitigations").text.hasSuffix("#notion/Project Hub/Kickoff Plan#"))
        #expect(try note(titled: "Project Hub").text.hasSuffix("\n\n#notion"))
    }

    @Test func testTagSegmentsAreMadeSafe() throws {
        let tree = try scratch.dir("odd")
        let parent = "Plan | Team #1 " + String(repeating: "e", count: 30) + "01"
        try scratch.write("odd/\(parent).md", "# Plan\n")
        try scratch.write("odd/\(parent)/Child " + String(repeating: "e", count: 30) + "02.md", "# Child\n\nText\n")

        let report = try run(tree)

        #expect(report.errors.isEmpty)
        #expect(tags(try note(titled: "Child")) == ["notion/Plan Team 1"])
    }

    // MARK: - Links

    @Test func testPageLinksBecomeWikiLinks() throws {
        let report = try run(try markdownZip())

        let hub = try note(titled: "Project Hub").text
        #expect(hub.contains("Start with [[Kickoff Plan]] and the [[Reading List]]."))
        #expect(hub.contains("- [ ] Draft the schedule\n- [x] Book the room"))
        let kickoff = try note(titled: "Kickoff Plan").text
        #expect(kickoff.contains("Back to [[Project Hub]]. Risks are written up in [[Risks and Mitigations]]."))
        #expect(kickoff.contains("[guide](https://example.com/guide)"))
        // A link into a page that was not exported stays as it was, and is reported once.
        #expect(kickoff.contains("[Gone](Gone%20" + String(repeating: "f", count: 32) + ".md)"))
        #expect(report.warnings.contains { $0.contains("Kickoff Plan") && $0.contains("1 link") })
        // Code stays literal.
        #expect(kickoff.contains("[Project Hub](../Project%20Hub%20" + String(repeating: "a", count: 30) + "01.md) stays literal"))
    }

    @Test func testPagesWithTheSameNameResolveLinksById() throws {
        try run(try markdownZip())

        let hub = try note(titled: "Project Hub").text
        #expect(hub.contains("Standups live in [[Meeting Notes]]; the project ones are in [[Meeting Notes (2)]]."))
        #expect(try note(titled: "Meeting Notes").text.contains("Standup agenda."))
        let second = try note(titled: "Meeting Notes (2)").text
        #expect(second.hasPrefix("# Meeting Notes (2)\n"))
        #expect(second.contains("Kickoff retro."))
    }

    // MARK: - Attachments

    @Test func testRelativeImagesBecomeAttachments() throws {
        let report = try run(try markdownZip())

        let kickoff = try note(titled: "Kickoff Plan")
        #expect(kickoff.text.contains("![Whiteboard sketch](whiteboard.png)"))
        #expect(attachmentNames(kickoff) == ["whiteboard.png"])
        #expect(report.attachmentsCopied == 1)
    }

    // MARK: - Databases

    @Test func testADatabaseCsvBecomesATableNote() throws {
        try run(try markdownZip())

        let list = try note(titled: "Reading List").text
        #expect(list.hasPrefix("# Reading List\n\n| Name | Author | Status | Notes |\n| --- | --- | --- | --- |\n"))
        #expect(list.contains("| [[Book One]] | Ada Example | Reading | Great, but long |"))
        #expect(list.contains("| Book Two | Sam Sample | Todo | line one<br>line two |"))
        #expect(tags(try note(titled: "Reading List")) == ["notion"])
    }

    // MARK: - Parts

    private func partsArchive() throws -> URL {
        let parts = notion.appendingPathComponent("parts")
        let outer = try scratch.dir("outer")
        try zip(parts.appendingPathComponent("Part-1"), ["."], to: outer.appendingPathComponent("Export-ccc-Part-1.zip"))
        try zip(parts.appendingPathComponent("Part-2"), ["."], to: outer.appendingPathComponent("Export-ccc-Part-2.zip"))
        let archive = scratch.url.appendingPathComponent("Export-ccc.zip")
        try zip(outer, ["Export-ccc-Part-1.zip", "Export-ccc-Part-2.zip"], to: archive)
        return archive
    }

    @Test func testNestedPartArchivesAreAllImported() throws {
        let report = try run(try partsArchive())

        #expect(report.errors.isEmpty)
        #expect(report.created == 4)
        #expect(try allNotes().map(\.title).sorted() == ["Alpha", "Beta", "Gamma", "Workspace"])
        // Links and parents are found across the parts.
        #expect(try note(titled: "Beta").text.contains("Back to [[Workspace]] in the other part."))
        #expect(try note(titled: "Workspace").text.contains("See [[Beta]] and [[Alpha]]."))
        #expect(tags(try note(titled: "Gamma")) == ["notion/Workspace"])
        #expect(tags(try note(titled: "Alpha")) == ["notion/Workspace"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func testPartArchivesInsideAFolderAreImportedToo() throws {
        let archive = try partsArchive()
        let folder = try scratch.dir("unpacked")
        try FileManager.default.copyItem(at: archive, to: folder.appendingPathComponent("Export-ccc.zip"))

        let report = try run(folder)

        #expect(report.created == 4)
    }

    // MARK: - HTML

    @Test func testAnHtmlExportImportsThroughTheSameRules() throws {
        let archive = scratch.url.appendingPathComponent("Export-html.zip")
        try zip(notion.appendingPathComponent("html-export"), ["."], to: archive)

        let report = try run(archive)

        #expect(report.errors.isEmpty)
        #expect(report.created == 2)
        let handbook = try note(titled: "Handbook")
        #expect(handbook.text.hasPrefix("# Handbook\n"))
        #expect(handbook.text.contains("[[Onboarding]]"))
        #expect(handbook.text.contains("**bold**"))
        #expect(handbook.text.contains("https://example.com/"))
        let onboarding = try note(titled: "Onboarding")
        #expect(onboarding.text.contains("[[Handbook]]"))
        #expect(onboarding.text.contains("](chart.png)"))
        #expect(attachmentNames(onboarding) == ["chart.png"])
        #expect(tags(onboarding) == ["notion/Handbook"])
        #expect(tags(handbook) == ["notion"])
    }

    // MARK: - Cancelling and failing

    @Test func testCancellingStopsBetweenNotes() throws {
        var done = 0
        let report = try run(
            try markdownZip(), progress: { finished, _ in done = finished }, isCancelled: { done >= 2 })

        #expect(report.wasCancelled)
        #expect(report.created == 2)
        #expect(try allNotes().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func testABrokenArchiveIsReportedNotThrown() throws {
        let bad = try scratch.write("broken.zip", "this is not a zip file")

        let report = try run(bad)

        #expect(report.created == 0)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].hasPrefix("broken.zip"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func testAMissingPathIsReported() throws {
        let report = try run(scratch.url.appendingPathComponent("nowhere.zip"))

        #expect(report.created == 0)
        #expect(report.errors == ["nowhere.zip: not found"])
    }

    @Test func testSymbolicLinksInAFolderAreNeverFollowed() throws {
        let secret = try scratch.write("outside/secret.md", "# Secret\n\nTOPSECRETKEY\n")
        let tree = try scratch.dir("linked")
        let id = String(repeating: "9", count: 32)
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("Evil \(id).md"), withDestinationURL: secret)
        try scratch.write("linked/Fine \(String(repeating: "8", count: 32)).md", "# Fine\n\n![](leak.png)\n")
        try FileManager.default.createSymbolicLink(
            at: tree.appendingPathComponent("leak.png"), withDestinationURL: secret)

        let report = try run(tree)

        #expect(report.created == 1)
        let titles = try allNotes().map(\.title)
        #expect(titles == ["Fine"])
        let fine = try note(titled: "Fine")
        #expect(attachmentNames(fine).isEmpty)
        #expect(!fine.text.contains("TOPSECRETKEY"))
    }

    // MARK: - Fix round 1

    @Test func testATitleWithHashWordDoesNotCreateATag() throws {
        let id1 = String(repeating: "7", count: 32), id2 = String(repeating: "6", count: 32)
        let tree = try scratch.dir("hash")
        try scratch.write("hash/Plan #word \(id1).md", "# Plan #word\n\nBody\n")
        try scratch.write("hash/Linker \(id2).md", "# Linker\n\nSee [Plan](Plan%20%23word%20\(id1).md).\n")

        let report = try run(tree)

        #expect(report.errors.isEmpty)
        let plan = try note(titled: "Plan #word")
        #expect(tags(plan) == ["notion"])
        #expect(try note(titled: "Linker").text.contains("See [[Plan #word]]."))
        let linker = try note(titled: "Linker")
        #expect(tags(linker) == ["notion"])
    }

    /// Three parts of about 4 KB each fit the per-archive limits; together they exceed the run budget.
    @Test func testPartArchivesShareOneRunBudget() throws {
        let outer = try scratch.dir("budget-outer")
        for part in 1...3 {
            let id = String(repeating: "\(part)", count: 32)
            try scratch.write(
                "budget-src\(part)/Page \(part) \(id).md",
                "# Page \(part)\n\n" + String(repeating: "word ", count: 800) + "\n")
            try zip(scratch.url.appendingPathComponent("budget-src\(part)"), ["."],
                    to: outer.appendingPathComponent("Export-b-Part-\(part).zip"))
        }
        let archive = scratch.url.appendingPathComponent("Export-b.zip")
        try zip(outer, ["Export-b-Part-1.zip", "Export-b-Part-2.zip", "Export-b-Part-3.zip"], to: archive)

        let unlimited = try run(archive)
        #expect(unlimited.created == 3)

        let limited = try run(archive, budget: .init(bytes: 6_000, entries: 1_000, files: 1_000))
        #expect(limited.errors.isEmpty)
        #expect(limited.created >= 1)
        #expect(limited.created < 3)
        #expect(limited.warnings.contains { $0.contains("budget") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.temp.path).isEmpty)
    }

    @Test func testUnclosedAnchorsDoNotStallTheLinkScan() throws {
        // About 1 MB of opening tags with no `</a` anywhere, then the same with one far closing tag
        // and many opening tags that link a page.
        let opening = String(repeating: "<a href=\"x\">", count: 90_000)
        var missing = 0
        var start = Date()
        let plain = NotionImporter.replacingAnchors(
            in: "<p>start</p>" + opening, resolve: { _ in nil }, isMissingPage: { _ in false }, missing: &missing)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(plain == "<p>start</p>" + opening)

        let linking = String(repeating: "<a href=\"p.html\">", count: 90_000)
        start = Date()
        let linked = NotionImporter.replacingAnchors(
            in: linking + "</a>tail", resolve: { _ in 0 }, isMissingPage: { _ in false }, missing: &missing)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(linked.hasSuffix("tail"))
        let unclosed = NotionImporter.replacingAnchors(
            in: linking, resolve: { _ in 0 }, isMissingPage: { _ in false }, missing: &missing)
        #expect(unclosed == linking)
    }

    @Test func testAnAnchorIsFoundWhateverTheAttributeOrder() throws {
        var missing = 0
        let html = "x <A class=\"c\" HREF='Page%20a.html' id=1>Text <b>bold</b></A> y <a name=\"n\">no link</a> <a href=\"gone.html\">g</a>"
        let out = NotionImporter.replacingAnchors(
            in: html, resolve: { $0 == "Page%20a.html" ? 3 : nil }, isMissingPage: { $0.hasSuffix(".html") },
            missing: &missing)
        #expect(out == "x \u{E000}3\u{E001} y <a name=\"n\">no link</a> <a href=\"gone.html\">g</a>")
        #expect(missing == 1)
    }

    // MARK: - Recognising an export

    // MARK: - Fix round 2

    @Test func testTheFileBudgetStopsTheWalkInsideAFolder() throws {
        let tree = try scratch.dir("many")
        for n in 1...15 {
            let number = String(format: "%02d", n)
            let id = String(repeating: "4", count: 30) + number
            try scratch.write("many/Page \(number) \(id).md", "# Page \(number)\n\nBody\n")
        }

        let report = try run(tree, budget: .init(bytes: 1 << 30, entries: 1_000, files: 10))

        #expect(report.created == 10)
        #expect(report.warnings.contains { $0.contains("file budget") })
        #expect(report.errors.isEmpty)
    }

    @Test func testTheFileBudgetCountsFilesAcrossParts() throws {
        let outer = try scratch.dir("fb-outer")
        for n in 1...15 {
            let number = String(format: "%02d", n)
            let id = String(repeating: "3", count: 30) + number
            try scratch.write("fb-src/Item \(number) \(id).md", "# Item \(number)\n")
        }
        try zip(scratch.url.appendingPathComponent("fb-src"), ["."], to: outer.appendingPathComponent("Export-f-Part-1.zip"))
        let archive = scratch.url.appendingPathComponent("Export-f.zip")
        try zip(outer, ["Export-f-Part-1.zip"], to: archive)

        // The outer folder holds one file (the part), leaving 9 for the 15 pages of the part.
        let report = try run(archive, budget: .init(bytes: 1 << 30, entries: 1_000, files: 10))

        #expect(report.created == 9)
        #expect(report.warnings.contains { $0.contains("file budget") })
    }

    @Test(arguments: [
        "<a href = \"P.html\">t</a>", "<a href\n=\n'P.html'>t</a>", "<a\thref\t=\t\"P.html\"\tid=1>t</a>",
        "<a href= P.html>t</a>", "<a href =P.html >t</a>", "<a id=1 href=P.html>t</a>", "<a href=P.html>t</a>",
        "<A  HREF  =  'P.html'  >t</A>",
    ])
    func testAnchorsAcceptWhitespaceAroundTheEqualsSign(_ html: String) throws {
        var missing = 0
        var seen: [String] = []
        let out = NotionImporter.replacingAnchors(
            in: "x " + html + " y", resolve: { seen.append($0); return $0 == "P.html" ? 4 : nil },
            isMissingPage: { _ in false }, missing: &missing)
        #expect(seen == ["P.html"])
        #expect(out == "x \u{E000}4\u{E001} y")
    }

    @Test func testOtherAttributesAreNotTakenForHref() throws {
        var missing = 0
        let html = "<a data-href=\"P.html\" title = \"href\">t</a><a nohref = \"P.html\">u</a>"
        let out = NotionImporter.replacingAnchors(
            in: html, resolve: { _ in 4 }, isMissingPage: { _ in false }, missing: &missing)
        #expect(out == html)
    }

    @Test func testLooksLikeNotionExport() throws {
        #expect(NotionImporter.looksLikeNotionExport(try markdownZip()))
        #expect(NotionImporter.looksLikeNotionExport(notion.appendingPathComponent("markdown-export")))
        #expect(NotionImporter.looksLikeNotionExport(notion.appendingPathComponent("html-export")))
        #expect(NotionImporter.looksLikeNotionExport(try partsArchive()))
    }

    @Test func testOtherFoldersAndArchivesAreNotNotionExports() throws {
        let plain = Self.fixtures.appendingPathComponent("markdown-folder")
        #expect(!NotionImporter.looksLikeNotionExport(plain))
        let archive = scratch.url.appendingPathComponent("plain.zip")
        try zip(plain, ["."], to: archive)
        #expect(!NotionImporter.looksLikeNotionExport(archive))
        #expect(!NotionImporter.looksLikeNotionExport(try scratch.write("broken.zip", "nope")))
        #expect(!NotionImporter.looksLikeNotionExport(scratch.url.appendingPathComponent("missing")))
    }
}

// MARK: - Attachment size caps (IMP-R61)

extension NotionImporterTests {
    private var pageId: String { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa01" }

    private func limitedRun(
        _ url: URL, limits: AppleNotesExportImporter.Limits = .standard
    ) throws -> FileImportReport {
        try NotionImporter(
            store: store, paths: tmp.paths, now: { [now] in now }, temporaryDirectory: scratch.temp,
            budget: .standard, attachmentLimits: limits
        ).importFile(url, options: FileImportOptions(), progress: { _, _ in }, isCancelled: { false })
    }

    /// A file of `megabytes` MB that takes no disk space (a hole).
    @discardableResult
    private func writeSparse(_ relative: String, megabytes: Int) throws -> URL {
        let url = try scratch.write(relative, Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) << 20)
        try handle.close()
        return url
    }

    @Test func aHugeLinkedFileIsNotReadAndThePageStillImports() throws {
        try scratch.write("export/Big \(pageId).md", "# Big\n\n[huge](huge.pdf)\n\n![](ok.bin)\n")
        try writeSparse("export/huge.pdf", megabytes: 129)
        try scratch.write("export/ok.bin", Data(count: 1024))

        let report = try limitedRun(scratch.url.appendingPathComponent("export"))

        #expect(report.created == 1)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.contains { $0.contains("huge.pdf") && $0.contains("larger than 128 MB") })
        let big = try note(titled: "Big")
        #expect(attachmentNames(big) == ["ok.bin"])
        #expect(big.text.contains("](huge.pdf)"), "the link stays as written")
    }

    @Test func aHugeFileInAZippedExportIsNotCopied() throws {
        try scratch.write("src/Big \(pageId).md", "# Big\n\n[huge](huge.pdf)\n")
        try writeSparse("src/huge.pdf", megabytes: 129)
        let archive = scratch.url.appendingPathComponent("Export-big.zip")
        try zip(scratch.url.appendingPathComponent("src"), ["."], to: archive)

        let report = try limitedRun(archive)

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 0)
        #expect(report.warnings.contains { $0.contains("huge.pdf") && $0.contains("larger than 128 MB") })
    }

    @Test func onePagesAttachmentsStopAtThePerNoteBudget() throws {
        try scratch.write("export/Many \(pageId).md", "# Many\n\n[1](1.bin)\n\n[2](2.bin)\n\n[3](3.bin)\n")
        for name in ["1", "2", "3"] { try scratch.write("export/\(name).bin", Data(count: (1 << 20) + Int(name)!)) }

        let report = try limitedRun(
            scratch.url.appendingPathComponent("export"), limits: .init(each: 2 << 20, perNote: 2_500_000, total: 100 << 20))

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.contains { $0.contains("3.bin") && $0.contains("size limit") })
    }

    @Test func theWholeRunStopsCopyingOnceTheTotalBudgetIsUsed() throws {
        for (position, name) in ["a", "b", "c"].enumerated() {
            try scratch.write("export/\(name) \(String(repeating: "\(position)", count: 32)).md", "# \(name)\n\n[f](\(name).bin)\n")
            try scratch.write("export/\(name).bin", Data(count: 1 << 20))
        }

        let report = try limitedRun(
            scratch.url.appendingPathComponent("export"), limits: .init(each: 2 << 20, perNote: 2 << 20, total: (2 << 20) + 10))

        #expect(report.created == 3, "the pages themselves still import")
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.filter { $0.contains("size limit") }.count == 1)
    }
}
