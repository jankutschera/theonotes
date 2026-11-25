// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// A Bear pull that rewrites a note while an open session holds unsaved edits to it (review I1).
@MainActor
@Suite struct PullSessionRaceTests {
    let tmp: TempPaths
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        store = NoteStore(db: try AppDatabase.inMemory(), notifier: nil, paths: tmp.paths)
    }

    private func pull(_ cli: FakeBearCLI) throws -> BearImportReport {
        try BearImporter(store: store, paths: tmp.paths, cli: cli, now: { Date(timeIntervalSince1970: 1_792_670_400) })
            .pull(progress: { _, _ in }, isCancelled: { false })
    }

    private static func record(_ content: String, attachments: [String], modified: TimeInterval) -> BearNoteRecord {
        BearNoteRecord(
            id: "B1", title: "Photo", locked: false, tags: [], created: Date(timeIntervalSince1970: 1_600_000_000),
            modified: Date(timeIntervalSince1970: modified), pins: [], location: .notes,
            attachments: attachments, content: content)
    }

    /// Attachment links of the note whose file is missing from `Attachments/<id>/`.
    private func danglingLinks(_ noteId: String) throws -> [String] {
        let note = try #require(try store.note(id: noteId))
        let dir = tmp.paths.attachments.appendingPathComponent(noteId, isDirectory: true)
        return NoteParser.metadata(for: note.text).attachments.map(\.filename).filter {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private func replace(_ text: String, _ target: String, with replacement: String) -> ChangeSet {
        let ns = text as NSString
        let range = ns.range(of: target)
        var sections: [ChangeSet.Section] = []
        if range.location > 0 { sections.append(.retain(range.location)) }
        sections.append(.replace(deleteLength: range.length, insert: replacement))
        let tail = ns.length - range.location - range.length
        if tail > 0 { sections.append(.retain(tail)) }
        return ChangeSet(sections: sections)
    }

    @Test func testPullRacingAnUnsavedSessionKeepsImagesInBothNotes() throws {
        let original = "# Photo\n\n![](a.jpg)\nline"
        let cli = FakeBearCLI(records: [Self.record(original, attachments: ["a.jpg"], modified: 1_700_000_000)])
        cli.setBlob(Data([1]), noteID: "B1", filename: "a.jpg")
        #expect(try pull(cli).created == 1)
        let noteId = try #require(try store.externalRefs(source: "bear")["B1"]?.noteId)

        // Jan types in the open note; the debounce keeps the session dirty (TestClock never fires).
        let session = try NoteSession(noteId: noteId, store: store, journalDirectory: tmp.paths.journal, clock: TestClock())
        var copies: [String] = []
        _ = session.addConflictCopyListener { copies.append($0) }
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: replace(original, "line", with: "local line"), origin: nil)
            == .acked(revision: 1))

        // Meanwhile on the iPhone: a.jpg replaced by b.jpg, the same line edited.
        let bear = "# Photo\n\n![](b.jpg)\nbear line"
        cli.records = [Self.record(bear, attachments: ["b.jpg"], modified: 1_750_000_000)]
        cli.setBlob(Data([2]), noteID: "B1", filename: "b.jpg")
        #expect(try pull(cli).updated == 1)

        // The session's next commit conflicts and keeps Bear's text as a copy.
        try session.flush()
        let copyId = try #require(copies.first)
        #expect(copies.count == 1)
        #expect(try store.note(id: noteId)?.text == "# Photo\n\n![](a.jpg)\nlocal line")
        #expect(try store.note(id: copyId)?.text == bear)
        #expect(try danglingLinks(noteId) == [])
        #expect(try danglingLinks(copyId) == [])

        // The copy holds exactly what Bear last wrote, so it takes over the Bear ref.
        #expect(try store.externalRefs(source: "bear")["B1"]?.noteId == copyId)
        #expect(try pull(cli).unchanged == 1)
        let next = "# Photo\n\n![](b.jpg)\nbear line 2"
        cli.records = [Self.record(next, attachments: ["b.jpg"], modified: 1_760_000_000)]
        let report = try pull(cli)
        #expect(report.updated == 1)
        #expect(report.conflicts == 0)
        #expect(try store.note(id: copyId)?.text == next)
        #expect(try store.note(id: noteId)?.text == "# Photo\n\n![](a.jpg)\nlocal line")
        #expect(try danglingLinks(copyId) == [])
        #expect(try store.allNotes().count == 2)
    }

    /// The same race, resolved by launch recovery (the app quit before the session committed).
    @Test func testRecoveryConflictCopyKeepsImagesAndTakesTheRef() throws {
        let original = "# Photo\n\n![](a.jpg)\nline"
        let cli = FakeBearCLI(records: [Self.record(original, attachments: ["a.jpg"], modified: 1_700_000_000)])
        cli.setBlob(Data([1]), noteID: "B1", filename: "a.jpg")
        _ = try pull(cli)
        let noteId = try #require(try store.externalRefs(source: "bear")["B1"]?.noteId)
        do {
            let session = try NoteSession(noteId: noteId, store: store, journalDirectory: tmp.paths.journal, clock: TestClock())
            _ = session.apply(txId: "t1", baseRevision: 0, changeSet: replace(original, "line", with: "local line"), origin: nil)
        }
        let bear = "# Photo\n\n![](b.jpg)\nbear line"
        cli.records = [Self.record(bear, attachments: ["b.jpg"], modified: 1_750_000_000)]
        cli.setBlob(Data([2]), noteID: "B1", filename: "b.jpg")
        #expect(try pull(cli).updated == 1)

        let recovered = try NoteSession(noteId: noteId, store: store, journalDirectory: tmp.paths.journal, clock: TestClock())
        let copyId = try #require(recovered.recoveryConflictCopyId)
        #expect(try store.note(id: copyId)?.text == bear)
        #expect(try danglingLinks(noteId) == [])
        #expect(try danglingLinks(copyId) == [])
        #expect(try store.externalRefs(source: "bear")["B1"]?.noteId == copyId)
    }
}
