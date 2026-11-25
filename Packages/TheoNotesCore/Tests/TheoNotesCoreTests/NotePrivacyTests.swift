// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct NotePrivacyTests {
    private struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let store: NoteStore
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID())"))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        func cleanup() {
            try? db.pool.close()
            try? FileManager.default.removeItem(at: paths.root)
        }
    }

    @Test func lockPurgesPlaintextAndPreservesExactBodyAndAttachmentBytes() throws {
        let library = try Library()
        defer { library.cleanup() }
        let secret = "body-secret-\(UUID())"
        let body = "# Visible title\n\n\(secret)\n## Private heading\n[[Secret target]]\n#work\n![](secret-photo.png)"
        let note = try library.store.create(text: body)
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let bytes = Data(("attachment-secret-\(UUID())" + String(repeating: "🐻", count: 40_000)).utf8)
        _ = try attachments.add(data: bytes, filename: "secret-photo.png", to: note.id)
        let ocrSecret = "recognized-secret-\(UUID())"
        let ocr = AttachmentTextStore(database: library.db)
        try ocr.record(OCRJob(noteId: note.id, filename: "secret-photo.png"),
                       result: .text(ocrSecret, sha256: "private-hash", byteSize: bytes.count, modifiedAt: .now))
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("correct horse")
        try access.lock(noteId: note.id)
        let persisted = try #require(try library.store.note(id: note.id))
        #expect(persisted.isLocked)
        #expect(persisted.text.isEmpty && persisted.subtitle.isEmpty)
        #expect(persisted.title == "Visible title")
        #expect(persisted.modifiedAt == note.modifiedAt)
        #expect(try access.note(id: note.id)?.text == body)
        #expect(attachments.url(for: "secret-photo.png", noteId: note.id) == nil)
        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try attachments.add(data: Data("leak".utf8), filename: "leak.txt", to: note.id)
        }
        #expect(throws: StoreError.noteLocked(id: note.id)) {
            try library.store.updateText(id: note.id, text: "leak", expectedRevision: persisted.revision)
        }
        #expect(throws: StoreError.noteLocked(id: note.id)) { try library.store.duplicate(id: note.id) }
        try library.db.pool.read { db throws -> Void in
            for table in ["heading", "note_stats", "note_search_content", "note_ui_state"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE noteId = ?", arguments: [note.id]) == 0)
            }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wiki_link WHERE sourceNoteId = ?", arguments: [note.id]) == 0)
        }
        let enumerator = try #require(FileManager.default.enumerator(at: library.paths.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let data = try Data(contentsOf: url)
            #expect(data.range(of: Data(secret.utf8)) == nil, "plaintext body in \(url.lastPathComponent)")
            #expect(data.range(of: Data(ocrSecret.utf8)) == nil, "plaintext OCR in \(url.lastPathComponent)")
            #expect(data.range(of: Data("secret-photo.png".utf8)) == nil, "plaintext filename in \(url.lastPathComponent)")
            #expect(data.range(of: Data(bytes.prefix(60))) == nil, "plaintext attachment in \(url.lastPathComponent)")
        }
        #expect(try ocr.pendingJobs(limit: 100).isEmpty)
        try ocr.record(OCRJob(noteId: note.id, filename: "secret-photo.png"), result: .text("late OCR", sha256: "late", byteSize: 1, modifiedAt: .now))
        #expect(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE noteId = ?", arguments: [note.id]) } == nil)
        let output = library.paths.root.appendingPathComponent("verified-preview.png")
        try access.decryptAttachment("secret-photo.png", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test func encryptedSelectionCopyKeepsProtectionFilesAndSourceWithoutPlaintextArtifacts() throws {
        let library = try Library()
        defer { library.cleanup() }
        let selected = "# Visible selection\nprivate-selection-e\u{301}-🐻\n![](secret.bin)\n\tend  "
        let original = try library.store.create(text: "# Original\nbefore\n" + selected + "\nafter")
        let bytes = Data("private-binary-selection-🐻".utf8)
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        _ = try attachments.add(data: bytes, filename: "secret.bin", to: original.id)
        let access = try NotePrivacy(store: library.store).setPassword("selection-password")
        try access.lock(noteId: original.id)
        try library.store.setPinned([original.id], pinned: true)
        try library.store.archive([original.id])
        try library.db.pool.write {
            try $0.execute(sql: "INSERT INTO external_ref(source,externalId,noteId,importedTextHash) VALUES('bear','private-selection',?,?)",
                           arguments: [original.id, NoteStore.textHash(selected)])
        }
        let before = try #require(try library.store.note(id: original.id))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let copy = try access.createFromSelection(of: original.id, text: selected, now: now)
        #expect(copy.isLocked && copy.text == selected && copy.location == .notes && !copy.isPinnedGlobal)
        #expect(copy.createdAt == now && copy.modifiedAt == now && copy.archivedAt == nil)
        #expect(try library.store.note(id: copy.id)?.text.isEmpty == true)
        #expect(try library.store.note(id: original.id) == before)
        #expect(attachments.url(for: "secret.bin", noteId: copy.id) == nil)
        let output = library.paths.root.appendingPathComponent("temporary-decrypted-test.bin")
        defer { try? FileManager.default.removeItem(at: output) }
        try access.decryptAttachment("secret.bin", noteId: copy.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        try FileManager.default.removeItem(at: output)
        try library.db.pool.read { db throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE externalId='private-selection'") == original.id)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_search_content WHERE noteId = ?", arguments: [copy.id]) == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM staging_batch") == 0)
        }
        let files = try #require(FileManager.default.enumerator(at: library.paths.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let data = try Data(contentsOf: url)
            #expect(data.range(of: Data("private-selection-e".utf8)) == nil)
            #expect(data.range(of: bytes) == nil)
        }
        access.revoke()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.createFromSelection(of: original.id, text: selected) }
    }

    @Test func passwordChangeAndRevocationKeepEncryptedCopiesReadableOnlyWithCurrentPassword() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Title\nprivate")
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        _ = try attachments.add(data: Data("binary secret".utf8), filename: "one.bin", to: note.id)
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("old-password")
        try access.lock(noteId: note.id)
        let originalCiphertext = try #require(try library.store.note(id: note.id)?.encryptedPayload)
        let cachedEnvelope = try #require(try privacy.envelope())
        let cachedKey = try access.journalKey()
        #expect(try privacy.restoreAccess(vaultKey: cachedKey, matching: cachedEnvelope).note(id: note.id)?.text == note.text)
        #expect(throws: CryptoError.tampered) {
            try privacy.restoreAccess(vaultKey: SymmetricKey(size: .bits256), matching: cachedEnvelope)
        }
        let copy = try access.createConflictCopy(of: note.id, text: "# Alternate\nsecret alternate")
        #expect(copy.isLocked)
        #expect(try library.store.note(id: copy.id)?.text == "")
        let destination = library.paths.root.appendingPathComponent("copy.bin")
        try access.decryptAttachment("one.bin", noteId: copy.id, to: destination)
        #expect(try Data(contentsOf: destination) == Data("binary secret".utf8))
        try privacy.changePassword(from: "old-password", to: "new-password")
        #expect(try library.store.note(id: note.id)?.encryptedPayload == originalCiphertext)
        #expect(throws: NotePrivacyError.accessRevoked) { try privacy.restoreAccess(vaultKey: cachedKey, matching: cachedEnvelope) }
        #expect(throws: CryptoError.wrongPassword) { try privacy.unlock(password: "old-password") }
        access.revoke()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.note(id: note.id) }
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        let reopened = try privacy.unlock(password: "new-password")
        #expect(try reopened.note(id: copy.id)?.text == copy.text)
        #expect(try reopened.note(id: note.id)?.text == note.text)
    }

    @MainActor @Test func encryptedSessionRecoversAcknowledgedTypingWithoutLeakingJournalText() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Private\ninitial")
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: note.id)
        let secret = "acknowledged-secret-\(UUID())"
        var session: NoteSession? = try NoteSession(noteId: note.id, store: access, journalDirectory: library.paths.journal,
                                                   journalKey: access.journalKey(), commitDelay: .seconds(600))
        let length = note.text.utf16.count
        #expect(session?.apply(txId: "t1", baseRevision: 0,
                               changeSet: ChangeSet(sections: [.retain(length), .replace(deleteLength: 0, insert: secret)]),
                               origin: nil) == .acked(revision: 1))
        let file = library.paths.journal.appendingPathComponent(note.id + ".jsonl")
        #expect(try Data(contentsOf: file).range(of: Data(secret.utf8)) == nil)
        session = nil
        let recovered = try NoteSession(noteId: note.id, store: access, journalDirectory: library.paths.journal,
                                        journalKey: access.journalKey())
        #expect(recovered.text == note.text + secret)
        #expect(try access.note(id: note.id)?.text == note.text + secret)
        #expect(try library.store.note(id: note.id)?.text == "")
    }

    @Test func pendingPlaintextRecoveryBlocksLockingWithoutChangingTheNote() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "important")
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: note.text))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0,
                                       changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "retained")])) )
        let access = try NotePrivacy(store: library.store).setPassword("password")
        #expect(throws: NotePrivacyError.pendingEdits) { try access.lock(noteId: note.id) }
        #expect(try library.store.note(id: note.id) == note)
        #expect(try journal.entries().count == 1)
    }
    @Test func interruptedLockFinishesFromCiphertextWithoutPasswordOrDataLoss() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Kept title\nprivate body")
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let bytes = Data("private attachment".utf8)
        _ = try attachments.add(data: bytes, filename: "file.txt", to: note.id)
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("password")
        #expect(throws: NotePrivacyError.cleanupPending) { try access.lock(noteId: note.id, installFiles: false) }
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        #expect(attachments.url(for: "file.txt", noteId: note.id) == nil)
        access.revoke()
        _ = try AttachmentFiles(paths: library.paths, database: library.db).recover()
        try privacy.finishPendingCleanup()
        let reopened = try privacy.unlock(password: "password")
        #expect(try reopened.note(id: note.id)?.text == note.text)
        let output = library.paths.root.appendingPathComponent("recovered.txt")
        try reopened.decryptAttachment("file.txt", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(!FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("file.txt").path))
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition") } == 0)
    }

    @Test func addingEncryptedAttachmentsAndRemovingProtectionPreservesTheNote() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Title\nPrivate content")
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: note.id)
        let bytes = Data(repeating: 87, count: ChunkedCipher.chunkSize * 2 + 17)
        let name = try access.addAttachment(data: bytes, filename: "file.bin", to: note.id)
        #expect(name == "file.bin")
        let second = try access.addAttachment(data: Data([1, 2, 3]), filename: "file.bin", to: note.id)
        #expect(second == "file 2.bin")
        let current = try #require(try access.note(id: note.id))
        let text = current.text + "\n[file](file.bin)"
        _ = try access.updateText(id: note.id, text: text, expectedRevision: current.revision)
        try access.removeLock(noteId: note.id)
        let restored = try #require(try library.store.note(id: note.id))
        #expect(!restored.isLocked && restored.encryptedPayload == nil)
        #expect(restored.text == text)
        let attachments = AttachmentStore(paths: library.paths, database: library.db)
        let file = try #require(attachments.url(for: name, noteId: note.id))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_search_content WHERE noteId = ?", arguments: [note.id]) } == 1)
        try access.lock(noteId: note.id)
        #expect(try access.note(id: note.id)?.text == text)
    }

    @Test func attachmentIdentifiersSurviveLockingAndCaseInsensitiveLinks() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Note\n![](Photo.png)")
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data([8, 9, 10]), filename: "photo.png", to: note.id)
        let originalID = try #require(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId = ?", arguments: [note.id]) })
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: note.id)
        let output = library.paths.root.appendingPathComponent("preview.png")
        try access.decryptAttachment("Photo.png", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == Data([8, 9, 10]))
        #expect(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId = ?", arguments: [note.id]) } == originalID)
        try access.removeLock(noteId: note.id)
        #expect(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId = ?", arguments: [note.id]) } == originalID)
        #expect(try library.store.note(id: note.id)?.text == note.text)
    }

    @Test func earlierMobileSchemaCanAcquireOCRTablesWithoutChangingLockedContent() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Kept\n![](photo.png)")
        _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data([1, 2, 3]), filename: "photo.png", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: note.id)
        let encrypted = try library.store.note(id: note.id)?.encryptedPayload
        // This is the schema shape of the mobile branch before the parallel OCR migration.
        try library.db.pool.write {
            try $0.execute(sql: "DROP TABLE attachment; DELETE FROM grdb_migrations WHERE identifier = 'v7'")
        }
        try library.db.pool.close()
        let reopened = try AppDatabase(path: library.paths.database)
        defer { try? reopened.pool.close() }
        let store = NoteStore(db: reopened, notifier: nil, paths: library.paths)
        #expect(try store.note(id: note.id)?.encryptedPayload == encrypted)
        let restored = try NotePrivacy(store: store).unlock(password: "password")
        #expect(try restored.note(id: note.id)?.text == note.text)
        try restored.removeLock(noteId: note.id)
        #expect(try store.note(id: note.id)?.text == note.text)
        #expect(try reopened.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attachment WHERE noteId = ?", arguments: [note.id]) } == 1)
    }

    @Test func reindexingNeverPersistsDecryptedPrivateContent() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "# Visible title\n#work\n## Private heading\nBody [[Private target]]")
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: note.id)
        _ = try library.db.pool.write { try NoteIndexer.index(noteId: note.id, text: note.text, in: $0) }
        let persisted = try #require(try library.store.note(id: note.id))
        #expect(persisted.title == "Visible title")
        #expect(persisted.text.isEmpty && persisted.subtitle.isEmpty)
        let counts = try library.db.pool.read { db in
            try ["heading", "note_stats", "note_search_content"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE noteId = ?", arguments: [note.id]) ?? -1
            }
        }
        #expect(counts == [0, 0, 0])
        #expect(try access.note(id: note.id)?.text == note.text)
    }

}
