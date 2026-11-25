// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncImportReconciliationTests {
    func prepare(_ library: SyncMaterializerTests.Library, text: String) throws -> (Note, SyncNotePayload, SyncEntity) {
        let local = try library.store.create(text: text)
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO external_ref(source,externalId,noteId) VALUES('bear','source-note',?)", arguments: [local.id])
        }
        var remote = try library.db.pool.read { try SyncNotePayload.capture(id: local.id, in: $0)! }
        remote.id = "remote-note"
        let ref = SyncExternalRefPayload(source: "bear", externalId: "source-note", noteId: remote.id,
            lastSeenModified: nil, lastSeenHash: nil, lastSeenTextHash: nil, lastSeenMeta: nil, importedTextHash: nil)
        return (local, remote, try library.entity(ref, type: .externalRef, id: "source-reference", sequence: 2))
    }

    @Test func unpublishedExactSourceDuplicateCollapsesAndBackupPrivacyFollowsCanonicalIdentity() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (local, remote, ref) = try prepare(library, text: "# Same import\nExact Markdown #Work")
        try await library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES('backup','backup.zip',?,?)",
                           arguments: [Date(), String(decoding: try JSONEncoder().encode([local.id]), as: UTF8.self)])
            try db.execute(sql: "INSERT INTO note_ui_state(noteId,selection,scrollTop) VALUES(?,'{\"anchor\":3,\"head\":3}',12)", arguments: [local.id])
        }
        let note = try library.entity(remote, id: remote.id)
        try library.receive([note, ref])
        _ = try await library.materializer().apply(note)
        #expect(try await library.materializer().apply(ref) == .applied)
        #expect(try library.store.note(id: local.id) == nil)
        #expect(try library.store.note(id: remote.id)?.text == local.text)
        let state = try await library.db.pool.read { db in
            (try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source='bear'"),
             try String.fetchOne(db, sql: "SELECT plaintextNoteIds FROM backup_catalog WHERE id='backup'"),
             try Double.fetchOne(db, sql: "SELECT scrollTop FROM note_ui_state WHERE noteId='remote-note'"))
        }
        #expect(state.0 == remote.id)
        let ids = try JSONDecoder().decode([String].self, from: Data(#require(state.1).utf8))
        #expect(Set(ids) == [local.id, remote.id])
        #expect(state.2 == 12)
        // The duplicate note/source markers are consumed by reconciliation. The independently
        // captured local tag preference remains publishable after initial sync is enabled.
        let remaining = try await library.db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.entityType,d.tombstone,t.pathKey FROM sync_dirty d
                LEFT JOIN tag t ON d.entityType='tagPreference' AND t.id=d.localId
                """).map { (type: $0["entityType"] as String, path: $0["pathKey"] as String?, tombstone: $0["tombstone"] as Bool) }
        }
        #expect(remaining.count == 1)
        #expect(remaining.first?.type == "tagPreference")
        #expect(remaining.first?.path == "work")
        #expect(remaining.first?.tombstone == false)
        #expect(try !library.queue.isEnabled())
        #expect(try library.inbox.pending().isEmpty)
    }

    @Test(arguments: ["unicode", "journal", "retained-file"])
    func differingBytesOrUnrecoveredLocalDataPreserveBothImports(_ reason: String) async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let (local, original, ref) = try prepare(library, text: "Cafe\u{301}")
        var remote = original
        if reason == "unicode" { remote.text = "Café" }
        if reason == "journal" {
            try Data("pending recovery".utf8).write(to: library.paths.journal.appendingPathComponent(local.id + ".jsonl.unreplayed-1"))
        }
        if reason == "retained-file" {
            let dir = library.paths.attachments.appendingPathComponent(local.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("retained by undo".utf8).write(to: dir.appendingPathComponent("unlinked.txt"))
        }
        let note = try library.entity(remote, id: remote.id)
        try library.receive([note, ref]); _ = try await library.materializer().apply(note)
        #expect(try await library.materializer().apply(ref) == .applied)
        #expect(try library.store.note(id: local.id) != nil)
        #expect(try library.store.note(id: remote.id) != nil)
        #expect(try library.queue.pendingCount() == 1)
        #expect(try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT noteId FROM external_ref WHERE source='bear'") } == remote.id)
        if reason == "retained-file" {
            #expect(FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(local.id + "/unlinked.txt").path))
        }
    }

    @Test func cleanupMarkerSurvivesDatabaseReopenAndNeverRemovesAResurrectedNote() throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        let alive = try library.store.create(text: "Keep me")
        for id in ["removed-note", alive.id] {
            let directory = library.paths.attachments.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try library.db.pool.write { try $0.execute(sql: "INSERT INTO sync_import_cleanup(noteId) VALUES(?)", arguments: [id]) }
        }
        let reopened = try AppDatabase(path: library.paths.database); defer { try? reopened.pool.close() }
        try SyncMaterializer.recoverImportCleanup(database: reopened, paths: library.paths)
        #expect(!FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent("removed-note").path))
        #expect(FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(alive.id + "/file.txt").path))
        #expect(try reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_import_cleanup") } == 0)
    }
}
