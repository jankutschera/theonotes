// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncPayloadTests {
    @Test func capturesPortableSemanticsAndKeepsLockedBodyInnerEncrypted() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-payload-\(UUID())"))
        try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let store = NoteStore(db: db, notifier: nil, paths: paths)
        let text = "# Exact title\nsecret body\n#work"
        let note = try store.create(text: text, now: Date(timeIntervalSince1970: 1_234.567))
        try store.setPinned([note.id], pinned: true, inTag: "work")
        try store.archive([note.id])
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_ui_state(noteId,selection,scrollTop) VALUES(?,'[2,4]',72)", arguments: [note.id])
        }
        let captured = try #require(try db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) })
        #expect(captured.text == text && captured.createdAt == 1_234_567)
        #expect(captured.location == .archive && captured.pinnedTags == ["work"])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        for key in ["revision", "titleKey", "subtitle", "selection", "scrollTop"] { #expect(json[key] == nil) }
        let access = try NotePrivacy(store: store).setPassword("test-password")
        try access.lock(noteId: note.id)
        let locked = try #require(try db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) })
        #expect(locked.text.isEmpty && locked.isLocked && locked.encryptedPayload != nil)
        #expect(locked.directTags == ["work"] && locked.title == "Exact title")
        let encoded = try SyncPayloadCodec.encoder().encode(locked)
        #expect(encoded.range(of: Data("secret body".utf8)) == nil)
        let account = try AccountKeys(accountID: "account")
        let context = try SyncWire.cipherContext(accountID: "account", type: .note, entityID: note.id)
        let outer = try NoteCipher.seal(encoded, vaultKey: account.vaultKey, context: context)
        let reopened = try SyncPayloadCodec.decode(SyncNotePayload.self, from: NoteCipher.open(outer, vaultKey: account.vaultKey, context: context))
        #expect(reopened.encryptedPayload == locked.encryptedPayload && reopened.text.isEmpty)
        #expect(throws: CryptoError.tampered) { try NoteCipher.open(#require(reopened.encryptedPayload), vaultKey: account.vaultKey, context: note.id) }
    }

    @Test func externalReferenceBaseUsesPortableHashAndNeverLocalRevision() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-ref-\(UUID())"))
        try paths.createDirectories(); let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try NoteStore(db: db, notifier: nil, paths: paths).create(text: "imported")
        try db.pool.write { db in
            try db.execute(sql: "INSERT INTO external_ref(source,externalId,noteId,importedRevision,importedTextHash) VALUES('bear','external',?,42,'hash')", arguments: [note.id])
        }
        let content = try db.pool.read { try SyncPayloadCodec.capture(SyncDirty(type: .externalRef, localID: "[\"bear\",\"external\"]", generation: 1, tombstone: false), in: $0) }
        let data = try #require(content.payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["importedRevision"] == nil)
        #expect(object["importedTextHash"] as? String == "hash")
        #expect(object["noteId"] as? String == note.id)
    }

    /// FOC-R4: the focus state is device-local. Writing it changes neither the note's wire bytes
    /// nor the sync outbox.
    @Test func noteWireFormatIsUnchangedByFocusState() throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Plan\n- [ ] first\n#work")
        func wire() throws -> Data {
            let captured = try #require(try library.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) })
            return try SyncPayloadCodec.encoder().encode(captured)
        }
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM sync_dirty") }
        let before = try wire()

        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET captureSource = 'share' WHERE id = ?", arguments: [note.id])
            try db.execute(sql: "INSERT INTO note_ui_state(noteId, lastOpenedAt) VALUES(?, ?)", arguments: [note.id, Date()])
            try db.execute(sql: """
                INSERT INTO note_ping(id, noteId, anchorLine, anchorHash, fireAt, createdAt) VALUES('p1', ?, 2, '0badf00d', ?, ?)
                """, arguments: [note.id, Date(), Date()])
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES('pool', NULL, ?)", arguments: [Date()])
            try db.execute(sql: "INSERT INTO focus_hide(candidateKey, noteId, hiddenUntil) VALUES(?, ?, ?)",
                           arguments: ["note:" + note.id, note.id, Date()])
            try db.execute(sql: "INSERT INTO note_snapshot(id, noteId, takenAt, text) VALUES('s1', ?, ?, 'old text')",
                           arguments: [note.id, Date()])
            try db.execute(sql: "INSERT INTO capture_receipt(itemId, noteId, processedAt) VALUES('c1', ?, ?)", arguments: [note.id, Date()])
        }
        try library.store.recordOpened(noteId: note.id)

        #expect(try wire() == before)
        #expect(try library.queue.pendingCount() == 0)
        // Creating a captured note is an ordinary insert: one outbox row for the note itself.
        _ = try library.store.create(text: "# Captured", captureSource: .voice)
        #expect(try library.queue.pendingCount() == 1)
    }
}
