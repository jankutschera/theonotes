// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB
import Testing
@testable import TheoNotesCore

@Suite @MainActor struct BrowserRecoveryTests {
    @Test func originallyProtectedSessionCanStillSealRecoveryAfterSourceUnlocks() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let access = try library.access()
        try access.lock(noteId: original.id)
        try access.removeLock(noteId: original.id)
        #expect(throws: (any Error).self) { try access.preserveBrowserRecovery(noteId: original.id, text: "Private recovery", baseRevision: 0, now: .now) }
        let copy = try access.preserveProtectedBrowserRecovery(noteId: original.id, text: "Private recovery", baseRevision: 0, now: .now)
        #expect(copy.note.isLocked)
        #expect(try library.store.note(id: copy.note.id)?.text == "")
        #expect(try access.note(id: copy.note.id)?.text == "Private recovery")
    }
    @Test func confirmedJournalDiscardRejectsAStaleRevision() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal, commitDelay: .seconds(60))
        let change = ChangeSet(sections: [.replace(deleteLength: 8, insert: "Unsaved")])
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: change, origin: nil) == .acked(revision: 1))
        #expect(throws: (any Error).self) { try session.discardPendingJournalAfterConfirmation(expectedRevision: 0) }
        #expect(try !session.journal.isEmpty())
        try session.discardPendingJournalAfterConfirmation(expectedRevision: 1)
        #expect(try session.journal.isEmpty())
    }
    @Test(arguments: ["noVault", "vaultUnlocked", "vaultLocked", "vaultPending"])
    func hardDeletedSourceUsesSafeRecoveryPolicy(mode: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        let access = mode == "vaultUnlocked" || mode == "vaultLocked" ? try library.access() : nil
        try library.db.pool.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [original.id])
            if mode == "vaultPending" {
                try db.execute(sql: "INSERT INTO sync_dirty(entityType, localId) VALUES('keyBundle','fixture')")
            }
        }
        switch mode {
        case "noVault":
            let copy = try session.preserveBrowserRecovery(text: "Orphan browser", baseRevision: 0)
            let stored = try #require(try library.store.note(id: copy))
            #expect(!stored.isLocked && stored.text == "Orphan browser")
        case "vaultUnlocked":
            let unlocked = try #require(access)
            let copy = try unlocked.preserveBrowserRecovery(noteId: original.id, text: "Orphan browser", baseRevision: 0, now: .now)
            let stored = try #require(try library.store.note(id: copy.note.id))
            #expect(copy.note.isLocked && stored.text.isEmpty)
            #expect(try unlocked.note(id: copy.note.id)?.text == "Orphan browser")
        default:
            #expect(throws: (any Error).self) { try session.preserveBrowserRecovery(text: "Orphan browser", baseRevision: 0) }
            #expect(try library.store.allNotes().isEmpty)
        }
    }
    @Test func verifiedPasswordRewrapKeepsOrphanRecoveryAvailable() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let access = try library.access(iterations: 100_000)
        let privacy = NotePrivacy(store: library.store)
        try privacy.changePassword(from: "fixture-password", to: "new-password")
        try access.acceptPasswordRewrap(password: "new-password")
        try library.db.pool.write { db in try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [original.id]) }
        let copy = try access.preserveBrowserRecovery(noteId: original.id, text: "Saved after rewrap", baseRevision: 0, now: .now)
        let recovered = try access.note(id: copy.note.id)
        #expect(copy.note.isLocked && recovered?.text == "Saved after rewrap")
    }
    @Test func replacedVaultCannotReceiveRecoveryEncryptedWithOldKey() throws {
        let library = try PrivacyTestLibrary(), replacement = try PrivacyTestLibrary()
        defer { library.cleanup(); replacement.cleanup() }
        let original = try library.store.create(text: "Original")
        let oldAccess = try library.access()
        try oldAccess.lock(noteId: original.id)
        _ = try replacement.access(iterations: 100_000)
        let newEnvelope = try #require(try replacement.db.pool.read { try Data.fetchOne($0, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") })
        try library.db.pool.write { db in try db.execute(sql: "UPDATE crypto_envelope SET envelope=? WHERE id=1", arguments: [newEnvelope]) }
        #expect(throws: (any Error).self) { try oldAccess.preserveBrowserRecovery(noteId: original.id, text: "Must not be lost", baseRevision: 0, now: .now) }
        #expect(throws: (any Error).self) { try oldAccess.acceptPasswordRewrap(password: "fixture-password") }
    }
    @Test func sessionTextRatherThanDelayedDatabaseRowDeterminesRecovery() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Saved")
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal,
                                      commitDelay: .seconds(60))
        let change = ChangeSet(sections: [.replace(deleteLength: 5, insert: "Acknowledged")])
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: change, origin: nil) == .acked(revision: 1))
        #expect(try library.store.note(id: original.id)?.text == "Saved")
        #expect(try session.preserveBrowserRecovery(text: "Acknowledged", baseRevision: 0) == original.id)
        #expect(try library.store.allNotes().count == 1)
        let copy = try session.preserveBrowserRecovery(text: "Saved", baseRevision: 0)
        #expect(copy != original.id)
        #expect(try library.store.note(id: copy)?.text == "Saved")
        #expect(session.text == "Acknowledged")
    }
    @Test(arguments: [false, true])
    func deletedSourceProducesRecoverableCopyWithMatchingProtection(locked: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let session: NoteSession
        let access: LockedNoteAccess?
        if locked {
            let privateAccess = try library.access(); access = privateAccess
            try privateAccess.lock(noteId: original.id)
            session = try NoteSession(noteId: original.id, store: privateAccess, journalDirectory: library.paths.journal, journalKey: privateAccess.journalKey())
        } else {
            access = nil
            session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        }
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET deletedAt = 100 WHERE id = ?", arguments: [original.id])
        }
        let copy = try session.preserveBrowserRecovery(text: "Unsaved browser text", baseRevision: 0)
        let stored = try #require(try library.store.note(id: copy))
        #expect(copy != original.id && stored.isLocked == locked && stored.location == .notes)
        #expect(try (locked ? access?.note(id: copy)?.text : stored.text) == "Unsaved browser text")
    }
    @Test(arguments: ["archive", "trash", "edited", "deleted"])
    func replayNeverOverwritesAnEditedOrHiddenRecoveryCopy(change: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        let id = try session.preserveBrowserRecovery(text: "Browser recovery", baseRevision: 0)
        try library.db.pool.write { db in
            switch change {
            case "archive", "trash": try db.execute(sql: "UPDATE note SET location=? WHERE id=?", arguments: [change, id])
            case "edited": try db.execute(sql: "UPDATE note SET text='User changed the recovery copy' WHERE id=?", arguments: [id])
            default: try db.execute(sql: "UPDATE note SET deletedAt=100 WHERE id=?", arguments: [id])
            }
        }
        let before = try library.store.note(id: id)
        #expect(throws: (any Error).self) { try session.preserveBrowserRecovery(text: "Browser recovery", baseRevision: 0) }
        #expect(try library.store.note(id: id) == before)
        #expect(try library.store.note(id: original.id)?.text == "Original")
    }
    @Test func recoveryIsDurableIdempotentAndDifferentPayloadsNeverCollide() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Acknowledged")
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        var notices = 0
        _ = session.addConflictCopyListener { _ in notices += 1 }
        let first = try session.preserveBrowserRecovery(text: "First unacknowledged text", baseRevision: 0)
        #expect(try session.preserveBrowserRecovery(text: "First unacknowledged text", baseRevision: 0) == first)
        #expect(notices == 1)
        let second = try session.preserveBrowserRecovery(text: "Other browser text at the same revision", baseRevision: 0)
        #expect(first != second)
        #expect(try library.store.note(id: original.id)?.text == "Acknowledged")
        #expect(try library.store.note(id: first)?.text == "First unacknowledged text")
        #expect(try library.store.note(id: second)?.text == "Other browser text at the same revision")
        #expect(try library.store.allNotes().count == 3)
    }

    @Test func protectedRecoveryIsEncryptedAndRevokedAccessCannotAcknowledgeIt() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Protected original")
        let access = try library.access()
        try access.lock(noteId: original.id)
        _ = try access.addAttachment(data: Data("attachment".utf8), filename: "photo.bin", to: original.id)
        let session = try NoteSession(noteId: original.id, store: access, journalDirectory: library.paths.journal,
                                      journalKey: access.journalKey())
        let secret = "Unacknowledged private recovery \(UUID())"
        let id = try session.preserveBrowserRecovery(text: secret, baseRevision: 0)
        let guessable = "editor-browser-recovery\0\(original.id)\00\0\(secret)"
        let digest = Array(SHA256.hash(data: Data(guessable.utf8)).prefix(16))
        let plainID = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7], digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15])).uuidString.lowercased()
        #expect(id != plainID)
        let stored = try #require(try library.store.note(id: id))
        #expect(!FileManager.default.fileExists(atPath: library.paths.attachments.appendingPathComponent(id).path))
        #expect(stored.isLocked && stored.text.isEmpty && stored.encryptedPayload != nil)
        #expect(try access.note(id: id)?.text == secret)
        access.revoke()
        #expect(throws: (any Error).self) { try session.preserveBrowserRecovery(text: secret, baseRevision: 0) }
        #expect(throws: (any Error).self) { try session.preserveBrowserRecovery(text: "Another secret", baseRevision: 0) }
        #expect(try library.store.allNotes().count == 2)
    }

    @Test(arguments: [NoteLocation.archive, .trash])
    func recoveryFromHiddenSourceIsInNotesAndNeverMovesImportIdentity(location: NoteLocation) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "Original")
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE note SET location=? WHERE id=?", arguments: [location.rawValue, original.id])
            try db.execute(sql: "INSERT INTO external_ref(source,externalId,noteId,importedTextHash) VALUES('fixture','source',?,?)",
                           arguments: [original.id, NoteStore.textHash("Browser recovery")])
        }
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        let copy = try session.preserveBrowserRecovery(text: "Browser recovery", baseRevision: 0)
        #expect(try library.store.note(id: copy)?.location == .notes)
        #expect(try library.store.note(id: original.id)?.location == location)
        let ref = try library.db.pool.read { try String.fetchOne($0, sql: "SELECT noteId FROM external_ref WHERE source='fixture'") }
        #expect(ref == original.id)
        let reopened = try AppDatabase(path: library.paths.database)
        defer { try? reopened.pool.close() }
        let store = NoteStore(db: reopened, notifier: nil, paths: library.paths)
        let replay = try NoteSession(noteId: original.id, store: store, journalDirectory: library.paths.journal)
        #expect(try replay.preserveBrowserRecovery(text: "Browser recovery", baseRevision: 0) == copy)
        #expect(try store.note(id: copy)?.text == "Browser recovery")
    }
}
