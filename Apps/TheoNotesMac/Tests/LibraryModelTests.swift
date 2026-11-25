// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import CryptoKit
import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct LibraryModelTests {
    /// A deleted note's journal (plain, or sealed with a password `vault` then revoked).
    private func orphanJournal(paths: AppPaths, sealed: Bool) throws -> (id: String, journal: URL) {
        try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        let access = sealed ? try NotePrivacy(store: store).setPassword("password") : nil
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: access?.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        access?.revoke()
        return (note.id, journal.fileURL)
    }
    @Test func forgottenPasswordResetDiscardsSealedOrphanOnlyAfterNamedConfirmation() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacReset-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let orphan = try orphanJournal(paths: paths, sealed: true)
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .unlockRequired)
        let model = PrivacySettingsModel(vault: environment.vault, store: environment.store,
            settings: TheoNotesCore.Settings(db: environment.database), appLock: environment.appLock,
            prepareJournalDiscard: { try? MissingJournalRecovery.prepareResetDiscard(store: environment.store) },
            discardJournals: { try environment.discardJournalsForPasswordReset($0) })
        model.resetPhrase = "reset"
        #expect(await model.resetNotePassword() == false)
        let plan = try #require(model.pendingJournalDiscard)
        #expect(plan.noteIDs == [orphan.id] && FileManager.default.fileExists(atPath: orphan.journal.path))
        environment.voiceCaptureBusy = { true }
        #expect(await model.resetNotePassword(discarding: plan) == false)
        #expect(FileManager.default.fileExists(atPath: orphan.journal.path))
        environment.voiceCaptureBusy = { false }
        #expect(await model.resetNotePassword(discarding: plan))
        #expect(!FileManager.default.fileExists(atPath: orphan.journal.path))
        #expect(try !NotePrivacy(store: environment.store).hasPassword && environment.journalKeyState == nil)
    }
    @Test func passwordChangeKeepsSealedOrphanRecoveryUsable() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacPasswordChange-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let orphan = try orphanJournal(paths: paths, sealed: true)
        let environment = try AppEnvironment(paths: paths)
        try await environment.vault.changePassword(old: "password", new: "changed")
        try await environment.vault.unlock(password: "changed")
        let notice = try #require(environment.recoveredSingleJournals.first { $0.sourceID == orphan.id })
        #expect(notice.note.isLocked)
        try environment.removeRecoveredSingleAfterConfirmation(notice)
        #expect(!FileManager.default.fileExists(atPath: orphan.journal.path) && environment.recoveredSingleJournals.isEmpty)
    }
    @Test func damagedMarkerRowMovesItAsideAndUnblocksSync() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacMarker-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let name = ".retirement-" + String(repeating: "b", count: 64) + ".json"
        try Data("invalid".utf8).write(to: paths.journal.appendingPathComponent(name))
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.markerMoveNames == [name])
        #expect(throws: (any Error).self) { try environment.requireJournalRecoveryReadyForSync() }
        let plan = try environment.prepareMarkerQuarantine(markerName: name)
        let destination = try environment.moveVariantFilesAfterConfirmation(plan)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path))
        #expect(environment.markerMoveNames.isEmpty)
        try environment.requireJournalRecoveryReadyForSync()
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func passwordResetSavesPlainRamOnlyOrphanAfterVaultIsGone() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacPlainOrphan-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let environment = try AppEnvironment(paths: paths)
        try SyncQueue(database: environment.database).enable(accountID: "account")  // B5: a synced library
        try await environment.vault.createPassword("password")
        let note = try environment.store.create(text: "Original")
        // Held weakly, as in the app: only the environment's cache owns the orphan session.
        weak var session: NoteSession?
        do {
            let held = try environment.session(for: note.id); session = held
            #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Plain unsaved")]), origin: nil) == .acked(revision: 1))
        }
        let id = note.id
        environment.vault.relock()  // the password is forgotten: no key
        try await environment.database.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) }
        for name in [id + ".jsonl", id + ".base"] { try? FileManager.default.removeItem(at: paths.journal.appendingPathComponent(name)) }
        // A change notification (also this process's own) runs `closeSessionsOfDeletedNotes`; with a
        // vault and no key the plain text cannot be saved yet, so the session stays open (Q3).
        environment.databaseDidChange()
        #expect(environment.hasCachedSession(for: id))
        let model = PrivacySettingsModel(vault: environment.vault, store: environment.store,
            settings: TheoNotesCore.Settings(db: environment.database), appLock: environment.appLock,
            prepareJournalDiscard: { try? MissingJournalRecovery.prepareResetDiscard(store: environment.store) },
            discardJournals: { try environment.discardJournalsForPasswordReset($0) },
            afterPasswordRemoved: { environment.savePlainOrphansAfterPasswordReset() })
        model.resetPhrase = "reset"
        #expect(await model.resetNotePassword())
        #expect(model.pendingJournalDiscard == nil && !environment.vault.hasPassword)
        let texts = try environment.store.allNotes().map(\.text)
        #expect(texts.filter { $0 == "Plain unsaved" }.count == 1, "notes: \(texts)")
        #expect(session?.isInvalidated != true && !environment.hasCachedSession(for: id))
        try environment.requireJournalRecoveryReadyForSync()
    }
    /// B6: a remote delete while typing saves a copy; the user then edits or trashes that copy. The
    /// next journal pass must not collide with it: nothing stays uncommitted and sync is allowed.
    @Test(arguments: ["edit", "trash"]) func editedRemoteDeleteCopyNeverBlocksSync(change: String) throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacCopyEdit-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let environment = try AppEnvironment(paths: paths)
        let note = try environment.store.create(text: "Original")
        do {
            let held = try environment.session(for: note.id)
            #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Typed text")]), origin: nil) == .acked(revision: 1))
        }
        let id = note.id
        try environment.database.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) }
        environment.databaseDidChange()  // the remote delete: [l] saves the copy, the journal stays
        let copy = try #require(try environment.store.allNotes().first { $0.text == "Typed text" })
        if change == "edit" { _ = try environment.store.updateText(id: copy.id, text: "Edited copy", expectedRevision: copy.revision) }
        else { try environment.store.trash([copy.id]) }
        environment.refreshJournalRecovery()
        #expect(!environment.journalRecoveryUncommitted && environment.variantRetryNoteIDs.isEmpty)
        try environment.requireJournalRecoveryReadyForSync()
        let kept = try #require(try environment.store.note(id: copy.id))
        #expect(change == "edit" ? kept.text == "Edited copy" : kept.location == .trash)
    }
    @Test func keptOpenOrphanIsSavedRightAfterUnlockOnce() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacUnlockOrphan-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let environment = try AppEnvironment(paths: paths)
        try await environment.vault.createPassword("password")
        environment.vault.relock()
        let note = try environment.store.create(text: "Original")
        do {
            let held = try environment.session(for: note.id)
            #expect(held.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Plain unsaved")]), origin: nil) == .acked(revision: 1))
        }
        let id = note.id
        let deleteRow: () throws -> Void = { try environment.database.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) } }
        try deleteRow()
        environment.databaseDidChange()  // no key: the text cannot be saved yet, the session stays
        #expect(environment.hasCachedSession(for: id))
        // N12: the unlock itself retries; no further database change is needed.
        try await environment.vault.unlock(password: "password")
        #expect(!environment.hasCachedSession(for: id))
        let access = try environment.vault.requireAccess()
        let texts = try environment.store.allNotes().filter(\.isLocked).compactMap { try access.note(id: $0.id)?.text }
        // S7 on the key path: the save and the journal pass agree on one sealed copy.
        #expect(texts.filter { $0 == "Plain unsaved" }.count == 1, "sealed copies: \(texts)")
    }
    @Test func remoteDeleteKeepsProtectedUnsavedTextOpenWithoutKeyAndNeverPlain() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacProtectedOrphan-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try paths.createDirectories()
        let environment = try AppEnvironment(paths: paths)
        try await environment.vault.createPassword("password")
        let note = try environment.store.create(text: "Secret")
        try environment.vault.requireAccess().lock(noteId: note.id)
        let session = try environment.session(for: note.id)
        #expect(session.apply(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: " unsaved")]), origin: nil) == .acked(revision: 1))
        let id = note.id
        let deleteRow: () throws -> Void = { try environment.database.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [id]) } }
        try deleteRow()
        try environment.vault.requireAccess().revoke()  // no key any more
        environment.databaseDidChange()
        #expect(environment.existingSession(for: id) === session && !session.isInvalidated)
        #expect(try environment.store.allNotes().allSatisfy { $0.isLocked || !$0.text.contains("unsaved") })
    }
    @Test func journalWaitingForSyncKeyBlocksEverySyncAndKeepsBytes() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("MacPendingKey-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let orphan = try orphanJournal(paths: paths, sealed: false)
        let database = try AppDatabase(path: paths.database)
        try await database.pool.write { try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')") }
        try database.pool.close()
        let before = try Data(contentsOf: orphan.journal)
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .waitingForSyncKey && environment.recoveredSingleJournals.isEmpty)
        #expect(throws: AppEnvironment.JournalRecoverySyncBlock.waitingForSyncKey) { try environment.requireJournalRecoveryReadyForSync() }
        #expect(try Data(contentsOf: orphan.journal) == before)
    }
    @Test func deletedSingleRecoveryIsRecreatedBeforeAnyJournalRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacDeletedRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let environment = try AppEnvironment(paths: paths)
        let old = try #require(environment.recoveredSingleJournals.first)
        let before = try Data(contentsOf: journal.fileURL)
        try environment.store.trash([old.note.id]); try environment.store.deletePermanently([old.note.id])
        #expect(throws: (any Error).self) { try environment.removeRecoveredSingleAfterConfirmation(old) }
        let replacement = try #require(environment.recoveredSingleJournals.first)
        #expect(replacement.note.id != old.note.id && replacement.note.text == "base!")
        #expect(try Data(contentsOf: journal.fileURL) == before)
    }
    @Test(arguments: [false, true]) func singleRecoveryRemainsReviewableAcrossRescanAndRemoval(locked: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSingle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        let access = locked ? try NotePrivacy(store: store).setPassword("password") : nil
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: access?.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        access?.revoke()
        let environment = try AppEnvironment(paths: paths)
        if locked { try await environment.vault.unlock(password: "password") }
        let first = try #require(environment.recoveredSingleJournals.first)
        #expect(first.note.isLocked == locked)
        if locked { #expect(try environment.vault.access?.note(id: first.note.id)?.text == "base!") }
        else { #expect(first.note.text == "base!") }
        environment.retryJournalRecovery()
        let retry = try #require(environment.recoveredSingleJournals.first)
        #expect(first.note.id == retry.note.id)
        try environment.removeRecoveredSingleAfterConfirmation(retry)
        #expect(environment.recoveredSingleJournals.isEmpty)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func unlockedValidSealedJournalWithFailedWriterOffersRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacRecoveryRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let db = try AppDatabase(path: paths.database), store = NoteStore(db: db, notifier: nil, paths: paths)
        let note = try store.create(text: "base"), access = try NotePrivacy(store: store).setPassword("password")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        access.revoke()
        try await db.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_recovery BEFORE INSERT ON note BEGIN SELECT RAISE(ABORT, 'test'); END") }
        let environment = try AppEnvironment(paths: paths)
        try await environment.vault.unlock(password: "password")
        #expect(environment.variantRetryNoteIDs.contains(note.id))
        #expect(environment.journalKeyState == nil && environment.variantQuarantineFiles[note.id] == nil)
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_recovery") }
        environment.applicationDidBecomeActive()  // ruling 5: the foreground retries
        #expect(environment.recoveredSingleJournals.contains { $0.sourceID == note.id })
    }
    @Test func damagedSingleMissingJournalOffersMoveAside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacDamagedPair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        try Data("bad base".utf8).write(to: paths.journal.appendingPathComponent(note.id + ".base"))
        try Data("bad entry\n".utf8).write(to: paths.journal.appendingPathComponent(note.id + ".jsonl"))
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.variantQuarantineFiles[note.id]?.count == 2)
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        _ = try environment.moveVariantFilesAfterConfirmation(plan)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func foreignVaultSingleMissingJournalOffersUnlockThenMoveAside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacForeignPair-\(UUID().uuidString)")
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacOtherPair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        let paths = AppPaths(root: root), otherPaths = AppPaths(root: otherRoot)
        try paths.createDirectories(); try otherPaths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let otherStore = NoteStore(db: try AppDatabase(path: otherPaths.database), notifier: nil, paths: otherPaths)
        let note = try store.create(text: "base"), current = try NotePrivacy(store: store).setPassword("password")
        let other = try NotePrivacy(store: otherStore).setPassword("other password")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: other.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "other vault"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(11), .replace(deleteLength: 0, insert: "!")])))
        current.revoke(); other.revoke()
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .unlockRequired)
        try await environment.vault.unlock(password: "password")
        #expect(environment.variantQuarantineFiles[note.id]?.count == 2)
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        _ = try environment.moveVariantFilesAfterConfirmation(plan)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func foreignVaultAbortedBaseOffersMoveAsideAfterUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacForeignBase-\(UUID().uuidString)")
        let foreignRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacForeignVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: foreignRoot) }
        let paths = AppPaths(root: root), foreignPaths = AppPaths(root: foreignRoot)
        try paths.createDirectories(); try foreignPaths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let foreign = NoteStore(db: try AppDatabase(path: foreignPaths.database), notifier: nil, paths: foreignPaths)
        let note = try store.create(text: "restored"), current = try NotePrivacy(store: store).setPassword("password")
        let other = try NotePrivacy(store: foreign).setPassword("other password")
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: other.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "other key"))
        try FileManager.default.removeItem(at: journal.fileURL)
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [note.id + ".base"]]).write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        current.revoke(); other.revoke()
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .unlockRequired)
        try await environment.vault.unlock(password: "password")
        #expect(environment.variantQuarantineFiles[note.id] == [note.id + ".base"])
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        _ = try environment.moveVariantFilesAfterConfirmation(plan)
        #expect(try environment.abortedJournalNoteIDs().isEmpty)
    }
    @Test func sealedAbortedPairRecoversAfterUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacAbortedSealed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "restored"), access = try NotePrivacy(store: store).setPassword("password")
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [note.id + ".base", note.id + ".jsonl"]]).write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        access.revoke()
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .unlockRequired)
        try await environment.vault.unlock(password: "password")
        let group = try #require(environment.recoveredVariantGroups.first)
        #expect(group.notes.count == 1 && group.notes[0].isLocked)
        #expect(try environment.vault.access?.note(id: group.notes[0].id)?.text.contains("secret!") == true)
        #expect(try environment.store.note(id: note.id)?.text == "restored")
        try environment.removeVariantGroupAfterConfirmation(group)
        #expect(try environment.abortedJournalNoteIDs().isEmpty)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test(arguments: [false, true]) func readableAbortedFilesBecomeVariantsBeforeRemoval(loneBase: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacAborted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "restored")
        let journal = try EditJournal(directory: paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        var files = [note.id + ".base"]
        if loneBase { try FileManager.default.removeItem(at: journal.fileURL) }
        else {
            try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
            files.append(note.id + ".jsonl")
        }
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": files]).write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let environment = try AppEnvironment(paths: paths)
        let group = try #require(environment.recoveredVariantGroups.first)
        #expect(group.noteId == note.id && group.notes.count == 1)
        #expect(group.notes[0].text.contains(loneBase ? "base" : "base!"))
        #expect(try environment.store.note(id: note.id)?.text == "restored")
        try environment.removeVariantGroupAfterConfirmation(group)
        #expect(try environment.abortedJournalNoteIDs().isEmpty)
        #expect(try environment.session(for: note.id).text == "restored")
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func excessiveVariantsOfferMoveAsideAndAllowBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTooMany-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        for n in 1...4 {
            try JSONEncoder().encode(JournalBase(storeRevision: n + 1, baseText: "else")).write(to: paths.journal.appendingPathComponent(note.id + ".base.unreplayed.\(n)"))
        }
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.variantQuarantineFiles[note.id]?.count == 6)
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        let destination = try environment.moveVariantFilesAfterConfirmation(plan)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(note.id + ".jsonl").path))
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }

    @Test func sealedAmbiguousRecoveryOffersUnlockThenMoveAside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSealed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base"), access = try NotePrivacy(store: store).setPassword("password")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try Data("extra".utf8).write(to: paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        access.revoke()
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalKeyState == .unlockRequired)
        try await environment.vault.unlock(password: "password")
        #expect(environment.variantQuarantineFiles[note.id]?.count == 3)
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        _ = try environment.moveVariantFilesAfterConfirmation(plan)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func ambiguousPlainGroupIsRecoveredAndOfferedForRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVariants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        let environment = try AppEnvironment(paths: paths)
        #expect(environment.recoveredVariantGroups.count == 1)
        #expect(environment.recoveredVariantGroups.first?.notes.count == 2)
        let model = LibraryModel(environment: environment)
        #expect(model.banner == .journalsMovedAside(count: 1))
        let group = try #require(environment.recoveredVariantGroups.first)
        try environment.removeVariantGroupAfterConfirmation(group)
        #expect(environment.recoveredVariantGroups.isEmpty)
        _ = try LibraryBackup(database: environment.database, paths: paths).createRolling()
    }
    @Test func abortedRecoveryIsSurfacedAndConfirmedMoveUnblocksNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "restored")
        let name = note.id + ".jsonl", data = Data("partial\n".utf8)
        try data.write(to: paths.journal.appendingPathComponent(name))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [name]]).write(to: paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let environment = try AppEnvironment(paths: paths)
        let model = LibraryModel(environment: environment)
        #expect(model.banner == .journalsMovedAside(count: 1))
        #expect(try environment.abortedJournalNoteIDs() == [note.id])
        let plan = try environment.prepareVariantQuarantine(noteId: note.id)
        let destination = try environment.moveVariantFilesAfterConfirmation(plan)
        #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == data)
        #expect(try environment.abortedJournalNoteIDs().isEmpty)
        #expect(try environment.session(for: note.id).text == "restored")
    }
    /// A temp data dir with an environment and a second, independent store on the same database
    /// file (stands in for another process such as the CLI).
    @MainActor
    final class Env {
        let root: URL
        let paths: AppPaths
        let environment: AppEnvironment
        let model: LibraryModel

        /// Link rewrites wait for `scheduler`, which only runs when a test advances it.
        init(scheduler: ManualScheduler = ManualScheduler()) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesLibrary-\(UUID().uuidString)", isDirectory: true)
            paths = AppPaths(root: root)
            environment = try AppEnvironment(paths: paths, linkScheduler: scheduler)
            model = LibraryModel(environment: environment)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var store: NoteStore { environment.store }

        func externalStore(notifier: ChangeNotifier? = nil) throws -> NoteStore {
            NoteStore(db: try AppDatabase(path: paths.database), notifier: notifier, paths: paths)
        }

        func journalFiles(_ noteId: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: paths.journal.path).filter { $0.hasPrefix(noteId + ".") }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    private func insert(_ s: String, after length: Int) -> ChangeSet {
        ChangeSet(sections: [.retain(length), .replace(deleteLength: 0, insert: s)])
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what): not within 2 s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func testNewNoteInTagScopeInsertsTag() throws {
        let env = try Env()
        _ = try env.store.create(text: "Work #work\n\n#my tag#")
        env.model.scope = .tag("work")

        let id = try env.model.newNote()
        #expect(try env.store.note(id: id)?.text == "\n\n#work")
        #expect(env.model.selectedNoteIDs == [id])
        #expect(env.model.focusedNoteID == id)
        #expect(env.model.items.contains { $0.id == id })
        #expect(env.model.newNoteCaret == LibraryModel.Caret(noteId: id, utf16Offset: 0))

        Settings(db: env.environment.database).tagPosition = .top
        env.model.scope = .tag("my tag")
        let top = try env.model.newNote()
        let text = try #require(try env.store.note(id: top)?.text)
        #expect(text == "#my tag#\n\n")
        #expect(env.model.newNoteCaret == LibraryModel.Caret(noteId: top, utf16Offset: text.utf16.count))
        #expect(env.model.items.map(\.id).contains(top))

        // Outside a tag scope the note is empty; a scope that would not list it falls back to Notes.
        env.model.scope = .trash
        let plain = try env.model.newNote()
        #expect(try env.store.note(id: plain)?.text == "")
        #expect(env.model.scope == .notes)
        #expect(env.model.focusedNoteID == plain)
    }

    @Test func readOnlySwitchTogglesTheSelectedNotes() throws {
        let env = try Env()
        let a = try env.store.create(text: "A", now: start)
        let b = try env.store.create(text: "B", now: start.addingTimeInterval(1))
        env.model.refresh()
        env.model.selectedNoteIDs = [a.id, b.id]
        env.model.toggleReadOnlySelected()
        #expect(try env.store.note(id: a.id)?.isReadOnly == true && env.store.note(id: b.id)?.isReadOnly == true)
        env.model.toggleReadOnlySelected()
        #expect(try env.store.note(id: a.id)?.isReadOnly == false && env.store.note(id: b.id)?.isReadOnly == false)
        // A mix becomes read-only, like the title ("Make Read-Only") says.
        try env.store.setReadOnly(a.id, readOnly: true)
        env.model.refresh()
        env.model.toggleReadOnlySelected()
        #expect(try env.store.note(id: b.id)?.isReadOnly == true)
    }

    @Test func copyLinkAndIdentifierWriteOnePerSelectedNote() throws {
        let env = try Env()
        let a = try env.store.create(text: "A", now: start)
        let b = try env.store.create(text: "B", now: start.addingTimeInterval(1))
        env.model.refresh()
        let board = NSPasteboard(name: NSPasteboard.Name("TheoNotesTest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        env.model.pasteboard = board
        env.model.selectedNoteIDs = [a.id]
        env.model.copyIdentifierSelected()
        #expect(board.string(forType: .string) == a.id)
        env.model.copyLinkSelected()
        #expect(board.string(forType: .string) == NoteLink.url(id: a.id).absoluteString)
        env.model.selectedNoteIDs = [a.id, b.id]
        env.model.copyIdentifierSelected()
        #expect(board.string(forType: .string) == [b.id, a.id].joined(separator: "\n"))
    }

    @Test func testTrashMovesFocusToNextItem() throws {
        let env = try Env()
        let a = try env.store.create(text: "A", now: start)
        let b = try env.store.create(text: "B", now: start.addingTimeInterval(1))
        let c = try env.store.create(text: "C", now: start.addingTimeInterval(2))
        env.model.refresh()
        #expect(env.model.items.map(\.id) == [c.id, b.id, a.id])

        env.model.selectedNoteIDs = [b.id]
        env.model.focusedNoteID = b.id
        env.model.trashSelected()
        #expect(env.model.items.map(\.id) == [c.id, a.id])
        #expect(env.model.focusedNoteID == a.id)
        #expect(env.model.selectedNoteIDs == [a.id])
        #expect(env.model.counts.trash == 1)

        // The last item: focus moves to the previous one.
        env.model.trashSelected()
        #expect(env.model.items.map(\.id) == [c.id])
        #expect(env.model.focusedNoteID == c.id)

        env.model.scope = .trash
        env.model.selectedNoteIDs = [a.id, b.id]
        env.model.focusedNoteID = a.id
        env.model.restoreSelected()
        #expect(env.model.items.isEmpty)
        #expect(env.model.focusedNoteID == nil)
        #expect(env.model.selectedNoteIDs.isEmpty)
        #expect(env.model.counts.notes == 3)
    }

    @Test func testScopeChangeUpdatesItems() throws {
        let env = try Env()
        let tagged = try env.store.create(text: "Tagged #x", now: start)
        let plain = try env.store.create(text: "Plain", now: start.addingTimeInterval(1))
        env.model.refresh()
        #expect(env.model.items.map(\.id) == [plain.id, tagged.id])
        #expect(env.model.tagTree.map(\.path) == ["x"])
        #expect(env.model.counts.notes == 2)

        env.model.scope = .tag("x")
        #expect(env.model.items.map(\.id) == [tagged.id])
        env.model.scope = .untagged
        #expect(env.model.items.map(\.id) == [plain.id])

        env.model.scope = .notes
        env.model.selectedNoteIDs = [plain.id]
        env.model.archiveSelected()
        env.model.scope = .archive
        #expect(env.model.items.map(\.id) == [plain.id])

        env.model.scope = .notes
        env.model.selectedNoteIDs = [tagged.id]
        env.model.togglePinSelected()
        #expect(env.model.items.first?.isPinned == true)
        #expect(env.model.counts.pinned == 1)

        Settings(db: env.environment.database).noteSort = .titleAscending
        env.model.refresh()
        #expect(env.model.sort == .titleAscending)
    }

    /// Review Focus 5: another process writes; GRDB observation does not see it, the notifier does.
    @Test func testExternalWriteRefreshesModel() async throws {
        let env = try Env()
        env.model.refresh()
        #expect(env.model.items.isEmpty)

        let cli = try env.externalStore(notifier: ChangeNotifier())
        let note = try cli.create(text: "From the CLI #inbox")
        try await waitUntil("items updated") { env.model.items.map(\.id) == [note.id] }
        #expect(env.model.counts.notes == 1)
        #expect(env.model.tagTree.map(\.path) == ["inbox"])
    }

    @Test func testEmptyTrashClosesSessionsAndRemovesJournals() throws {
        let env = try Env()
        let note = try env.store.create(text: "doomed")
        let kept = try env.store.create(text: "kept")
        let session = try env.environment.session(for: note.id)
        _ = session.addTextListener { _, _ in }
        #expect(session.apply(txId: "t1", baseRevision: 0, changeSet: insert("!", after: 6), origin: nil) == .acked(revision: 1))
        #expect(try !env.journalFiles(note.id).isEmpty)

        env.model.refresh()
        env.model.selectedNoteIDs = [note.id]
        env.model.trashSelected()
        env.model.scope = .trash
        env.model.emptyTrash()

        #expect(env.environment.existingSession(for: note.id) == nil)
        #expect(session.textListenerCount == 0)
        #expect(try env.journalFiles(note.id).isEmpty)
        #expect(try env.store.note(id: note.id) == nil)
        #expect(try env.store.note(id: kept.id) != nil)
        #expect(env.model.counts.trash == 0)
        #expect(env.model.items.isEmpty)

        // Delete Permanently on a selection closes sessions the same way.
        try env.store.trash([kept.id])
        let keptSession = try env.environment.session(for: kept.id)
        env.model.refresh()
        env.model.selectedNoteIDs = [kept.id]
        env.model.deleteSelectedPermanently()
        #expect(env.environment.existingSession(for: kept.id) == nil)
        #expect(try env.store.note(id: kept.id) == nil)
        _ = keptSession
    }

    /// Empty Trash races a pull that restores or trashes notes: only deleted notes lose their
    /// session; a listed note that survived keeps its session and editor.
    @Test func testEmptyTrashKeepsSessionsOfNotesThatSurvive() throws {
        let env = try Env()
        let restored = try env.store.create(text: "restored")
        let (controller, _) = try openInEditor(env, restored.id)
        let session = try #require(controller.session)
        try env.store.trash([restored.id])
        let listed = try env.store.allNotes(location: .trash).map(\.id)
        try env.store.restore([restored.id])

        let deleted = try env.environment.closeSessions(ids: listed) { try env.store.emptyTrash(ids: listed) }
        #expect(deleted.isEmpty)
        #expect(env.environment.existingSession(for: restored.id) === session)
        #expect(controller.session === session)
        #expect(session.textListenerCount == 1)
    }

    @Test func missingJournalIsRecoveredAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "base")
        try store.trash([note.id]); try store.deletePermanently([note.id])
        let journal = try EditJournal(directory: paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " recovered")])))
        let environment = try AppEnvironment(paths: paths)
        #expect(try environment.store.allNotes().contains { $0.text == "base recovered" })
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }

    /// A note command the store refuses (busy database, rolled-back batch) shows a banner with
    /// the action instead of doing nothing silently.
    @Test func testFailedCommandsShowABanner() throws {
        let env = try Env()
        let note = try env.store.create(text: "A")
        let other = try env.store.create(text: "B")
        try env.store.trash([other.id])
        try AppDatabase(path: env.paths.database).pool.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_update BEFORE UPDATE ON note BEGIN SELECT RAISE(ABORT, 'refused'); END")
            try db.execute(sql: "CREATE TRIGGER refuse_delete BEFORE DELETE ON note BEGIN SELECT RAISE(ABORT, 'refused'); END")
        }
        env.model.refresh()
        env.model.selectedNoteIDs = [note.id]
        env.model.trashSelected()
        #expect(env.model.banner == .commandFailed(action: "trash"))
        #expect(try env.store.note(id: note.id)?.location == .notes)

        env.model.dismissBanner()
        env.model.scope = .trash
        env.model.emptyTrash()
        #expect(env.model.banner == .commandFailed(action: "empty trash"))
        #expect(try env.store.note(id: other.id) != nil)
    }

    /// A journal whose note is gone (a late edit after a delete) is removed at launch instead of
    /// failing recovery on every launch and keeping note text on disk.
    /// A journal of a note that is gone is never replayed, and never deleted either: it may hold
    /// the only copy of typed text, so launch moves it aside for manual recovery (M2 ruling R20).
    @Test func testMalformedJournalOfADeletedNoteIsRetainedAtLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "body")
        try store.deletePermanently([note.id])
        try Data("{}\n".utf8).write(to: paths.journal.appendingPathComponent("\(note.id).jsonl"))
        try Data("{}".utf8).write(to: paths.journal.appendingPathComponent("\(note.id).base"))

        let environment = try AppEnvironment(paths: paths)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: paths.journal.path))
            == ["\(note.id).jsonl", "\(note.id).base"])
        #expect(environment.journalsMovedAsideAtLaunch.isEmpty)
        #expect(try Data(contentsOf: paths.journal.appendingPathComponent("\(note.id).jsonl")) == Data("{}\n".utf8))
    }

    @Test func testOwnCommitEchoIsIgnored() async throws {
        let env = try Env()
        let note = try env.store.create(text: "mine")
        let session = try env.environment.session(for: note.id)
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: insert("!", after: 4), origin: nil)
        try session.flush()  // posts a Darwin notification this process receives too
        try await Task.sleep(for: .milliseconds(200))
        env.environment.databaseDidChange()
        #expect(env.environment.externalChangeCallCount == 0)

        let cli = try env.externalStore()
        _ = try cli.updateText(id: note.id, text: "theirs", expectedRevision: session.committedStoreRevision)
        env.environment.databaseDidChange()
        #expect(env.environment.externalChangeCallCount == 1)
        #expect(session.text == "theirs")
    }

    @Test func testConflictCopySurfaced() throws {
        let env = try Env()
        let base = "line1\nline2\nline3"
        let note = try env.store.create(text: base)
        let session = try env.environment.session(for: note.id)
        let local = ChangeSet(sections: [.retain(6), .replace(deleteLength: 5, insert: "local2"), .retain(6)])
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: local, origin: nil)
        _ = try env.externalStore().updateText(id: note.id, text: "line1\nremote2\nline3", expectedRevision: 1)

        env.environment.databaseDidChange()
        let copy = try #require(try env.store.allNotes().first { $0.id != note.id })
        #expect(copy.text == "line1\nremote2\nline3")
        #expect(env.model.banner == .conflictCopiesCreated(noteIds: [copy.id]))

        env.model.scope = .trash
        env.model.showBannerNote()
        #expect(env.model.scope == .notes)
        #expect(env.model.selectedNoteIDs == [copy.id])
        #expect(env.model.focusedNoteID == copy.id)
        #expect(env.model.banner == nil)
    }

    @Test func testJournalMovedAsideAtLaunchIsSurfaced() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.createDirectories()
        let store = NoteStore(db: try AppDatabase(path: paths.database), notifier: nil, paths: paths)
        let note = try store.create(text: "body")
        // An undecodable line followed by another line cannot be replayed safely.
        try Data("garbage\n{\"also\":\"bad\"}\n".utf8).write(to: paths.journal.appendingPathComponent("\(note.id).jsonl"))
        // Left over from an earlier launch: listed, but not reported again.
        try Data("old".utf8).write(to: paths.journal.appendingPathComponent("other.jsonl.unreplayed"))

        let environment = try AppEnvironment(paths: paths)
        #expect(environment.journalsMovedAsideAtLaunch.map(\.lastPathComponent) == ["\(note.id).jsonl.unreplayed"])
        #expect(Set(environment.movedAsideJournals().map(\.lastPathComponent))
            == ["\(note.id).jsonl.unreplayed", "other.jsonl.unreplayed"])
        let model = LibraryModel(environment: environment)
        #expect(model.banner == .journalsMovedAside(count: 1))
    }

    @Test func testUnopenedSessionsAreEvictedAfterFlush() throws {
        let env = try Env()
        let a = try env.store.create(text: "a")
        let b = try env.store.create(text: "b")
        let sessionA = try env.environment.session(for: a.id)
        _ = sessionA.apply(txId: "t1", baseRevision: 0, changeSet: insert("!", after: 1), origin: nil)
        let sessionB = try env.environment.session(for: b.id)
        _ = sessionB.addTextListener { _, _ in }  // attached to an editor

        env.model.focusedNoteID = b.id
        #expect(env.environment.openNoteIds == [b.id])
        #expect(env.environment.existingSession(for: a.id) == nil)
        #expect(try env.store.note(id: a.id)?.text == "a!")
        #expect(env.environment.existingSession(for: b.id) === sessionB)

        // Still attached to the editor: kept even when no longer reported open.
        env.model.focusedNoteID = nil
        env.environment.flushAll()
        #expect(env.environment.existingSession(for: b.id) === sessionB)
    }

    // MARK: - Fix round 1: closing sessions that an editor shows

    private func openInEditor(_ env: Env, _ noteId: String) throws -> (EditorBridgeController, FakeEditorPage) {
        let page = FakeEditorPage()
        let controller = EditorBridgeController(
            environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil
        )
        _ = controller.handle(.ready(version: EditorBridge.version))
        try controller.open(noteId: noteId)
        return (controller, page)
    }

    @Test func testDeletingFocusedNoteDetachesEditorAndRefusesLaterChanges() throws {
        let env = try Env()
        let note = try env.store.create(text: "gone")
        let (controller, page) = try openInEditor(env, note.id)
        let typed = EditorToHostMessage.changes(
            noteId: note.id, txId: "t1", baseRevision: 0, revision: 1, changeSet: insert("!", after: 4)
        )
        #expect(controller.handle(typed) == .acked(revision: 1))
        try env.store.trash([note.id])

        env.model.scope = .trash
        env.model.selectedNoteIDs = [note.id]
        env.model.focusedNoteID = note.id
        env.model.deleteSelectedPermanently()

        #expect(try env.store.note(id: note.id) == nil)
        #expect(controller.session == nil)
        #expect(page.loadNotes.last == .loadNote(
            noteId: EditorBridgeController.placeholderNoteId, text: "", revision: 0, readOnly: true
        ))
        // Queued or late edits for the deleted note: rejected, no session, no journal.
        let late = EditorToHostMessage.changes(
            noteId: note.id, txId: "t2", baseRevision: 1, revision: 2, changeSet: insert("?", after: 5)
        )
        #expect(controller.handle(late) == .needsFullText(currentRevision: 0))
        #expect(env.environment.existingSession(for: note.id) == nil)
        #expect(try env.journalFiles(note.id).isEmpty)
    }

    @Test func testFailedBatchDeleteKeepsOneSessionPerNote() throws {
        let env = try Env()
        let note = try env.store.create(text: "kept")
        try env.store.trash([note.id])
        let (controller, _) = try openInEditor(env, note.id)
        let session = try #require(controller.session)

        #expect(throws: StoreError.noteNotFound(id: "missing")) {
            try env.environment.closeSessions(ids: [note.id, "missing"]) {
                try env.store.deletePermanently([note.id, "missing"])
            }
        }
        #expect(try env.store.note(id: note.id) != nil)
        #expect(env.environment.existingSession(for: note.id) === session)
        #expect(try env.environment.session(for: note.id) === session)
        #expect(controller.session === session)
        #expect(session.textListenerCount == 1)
    }

    @Test func testSessionWhoseFlushFailsIsNeverEvicted() throws {
        let env = try Env()
        let note = try env.store.create(text: "unsaved")
        let session = try env.environment.session(for: note.id)
        _ = session.apply(txId: "t1", baseRevision: 0, changeSet: insert("!", after: 7), origin: nil)
        // Deleted by another process: the acked edit can no longer be committed.
        try env.externalStore().deletePermanently([note.id])

        env.environment.setOpenNoteIds([], for: ObjectIdentifier(env.model))
        #expect(env.environment.existingSession(for: note.id) === session)
        env.environment.flushAll()
        #expect(env.environment.existingSession(for: note.id) === session)
    }
}
