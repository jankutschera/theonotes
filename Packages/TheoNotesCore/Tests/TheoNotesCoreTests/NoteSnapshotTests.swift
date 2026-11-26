// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Per-note history: snapshots of unlocked notes, their retention, Restore as Copy and
/// Replace This Note. The locked-note side is `SnapshotPrivacyTests`.
@Suite struct NoteSnapshotTests {
    static let day: TimeInterval = 86_400
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func rows(_ noteId: String, in db: AppDatabase) throws -> [(id: String, text: String?)] {
        try db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text FROM note_snapshot WHERE noteId = ? ORDER BY takenAt, id", arguments: [noteId])
                .map { (id: $0["id"] as String, text: $0["text"] as String?) }
        }
    }

    @Test func takeSkipsTextEqualToTheNewest() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")

        let first = try #require(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\nA", now: Self.start))
        #expect(first.noteId == note.id && !first.isSealed && first.preview == "Plan")
        #expect(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\nA", now: Self.start + 60) == nil)
        #expect(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\nB", now: Self.start + 120) != nil)
        // Only the newest counts: going back to an older text is a new snapshot.
        #expect(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\nA", now: Self.start + 180) != nil)

        #expect(try Self.rows(note.id, in: library.db).map(\.text) == ["# Plan\nA", "# Plan\nB", "# Plan\nA"])
        let listed = try library.store.snapshots(noteId: note.id)
        #expect(listed.map(\.takenAt) == [Self.start + 180, Self.start + 120, Self.start])
        #expect(try library.store.snapshotText(id: first.id) == "# Plan\nA")
    }

    @Test func retentionKeepsTwentyNewestPlusTheFloor() throws {
        let now = Self.start + 60 * Self.day
        // 30 snapshots, one every two days, over the last 60 days.
        let items = (0..<30).map { (id: "s\($0)", takenAt: Self.start + Double($0) * 2 * Self.day) }
        let survivors = SnapshotRetention.survivors(items, now: now)
        #expect(survivors.count == 21)
        #expect(survivors == Set((10..<30).map { "s\($0)" } + ["s0"]))

        // The store prunes on every take, by the same rule.
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan")
        var ids: [String] = []
        for (index, item) in items.enumerated() {
            let taken = try #require(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\n\(index)", now: item.takenAt))
            ids.append(taken.id)
        }
        let kept = Set(try Self.rows(note.id, in: library.db).map(\.id))
        #expect(kept.count == 21)
        #expect(kept == Set(ids[10...] + [ids[0]]))
    }

    @Test func retentionDropsEverythingOlderThanNinetyDays() {
        let now = Self.start + 200 * Self.day
        let items = [
            (id: "edge", takenAt: now - 90 * Self.day),
            (id: "old", takenAt: now - 91 * Self.day),
            (id: "older", takenAt: now - 150 * Self.day),
            (id: "young", takenAt: now - 10 * Self.day),
        ]
        // At most 90 days old stays (the edge is the floor); older goes even when it is the oldest.
        #expect(SnapshotRetention.survivors(items, now: now) == ["edge", "young"])
        #expect(SnapshotRetention.survivors(Array(items[1...2]), now: now).isEmpty)
        #expect(SnapshotRetention.maxCount == 20)
        #expect(SnapshotRetention.maxAge == 90 * 86_400)
    }

    @Test func restoreAsCopyLeavesTheSourceByteIdentical() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        var note = try library.store.create(text: "# Plan\nfirst draft", now: Self.start)
        let snapshot = try #require(try library.store.takeSnapshot(noteId: note.id, text: note.text, now: Self.start))
        note = try library.store.updateText(id: note.id, text: "# Plan\nsecond draft", expectedRevision: note.revision, now: Self.start + 60)
        let before = try #require(try library.store.note(id: note.id))
        let rowsBefore = try Self.rows(note.id, in: library.db)

        let copy = try library.store.restoreSnapshotAsCopy(id: snapshot.id, now: Self.start + 120)

        #expect(copy.id != note.id)
        #expect(copy.text == "# Plan\nfirst draft")
        #expect(copy.location == .notes)
        #expect(try library.store.note(id: note.id) == before)
        #expect(try Self.rows(note.id, in: library.db).map(\.id) == rowsBefore.map(\.id))
        #expect(try Self.rows(copy.id, in: library.db).isEmpty)
    }

    @Test func restoreAsCopyBringsTheAttachments() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n![](photo.png)")
        let bytes = Data("fixture image bytes".utf8)
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: bytes, filename: "photo.png", to: note.id)
        let snapshot = try #require(try library.store.takeSnapshot(noteId: note.id, text: "# Plan\n![](photo.png)", now: Self.start))

        let copy = try library.store.restoreSnapshotAsCopy(id: snapshot.id, now: Self.start + 60)

        let copied = library.paths.attachments.appendingPathComponent(copy.id).appendingPathComponent("photo.png")
        #expect(try Data(contentsOf: copied) == bytes)
        let original = library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("photo.png")
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func replaceSnapshotsTheCurrentTextFirst() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        var note = try library.store.create(text: "# Plan\nold", now: Self.start)
        let old = try #require(try library.store.takeSnapshot(noteId: note.id, text: note.text, now: Self.start))
        note = try library.store.updateText(id: note.id, text: "# Plan\nnew", expectedRevision: note.revision, now: Self.start + 60)

        let replaced = try library.store.replaceNote(withSnapshot: old.id, expectedRevision: note.revision, now: Self.start + 120)

        #expect(replaced.text == "# Plan\nold")
        #expect(replaced.revision == note.revision + 1)
        #expect(try library.store.note(id: note.id)?.text == "# Plan\nold")
        // The text the replace overwrote is now the newest snapshot.
        #expect(try Self.rows(note.id, in: library.db).map(\.text) == ["# Plan\nold", "# Plan\nnew"])
        let newest = try #require(try library.store.snapshots(noteId: note.id).first)
        #expect(newest.takenAt == Self.start + 120)
        #expect(try library.store.snapshotText(id: newest.id) == "# Plan\nnew")
    }

    @Test func replaceWithAStaleRevisionThrowsRevisionConflict() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        var note = try library.store.create(text: "# Plan\nold", now: Self.start)
        let old = try #require(try library.store.takeSnapshot(noteId: note.id, text: note.text, now: Self.start))
        let stale = note.revision
        note = try library.store.updateText(id: note.id, text: "# Plan\nnew", expectedRevision: note.revision, now: Self.start + 60)
        let rowsBefore = try Self.rows(note.id, in: library.db)

        #expect(throws: StoreError.revisionConflict(current: note.revision)) {
            try library.store.replaceNote(withSnapshot: old.id, expectedRevision: stale, now: Self.start + 120)
        }

        #expect(try library.store.note(id: note.id) == note)
        #expect(try Self.rows(note.id, in: library.db).map(\.id) == rowsBefore.map(\.id))
    }

    @Test func snapshotsNeverReachTheMarkdown() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\ncurrent", now: Self.start)
        let marker = "history" + UUID().uuidString
        _ = try library.store.takeSnapshot(noteId: note.id, text: "# Plan\n\(marker)", now: Self.start)

        // Taking a snapshot is not an edit of the note.
        #expect(try library.store.note(id: note.id) == note)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: destination) }
        let exporter = NoteExporter(store: library.store, paths: library.paths)
        for format in FileExportFormat.allCases {
            let files = try exporter.write(ExportItem(noteId: note.id, folder: [format.rawValue], stem: "Plan"),
                                           format: format, under: destination, options: ExportOptions())
            #expect(try PrivacyCanaryScanner(markers: ["history": marker]).files(in: files.primary.deletingLastPathComponent()).isEmpty)
        }
        #expect(try PrivacyCanaryScanner(markers: ["current": "current"]).files(in: destination) == ["current"])
    }
}
