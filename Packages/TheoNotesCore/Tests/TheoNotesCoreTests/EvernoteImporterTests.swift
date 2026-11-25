// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Counts the bytes the XML parser has pulled from the file, to show that an import streams.
final class CountingInputStream: InputStream, @unchecked Sendable {
    private let base: InputStream
    nonisolated(unsafe) private(set) var bytesRead = 0

    init(file url: URL) {
        base = InputStream(url: url)!
        super.init(data: Data())
    }

    override func open() { base.open() }
    override func close() { base.close() }
    override var streamStatus: Stream.Status { base.streamStatus }
    override var streamError: (any Error)? { base.streamError }
    override var hasBytesAvailable: Bool { base.hasBytesAvailable }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let count = base.read(buffer, maxLength: len)
        if count > 0 { bytesRead += count }
        return count
    }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
}

/// Counts how many resources reach the Base64 decoder.
final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func decode(_ text: String) -> Data? {
        lock.lock()
        count += 1
        lock.unlock()
        return ENEXReader.decodeBase64(text)
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite struct EvernoteImporterTests {
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
        .appendingPathComponent("Fixtures/import/evernote", isDirectory: true)

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    private func importer(
        limits: ENEXLimits = .standard, decoder: @escaping @Sendable (String) -> Data? = ENEXReader.decodeBase64
    ) -> EvernoteImporter {
        EvernoteImporter(store: store, paths: tmp.paths, now: { [now] in now }, limits: limits, decoder: decoder)
    }

    @discardableResult
    private func run(
        _ url: URL, _ options: FileImportOptions = FileImportOptions(), limits: ENEXLimits = .standard
    ) throws -> FileImportReport {
        try importer(limits: limits).importFile(url, options: options)
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
    }

    private func attachmentNames(_ note: Note) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private static let head = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
        <en-export export-date="20261020T101500Z" application="Evernote" version="10.0">

        """

    /// A synthetic note element; `resources` are raw `<resource>` strings.
    private func noteXML(
        title: String = "T", body: String, created: String? = "20240315T091500Z",
        updated: String? = "20240316T101530Z", tags: [String] = [], resources: [String] = []
    ) -> String {
        var s = "<note><title>\(title)</title><content><![CDATA[<?xml version=\"1.0\"?><en-note>\(body)</en-note>]]></content>"
        if let created { s += "<created>\(created)</created>" }
        if let updated { s += "<updated>\(updated)</updated>" }
        for tag in tags { s += "<tag>\(tag)</tag>" }
        return s + resources.joined() + "</note>\n"
    }

    private func resourceXML(_ data: Data, mime: String, fileName: String? = nil) -> String {
        let attributes = fileName.map { "<resource-attributes><file-name>\($0)</file-name></resource-attributes>" } ?? ""
        return "<resource><data encoding=\"base64\">\(data.base64EncodedString(options: .lineLength64Characters))</data>"
            + "<mime>\(mime)</mime>\(attributes)</resource>"
    }

    @discardableResult
    private func writeENEX(_ name: String, notes: [String]) throws -> URL {
        try scratch.write(name, Self.head + notes.joined() + "</en-export>\n")
    }

    // MARK: - Title, body, dates

    @Test func testTitleBodyDatesAndSource() throws {
        let report = try run(fixture("Travel.enex"))

        #expect(report.created == 2)
        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        let notes = try allNotes()
        #expect(notes.count == 2)
        let first = try #require(notes.first { $0.title == "Packing list" })
        #expect(first.text == """
            # Packing list

            Passport and **tickets**, then *sunscreen*.

            Second paragraph & more.

            Source: https://example.com/packing

            #evernote/Travel
            """)
        #expect(first.createdAt == date("2024-03-15T09:15:00Z"))
        #expect(first.modifiedAt == date("2024-03-16T10:15:30Z"))
    }

    @Test func testEmptyTitleWithHeadingBodyAddsNoTitleLine() throws {
        try run(fixture("Travel.enex"))
        let note = try #require(try allNotes().first { $0.title == "Own heading" })
        #expect(note.text == "# Own heading\nBody below.\n\n#evernote/Travel")
    }

    @Test func testDatesAreNowWhenKeepDatesIsOff() throws {
        try run(fixture("Travel.enex"), FileImportOptions(keepDates: false))
        let notes = try allNotes()
        #expect(notes.count == 2)
        #expect(notes.allSatisfy { abs($0.createdAt.timeIntervalSince(now)) < 1 && abs($0.modifiedAt.timeIntervalSince(now)) < 1 })
    }

    @Test func testMissingAndBrokenDatesFallBack() throws {
        let url = try writeENEX("Dates.enex", notes: [
            noteXML(title: "OnlyUpdated", body: "<div>a</div>", created: nil, updated: "20230102T030405Z"),
            noteXML(title: "NoDates", body: "<div>b</div>", created: "garbage", updated: nil),
            noteXML(title: "UpdatedBeforeCreated", body: "<div>c</div>", created: "20240101T000000Z", updated: "20230101T000000Z"),
        ])
        try run(url)
        let notes = try allNotes()
        let only = try #require(notes.first { $0.title == "OnlyUpdated" })
        #expect(only.createdAt == date("2023-01-02T03:04:05Z") && only.modifiedAt == only.createdAt)
        let none = try #require(notes.first { $0.title == "NoDates" })
        #expect(none.createdAt == now && none.modifiedAt == now)
        let inverted = try #require(notes.first { $0.title == "UpdatedBeforeCreated" })
        #expect(inverted.createdAt == date("2023-01-01T00:00:00Z") && inverted.modifiedAt == inverted.createdAt)
    }

    @Test func testNoteWithOnlyATitleIsImportedAndEmptyNoteIsSkipped() throws {
        let url = try writeENEX("Sparse.enex", notes: [
            noteXML(title: "Just a title", body: ""),
            noteXML(title: "", body: "<div><br/></div>"),
        ])
        let report = try run(url)
        #expect(report.created == 1)
        #expect(report.skipped == 1)
        #expect(report.warnings == ["Sparse.enex: note 2: empty, skipped"])
        #expect(try allNotes().first?.text == "# Just a title\n\n#evernote/Sparse")
    }

    // MARK: - Tags

    @Test func testTagsAndNotebookTag() throws {
        let report = try run(fixture("Tagged.enex"))
        #expect(report.created == 1)
        #expect(report.warnings.isEmpty)
        let note = try #require(try allNotes().first)
        #expect(note.text == "# Tagged note\n\nSome text.\n\n#alpha #Project X# #2026# #a-b #evernote/Tagged")
        let tags = NoteParser.metadata(for: note.text).tags
        #expect(Set(tags) == ["alpha", "Project X", "2026", "a-b", "evernote/Tagged"])
    }

    @Test func testNotebookNameWithSpacesBecomesAClosedTag() throws {
        let url = try writeENEX("Work Log.enex", notes: [noteXML(title: "N", body: "<div>x</div>", tags: ["Alpha", "alpha"])])
        try run(url)
        let note = try #require(try allNotes().first)
        #expect(note.text == "# N\n\nx\n\n#Alpha #evernote/Work Log#")
    }

    // MARK: - To-do items

    @Test func testCheckedAndUncheckedTodos() throws {
        try run(fixture("Todos.enex"))
        let note = try #require(try allNotes().first)
        #expect(note.text == """
            # Chores

            - [x] Take out the bins
            - [ ] Water the plants
            - [ ] Call the plumber

            Plain line

            #evernote/Todos
            """)
    }

    @Test func testTodoInsideAListItemKeepsOneMarker() throws {
        let url = try writeENEX("Nested.enex", notes: [
            noteXML(title: "L", body: "<ul><li><en-todo checked=\"true\"/>first</li><li><en-todo/>second <b>bold</b></li></ul>")
        ])
        try run(url)
        let note = try #require(try allNotes().first)
        #expect(note.text.contains("- [x] first\n- [ ] second **bold**"))
        #expect(!note.text.contains("- - "))
    }

    // MARK: - Resources

    @Test func testImageAndPDFAreLinkedAndStored() throws {
        let report = try run(fixture("Media.enex"))
        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.isEmpty)
        let note = try #require(try allNotes().first)
        let pdfName = "a3f03fbce7b974dc81740d4448bb17af.pdf"
        #expect(note.text == """
            # Photo and paper

            Look at this:
            ![](sketch.png)
            And the contract:
            [\(pdfName)](\(pdfName)) <!-- {"preview":"true","embed":"true"} -->

            #evernote/Media
            """)
        #expect(attachmentNames(note) == [pdfName, "sketch.png"])
        let png = try Data(contentsOf: tmp.paths.attachments.appendingPathComponent("\(note.id)/sketch.png"))
        #expect(EvernoteImporter.md5Hex(png) == "2cd8bde463f5d82aae0f0cec061d6b8f")
        let refs = NoteParser.metadata(for: note.text).attachments.map(\.filename)
        #expect(Set(refs) == ["sketch.png", pdfName])
    }

    @Test func testSameFileNamesGetNumberedAndAppearOnceForIdenticalBytes() throws {
        let a = Data("first file".utf8), b = Data("second file".utf8)
        let url = try writeENEX("Names.enex", notes: [
            noteXML(
                title: "N",
                body: "<en-media hash=\"\(EvernoteImporter.md5Hex(a))\" type=\"text/plain\"/><en-media hash=\"\(EvernoteImporter.md5Hex(b))\" type=\"text/plain\"/>"
                    + "<en-media hash=\"\(EvernoteImporter.md5Hex(a).uppercased())\" type=\"text/plain\"/>",
                resources: [
                    resourceXML(a, mime: "text/plain", fileName: "notes.txt"),
                    resourceXML(b, mime: "text/plain", fileName: "Notes.TXT"),
                    resourceXML(a, mime: "text/plain", fileName: "again.txt"),
                ])
        ])
        let report = try run(url)
        #expect(report.attachmentsCopied == 2)
        let note = try #require(try allNotes().first)
        #expect(attachmentNames(note) == ["Notes 2.TXT", "notes.txt"])
        #expect(note.text.contains("[notes.txt](notes.txt) <!-- {\"embed\":\"true\"} -->"))
        #expect(note.text.contains("[Notes 2.TXT](Notes%202.TXT)"))
    }

    @Test func testUnsafeFileNamesAreMadeSafe() {
        let traversal = EvernoteImporter.attachmentName(fileName: "../../etc/passwd", mime: "text/plain", hash: "h")
        #expect(!traversal.contains("/") && !traversal.hasPrefix("."))
        #expect(EvernoteImporter.attachmentName(fileName: ".hidden", mime: "image/png", hash: "h") == "hidden.png")
        #expect(EvernoteImporter.attachmentName(fileName: "  ", mime: "image/jpeg", hash: "abc") == "abc.jpg")
        #expect(EvernoteImporter.attachmentName(fileName: nil, mime: "application/x-unknown-thing", hash: "abc") == "abc.bin")
        let long = String(repeating: "é", count: 300) + ".pdf"
        let name = EvernoteImporter.attachmentName(fileName: long, mime: "application/pdf", hash: "h")
        #expect(name.utf8.count <= 200 && name.hasSuffix(".pdf"))
    }

    @Test func testResourceWithoutMediaReferenceIsAppendedAsALink() throws {
        let data = Data("loose".utf8)
        let url = try writeENEX("Loose.enex", notes: [
            noteXML(title: "N", body: "<div>text</div>", resources: [resourceXML(data, mime: "application/zip", fileName: "bundle.zip")])
        ])
        let report = try run(url)
        #expect(report.attachmentsCopied == 1)
        let note = try #require(try allNotes().first)
        #expect(note.text == "# N\n\ntext\n\n[bundle.zip](bundle.zip) <!-- {\"embed\":\"true\"} -->\n\n#evernote/Loose")
    }

    @Test func testMissingResourceLeavesAVisiblePlaceholder() throws {
        let report = try run(fixture("Missing.enex"))
        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 0)
        #expect(report.errors.isEmpty)
        #expect(report.warnings == ["Missing.enex: note 1: 1 attachment(s) are not in the export, marked in the text"])
        let note = try #require(try allNotes().first)
        #expect(note.text == "# Lost image\n\nBefore\n[Evernote attachment not imported]\nAfter\n\n#evernote/Missing")
        #expect(!note.text.contains("!["))
    }

    @Test func testOversizedResourceIsSkippedWithAWarning() throws {
        let big = Data(repeating: 7, count: 5_000)
        let small = Data("ok".utf8)
        let url = try writeENEX("Big.enex", notes: [
            noteXML(
                title: "N",
                body: "<en-media hash=\"\(EvernoteImporter.md5Hex(big))\" type=\"application/pdf\"/><en-media hash=\"\(EvernoteImporter.md5Hex(small))\" type=\"text/plain\"/>",
                resources: [resourceXML(big, mime: "application/pdf", fileName: "big.pdf"), resourceXML(small, mime: "text/plain", fileName: "small.txt")])
        ])
        let report = try run(url, limits: ENEXLimits(resource: 1_000, run: 1 << 20, content: 1 << 20))
        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.contains("Big.enex: note 1: an attachment was not imported (larger than the 128 MB limit)"))
        let note = try #require(try allNotes().first)
        #expect(attachmentNames(note) == ["small.txt"])
        #expect(note.text.contains("[Evernote attachment not imported]"))
    }

    @Test func testRunBudgetStopsDecodingResources() throws {
        let one = Data(repeating: 1, count: 600), two = Data(repeating: 2, count: 600)
        let url = try writeENEX("Budget.enex", notes: [
            noteXML(title: "A", body: "<div>a</div>", resources: [resourceXML(one, mime: "application/pdf", fileName: "one.pdf")]),
            noteXML(title: "B", body: "<div>b</div>", resources: [resourceXML(two, mime: "application/pdf", fileName: "two.pdf")]),
        ])
        let report = try run(url, limits: ENEXLimits(resource: 1_000, run: 1_000, content: 1 << 20))
        #expect(report.created == 2)
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.contains { $0.hasPrefix("Budget.enex: note 2: an attachment was not imported") })
    }

    @Test func testCapsAreCheckedBeforeDecoding() throws {
        func data(_ count: Int, _ byte: UInt8) -> Data { Data(repeating: byte, count: count) }
        let url = try writeENEX("Caps.enex", notes: [
            noteXML(title: "N", body: "<div>x</div>", resources: [
                resourceXML(data(600, 1), mime: "application/pdf", fileName: "ok1.pdf"),
                resourceXML(data(1_100, 2), mime: "application/pdf", fileName: "overResource.pdf"),
                resourceXML(data(600, 3), mime: "application/pdf", fileName: "ok2.pdf"),
                resourceXML(data(600, 4), mime: "application/pdf", fileName: "overRun.pdf"),
                resourceXML(data(10, 5), mime: "application/pdf", fileName: "tiny.pdf"),
            ])
        ])
        let counter = DecodeCounter()
        let report = try importer(
            limits: ENEXLimits(resource: 1_000, run: 1_500, content: 1 << 20), decoder: { counter.decode($0) }
        ).importFile(url)

        #expect(counter.calls == 3)
        #expect(report.attachmentsCopied == 3)
        let note = try #require(try allNotes().first)
        #expect(attachmentNames(note) == ["ok1.pdf", "ok2.pdf", "tiny.pdf"])
        #expect(report.warnings.filter { $0.contains("larger than the 128 MB limit") }.count == 1)
        #expect(report.warnings.filter { $0.contains("2 GB total limit") }.count == 1)
    }

    @Test func testHugeDataIsDroppedWhileReadingWithoutDecoding() throws {
        let big = Data(repeating: 9, count: 20_000)
        let url = try writeENEX("Huge.enex", notes: [
            noteXML(title: "N", body: "<div>x</div>", resources: [resourceXML(big, mime: "application/pdf", fileName: "big.pdf")])
        ])
        let counter = DecodeCounter()
        let report = try importer(
            limits: ENEXLimits(resource: 1_000, run: 1 << 20, content: 1 << 20), decoder: { counter.decode($0) }
        ).importFile(url)
        #expect(counter.calls == 0)
        #expect(report.created == 1)
        #expect(report.warnings.contains { $0.contains("larger than the 128 MB limit") })
    }

    // MARK: - Hostile structure

    @Test func testDeeplyNestedXMLStopsTheReadWithAClearError() throws {
        let good = noteXML(title: "Good", body: "<div>fine</div>")
        let deep = String(repeating: "<a>", count: 500)
        let url = try scratch.write("Deep.enex", Self.head + good + "<note><title>x</title>" + deep + "</en-export>")
        let report = try run(url)
        #expect(report.created == 1)
        #expect(report.errors == ["Deep.enex: the file is nested too deeply (over 64 levels), reading stopped"])
    }

    /// ENML element and attribute names are matched ignoring ASCII case, as before the linear scan.
    @Test func testElementNamesMatchIgnoringCase() throws {
        let data = Data("case".utf8)
        let hash = EvernoteImporter.md5Hex(data)
        let url = try writeENEX("Cases.enex", notes: [
            noteXML(
                title: "N",
                body: "<EN-TODO CHECKED=\"TRUE\"/>done<div><En-Todo/>open</div>"
                    + "<div><EN-MEDIA HASH=\"\(hash.uppercased())\" TYPE=\"text/plain\"></EN-MEDIA></div>"
                    + "<div>a<EN-CRYPT hint=\"h\">AAAA</EN-CRYPT>b</div>"
                    + "<div><En-Crypt/></div><div>tail</div>",
                resources: [resourceXML(data, mime: "text/plain", fileName: "c.txt")])
        ])
        let report = try run(url)
        let note = try #require(try allNotes().first)
        #expect(report.attachmentsCopied == 1)
        #expect(note.text.contains("- [x] done"))
        #expect(note.text.contains("- [ ] open"))
        // Linked where the element stood, not appended after the body as an unreferenced resource.
        let link = try #require(note.text.range(of: "[c.txt](c.txt)"))
        let tail = try #require(note.text.range(of: "tail"))
        #expect(link.lowerBound < tail.lowerBound)
        #expect(!note.text.contains("AAAA"))
        #expect(note.text.components(separatedBy: "[Encrypted Evernote text not imported]").count == 3)
        #expect(report.warnings == ["Cases.enex: note 1: 2 encrypted section(s) not imported"])
    }

    @Test func testUnclosedUppercaseEncryptedElementIsOneSection() throws {
        let url = try writeENEX("Upper.enex", notes: [
            noteXML(title: "N", body: "<div>before</div><EN-CRYPT hint=\"h\">AAAA<div>after</div>")
        ])
        let report = try run(url)
        let note = try #require(try allNotes().first)
        #expect(report.warnings == ["Upper.enex: note 1: 1 encrypted section(s) not imported"])
        #expect(note.text.contains("[Encrypted Evernote text not imported]"))
        #expect(!note.text.contains("AAAA") && !note.text.contains("after"))
    }

    @Test func testUnclosedEncryptedElementsAreLinear() throws {
        let body = "<div>start</div>" + String(repeating: "<en-crypt hint=\"h\">", count: 50_000)
        #expect(body.utf8.count > 900_000)
        let url = try writeENEX("Crypts.enex", notes: [noteXML(title: "N", body: body)])
        let started = Date()
        let report = try run(url)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(report.created == 1)
        #expect(report.warnings == ["Crypts.enex: note 1: 1 encrypted section(s) not imported"])
        let note = try #require(try allNotes().first)
        #expect(note.text.contains("[Encrypted Evernote text not imported]"))
    }

    @Test func testUnclosedOpenersOfEveryKindAreLinear() throws {
        for opener in ["<?xml ", "<!DOCTYPE ", "<en-media x=\"", "<en-todo x='", "<en-note "] {
            let body = String(repeating: opener, count: 100_000 / opener.utf8.count)
            let url = try writeENEX("Open.enex", notes: [noteXML(title: "N", body: "<div>t</div>" + body)])
            let started = Date()
            let report = try run(url)
            #expect(Date().timeIntervalSince(started) < 5, "opener \(opener)")
            #expect(report.created == 1, "opener \(opener)")
        }
    }

    // MARK: - Encrypted sections

    @Test func testEncryptedSectionIsReportedAndMarked() throws {
        let report = try run(fixture("Secret.enex"))
        #expect(report.created == 1)
        #expect(report.warnings == ["Secret.enex: note 1: 1 encrypted section(s) not imported"])
        let note = try #require(try allNotes().first)
        #expect(note.text == "# Vault\n\nPublic part\n[Encrypted Evernote text not imported]\nAfter\n\n#evernote/Secret")
        #expect(!note.text.contains("U29tZUZha2VDaXBoZXJ0ZXh0"))
    }

    // MARK: - Hostile and broken input

    @Test func testReportsNeverCarryNoteText() throws {
        let url = try writeENEX("Private.enex", notes: [
            noteXML(title: "Secret title", body: "<en-media hash=\"00\" type=\"image/png\"/><en-crypt>xx</en-crypt>", tags: ["#"])
        ])
        let report = try run(url)
        let all = (report.warnings + report.errors).joined(separator: "\n")
        #expect(!all.contains("Secret title"))
        #expect(!report.warnings.isEmpty)
    }

    @Test func testFileThatIsNotENEX() throws {
        let url = try scratch.write("Other.enex", "<?xml version=\"1.0\"?><html><body>hi</body></html>")
        let report = try run(url)
        #expect(report.created == 0)
        #expect(report.errors == ["Other.enex: not an Evernote export (ENEX) file"])
    }

    @Test func testTruncatedFileKeepsTheNotesBeforeTheBreak() throws {
        let whole = Self.head + noteXML(title: "Whole", body: "<div>one</div>") + noteXML(title: "Cut", body: "<div>two</div>")
        let url = try scratch.write("Cut.enex", String(whole.dropLast(60)))
        let report = try run(url)
        #expect(report.created == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].hasPrefix("Cut.enex: the file is not valid XML (line "))
        #expect(try allNotes().map(\.title) == ["Whole"])
    }

    @Test func testExternalEntityIsNotResolved() throws {
        let secret = try scratch.write("secret.txt", "TOP-SECRET-CONTENT")
        let xml = """
            <?xml version="1.0"?>
            <!DOCTYPE en-export [<!ENTITY leak SYSTEM "\(secret.absoluteString)">]>
            <en-export><note><title>&leak;</title><content><![CDATA[<en-note><div>body</div></en-note>]]></content></note></en-export>
            """
        let url = try scratch.write("Xxe.enex", xml)
        _ = try? run(url)
        for note in try allNotes() { #expect(!note.text.contains("TOP-SECRET-CONTENT")) }
    }

    @Test func testEntityExpansionBombFailsFastWithoutNotes() throws {
        var entities = "<!ENTITY a0 \"lol lol lol lol lol lol lol lol lol lol\">"
        for level in 1...9 {
            let previous = (0..<10).map { _ in "&a\(level - 1);" }.joined()
            entities += "<!ENTITY a\(level) \"\(previous)\">"
        }
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE en-export [\(entities)]><en-export><note><title>&a9;</title></note></en-export>"
        let url = try scratch.write("Bomb.enex", xml)
        let started = Date()
        let report = try run(url)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(report.created == 0)
        #expect(try allNotes().isEmpty)
    }

    @Test func testMediaElementVariants() throws {
        let data = Data("variant".utf8)
        let hash = EvernoteImporter.md5Hex(data)
        let url = try writeENEX("Variants.enex", notes: [
            noteXML(
                title: "N",
                body: "<div><en-media type='text/plain' style=\"height:1px\" hash='\(hash)'></en-media></div><div><en-media width=\"5\" hash=\"\(hash)\" type=\"text/plain\" /></div>",
                resources: [resourceXML(data, mime: "text/plain", fileName: "v.txt")])
        ])
        let report = try run(url)
        #expect(report.attachmentsCopied == 1)
        let note = try #require(try allNotes().first)
        let link = "[v.txt](v.txt) <!-- {\"embed\":\"true\"} -->"
        #expect(note.text == "# N\n\n\(link)\n\(link)\n\n#evernote/Variants")
    }

    @Test func testMissingFileIsReported() throws {
        let report = try run(scratch.url.appendingPathComponent("Nope.enex"))
        #expect(report.errors == ["Nope.enex: not found"])
    }

    @Test func testOversizedNoteBodyIsAnErrorNotACrash() throws {
        let url = try writeENEX("Huge.enex", notes: [
            noteXML(title: "Big", body: "<div>\(String(repeating: "x", count: 5_000))</div>"),
            noteXML(title: "Small", body: "<div>fine</div>"),
        ])
        let report = try run(url, limits: ENEXLimits(resource: 1 << 20, run: 1 << 20, content: 1_000))
        #expect(report.created == 1)
        #expect(report.errors == ["Huge.enex: note 1: the note body is too large (over 0 MB)"])
    }

    // MARK: - Streaming and cancellation

    /// 1,000 notes with an attachment each; the parser must have read only about one block of the file
    /// when the first notes are done, so no whole-file buffering happens.
    @Test func testThousandNotesAreReadAsAStream() throws {
        let count = 1_000
        let payload = Data((0..<12_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var notes: [String] = []
        for n in 0..<count {
            var data = payload
            data.append(contentsOf: Array("\(n)".utf8))
            notes.append(noteXML(
                title: "Note \(n)",
                body: "<div>Photo \(n)</div><en-media hash=\"\(EvernoteImporter.md5Hex(data))\" type=\"image/png\"/>",
                resources: [resourceXML(data, mime: "image/png", fileName: "p\(n).png")]))
        }
        let url = try writeENEX("Many.enex", notes: notes)
        let fileSize = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(fileSize > 15_000_000)

        let stream = CountingInputStream(file: url)
        var readAtFirst = 0, readAtTen = 0, readAtEnd = 0
        let report = importer().importStream(
            stream, notebook: "Many", label: "Many.enex", total: count, options: FileImportOptions(),
            progress: { done, total in
                #expect(total == count)
                if done == 1 { readAtFirst = stream.bytesRead }
                if done == 10 { readAtTen = stream.bytesRead }
                if done == count { readAtEnd = stream.bytesRead }
            },
            isCancelled: { false })

        #expect(report.created == count)
        #expect(report.attachmentsCopied == count)
        #expect(report.errors.isEmpty)
        // The parser reads in blocks of up to 512 KiB; a whole-file read would show the file size here.
        #expect(readAtFirst <= 1 << 20)
        #expect(readAtTen <= 1 << 20)
        #expect(readAtEnd > fileSize * 9 / 10)
    }

    @Test func testNoteCountForProgress() throws {
        #expect(EvernoteImporter.countNotes(in: fixture("Travel.enex")) == 2)
        #expect(EvernoteImporter.countNotes(in: fixture("Media.enex")) == 1)
    }

    @Test func testProgressStartsAtZeroAndReachesTheCount() throws {
        var calls: [[Int]] = []
        try importer().importFile(fixture("Travel.enex"), progress: { calls.append([$0, $1]) })
        #expect(calls == [[0, 2], [1, 2], [2, 2]])
    }

    @Test func testCancellationBetweenNotes() throws {
        let url = try writeENEX("Five.enex", notes: (1...5).map { noteXML(title: "N\($0)", body: "<div>\($0)</div>") })
        var done = 0
        let report = try importer().importFile(
            url, progress: { d, _ in done = d }, isCancelled: { done >= 2 })
        #expect(report.wasCancelled)
        #expect(report.created == 2)
        #expect(try allNotes().count == 2)
    }
}
