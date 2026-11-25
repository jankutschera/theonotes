// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct BearImporterTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400) // 2026-10-21T12:00:00Z

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func importer(_ cli: FakeBearCLI) -> BearImporter {
        BearImporter(store: store, paths: tmp.paths, cli: cli, now: { [now] in now })
    }

    private func pull(_ cli: FakeBearCLI, cancelAfter: Int? = nil) throws -> BearImportReport {
        var calls = 0
        return try importer(cli).pull(progress: { done, _ in calls = done }, isCancelled: {
            guard let cancelAfter else { return false }
            return calls >= cancelAfter
        })
    }

    private func noteID(bearID: String) throws -> String {
        try #require(try store.externalRefs(source: "bear")[bearID]?.noteId)
    }

    private func note(bearID: String) throws -> Note {
        try #require(try store.note(id: noteID(bearID: bearID)))
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0) }
    }

    private func pinnedTags(_ noteId: String) throws -> [String] {
        try db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag.displayPath FROM note_pin JOIN tag ON tag.id = note_pin.tagId
                WHERE note_pin.noteId = ? ORDER BY tag.pathKey
                """, arguments: [noteId])
        }
    }

    static func record(
        _ id: String, _ content: String?, title: String = "", locked: Bool = false,
        modified: TimeInterval = 1_700_000_000, location: NoteLocation = .notes,
        pins: [BearPin] = [], attachments: [String] = []
    ) -> BearNoteRecord {
        BearNoteRecord(
            id: id, title: title, locked: locked, tags: [], created: Date(timeIntervalSince1970: 1_600_000_000),
            modified: Date(timeIntervalSince1970: modified), pins: pins, location: location,
            attachments: attachments, content: content)
    }

    private func stagingIsEmpty() -> Bool {
        let staging = AttachmentFiles(paths: tmp.paths, database: db).staging
        return ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty
    }

    @Test func testInitialImportPreservesFields() throws {
        let cli = FakeBearCLI(readOnly: ["SYN-0001"])
        let report = try pull(cli)
        #expect(report.created == 3)
        #expect(report.total == 3)
        #expect(report.lockedStubs == 1)
        #expect(report.attachmentsCopied == 1)
        #expect(report.errors.isEmpty)

        let a = try note(bearID: "SYN-0001")
        #expect(a.createdAt == Date(timeIntervalSince1970: 1_735_787_045))
        #expect(a.modifiedAt == Date(timeIntervalSince1970: 1_738_555_506))
        #expect(a.location == .notes)
        #expect(a.isPinnedGlobal)
        #expect(a.isReadOnly)
        #expect(a.text == "# Synthetic plain note\n\n#work #multi word# #work/sub\n\n- [ ] a\n- [x] b\n- [x] c")
        #expect(try pinnedTags(a.id) == ["work"])
        #expect(try tagRows(db, a.id) == [
            TagRow(path: "multi word", isDirect: true), TagRow(path: "work", isDirect: true),
            TagRow(path: "work/sub", isDirect: true),
        ])

        let b = try note(bearID: "SYN-0002")
        #expect(b.location == .trash)
        #expect(b.trashedAt == b.modifiedAt)
        #expect(b.modifiedAt == Date(timeIntervalSince1970: 1_717_327_800))
        #expect(!b.isPinnedGlobal && !b.isReadOnly)
        let photo = tmp.paths.attachments.appendingPathComponent("\(b.id)/photo 2.jpg")
        let expected = try Data(contentsOf: FakeBearCLI.fixtureDir.appendingPathComponent("attachments/SYN-0002/photo 2.jpg"))
        #expect(try Data(contentsOf: photo) == expected)

        let c = try note(bearID: "SYN-0003")
        #expect(c.location == .archive)
        #expect(c.archivedAt == c.modifiedAt)
        #expect(c.text == "# Synthetic locked note\n\nThis note is locked in Bear and could not be imported.")
        #expect(try tagRows(db, c.id).isEmpty)
        #expect(stagingIsEmpty())
    }

    @Test func testPullIsIdempotent() throws {
        let cli = FakeBearCLI(readOnly: ["SYN-0001"])
        _ = try pull(cli)
        let before = try allNotes()
        let report = try pull(cli)
        #expect(report == BearImportReport(total: 3, unchanged: 3))
        #expect(try allNotes() == before)
    }

    @Test func testBearOnlyChangeUpdatesInPlace() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0001")
        var records = cli.records
        records[0].content = "# Edited in Bear\n#home"
        records[0].modified = Date(timeIntervalSince1970: 1_750_000_000)
        records[0].pins = [.tag("home")]
        cli.records = records

        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.unchanged == 2)
        #expect(report.created == 0)
        let updated = try note(bearID: "SYN-0001")
        #expect(updated.id == original.id)
        #expect(updated.text == "# Edited in Bear\n#home")
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.modifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(!updated.isPinnedGlobal)
        #expect(try pinnedTags(updated.id) == ["home"])
        #expect(try allNotes().count == 3)
        #expect(try store.externalRefs(source: "bear")["SYN-0001"]?.importedRevision == updated.revision)
        #expect(try pull(cli).unchanged == 3)
    }

    /// bearcli lists a note's attachments in no stable order (seen live on Jan's library).
    @Test func testAttachmentOrderIsNotAChange() throws {
        let cli = FakeBearCLI(records: [Self.record("O1", "# O\n![](a.jpg)\n![](b.jpg)", attachments: ["a.jpg", "b.jpg"])])
        cli.setBlob(Data([1]), noteID: "O1", filename: "a.jpg")
        cli.setBlob(Data([2]), noteID: "O1", filename: "b.jpg")
        _ = try pull(cli)
        cli.records = [Self.record("O1", "# O\n![](a.jpg)\n![](b.jpg)", attachments: ["b.jpg", "a.jpg"])]
        #expect(try pull(cli) == BearImportReport(total: 1, unchanged: 1))
    }

    @Test func testBearFlagOnlyChangeUpdates() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        cli.readOnly = ["SYN-0002"]
        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(try note(bearID: "SYN-0002").isReadOnly)
    }

    private func editInBear(_ cli: FakeBearCLI, _ index: Int, content: String? = nil, modified: TimeInterval,
                            location: NoteLocation? = nil) {
        var records = cli.records
        if let content { records[index].content = content }
        if let location { records[index].location = location }
        records[index].modified = Date(timeIntervalSince1970: modified)
        cli.records = records
    }

    @Test func testBothChangedCreatesConflictCopy() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0001")
        _ = try store.updateText(id: original.id, text: "# Edited in Baerchen", expectedRevision: original.revision)
        editInBear(cli, 0, content: "# Edited in Bear\nbody", modified: 1_750_000_000)

        let report = try pull(cli)
        #expect(report.conflicts == 1)
        #expect(report.updated == 0)
        #expect(try store.note(id: original.id)?.text == "# Edited in Baerchen")
        let copy = try note(bearID: "SYN-0001")
        #expect(copy.id != original.id)
        #expect(copy.text == "# Edited in Bear (Bear conflict \(BearImporter.localDay(now)))\nbody")
        #expect(copy.modifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(try allNotes().count == 4)
        #expect(try pull(cli).unchanged == 3)

        // The ref moved to the copy: the next Bear edit updates the copy, no second copy.
        editInBear(cli, 0, content: "# Edited in Bear again", modified: 1_760_000_000)
        let next = try pull(cli)
        #expect(next.updated == 1)
        #expect(next.conflicts == 0)
        #expect(try note(bearID: "SYN-0001").id == copy.id)
        #expect(try note(bearID: "SYN-0001").text == "# Edited in Bear again")
        #expect(try store.note(id: original.id)?.text == "# Edited in Baerchen")
        #expect(try allNotes().count == 4)
    }

    @Test func testLocalMetadataChangeThenBearEditUpdatesInPlace() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0002")
        try store.setPinned([original.id], pinned: true)
        try store.restore([original.id])
        editInBear(cli, 1, content: "# Appended on iPhone\n[photo 2.jpg](photo%202.jpg)\nmore", modified: 1_750_000_000)

        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.conflicts == 0)
        let updated = try note(bearID: "SYN-0002")
        #expect(updated.id == original.id)
        #expect(updated.text.hasPrefix("# Appended on iPhone"))
        #expect(updated.modifiedAt == Date(timeIntervalSince1970: 1_750_000_000))
        // Bear's metadata did not change, so the local pin and restore stay.
        #expect(updated.isPinnedGlobal)
        #expect(updated.location == .notes)
        #expect(try allNotes().count == 3)
    }

    @Test func testBearMetadataOnlyChangeKeepsLocalText() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0001")
        let edited = try store.updateText(id: original.id, text: "# Local edit #work", expectedRevision: original.revision)
        editInBear(cli, 0, modified: 1_738_555_506, location: .archive)
        cli.readOnly = ["SYN-0001"]

        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.conflicts == 0)
        let updated = try #require(try store.note(id: original.id))
        #expect(updated.text == "# Local edit #work")
        #expect(updated.location == .archive)
        #expect(updated.isReadOnly)
        #expect(updated.modifiedAt == edited.modifiedAt)
        #expect(try allNotes().count == 3)
        #expect(try pull(cli).unchanged == 3)

        // Bear's text then changes: the local text edit still wins with a copy.
        editInBear(cli, 0, content: "# Bear text", modified: 1_750_000_000)
        #expect(try pull(cli).conflicts == 1)
        #expect(try store.note(id: original.id)?.text == "# Local edit #work")
    }

    private func makeConflict(_ cli: FakeBearCLI) throws -> (original: Note, copy: Note) {
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0001")
        _ = try store.updateText(id: original.id, text: "# Edited in Baerchen #work", expectedRevision: original.revision)
        editInBear(cli, 0, content: "# Edited in Bear\nbody #work", modified: 1_750_000_000)
        #expect(try pull(cli).conflicts == 1)
        return (original, try note(bearID: "SYN-0001"))
    }

    @Test func testUntouchedConflictCopyKeepsMarkerOnBearMetadataChange() throws {
        let cli = FakeBearCLI()
        let (_, copy) = try makeConflict(cli)
        editInBear(cli, 0, modified: 1_750_000_000, location: .archive)
        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.conflicts == 0)
        let after = try #require(try store.note(id: copy.id))
        #expect(after.text == copy.text)
        #expect(after.text.contains("(Bear conflict "))
        #expect(after.location == .archive)
        #expect(try allNotes().count == 4)
    }

    @Test func testEditedConflictCopyGetsNoSecondCopyOnBearMetadataChange() throws {
        let cli = FakeBearCLI()
        let (_, copy) = try makeConflict(cli)
        let edited = try store.updateText(id: copy.id, text: "# Edited in Bear\nbody #work\nmine", expectedRevision: copy.revision)
        editInBear(cli, 0, modified: 1_750_000_000, location: .archive)
        let report = try pull(cli)
        #expect(report.conflicts == 0)
        #expect(report.updated == 1)
        let after = try #require(try store.note(id: copy.id))
        #expect(after.text == edited.text)
        #expect(after.location == .archive)
        #expect(try note(bearID: "SYN-0001").id == copy.id)
        #expect(try allNotes().count == 4)
    }

    @Test func testLocalPinSurvivesBearArchive() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0002")
        try store.setPinned([original.id], pinned: true)
        editInBear(cli, 1, modified: 1_717_327_800, location: .archive)
        let report = try pull(cli)
        #expect(report.updated == 1)
        let after = try #require(try store.note(id: original.id))
        #expect(after.location == .archive)
        #expect(after.isPinnedGlobal)
    }

    @Test func testBearTagPinChangeKeepsLocalReadOnlyAndLocation() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let original = try note(bearID: "SYN-0001")
        try store.archive([original.id])
        var records = cli.records
        records[0].pins = [.global, .tag("work/sub")]
        cli.records = records
        let report = try pull(cli)
        #expect(report.updated == 1)
        let after = try #require(try store.note(id: original.id))
        #expect(after.location == .archive)
        #expect(after.isPinnedGlobal)
        #expect(try pinnedTags(original.id) == ["work/sub"])
    }

    @Test func testPermanentDeleteIsNotReimported() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        try store.deletePermanently([try noteID(bearID: "SYN-0002")])
        let report = try pull(cli)
        #expect(report.created == 0)
        #expect(report.deletedInTheoNotes == 1)
        #expect(report.unchanged == 2)
        #expect(try allNotes().count == 2)
        editInBear(cli, 1, content: "# changed", modified: 1_750_000_000)
        #expect(try pull(cli).deletedInTheoNotes == 1)
        #expect(try allNotes().count == 2)
    }

    /// A permanent delete that lands while the pull fetches attachments keeps the tombstone:
    /// neither the in-place update nor the conflict copy brings the note back.
    @Test func testPermanentDeleteDuringPullKeepsTheTombstone() throws {
        let cli = FakeBearCLI(records: [
            Self.record("D1", "# One\n![](a.jpg)", attachments: ["a.jpg"]),
            Self.record("D2", "# Two\n![](a.jpg)", attachments: ["a.jpg"]),
        ])
        for id in ["D1", "D2"] { cli.setBlob(Data([1]), noteID: id, filename: "a.jpg") }
        _ = try pull(cli)
        let one = try noteID(bearID: "D1"), two = try noteID(bearID: "D2")
        let twoNote = try #require(try store.note(id: two))
        _ = try store.updateText(id: two, text: "# Two edited here", expectedRevision: twoNote.revision)
        editInBear(cli, 0, content: "# One from Bear\n![](a.jpg)", modified: 1_750_000_000)  // in place
        editInBear(cli, 1, content: "# Two from Bear\n![](a.jpg)", modified: 1_750_000_000)  // conflict copy
        cli.onAttachmentData = { [store] bearID, _ in
            try? store.deletePermanently([bearID == "D1" ? one : two])
        }

        let report = try pull(cli)
        #expect(report.deletedInTheoNotes == 2)
        #expect(report.errors.isEmpty)
        #expect(report.conflicts == 0)
        #expect(try allNotes().isEmpty)
        let refs = try store.externalRefs(source: "bear")
        #expect(refs["D1"]?.noteId == nil && refs["D1"] != nil)
        #expect(refs["D2"]?.noteId == nil && refs["D2"] != nil)
        #expect(stagingIsEmpty())
        cli.onAttachmentData = nil
        #expect(try pull(cli).deletedInTheoNotes == 2)
        #expect(try allNotes().isEmpty)
    }

    /// Locking a note in Bear after the import: the Bear side is now the stub, so an unedited
    /// note gets the stub text (the plain text leaves Theo Notes too), with a warning. Its attachment
    /// files stay until the app's cleanup (eviction or launch, ruling R23) finds them unreferenced.
    @Test func testNoteLockedInBearAfterImport() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let id = try noteID(bearID: "SYN-0002")
        var records = cli.records
        records[1].locked = true
        records[1].content = nil
        records[1].modified = Date(timeIntervalSince1970: 1_750_000_000)
        cli.records = records

        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.lockedStubs == 1)
        #expect(report.warnings == ["SYN-0002: locked in Bear since the last pull; the text was replaced by the locked stub"])
        let note = try #require(try store.note(id: id))
        #expect(note.text == BearImporter.lockedStub(title: "Synthetic trashed note with file"))
        let file = tmp.paths.attachments.appendingPathComponent(id).appendingPathComponent("photo 2.jpg")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let again = try pull(cli)
        #expect(again.unchanged == 3)
        #expect(again.warnings.isEmpty)
    }

    @Test func testUnlockedNoteWithoutContentIsAnError() throws {
        let cli = FakeBearCLI(records: [Self.record("U1", nil, title: "Empty"), Self.record("U2", "# ok")])
        let report = try pull(cli)
        #expect(report.created == 1)
        #expect(report.errors == ["U1: bearcli returned no content for an unlocked note"])
    }

    @Test func testConflictTitleSuffix() {
        let day = "2026-10-21"
        #expect(BearImporter.markingConflict("# T\nx", day: day) == "# T (Bear conflict 2026-10-21)\nx")
        #expect(BearImporter.markingConflict("T", day: day) == "T (Bear conflict 2026-10-21)")
        #expect(BearImporter.markingConflict("---\na: 1\n---\n# T\nb", day: day)
            == "---\na: 1\n---\n# T (Bear conflict 2026-10-21)\nb")
        #expect(BearImporter.markingConflict("", day: day) == "Bear conflict 2026-10-21")
        #expect(BearImporter.markingConflict("\nbody", day: day) == "Bear conflict 2026-10-21\n\nbody")
        #expect(BearImporter.markingConflict("```swift\nx\n```", day: day) == "Bear conflict 2026-10-21\n```swift\nx\n```")
        #expect(TagScanner.tags(inLine: BearImporter.markingConflict("# T #a", day: day)) == ["a"])
    }

    @Test func testAttachmentNamesPreserved() throws {
        let content = "# Files\n![](photo%202.jpg)\n[Ünïcode.pdf](%C3%9Cn%C3%AFcode.pdf)<!-- {\"embed\":\"true\"} -->"
        let cli = FakeBearCLI(records: [Self.record("F1", content, attachments: ["photo 2.jpg", "Ünïcode.pdf"])])
        let photo = Data((0..<256).map { UInt8($0) })
        let pdf = Data("%PDF-1.4 \u{0}\u{FF}".utf8)
        cli.setBlob(photo, noteID: "F1", filename: "photo 2.jpg")
        cli.setBlob(pdf, noteID: "F1", filename: "Ünïcode.pdf")

        let report = try pull(cli)
        #expect(report.attachmentsCopied == 2)
        let id = try noteID(bearID: "F1")
        let dir = tmp.paths.attachments.appendingPathComponent(id)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.utf8.elementsEqual("photo 2.jpg".utf8) })
        #expect(names.contains { $0.utf8.elementsEqual("Ünïcode.pdf".utf8) })
        #expect(try Data(contentsOf: dir.appendingPathComponent("photo 2.jpg")) == photo)
        #expect(try Data(contentsOf: dir.appendingPathComponent("Ünïcode.pdf")) == pdf)
        let linked = NoteParser.metadata(for: try note(bearID: "F1").text).attachments.map(\.filename)
        #expect(linked.count == 2)
        for name in linked {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
    }

    @Test func testLockedNoteBecomesStub() throws {
        let cli = FakeBearCLI(records: [
            Self.record("L1", nil, title: "Plans #work", locked: true, location: .notes, pins: [.global, .tag("work")]),
        ])
        let report = try pull(cli)
        #expect(report.lockedStubs == 1)
        #expect(report.created == 1)
        let stub = try note(bearID: "L1")
        #expect(stub.text == "# Plans \\#work\n\nThis note is locked in Bear and could not be imported.")
        #expect(try tagRows(db, stub.id).isEmpty)
        #expect(try pinnedTags(stub.id).isEmpty)
        #expect(stub.isPinnedGlobal)
        #expect(report.warnings == ["L1: pin in tag 'work' skipped (the note does not carry that tag)"])
        #expect(report.errors.isEmpty)
        #expect(try pull(cli).lockedStubs == 0)
    }

    @Test func testTagPinWithoutTagIsSkippedAndReported() throws {
        let cli = FakeBearCLI(records: [Self.record("P1", "# P\n#a", pins: [.tag("a"), .tag("gone")])])
        let report = try pull(cli)
        #expect(report.created == 1)
        #expect(report.warnings == ["P1: pin in tag 'gone' skipped (the note does not carry that tag)"])
        #expect(report.errors.isEmpty)
        #expect(try pinnedTags(noteID(bearID: "P1")) == ["a"])
    }

    @Test func testFailureMidRunKeepsImportedNotes() throws {
        let cli = FakeBearCLI(records: (1...4).map { Self.record("R\($0)", "# Note \($0)\n![](a.jpg)", attachments: ["a.jpg"]) })
        for i in 1...4 { cli.setBlob(Data([UInt8(i)]), noteID: "R\(i)", filename: "a.jpg") }
        cli.fail(noteID: "R3", filename: "a.jpg")

        let report = try pull(cli)
        #expect(report.created == 3)
        #expect(report.errors == ["R3: bearcli exited with code 1: simulated failure"])
        #expect(try store.externalRefs(source: "bear")["R3"] == nil)
        #expect(try allNotes().count == 3)
        #expect(!(try allNotes()).contains { $0.text.hasPrefix("# Note 3") })
        #expect(stagingIsEmpty())
        let dirs = try FileManager.default.contentsOfDirectory(atPath: tmp.paths.attachments.path).filter { !$0.hasPrefix(".") }
        #expect(dirs.count == 3)

        cli.clearFailures()
        let retry = try pull(cli)
        #expect(retry.created == 1)
        #expect(retry.unchanged == 3)
    }

    @Test func testListFailureThrows() throws {
        struct Broken: BearCLIClient {
            func listAll() throws -> BearNoteList { throw BearCLIError.notInstalled }
            func readOnlyIDs() throws -> Set<String> { [] }
            func attachmentData(noteID: String, filename: String) throws -> Data { Data() }
        }
        let importer = BearImporter(store: store, paths: tmp.paths, cli: Broken())
        #expect(throws: BearCLIError.notInstalled) { _ = try importer.pull(progress: { _, _ in }, isCancelled: { false }) }
    }

    @Test func testUndecodableRecordsAreReported() throws {
        let cli = FakeBearCLI()
        cli.listErrors = ["X9: invalid value for field 'location'"]
        let report = try pull(cli)
        #expect(report.created == 3)
        #expect(report.errors == ["X9: invalid value for field 'location'"])
    }

    @Test func testCancelStopsBetweenNotes() throws {
        let cli = FakeBearCLI(records: (1...5).map { Self.record("C\($0)", "# C\($0)") })
        var seen: [(Int, Int)] = []
        var done = 0
        let report = try importer(cli).pull(
            progress: { d, t in seen.append((d, t)); done = d },
            isCancelled: { done >= 2 })
        #expect(report.wasCancelled)
        #expect(report.created == 2)
        #expect(try allNotes().count == 2)
        #expect(seen.map(\.0) == [0, 1, 2])
        #expect(seen.allSatisfy { $0.1 == 5 })
    }

    @Test func testMissingInBearCounted() throws {
        let cli = FakeBearCLI()
        _ = try pull(cli)
        let kept = try note(bearID: "SYN-0002")
        cli.records = cli.records.filter { $0.id != "SYN-0002" }
        let report = try pull(cli)
        #expect(report.missingInBear == 1)
        #expect(report.unchanged == 2)
        #expect(try store.note(id: kept.id) == kept)
    }

    @Test func testLiveBearDryRunIntoTempDir() throws {
        guard ProcessInfo.processInfo.environment["BAERCHEN_LIVE_BEAR"] == "1" else { return }
        #expect(tmp.paths.root.path != AppPaths.production.root.path)
        let fileDB = try AppDatabase(path: tmp.paths.database)
        let liveStore = NoteStore(db: fileDB, notifier: nil, paths: tmp.paths)
        let importer = BearImporter(store: liveStore, paths: tmp.paths, cli: ProcessBearCLI(executable: ProcessBearCLI.defaultPath))
        let first = try importer.pull(progress: { _, _ in }, isCancelled: { false })
        let second = try importer.pull(progress: { _, _ in }, isCancelled: { false })
        let counts = try fileDB.pool.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE location = 'notes'") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE location = 'archive'") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE location = 'trash'") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT noteId) FROM note_stats WHERE hasImages OR hasFiles") ?? 0)
        }
        print("LIVE_PULL1 total=\(first.total) created=\(first.created) locked=\(first.lockedStubs) attachments=\(first.attachmentsCopied) errors=\(first.errors.count)")
        print("LIVE_PULL1_WARNINGS \(first.warnings.count)")
        print("LIVE_PULL2 total=\(second.total) unchanged=\(second.unchanged) created=\(second.created) updated=\(second.updated) conflicts=\(second.conflicts)")
        print("LIVE_DB notes=\(counts.0) archive=\(counts.1) trash=\(counts.2) tags=\(counts.3) notesWithAttachments=\(counts.4)")
        for error in first.errors { print("LIVE_ERROR \(error)") }
        #expect(second.created + second.updated + second.conflicts == 0)
    }
}
