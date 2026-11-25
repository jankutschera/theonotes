// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Scratch directory for import sources and the importer's temp area; removed on deinit.
final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baerchen-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var temp: URL { url.appendingPathComponent("tmp", isDirectory: true) }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL { try write(relative, Data(text.utf8)) }

    func dir(_ relative: String) throws -> URL {
        let dir = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite struct FileImporterTests {
    let tmp: TempPaths
    let scratch: Scratch
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-21T12:00:00Z

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

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    private func importer() -> FileImporter {
        FileImporter(store: store, paths: tmp.paths, now: { [now] in now }, temporaryDirectory: scratch.temp)
    }

    @discardableResult
    private func run(
        _ urls: [URL], _ options: FileImportOptions = FileImportOptions()
    ) throws -> FileImportReport {
        try importer().importItems(urls, options: options, progress: { _, _ in }, isCancelled: { false })
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
    }

    private func note(titled title: String) throws -> Note {
        try #require(try allNotes().first { $0.title == title })
    }

    private func attachmentNames(_ note: Note) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func attachmentData(_ note: Note, _ name: String) throws -> Data {
        try Data(contentsOf: tmp.paths.attachments.appendingPathComponent("\(note.id)/\(name)"))
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func parsedAttachments(_ note: Note) -> [AttachmentRef] {
        NoteParser.metadata(for: note.text).attachments
    }

    // MARK: - Plain files

    @Test func testMarkdownFileKeepsFileDates() throws {
        let file = try scratch.write("Hello.md", "# Hello\n\nBody #tag\n")
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: created, .modificationDate: modified], ofItemAtPath: file.path)

        let report = try run([file])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty)
        let note = try note(titled: "Hello")
        #expect(note.text == "# Hello\n\nBody #tag\n")
        #expect(abs(note.createdAt.timeIntervalSince(created)) < 1)
        #expect(abs(note.modifiedAt.timeIntervalSince(modified)) < 1)
    }

    @Test func testKeepDatesOffUsesNow() throws {
        let file = try scratch.write("Hello.md", "# Hello\n")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_650_000_000)], ofItemAtPath: file.path)

        try run([file], FileImportOptions(keepDates: false))

        let note = try note(titled: "Hello")
        #expect(abs(note.createdAt.timeIntervalSince(now)) < 1)
        #expect(abs(note.modifiedAt.timeIntervalSince(now)) < 1)
    }

    @Test(arguments: [
        ("utf8-bom", Data([0xEF, 0xBB, 0xBF]) + Data("# Grüße 日本\n".utf8)),
        ("utf16le", Data([0xFF, 0xFE]) + "# Grüße 日本\n".data(using: .utf16LittleEndian)!),
        ("utf16be", Data([0xFE, 0xFF]) + "# Grüße 日本\n".data(using: .utf16BigEndian)!),
        ("utf8", Data("# Grüße 日本\n".utf8)),
    ])
    func testUnicodeEncodings(name: String, data: Data) throws {
        let file = try scratch.write("\(name).txt", data)

        let report = try run([file])

        #expect(report.created == 1)
        #expect(report.warnings.isEmpty)
        #expect(try allNotes().first?.text == "# Grüße 日本\n")
    }

    @Test func testWindows1252FallbackWarns() throws {
        // "Café – 5 €" in Windows-1252: é = E9, en dash = 96, euro = 80. Not valid UTF-8.
        let file = try scratch.write("legacy.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x96, 0x20, 0x35, 0x20, 0x80, 0x0A]))

        let report = try run([file])

        #expect(report.created == 1)
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].contains("legacy.txt"))
        #expect(try allNotes().first?.text == "Café – 5 €\n")
    }

    @Test func testCRLFIsNormalized() throws {
        let file = try scratch.write("crlf.md", "# A\r\n\r\nb\r\n")
        try run([file])
        #expect(try allNotes().first?.text == "# A\n\nb\n")
    }

    @Test func testEmptyAndUnsupportedFilesAreSkipped() throws {
        let empty = try scratch.write("empty.md", "  \n\n")
        let pdf = try scratch.write("doc.pdf", "%PDF")

        let report = try run([empty, pdf])

        #expect(report.created == 0)
        #expect(report.skipped == 2)
        #expect(report.warnings.count == 2)
        #expect(try allNotes().isEmpty)
    }

    @Test func testMissingItemIsReportedNotThrown() throws {
        let report = try run([scratch.url.appendingPathComponent("nope.md")])
        #expect(report.created == 0)
        #expect(report.errors.count == 1)
    }

    // MARK: - titleFromFilename

    @Test func testTitleFromFilenameInsertsHeading() throws {
        let file = try scratch.write("Meeting notes.md", "Agenda first\n")
        try run([file], FileImportOptions(titleFromFilename: true))
        #expect(try allNotes().first?.text == "# Meeting notes\n\nAgenda first\n")
    }

    @Test func testTitleFromFilenameKeepsExistingHeading() throws {
        let file = try scratch.write("Meeting notes.md", "# Meeting notes\n\nAgenda\n")
        try run([file], FileImportOptions(titleFromFilename: true))
        #expect(try allNotes().first?.text == "# Meeting notes\n\nAgenda\n")
    }

    @Test func testTitleFromFilenameGoesAfterFrontMatter() throws {
        let file = try scratch.write("Plan.md", "---\nkey: v\n---\nBody\n")
        try run([file], FileImportOptions(titleFromFilename: true))
        #expect(try allNotes().first?.text == "---\nkey: v\n---\n# Plan\n\nBody\n")
    }

    @Test func testTitleOffLeavesTextAlone() throws {
        let file = try scratch.write("Meeting notes.md", "Agenda first\n")
        try run([file])
        #expect(try allNotes().first?.text == "Agenda first\n")
    }

    // MARK: - TextBundle / TextPack / Bear backup

    @Test func testTextBundleFixtureHonorsBearInfo() throws {
        let report = try run([fixture("sample.textbundle")])

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        #expect(report.errors.isEmpty)
        let note = try note(titled: "Sample TextBundle")
        #expect(note.createdAt == date("2024-03-01T10:00:00Z"))
        #expect(note.modifiedAt == date("2024-03-05T12:30:00Z"))
        #expect(note.isPinnedGlobal)
        #expect(!note.isReadOnly)
        #expect(note.location == .notes)
        #expect(note.text.contains("![](photo.png)"))
        #expect(note.text.contains("[Spec sheet](spec%20sheet.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(!note.text.contains("assets/"))
        #expect(attachmentNames(note) == ["photo.png", "spec sheet.pdf"])
        #expect(try attachmentData(note, "photo.png") == Data(contentsOf: fixture("sample.textbundle/assets/photo.png")))
        #expect(parsedAttachments(note).map(\.filename).sorted() == ["photo.png", "spec sheet.pdf"])
    }

    @Test func testTextPackFixture() throws {
        let report = try run([fixture("sample.textpack")])

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        let note = try note(titled: "Sample TextBundle")
        #expect(note.isPinnedGlobal)
        #expect(attachmentNames(note) == ["photo.png", "spec sheet.pdf"])
        #expect(report.warnings.isEmpty)
    }

    @Test func testBear2bkFixtureImportsEveryBundleWithFlags() throws {
        let report = try run([fixture("sample.bear2bk")])

        #expect(report.created == 2)
        #expect(report.errors.isEmpty)
        let alpha = try note(titled: "Alpha note")
        #expect(alpha.location == .notes)
        #expect(alpha.createdAt == date("2023-01-02T08:00:00Z"))
        #expect(attachmentNames(alpha) == ["pic.png"])
        let old = try note(titled: "Old note")
        #expect(old.location == .trash)
        #expect(old.modifiedAt == date("2022-05-07T09:00:00Z"))
        #expect(old.trashedAt == old.modifiedAt)
    }

    @Test func testInfoJSONFlatKeysAndAppleReferenceDates() throws {
        let bundle = try scratch.dir("flat.textbundle")
        try scratch.write("flat.textbundle/text.markdown", "# Flat\n")
        try scratch.write("flat.textbundle/info.json", """
            {"creationDate": 700000000, "modificationDate": 700000500.5, "archived": true, "readOnly": "yes", "pinned": 1}
            """)

        try run([bundle])

        let note = try note(titled: "Flat")
        #expect(note.createdAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(abs(note.modifiedAt.timeIntervalSinceReferenceDate - 700_000_500.5) < 0.01)
        #expect(note.location == .archive)
        #expect(note.isReadOnly)
        #expect(note.isPinnedGlobal)
    }

    @Test func testInfoJSONFractionalISODatesTrashedWinsOverArchived() throws {
        let bundle = try scratch.dir("t.textbundle")
        try scratch.write("t.textbundle/text.md", "# T\n")
        try scratch.write("t.textbundle/info.json", """
            {"net.shinyfrog.bear": {"creationDate": "2024-05-01T10:00:00.250Z", "trashed": 1, "archived": 1, "unknownKey": {"x": 1}}, "other": 5}
            """)

        try run([bundle])

        let note = try note(titled: "T")
        #expect(abs(note.createdAt.timeIntervalSince(date("2024-05-01T10:00:00Z")) - 0.25) < 0.01)
        #expect(note.location == .trash)
    }

    @Test func testBundleWithoutInfoOrWithBrokenInfoStillImports() throws {
        let one = try scratch.dir("a.textbundle")
        try scratch.write("a.textbundle/text.txt", "# A\n")
        let two = try scratch.dir("b.textbundle")
        try scratch.write("b.textbundle/text.md", "# B\n")
        try scratch.write("b.textbundle/info.json", "{not json")

        let report = try run([one, two])

        #expect(report.created == 2)
        #expect(report.errors.isEmpty)
        #expect(try allNotes().count == 2)
    }

    @Test func testBundleWithoutTextFileIsAnError() throws {
        let bundle = try scratch.dir("empty.textbundle")
        try scratch.write("empty.textbundle/info.json", "{}")

        let report = try run([bundle])

        #expect(report.created == 0)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].contains("empty.textbundle"))
    }

    @Test func testAssetCollisionsAreRenamedAndLinksUpdated() throws {
        let bundle = try scratch.dir("c.textbundle")
        try scratch.write("c.textbundle/text.md", """
            # C

            ![](assets/x.jpg)
            ![again](assets/x.jpg)
            ![other](assets/sub/x.jpg)
            ![case](assets/more/X.JPG)

            """)
        try scratch.write("c.textbundle/assets/x.jpg", Data([1]))
        try scratch.write("c.textbundle/assets/sub/x.jpg", Data([2]))
        try scratch.write("c.textbundle/assets/more/X.JPG", Data([3]))

        let report = try run([bundle])

        #expect(report.attachmentsCopied == 3)
        let note = try note(titled: "C")
        #expect(note.text == "# C\n\n![](x.jpg)\n![again](x.jpg)\n![other](x%202.jpg)\n![case](X%203.JPG)\n")
        #expect(attachmentNames(note).count == 3)
        #expect(try attachmentData(note, "x.jpg") == Data([1]))
        #expect(try attachmentData(note, "x 2.jpg") == Data([2]))
        #expect(try attachmentData(note, "X 3.JPG") == Data([3]))
        #expect(parsedAttachments(note).map(\.filename) == ["x.jpg", "x 2.jpg", "X 3.JPG"])
    }

    @Test func testPercentEncodedAndUnicodeNames() throws {
        let bundle = try scratch.dir("p.textbundle")
        try scratch.write("p.textbundle/text.md", "# P\n\n![](assets/my%20photo%20%281%29.png)\n\n[Résumé](assets/R%C3%A9sum%C3%A9.pdf)\n")
        try scratch.write("p.textbundle/assets/my photo (1).png", Data([1]))
        try scratch.write("p.textbundle/assets/Résumé.pdf", Data([2]))

        let report = try run([bundle])

        #expect(report.warnings.isEmpty)
        let note = try note(titled: "P")
        #expect(note.text.contains("![](my%20photo%20%281%29.png)"))
        #expect(note.text.contains("[Résumé](R%C3%A9sum%C3%A9.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(parsedAttachments(note).map(\.filename).sorted() == ["Résumé.pdf", "my photo (1).png"].sorted())
        #expect(try attachmentData(note, "my photo (1).png") == Data([1]))
        #expect(try attachmentData(note, "Résumé.pdf") == Data([2]))
    }

    @Test func testFileLinkMetadataComments() throws {
        let bundle = try scratch.dir("m.textbundle")
        try scratch.write("m.textbundle/text.md", """
            # M

            [Sheet](assets/data.xlsx)
            [Keep](assets/keep.zip) <!-- {"preview":"true"} -->
            ![](assets/pic.png)
            ![pdf as image](assets/doc.pdf)

            """)
        for name in ["data.xlsx", "keep.zip", "pic.png", "doc.pdf"] {
            try scratch.write("m.textbundle/assets/\(name)", Data([1]))
        }

        try run([bundle])

        let note = try note(titled: "M")
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.contains("[Sheet](data.xlsx) <!-- {\"embed\":\"true\"} -->"))
        #expect(lines.contains("[Keep](keep.zip) <!-- {\"preview\":\"true\"} -->"))
        #expect(lines.contains("![](pic.png)"))
        #expect(lines.contains("[pdf as image](doc.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(parsedAttachments(note).count == 4)
    }

    @Test func testLinksInCodeAreNotTouched() throws {
        let bundle = try scratch.dir("k.textbundle")
        let text = "# K\n\n`![](assets/a.png)`\n\n```\n![](assets/a.png)\n[f](assets/a.pdf)\n```\n\nreal ![](assets/a.png)\n"
        try scratch.write("k.textbundle/text.md", text)
        try scratch.write("k.textbundle/assets/a.png", Data([1]))

        let report = try run([bundle])

        #expect(report.attachmentsCopied == 1)
        let note = try note(titled: "K")
        #expect(note.text == "# K\n\n`![](assets/a.png)`\n\n```\n![](assets/a.png)\n[f](assets/a.pdf)\n```\n\nreal ![](a.png)\n")
    }

    @Test func testZipImportsLeaveNoTempDirectory() throws {
        try run([fixture("sample.bear2bk"), fixture("sample.textpack")])
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func testCorruptZipIsReportedNotThrown() throws {
        let bad = try scratch.write("broken.bear2bk", "this is not a zip file")
        let good = try scratch.write("fine.md", "# Fine\n")

        let report = try run([bad, good])

        #expect(report.created == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].contains("broken.bear2bk"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func testSafeZipRefusesACorruptZip() throws {
        let bad = try scratch.write("bad.zip", "nope")
        let out = scratch.url.appendingPathComponent("out")
        #expect(throws: SafeZipError.notAZip) {
            try SafeZip.extract(archive: bad, to: out, limits: .bulkImports)
        }
    }

    @Test func testSafeZipExtractsTheTextPackFixture() throws {
        let out = scratch.url.appendingPathComponent("out")
        try SafeZip.extract(archive: fixture("sample.textpack"), to: out, limits: .bulkImports)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("sample.textbundle/text.md").path))
    }

    // MARK: - Folders

    @Test func testMarkdownFolderFixture() throws {
        let report = try run([fixture("markdown-folder")])

        #expect(report.created == 3)
        #expect(report.errors.isEmpty)
        // Welcome: a.png (via [[..]] embed) and brief.pdf. Plan: a.png + brief.pdf. Notes: b.png.
        #expect(report.attachmentsCopied == 5)

        let welcome = try note(titled: "Welcome")
        #expect(welcome.text.contains("![a.png](a.png)"))
        #expect(welcome.text.contains("[brief.pdf](brief.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(welcome.text.contains("[[Plan]]"))
        #expect(!welcome.text.contains("[["+"a.png"))
        #expect(welcome.text.hasSuffix("\n\n#alpha #two words#"))
        #expect(attachmentNames(welcome) == ["a.png", "brief.pdf"])

        let plan = try note(titled: "Plan")
        #expect(plan.text.contains("![diagram](a.png)"))
        #expect(plan.text.contains("[Brief](brief.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(plan.text.contains("![x](../../outside.png)"))
        #expect(plan.text.contains("![m](nope.png)"))
        #expect(plan.text.contains("[site](https://example.com)"))
        #expect(attachmentNames(plan) == ["a.png", "brief.pdf"])

        let deep = try note(titled: "Deep notes")
        #expect(deep.text.contains("![b](b.png)"))
        #expect(attachmentNames(deep) == ["b.png"])

        let planWarnings = report.warnings.filter { $0.contains("Plan.md") }
        #expect(planWarnings.count == 2)
        #expect(planWarnings.contains { $0.contains("outside.png") && $0.contains("outside") })
        #expect(planWarnings.contains { $0.contains("nope.png") && $0.contains("not found") })
        #expect(!report.warnings.contains { $0.contains(".obsidian") })
    }

    @Test func testFolderSkipsHiddenAndFollowsTextBundlesInside() throws {
        try scratch.write("vault/.hidden/secret.md", "# Secret\n")
        try scratch.write("vault/__MACOSX/._x.md", "junk")
        try scratch.write("vault/top.md", "# Top\n")
        try scratch.write("vault/sub/inner.bundle.textbundle/text.md", "# Inner bundle\n")
        try scratch.write("vault/sub/readme.markdown", "# Readme\n")
        try scratch.write("vault/sub/data.csv", "a,b\n")

        let report = try run([scratch.url.appendingPathComponent("vault")])

        #expect(report.created == 3)
        #expect(report.skipped == 0)
        #expect(Set(try allNotes().map(\.title)) == ["Top", "Inner bundle", "Readme"])
    }

    @Test func testSymlinkOutsideRootIsNotFollowed() throws {
        let outside = try scratch.write("outside/secret.png", Data([9]))
        try scratch.write("vault/n.md", "# N\n\n![](leak.png)\n")
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("vault/leak.png"), withDestinationURL: outside)

        let report = try run([scratch.url.appendingPathComponent("vault")])

        let note = try note(titled: "N")
        #expect(note.text == "# N\n\n![](leak.png)\n")
        #expect(attachmentNames(note).isEmpty)
        #expect(report.attachmentsCopied == 0)
        #expect(report.warnings.contains { $0.contains("leak.png") && $0.contains("outside") })
    }

    @Test func testSingleFileResolvesRelativeLinksInItsFolder() throws {
        try scratch.write("docs/note.md", "# Note\n\n![](pics/a.png)\n")
        try scratch.write("docs/pics/a.png", Data([1]))

        let report = try run([scratch.url.appendingPathComponent("docs/note.md")])

        #expect(report.attachmentsCopied == 1)
        #expect(try note(titled: "Note").text == "# Note\n\n![](a.png)\n")
    }

    @Test func testObsidianTagFormats() throws {
        try scratch.write("v/list.md", "---\ntags:\n  - one\n  - \"two/three\"\n  - '#four'\ntitle: x\n---\nList body\n")
        try scratch.write("v/comma.md", "---\ntags: red, green blue ,#x\n---\nComma body\n")
        try scratch.write("v/single.md", "---\ntag: solo\n---\nSingle body\n")
        try scratch.write("v/none.md", "---\ntitle: nope\n---\nNone body\n")

        try run([scratch.url.appendingPathComponent("v")])

        #expect(try note(titled: "List body").text.hasSuffix("List body\n\n#one #two/three #four"))
        #expect(try note(titled: "Comma body").text.hasSuffix("Comma body\n\n#red #green blue# #x"))
        #expect(try note(titled: "Single body").text.hasSuffix("Single body\n\n#solo"))
        #expect(try note(titled: "None body").text == "---\ntitle: nope\n---\nNone body\n")
        let tags = NoteParser.metadata(for: try note(titled: "Comma body").text).tags
        #expect(tags == ["red", "green blue", "x"])
    }

    @Test func testObsidianEmbedsResolveByNameAndMissingOnesWarn() throws {
        try scratch.write("v/Notes/a.md", "# A\n\n![[logo.png|200]]\n\n[[manual.pdf]]\n\n![[ghost.png]]\n\n[[Some Note]]\n\n[[Dotted.Name]]\n")
        try scratch.write("v/assets/logo.png", Data([1]))
        try scratch.write("v/assets/manual.pdf", Data([2]))

        let report = try run([scratch.url.appendingPathComponent("v")])

        let note = try note(titled: "A")
        #expect(note.text.contains("![logo.png](logo.png)"))
        #expect(note.text.contains("[manual.pdf](manual.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(note.text.contains("![[ghost.png]]"))
        #expect(note.text.contains("[[Some Note]]"))
        #expect(note.text.contains("[[Dotted.Name]]"))
        #expect(report.warnings.filter { $0.contains("ghost.png") }.count == 1)
        #expect(report.warnings.count == 1)
        #expect(attachmentNames(note) == ["logo.png", "manual.pdf"])
    }

    @Test func testRemoteImagesAreCountedNotCopied() throws {
        try scratch.write("v/r.md", "# R\n\n![a](https://example.com/a.png)\n![b](http://example.com/b.png)\n[site](https://example.com)\n")

        let report = try run([scratch.url.appendingPathComponent("v")])

        #expect(try note(titled: "R").text.contains("![a](https://example.com/a.png)"))
        #expect(report.warnings.count == 1)
        #expect(report.warnings[0].contains("2"))
        #expect(report.attachmentsCopied == 0)
    }

    // MARK: - Security: symlinks and hidden files

    /// Zips `tree` with symlinks stored as links (not followed).
    private func zipKeepingLinks(_ tree: URL, to zip: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-q", "-r", "--symlinks", zip.path, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func craftedArchive() throws -> URL {
        let secret = try scratch.write("outside/secret.txt", "TOPSECRETKEY")
        try scratch.write("tree/evil.textbundle/info.json", "{}")
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("tree/evil.textbundle/text.md"), withDestinationURL: secret)
        try scratch.write("tree/good.textbundle/text.md", "# Good\n\n![](assets/leak.png)\n")
        try FileManager.default.createDirectory(
            at: scratch.url.appendingPathComponent("tree/good.textbundle/assets"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("tree/good.textbundle/assets/leak.png"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("tree/linkdir"), withDestinationURL: scratch.url.appendingPathComponent("outside"))
        let zip = scratch.url.appendingPathComponent("evil.bear2bk")
        try zipKeepingLinks(scratch.url.appendingPathComponent("tree"), to: zip)
        return zip
    }

    @Test func testArchivesWithSymlinksAreRefusedWhole() throws {
        let zip = try craftedArchive()
        let out = scratch.url.appendingPathComponent("extracted")
        #expect(throws: SafeZipError.symbolicLink) {
            try SafeZip.extract(archive: zip, to: out, limits: .bulkImports)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try String(contentsOf: scratch.url.appendingPathComponent("outside/secret.txt"), encoding: .utf8) == "TOPSECRETKEY")
    }

    /// Every archive type goes through SafeZip (M8-R100): a link anywhere refuses the whole archive.
    @Test func testSymlinkedTextAndAssetInArchiveAreNeverRead() throws {
        let report = try run([try craftedArchive()])

        #expect(report.created == 0)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].hasPrefix("evil.bear2bk: archive refused:"))
        #expect(report.errors[0].contains("symbolic link"))
        #expect(try allNotes().isEmpty)
        #expect(try String(contentsOf: scratch.url.appendingPathComponent("outside/secret.txt"), encoding: .utf8) == "TOPSECRETKEY")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
    }

    /// `d/` stored with mode 0300 (no read permission) and `d/deep` with 0100, optionally holding
    /// symlinks: archive modes are not applied, so nothing can hide from cleanup.
    private func lockedDirectoryArchive(withLinks: Bool) throws -> URL {
        let secret = try scratch.write("outside/secret.txt", "TOPSECRETKEY")
        let tree = try scratch.dir("ltree-\(withLinks)")
        let fm = FileManager.default
        try fm.createDirectory(at: tree.appendingPathComponent("d/deep"), withIntermediateDirectories: true)
        var entries = ["locked.md", "d", "d/deep"]
        if withLinks {
            try fm.createSymbolicLink(at: tree.appendingPathComponent("d/leak.png"), withDestinationURL: secret)
            try fm.createSymbolicLink(at: tree.appendingPathComponent("d/deep/leak2.png"), withDestinationURL: secret)
            entries += ["d/leak.png", "d/deep/leak2.png"]
        } else {
            try Data([1, 2, 3]).write(to: tree.appendingPathComponent("d/deep/pic.png"))
            entries += ["d/deep/pic.png"]
        }
        try Data("# Locked\n\n![](d/deep/pic.png)\n".utf8).write(to: tree.appendingPathComponent("locked.md"))
        try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: tree.appendingPathComponent("d/deep").path)
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: tree.appendingPathComponent("d").path)
        defer {
            for path in ["d", "d/deep"] {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tree.appendingPathComponent(path).path)
            }
        }
        let zip = scratch.url.appendingPathComponent("locked-\(withLinks).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        // Explicit entries: zip cannot list the 0300 directory itself.
        process.arguments = ["-q", "--symlinks", zip.path] + entries
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }

    @Test func testLockedDirectoriesCannotHideSymlinks() throws {
        let report = try run([try lockedDirectoryArchive(withLinks: true)])
        #expect(report.created == 0)
        #expect(report.errors.count == 1)
        #expect(report.errors.first?.contains("symbolic link") == true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
        #expect(try String(contentsOf: scratch.url.appendingPathComponent("outside/secret.txt"), encoding: .utf8) == "TOPSECRETKEY")
    }

    @Test func testLockedDirectoryArchiveImportLeavesNoTempFiles() throws {
        let report = try run([try lockedDirectoryArchive(withLinks: false)])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.created == 1)
        let note = try note(titled: "Locked")
        #expect(attachmentNames(note) == ["pic.png"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
    }

    /// Finder-style `__MACOSX/._name` entries (ditto `--sequesterRsrc`, or added to a `zip -r` tree)
    /// extract as plain files and are skipped by the importer.
    @Test(arguments: ["ditto", "zip"])
    func testDittoAndZipArchivesWithMacOSXEntriesImport(tool: String) throws {
        let tree = try scratch.dir("compat-\(tool)")
        try scratch.write("compat-\(tool)/Trip.textbundle/text.md", "# Trip\n\n![](assets/map.png)\n")
        try scratch.write("compat-\(tool)/Trip.textbundle/assets/map.png", Data([9, 8, 7]))
        try scratch.write("compat-\(tool)/Loose note.md", "# Loose note\n")
        let file = tree.appendingPathComponent("Loose note.md").path
        #expect(setxattr(file, "com.example.test", "x", 1, 0, 0) == 0)
        let zip = scratch.url.appendingPathComponent("compat-\(tool).zip")
        let process = Process()
        if tool == "ditto" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", tree.path, zip.path]
        } else {
            try scratch.write("compat-\(tool)/__MACOSX/._Loose note.md", Data([0, 5, 22, 7, 0, 2, 0, 0]))
            try scratch.write("compat-\(tool)/__MACOSX/Trip.textbundle/._text.md", Data([0, 5, 22, 7]))
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = tree
            process.arguments = ["-q", "-r", zip.path, "."]
        }
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let names = try String(decoding: Data(contentsOf: zip), as: UTF8.self)
        #expect(names.contains("__MACOSX/"), "the archive has Finder-style entries")

        let report = try run([zip])

        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(try allNotes().map(\.title).sorted() == ["Loose note", "Trip"])
        #expect(attachmentNames(try note(titled: "Trip")) == ["map.png"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
    }

    @Test func testSymlinkedTextFileInLooseBundleIsRejected() throws {
        let secret = try scratch.write("outside/secret.txt", "TOPSECRETKEY")
        try scratch.dir("loose.textbundle")
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("loose.textbundle/text.md"), withDestinationURL: secret)

        let report = try run([scratch.url.appendingPathComponent("loose.textbundle")])

        #expect(report.created == 0)
        #expect(report.errors.count == 1)
        #expect(try allNotes().isEmpty)
    }

    @Test func testSymlinkedInfoJSONIsIgnored() throws {
        let info = try scratch.write("outside/info.json", #"{"trashed": 1, "pinned": 1}"#)
        let bundle = try scratch.dir("i.textbundle")
        try scratch.write("i.textbundle/text.md", "# I\n")
        try FileManager.default.createSymbolicLink(
            at: bundle.appendingPathComponent("info.json"), withDestinationURL: info)

        try run([bundle])

        let note = try note(titled: "I")
        #expect(note.location == .notes)
        #expect(!note.isPinnedGlobal)
    }

    @Test func testHiddenFilesAreNeverCopiedFromSingleFileImport() throws {
        try scratch.write("docs/note.md", "# Note\n\n![](.secret/key.png)\n\n[x](../.ssh/id)\n\n[ok](pics/ok.pdf)\n")
        try scratch.write("docs/.secret/key.png", Data([1]))
        try scratch.write(".ssh/id", "PRIVATEKEY")
        try scratch.write("docs/pics/ok.pdf", Data([2]))

        let report = try run([scratch.url.appendingPathComponent("docs/note.md")])

        let note = try note(titled: "Note")
        #expect(note.text.contains("![](.secret/key.png)"))
        #expect(note.text.contains("[x](../.ssh/id)"))
        #expect(attachmentNames(note) == ["ok.pdf"])
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.filter { $0.contains("key.png") && $0.contains("hidden") }.count == 1)
        #expect(report.warnings.filter { $0.contains(".ssh/id") && $0.contains("outside") }.count == 1)
    }

    @Test func testHiddenFilesInsideFolderRootAreNotCopied() throws {
        try scratch.write("vault/n.md", "# N\n\n![](.git/x.png)\n[e](sub/.env)\n![[.git/x.png]]\n![](vis/ok.png)\n")
        try scratch.write("vault/.git/x.png", Data([1]))
        try scratch.write("vault/sub/.env", "SECRET=1")
        try scratch.write("vault/vis/ok.png", Data([2]))

        let report = try run([scratch.url.appendingPathComponent("vault")])

        let note = try note(titled: "N")
        #expect(attachmentNames(note) == ["ok.png"])
        #expect(report.warnings.filter { $0.contains("hidden") }.count == 3)
    }

    @Test func testSymlinkToHiddenFileIsNotCopied() throws {
        try scratch.write("vault/.private/key.png", Data([1]))
        try scratch.write("vault/n.md", "# N\n\n![](pic.png)\n")
        try FileManager.default.createSymbolicLink(
            at: scratch.url.appendingPathComponent("vault/pic.png"),
            withDestinationURL: scratch.url.appendingPathComponent("vault/.private/key.png"))

        let report = try run([scratch.url.appendingPathComponent("vault")])

        #expect(attachmentNames(try note(titled: "N")).isEmpty)
        #expect(report.warnings.contains { $0.contains("pic.png") && $0.contains("hidden") })
    }

    // MARK: - Progress, cancel, errors

    @Test func testProgressAndCancel() throws {
        for i in 1...4 { try scratch.write("v/n\(i).md", "# N\(i)\n") }
        var seen: [[Int]] = []
        var calls = 0
        let report = try importer().importItems(
            [scratch.url.appendingPathComponent("v")], options: FileImportOptions(),
            progress: { done, total in seen.append([done, total]); calls = done },
            isCancelled: { calls >= 2 })

        #expect(seen.first == [0, 4])
        #expect(report.wasCancelled)
        #expect(report.created == 2)
        #expect(try allNotes().count == 2)
    }

    @Test func testReportNeverContainsNoteBodies() throws {
        try scratch.write("v/secret.md", "# Title\n\nTOPSECRETBODY ![](missing.png)\n")
        let report = try run([scratch.url.appendingPathComponent("v")])
        let all = (report.warnings + report.errors).joined()
        #expect(!all.contains("TOPSECRETBODY"))
        #expect(report.warnings.first?.hasPrefix("v/secret.md") == true)
    }

    // MARK: - Theo Notes' own info.json key (M8-R15)

    @Test func readsTheTheoNotesInfoKeyIncludingTagPins() throws {
        let bundle = try scratch.dir("own.textbundle")
        try scratch.write("own.textbundle/text.md", "---\ntags: [x]\n---\n# Own\n#work #home\n")
        try scratch.write("own.textbundle/info.json", """
            {"version": 2, "type": "net.daringfireball.markdown",
             "creatorIdentifier": "com.truebrewbirdie.baerchen", "transient": false,
             "com.truebrewbirdie.baerchen": {"id": "abc", "creationDate": "2024-05-01T10:00:00.250Z",
               "modificationDate": "2024-05-02T11:30:00.500Z", "pinned": true, "archived": true,
               "trashed": false, "readOnly": true, "tagPins": ["work", "absent"]}}
            """)

        let info = BundleInfo.read(bundle.appendingPathComponent("info.json"))
        #expect(info.fromDialectApp)
        #expect(info.tagPins == ["work", "absent"])
        #expect(info.isPinned == true && info.isArchived == true && info.isReadOnly == true)
        #expect(info.isTrashed == false)
        #expect(info.created == date("2024-05-01T10:00:00Z") + 0.25)

        try run([bundle])

        let note = try note(titled: "Own")
        #expect(note.text == "---\ntags: [x]\n---\n# Own\n#work #home\n")
        #expect(note.location == .archive && note.isPinnedGlobal && note.isReadOnly)
        #expect(note.createdAt == date("2024-05-01T10:00:00Z") + 0.25)
        let pins = try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag.displayPath FROM note_pin JOIN tag ON tag.id = note_pin.tagId WHERE noteId = ?
                """, arguments: [note.id])
        }
        #expect(pins == ["work"])
    }

    @Test func aBundleWithoutAnAppKeyStillGetsFrontMatterTags() throws {
        let bundle = try scratch.dir("plain.textbundle")
        try scratch.write("plain.textbundle/text.md", "---\ntags: [x]\n---\n# Plain\n")
        try scratch.write("plain.textbundle/info.json", #"{"version": 2}"#)

        try run([bundle])

        #expect(try note(titled: "Plain").text.hasSuffix("\n\n#x"))
        #expect(!BundleInfo.read(bundle.appendingPathComponent("info.json")).fromDialectApp)
    }
}

// MARK: - HTML, RTF/RTFD and .bear/.bearnote/.panda (M8 Task 7)

/// A minimal zip writer for crafted archives: stored entries, a Unix mode per entry, and sizes
/// the central directory can lie about.
private struct ZipEntry {
    var name: String
    var data = Data()
    var mode: UInt32 = 0o100644
    var declaredSize: UInt32?
    var flags: UInt16 = 0
}

private func crc32(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        table[n] = c
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}

private func zipBytes(_ entries: [ZipEntry], endMarker: UInt16? = nil) -> Data {
    var out = Data()
    var central = Data()
    func put16(_ d: inout Data, _ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    func put32(_ d: inout Data, _ v: UInt32) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
    for entry in entries {
        let name = Data(entry.name.utf8)
        let size = entry.declaredSize ?? UInt32(entry.data.count)
        let crc = crc32(entry.data)
        let offset = UInt32(out.count)
        put32(&out, 0x0403_4B50); put16(&out, 20); put16(&out, entry.flags); put16(&out, 0); put16(&out, 0); put16(&out, 0x21)
        put32(&out, crc); put32(&out, size); put32(&out, size); put16(&out, UInt16(name.count)); put16(&out, 0)
        out.append(name); out.append(entry.data)
        put32(&central, 0x0201_4B50); put16(&central, 3 << 8 | 20); put16(&central, 20); put16(&central, entry.flags)
        put16(&central, 0); put16(&central, 0); put16(&central, 0x21)
        put32(&central, crc); put32(&central, size); put32(&central, size)
        put16(&central, UInt16(name.count)); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
        put32(&central, entry.mode << 16); put32(&central, offset)
        central.append(name)
    }
    let directoryOffset = UInt32(out.count)
    out.append(central)
    put32(&out, 0x0605_4B50); put16(&out, 0); put16(&out, 0)
    put16(&out, endMarker ?? UInt16(entries.count)); put16(&out, endMarker ?? UInt16(entries.count))
    put32(&out, UInt32(central.count)); put32(&out, directoryOffset); put16(&out, 0)
    return out
}

extension FileImporterTests {
    private var png: Data {
        get throws { try Data(contentsOf: fixture("html-assets/pic.png")) }
    }

    @Test func importsGenericHTMLWithItsImage() throws {
        let report = try run([fixture("images.html")])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty)
        let note = try #require(try allNotes().first)
        #expect(note.text == "# With a picture\nBefore the picture.\n\n![](pic.png)\n\nAfter the picture.")
        #expect(attachmentNames(note) == ["pic.png"])
        #expect(try attachmentData(note, "pic.png") == png)
        #expect(report.attachmentsCopied == 1)
        // The HTML's own heading is the title: no filename title line was added.
        #expect(note.title == "With a picture")
    }

    @Test func genericHTMLKeepsStructureAndDropsScripts() throws {
        try run([fixture("generic.html")])

        let note = try note(titled: "Field notes")
        #expect(note.text == """
            # Field notes
            A **bold** start with *emphasis*, ==a highlight== and a [link](https://example.com/docs). #fieldwork

            - first
            - second
            \t- nested
            > Quoted line
            ```swift
            let answer = 42
            print(answer)
            ```
            """)
        #expect(!note.text.contains("never shown") && !note.text.contains("also dropped"))
        #expect(!note.text.contains("Ignored page title"))
    }

    @Test func htmlDataImagesAndLinkedFilesDoNotCollide() throws {
        let data = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString()
        try scratch.write("page.html", "<p>x</p><img src=\"data:image/png;base64,\(data)\"><img src=\"sub/image.png\"><img src=\"missing.png\">")
        try scratch.write("sub/image.png", Data([9, 9, 9]))

        let report = try run([scratch.url.appendingPathComponent("page.html")])

        let note = try #require(try allNotes().first)
        #expect(Set(attachmentNames(note)) == ["image 2.png", "image.png"])
        #expect(try attachmentData(note, "image 2.png") == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        #expect(try attachmentData(note, "image.png") == Data([9, 9, 9]))
        #expect(report.warnings.contains { $0.contains("missing.png") })
    }

    @Test func importsRTFAndRTFD() throws {
        let report = try run([fixture("styled.rtf"), fixture("with-image.rtfd")])

        #expect(report.created == 2)
        #expect(report.errors.isEmpty)
        let notes = try allNotes()
        let styled = try #require(notes.first { $0.text.contains("bold words") })
        #expect(styled.text == """
            Plain start, **bold words**, *italic words*, ~underlined~ and ~~struck~~.
            Visit [the site](https://example.com/page) or [mail](mailto:hi@example.com).
            - apple
            - pear
            \t- green
            1. one
            2. two
            ```
            let x = 1
            ```
            """)
        let pictured = try #require(notes.first { $0.text.contains("Before the picture") })
        #expect(pictured.text == "Before the picture\n![](image.png)\nAfter the **picture**")
        #expect(attachmentNames(pictured) == ["image.png"])
        #expect(try attachmentData(pictured, "image.png").starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(attachmentNames(styled).isEmpty)
    }

    @Test func rtfAttachmentNamesAreNeverLookedUpOnDisk() throws {
        // A sibling file named like the generated attachment must not be copied in its place.
        let folder = try scratch.dir("pack")
        let rtfd = folder.appendingPathComponent("with-image.rtfd")
        try FileManager.default.copyItem(at: fixture("with-image.rtfd"), to: rtfd)
        try scratch.write("pack/image.png", "NOT THE IMAGE")

        try run([rtfd])

        let note = try #require(try allNotes().first)
        #expect(try attachmentData(note, "image.png").starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func importsBearAndPandaArchivesAsBundles() throws {
        let report = try run([fixture("sample.bear"), fixture("sample.panda")])

        #expect(report.created == 2)
        #expect(report.errors.isEmpty)
        let bear = try note(titled: "Bear archive note")
        #expect(bear.text.contains("![](pic.png)"))
        #expect(bear.createdAt == date("2024-03-05T10:00:00Z"))
        #expect(bear.modifiedAt == date("2024-03-06T11:30:00Z"))
        #expect(bear.isPinnedGlobal)
        #expect(attachmentNames(bear) == ["pic.png"])
        let panda = try note(titled: "Panda archive note")
        #expect(panda.createdAt == date("2023-11-01T08:15:00Z"))
        #expect(panda.modifiedAt == date("2023-11-02T09:45:00Z"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
    }

    @Test func aBearnoteIsReadLikeAnyOtherZippedBundle() throws {
        let zip = zipBytes([
            ZipEntry(name: "Inner/text.md", data: Data("# Inner note\n\nBody\n".utf8)),
            ZipEntry(name: "Inner/info.json", data: Data(#"{"creationDate":"2022-02-02T02:02:02Z","modificationDate":"2022-02-03T02:02:02Z"}"#.utf8)),
        ])
        let file = try scratch.write("Mine.bearnote", zip)

        let report = try run([file])

        #expect(report.errors.isEmpty)
        let note = try note(titled: "Inner note")
        #expect(note.createdAt == date("2022-02-02T02:02:02Z"))
    }

    @Test func htmlInsideAFolderIsNotImported() throws {
        try scratch.write("vault/keep.md", "# Keep\n")
        try scratch.write("vault/asset.html", "<p>asset page</p>")
        try scratch.write("vault/sub/page.htm", "<p>another</p>")
        try scratch.write("vault/sub/doc.rtf", "{\\rtf1 hi}")
        try FileManager.default.copyItem(at: fixture("with-image.rtfd"), to: scratch.url.appendingPathComponent("vault/pack.rtfd"))

        let report = try run([scratch.url.appendingPathComponent("vault")])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty)
        #expect(try allNotes().map(\.title) == ["Keep"])
    }

    @Test func aNonZipBearnoteIsReportedNotThrown() throws {
        let bad = try scratch.write("Broken.bearnote", "this is not a zip file")
        let alsoBad = try scratch.write("Empty.bear", Data())
        let good = try scratch.write("fine.md", "# Fine\n")

        let report = try run([bad, alsoBad, good])

        #expect(report.created == 1)
        #expect(report.errors.count == 2)
        #expect(report.errors[0].hasPrefix("Broken.bearnote:"))
        #expect(report.errors[1].hasPrefix("Empty.bear:"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty)
    }

    @Test func aBrokenRTFIsReportedAndTheRunContinues() throws {
        let bad = try scratch.write("bad.rtf", Data([0, 1, 2, 3]))
        let good = try scratch.write("fine.md", "# Fine\n")

        let report = try run([bad, good])

        #expect(report.created == 1)
        #expect(report.errors.count + report.skipped >= 1)
    }

    // MARK: Hostile archives

    private func refused(
        _ name: String, _ bytes: Data, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let file = try scratch.write(name, bytes)
        let good = try scratch.write("good-\(name).md", "# Good \(name)\n")
        let before = try allNotes().count
        let report = try run([file, good])
        #expect(report.created == 1, sourceLocation: sourceLocation)
        #expect(report.errors.count == 1, sourceLocation: sourceLocation)
        #expect(try allNotes().count == before + 1, sourceLocation: sourceLocation)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []).isEmpty, sourceLocation: sourceLocation)
        return report.errors.first ?? ""
    }

    @Test(arguments: ["a.bear", "a.bearnote", "a.panda"])
    func archivesWithASymbolicLinkAreRefusedBeforeAnyWrite(name: String) throws {
        let message = try refused(name, zipBytes([
            ZipEntry(name: "text.md", data: Data("# T\n".utf8)),
            ZipEntry(name: "assets/leak.png", data: Data("/etc/passwd".utf8), mode: 0o120755),
        ]))
        #expect(message.contains("symbolic link"))
    }

    @Test func archivesWithEscapingOrAbsolutePathsAreRefused() throws {
        for (index, evil) in ["../evil.md", "a/../../evil.md", "/tmp/evil.md", "a\\..\\evil.md", "C:/evil.md"].enumerated() {
            let message = try refused("e\(index).bear", zipBytes([
                ZipEntry(name: "text.md", data: Data("# T\n".utf8)), ZipEntry(name: evil, data: Data("x".utf8)),
            ]))
            #expect(message.contains("path"), "\(evil): \(message)")
        }
    }

    @Test func archivesOverTheLimitsAreRefused() throws {
        let tiny = Data("# T\n".utf8)
        let many = (0...SafeZip.Limits.imports.maxEntries).map { ZipEntry(name: "f\($0).txt") }
        #expect(try refused("many.bear", zipBytes(many)).contains("entries"))
        let huge = try refused("huge.panda", zipBytes([ZipEntry(name: "text.md", data: tiny, declaredSize: 600 << 20)]))
        #expect(huge.contains("larger"))
        let total = (0..<3).map { ZipEntry(name: "f\($0).bin", data: tiny, declaredSize: 400 << 20) }
        #expect(try refused("total.bearnote", zipBytes(total)).contains("expands"))
        #expect(try refused("zip64.bear", zipBytes([ZipEntry(name: "text.md", data: tiny)], endMarker: 0xFFFF)).contains("ZIP64"))
        #expect(try refused("enc.bear", zipBytes([ZipEntry(name: "text.md", data: tiny, flags: 1)])).contains("encrypted"))
        #expect(try refused("trunc.bear", Data(zipBytes([ZipEntry(name: "text.md", data: tiny)]).dropLast(5))).contains("zip"))
    }

    // MARK: Fix round 1

    @Test func anArchiveWithMoreThanOneBundleIsRefusedBeforeAnyWrite() throws {
        let note = { (title: String) in Data("# \(title)\n".utf8) }
        let cases: [(String, [ZipEntry])] = [
            ("two.bear", [ZipEntry(name: "A.textbundle/text.md", data: note("A")), ZipEntry(name: "B.textbundle/text.md", data: note("B"))]),
            ("rootplus.panda", [ZipEntry(name: "text.md", data: note("Root")), ZipEntry(name: "B.textbundle/text.md", data: note("B"))]),
            ("loose.bearnote", [ZipEntry(name: "A.textbundle/text.md", data: note("A")), ZipEntry(name: "extra.md", data: note("Extra"))]),
            ("deep.bear", [ZipEntry(name: "One/A.textbundle/text.md", data: note("A")), ZipEntry(name: "One/B.textbundle/text.md", data: note("B"))]),
            ("none.bear", [ZipEntry(name: "readme.bin", data: Data([1, 2, 3]))]),
        ]
        for (name, entries) in cases {
            let message = try refused(name, zipBytes(entries))
            #expect(message.contains("exactly one TextBundle") || message.contains("no TextBundle"), "\(name): \(message)")
        }
        #expect(try allNotes().map(\.title).sorted() == cases.map { "Good \($0.0)" }.sorted())
    }

    @Test func oneBundleInAFolderOrAtTheRootStillImports() throws {
        let note = Data("# One\n".utf8)
        let report = try run([
            try scratch.write("root.bear", zipBytes([ZipEntry(name: "text.md", data: note)])),
            try scratch.write("folder.panda", zipBytes([ZipEntry(name: "Any name/text.md", data: Data("# Two\n".utf8))])),
            try scratch.write("named.bearnote", zipBytes([ZipEntry(name: "Three.textbundle/text.md", data: Data("# Three\n".utf8))])),
        ])
        #expect(report.errors.isEmpty)
        #expect(report.created == 3)
    }

    private func rtfdPackage(_ name: String, extra: (URL) throws -> Void) throws -> URL {
        let package = scratch.url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture("with-image.rtfd"), to: package)
        try extra(package)
        return package
    }

    @Test func anRTFDPackageIsCheckedBeforeItIsRead() throws {
        let secret = try scratch.write("outside/secret.png", "TOPSECRET")
        let linked = try rtfdPackage("linked.rtfd") {
            try FileManager.default.removeItem(at: $0.appendingPathComponent("Attachment.png"))
            try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("Attachment.png"), withDestinationURL: secret)
        }
        let linkedText = try rtfdPackage("linkedtext.rtfd") {
            try FileManager.default.removeItem(at: $0.appendingPathComponent("TXT.rtf"))
            try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("TXT.rtf"), withDestinationURL: secret)
        }
        let nested = try rtfdPackage("nested.rtfd") {
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: $0.appendingPathComponent("sub/leak"), withDestinationURL: secret)
        }
        let bigAttachment = try rtfdPackage("bigfile.rtfd") {
            let big = $0.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: 33 << 20)
            try handle.close()
        }
        let bigText = try rtfdPackage("bigtext.rtfd") {
            let text = $0.appendingPathComponent("TXT.rtf")
            let handle = try FileHandle(forWritingTo: text)
            try handle.truncate(atOffset: 129 << 20)
            try handle.close()
        }
        let manyFiles = try rtfdPackage("many.rtfd") { package in
            for i in 0..<5 {
                let file = package.appendingPathComponent("p\(i).bin")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: 30 << 20)
                try handle.close()
            }
        }
        let good = try scratch.write("fine.md", "# Fine\n")

        let report = try run([linked, linkedText, nested, bigAttachment, bigText, manyFiles, good])

        #expect(report.created == 1)
        #expect(report.errors.count == 6)
        #expect(try allNotes().map(\.title) == ["Fine"])
        #expect(!(try allNotes().contains { $0.text.contains("TOPSECRET") }))
        #expect(report.errors.allSatisfy { $0.contains("rtfd") })
    }

    @Test func anUntrustedPageCopiesNoLocalFilesExceptItsOwnImages() throws {
        try scratch.write("secret.txt", "TOPSECRET")
        try scratch.write("x.png", Data([1, 2, 3]))
        try scratch.write("site/page.html", """
            <p>ok</p><a href="../secret.txt">s</a><a href="note.pdf">p</a><a href="file:///etc/hosts">h</a>
            <img src="../../x.png"><img src="../x.png"><img src="/etc/hosts.png"><img src="notes.txt"><img src="note.pdf"><img src="%2e%2e/x.png">
            <img src="files/in.png"><p>![](../x.png) [x](../secret.txt) [[x.png]]</p>
            """)
        try scratch.write("site/note.pdf", Data([9]))
        try scratch.write("site/notes.txt", "private")
        try scratch.write("site/files/in.png", Data([4, 5, 6]))

        let report = try run([scratch.url.appendingPathComponent("site/page.html")])

        let note = try #require(try allNotes().first)
        #expect(attachmentNames(note) == ["in.png"])
        #expect(try attachmentData(note, "in.png") == Data([4, 5, 6]))
        #expect(report.attachmentsCopied == 1)
        #expect(!note.text.contains("TOPSECRET"))
        #expect(!note.text.contains("note.pdf") && !note.text.contains("notes.txt"))
    }

    @Test func aWellFormedCraftedArchiveStillImports() throws {
        let zip = zipBytes([ZipEntry(name: "text.md", data: Data("# Plain crafted\n".utf8))])
        let report = try run([try scratch.write("ok.bear", zip)])
        #expect(report.errors.isEmpty)
        #expect(report.created == 1)
    }

    // MARK: Fix round 2 (SafeZip)

    @Test func archivesThatOnlyAStricterReaderRefusesAreRefusedBeforeAnyWrite() throws {
        var renamed = TestZip.Entry("text.md", "# Renamed\n")
        renamed.localName = "../../escape"
        var described = TestZip.Entry("text.md", "# Described\n", deflate: true)
        described.flags = 8
        described.descriptor = (TestZip.crc32(Data("# Described\n".utf8)), 2, 2)
        var bomb = TestZip.Entry("assets/zero.bin", data: Data(count: 32 << 20), deflate: true)
        bomb.size = 1
        bomb.crc = 0
        var twoEnds = TestZip([.init("text.md", "# Two ends\n")])
        twoEnds.comment = TestZip.endRecord(entries: 0, size: 0, offset: 0)
        var link = TestZip.Entry("assets/leak.png", "/etc/passwd")
        link.creator = 0
        link.attributes = 0o120777 << 16
        let cases: [(String, TestZip)] = [
            ("renamed.bear", TestZip([renamed])),
            ("described.bearnote", TestZip([described])),
            ("bomb.panda", TestZip([.init("text.md", "# Bomb\n"), bomb])),
            ("ends.bear", twoEnds),
            ("case.bear", TestZip([.init("text.md", "# Case\n"), .init("assets/PIC.png", "1"), .init("assets/pic.png", "2")])),
            ("nfc.panda", TestZip([.init("text.md", "# NFC\n"), .init("assets/\u{E9}.png", "1"), .init("assets/e\u{301}.png", "2")])),
            ("dos-link.bear", TestZip([.init("text.md", "# Link\n"), link])),
        ]
        for (name, zip) in cases {
            let message = try refused(name, zip.bytes())
            #expect(message.hasPrefix(name + ": archive refused:"), "\(name): \(message)")
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.url.deletingLastPathComponent().appendingPathComponent("escape").path))
        #expect(try allNotes().map(\.title).sorted() == cases.map { "Good \($0.0)" }.sorted())
    }

    @Test func aDittoMadeBearFileImports() throws {
        try scratch.write("src/Ditto note.textbundle/text.md", "# Ditto note\n\n![](assets/pic.png)\n")
        try scratch.write("src/Ditto note.textbundle/assets/pic.png", Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        let archive = scratch.url.appendingPathComponent("Ditto note.bear")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", scratch.url.appendingPathComponent("src").path, archive.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        let report = try run([archive])

        #expect(report.errors.isEmpty, "\(report.errors)")
        let note = try note(titled: "Ditto note")
        #expect(attachmentNames(note) == ["pic.png"])
        #expect(try attachmentData(note, "pic.png") == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
    }
}

// MARK: - Attachment size caps (IMP-R61)

extension FileImporterTests {
    private func limitedRun(
        _ urls: [URL], limits: AppleNotesExportImporter.Limits = .standard
    ) throws -> FileImportReport {
        try FileImporter(
            store: store, paths: tmp.paths, now: { [now] in now }, temporaryDirectory: scratch.temp, limits: limits
        ).importItems(urls, options: FileImportOptions(), progress: { _, _ in }, isCancelled: { false })
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

    @Test func aHugeLinkedFileIsNotReadAndTheNoteStillImports() throws {
        try scratch.write("vault/Big.md", "# Big\n\n[huge](huge.pdf)\n\n![](ok.png)\n")
        try writeSparse("vault/huge.pdf", megabytes: 129)
        try scratch.write("vault/ok.png", try png)

        let report = try limitedRun([scratch.url.appendingPathComponent("vault")])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.contains { $0.contains("huge.pdf") && $0.contains("larger than 128 MB") })
        let big = try note(titled: "Big")
        #expect(attachmentNames(big) == ["ok.png"])
        #expect(big.text.contains("](huge.pdf)"), "the link stays as written")
    }

    @Test func aHugeFileInATextBundleIsNotCopied() throws {
        try scratch.write("Bundle.textbundle/text.md", "# Bundle\n\n![](assets/huge.bin)\n\n![](assets/ok.png)\n")
        try scratch.write("Bundle.textbundle/info.json", #"{"version":2,"type":"net.daringfireball.markdown"}"#)
        try writeSparse("Bundle.textbundle/assets/huge.bin", megabytes: 129)
        try scratch.write("Bundle.textbundle/assets/ok.png", try png)

        let report = try limitedRun([scratch.url.appendingPathComponent("Bundle.textbundle")])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(report.warnings.contains { $0.contains("huge.bin") && $0.contains("larger than 128 MB") })
        #expect(attachmentNames(try note(titled: "Bundle")) == ["ok.png"])
    }

    @Test func oneNotesAttachmentsStopAtThePerNoteBudget() throws {
        try scratch.write("vault/Many.md", "# Many\n\n[1](1.bin)\n\n[2](2.bin)\n\n[3](3.bin)\n")
        for name in ["1", "2", "3"] { try scratch.write("vault/\(name).bin", Data(count: (1 << 20) + Int(name)!)) }

        let report = try limitedRun(
            [scratch.url.appendingPathComponent("vault")], limits: .init(each: 2 << 20, perNote: 2_500_000, total: 100 << 20))

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.contains { $0.contains("3.bin") && $0.contains("size limit") })
    }

    @Test func theWholeRunStopsCopyingOnceTheTotalBudgetIsUsed() throws {
        for name in ["a", "b", "c"] {
            try scratch.write("vault/\(name).md", "# \(name)\n\n[f](\(name).bin)\n")
            try scratch.write("vault/\(name).bin", Data(count: 1 << 20))
        }

        let report = try limitedRun(
            [scratch.url.appendingPathComponent("vault")], limits: .init(each: 2 << 20, perNote: 2 << 20, total: (2 << 20) + 10))

        #expect(report.created == 3, "the notes themselves still import")
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.filter { $0.contains("size limit") }.count == 1)
    }

    @Test func aFileAtTheCapStillComes() throws {
        try scratch.write("vault/Edge.md", "# Edge\n\n[a](a.bin)\n")
        try scratch.write("vault/a.bin", Data(count: 1 << 20))

        let report = try limitedRun(
            [scratch.url.appendingPathComponent("vault")], limits: .init(each: 1 << 20, perNote: 4 << 20, total: 8 << 20))

        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.isEmpty)
    }
}
