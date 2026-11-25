// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import CryptoKit
import Testing
@testable import TheoNotesCore

@Suite struct MissingJournalRecoveryTests {
    @Test(arguments: [false, true]) func repeatedRecoveryOfUnchangedPairReadsNoFile(sealed: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = sealed ? try library.access() : nil
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access?.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let first = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        // Unreadable files: any read on the second pass would throw.
        for url in [journal.fileURL, journal.baseURL] { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path) }
        defer { for url in [journal.fileURL, journal.baseURL] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) } }
        let second = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        #expect(second.note.id == first.note.id && !second.created)
        // Deleting the copy invalidates the hit: the full path runs and must read again.
        try library.store.trash([first.note.id]); try library.store.deletePermanently([first.note.id])
        #expect(throws: (any Error).self) { try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access) }
    }
    @Test func resetWarningNamesEachAffectedNoteOnceAndExplainsCopying() {
        let text = MissingJournalRecovery.resetWarning(noteIDs: ["note-b", "note-a", "note-b", "note-c"])
        #expect(text.hasPrefix("3 affected notes (ids: note-a, note-b, note-c)."))
        #expect(text.contains("permanently") && text.contains("open editor") && text.contains("copy"))
    }
    @Test @MainActor func resetInvalidatesLiveHolderUnderWriterThenDiscards() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try access.lock(noteId: note.id)
        let holder = try NoteSession(noteId: note.id, store: access, journalDirectory: library.paths.journal,
                                     journalKey: access.journalKey(), commitDelay: .seconds(60))
        #expect(holder.apply(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 1))
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        let plan = try MissingJournalRecovery.prepareResetDiscard(store: library.store)
        #expect(plan.items.map(\.noteID) == [note.id])
        let journal = library.paths.journal.appendingPathComponent(note.id + ".jsonl"), base = library.paths.journal.appendingPathComponent(note.id + ".base")
        let before = try Data(contentsOf: journal)
        try MissingJournalRecovery.validateDiscardsAndInvalidate(plan.items.map(\.token), store: library.store, matching: plan.sessionFence)
        #expect(holder.isInvalidated)
        #expect(holder.apply(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "?")]), origin: nil) == .needsFullText(currentRevision: holder.revision))
        #expect(throws: NoteSessionError.sessionClosed) { try holder.flush() }
        #expect(try Data(contentsOf: journal) == before)
        for item in plan.items { try MissingJournalRecovery.discardLeftoverAfterConfirmation(item.token, store: library.store) }
        #expect(!FileManager.default.fileExists(atPath: journal.path) && !FileManager.default.fileExists(atPath: base.path))
    }
    @Test @MainActor func resetPlanNeverIncludesPlainRamOnlyText() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        _ = try library.access()
        let note = try library.store.create(text: "plain")
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        #expect(holder.apply(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 1))
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        for name in [note.id + ".jsonl", note.id + ".base"] { try? FileManager.default.removeItem(at: library.paths.journal.appendingPathComponent(name)) }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.prepareResetDiscard(store: library.store) }
        #expect(!holder.isInvalidated && holder.text == "plain!")
    }
    @Test @MainActor func resetPlanCoversSealedPairAndDirtyRamOnlySessionButRefusesPlainJournal() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access()
        let sealed = try library.store.create(text: "base"), ram = try library.store.create(text: "ram")
        try access.lock(noteId: ram.id)
        let holder = try NoteSession(noteId: ram.id, store: access, journalDirectory: library.paths.journal, journalKey: access.journalKey())
        #expect(holder.apply(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(3), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 1))
        try library.store.trash([sealed.id]); try library.store.deletePermanently([sealed.id])
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [ram.id]) }
        for name in [ram.id + ".jsonl", ram.id + ".base"] { try? FileManager.default.removeItem(at: library.paths.journal.appendingPathComponent(name)) }
        let journal = try EditJournal(directory: library.paths.journal, noteId: sealed.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: sealed.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let plan = try MissingJournalRecovery.prepareResetDiscard(store: library.store)
        #expect(plan.items.map(\.noteID) == [sealed.id] && plan.ramOnlyNoteIDs == [ram.id])
        let plain = try EditJournal(directory: library.paths.journal, noteId: UUID().uuidString.lowercased())
        try plain.writeBase(JournalBase(storeRevision: 0, baseText: "plain"))
        try plain.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")])))
        #expect(throws: (any Error).self) { try MissingJournalRecovery.prepareResetDiscard(store: library.store) }
    }
    @Test @MainActor func changedDiscardTokenNeverInvalidatesLiveHolder() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        let access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        let fence = NoteSession.captureSessionFence(journalDirectory: library.paths.journal, noteIDs: [note.id])
        try journal.append(JournalEntry(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")])))
        #expect(throws: (any Error).self) { try MissingJournalRecovery.validateDiscardsAndInvalidate([token], store: library.store, matching: fence) }
        #expect(!holder.isInvalidated && holder.text == "base")
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func markerlessBaseWaitsOnlyForItsExcludedSource() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let first = try library.store.create(text: "first"), second = try library.store.create(text: "second")
        try library.store.trash([first.id, second.id]); try library.store.deletePermanently([first.id, second.id])
        for note in [first, second] {
            let url = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
            try JSONEncoder().encode(JournalBase(storeRevision: note.revision, baseText: note.text)).write(to: url)
        }
        let skipped = try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil, excluding: [first.id])
        #expect(skipped == [first.id])
        #expect(FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(first.id + ".base.unreplayed").path))
        #expect(!FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(second.id + ".base.unreplayed").path))
        #expect(try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil, excluding: []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(first.id + ".base.unreplayed").path))
    }
    @Test func forgottenPasswordDiscardAllowsDeletedRecoveryCopy() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        access.revoke()
        try library.store.trash([saved.note.id]); try library.store.deletePermanently([saved.note.id])
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        try MissingJournalRecovery.discardLeftoverAfterConfirmation(token, store: library.store)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func discardRejectsChangedGenerationEvenWhenRecoveryCopyWasDeleted() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        access.revoke()
        try library.store.trash([saved.note.id]); try library.store.deletePermanently([saved.note.id])
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        try library.db.pool.write { db in
            let fetched = try Row.fetchOne(db, sql: "SELECT key,value FROM setting WHERE key LIKE 'journal.recovery.generation.%'")
            let row = try #require(fetched)
            let value: String = row["value"]
            let parsed = try JSONSerialization.jsonObject(with: Data(value.utf8))
            var object = try #require(parsed as? [String: Any])
            object["generation"] = try #require(object["generation"] as? Int) + 1
            let changed = try JSONSerialization.data(withJSONObject: object)
            try db.execute(sql: "UPDATE setting SET value=? WHERE key=?", arguments: [String(decoding: changed, as: UTF8.self), row["key"] as String])
        }
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.discardLeftoverAfterConfirmation(token, store: library.store) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: journal.baseURL.path))
    }

    @Test(arguments: [false, true]) func removalRefusesWhenSourceReappearsOrCopyIsDeleted(sourceReturns: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        if sourceReturns { _ = try library.db.pool.write { try NoteStore.insert(id: note.id, text: "restored", now: .now, in: $0) } }
        else { try library.store.trash([saved.note.id]); try library.store.deletePermanently([saved.note.id]) }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func protectedRemovalRefusesRestoredSourceAndKeepsBothFiles() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        _ = try library.db.pool.write { try NoteStore.insert(id: note.id, text: "restored", now: .now, in: $0) }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement, access: access) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func plainRecoveryCopyLockedAfterwardRequiresCurrentVaultAccess() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        let access = try library.access()
        try access.lock(noteId: saved.note.id)
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        try MissingJournalRecovery.removeLeftover(saved.retirement, access: access)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func interruptedRemovalWithDeletedCopyPreservesRemainingBase() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try MissingJournalRecovery.removeLeftover(saved.retirement, afterJournalRemoved: { throw CocoaError(.fileWriteUnknown) })
        }
        try library.store.trash([saved.note.id]); try library.store.deletePermanently([saved.note.id])
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(try library.store.allNotes().contains { $0.text == "base" })
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func validConfirmedRetirementMarkerCannotBeQuarantined() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement, beforeJournalRemoved: { throw CocoaError(.fileWriteUnknown) }, afterJournalRemoved: {}) }
        let names = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path)
        let marker = try #require(names.first { $0.hasPrefix(".retirement-") })
        #expect(throws: (any Error).self) { try JournalQuarantine.inspectDamagedMarker(libraryRoot: library.paths.root, fileName: marker) }
        #expect(FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(marker).path))
    }
    @Test func damagedMarkerDoesNotPreventOtherConfirmedRetirements() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement, beforeJournalRemoved: { throw CocoaError(.fileWriteUnknown) }, afterJournalRemoved: {}) }
        let bad = library.paths.journal.appendingPathComponent(".retirement-" + String(repeating: "a", count: 64) + ".json")
        try Data("bad".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil) }
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: bad.path))
    }
    @Test func resetRejectsMixedOrTruncatedProtectedJournal() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let original = try Data(contentsOf: journal.fileURL)
        let handle = try FileHandle(forWritingTo: journal.fileURL); try handle.seekToEnd(); try handle.write(contentsOf: Data("plain text\n".utf8)); try handle.close()
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true) }
        try Data(original.dropLast()).write(to: journal.fileURL)
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func resetRetriesOnlyRemainingConfirmedProtectedPair() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), first = try library.store.create(text: "first"), second = try library.store.create(text: "second")
        try library.store.trash([first.id, second.id]); try library.store.deletePermanently([first.id, second.id])
        let j1 = try EditJournal(directory: library.paths.journal, noteId: first.id, encryptionKey: access.journalKey())
        let j2 = try EditJournal(directory: library.paths.journal, noteId: second.id, encryptionKey: access.journalKey())
        try j1.writeBase(JournalBase(storeRevision: first.revision, baseText: "first"))
        try j2.writeBase(JournalBase(storeRevision: second.revision, baseText: "second"))
        try j1.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")])))
        try j2.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        access.revoke()
        let t1 = try MissingJournalRecovery.prepareDiscard(noteId: first.id, store: library.store, forVaultReset: true)
        let t2 = try MissingJournalRecovery.prepareDiscard(noteId: second.id, store: library.store, forVaultReset: true)
        try MissingJournalRecovery.discardLeftoverAfterConfirmation(t1, store: library.store)
        try j2.append(JournalEntry(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(7), .replace(deleteLength: 0, insert: "!")])))
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.discardLeftoverAfterConfirmation(t2, store: library.store) }
        #expect(!FileManager.default.fileExists(atPath: j1.fileURL.path) && FileManager.default.fileExists(atPath: j2.fileURL.path))
        let privacy = NotePrivacy(store: library.store)
        #expect(throws: NotePrivacyError.pendingEdits) { try privacy.deletePassword() }
        #expect(try privacy.hasPassword)
        let retry = try MissingJournalRecovery.prepareDiscard(noteId: second.id, store: library.store, forVaultReset: true)
        try MissingJournalRecovery.discardLeftoverAfterConfirmation(retry, store: library.store)
        try privacy.deletePassword()
        #expect(try !privacy.hasPassword)
    }
    @Test func confirmedResetCanDiscardOneUnrecoveredSealedPairWithoutKey() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " private")])))
        access.revoke()
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store) }
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        try MissingJournalRecovery.discardLeftoverAfterConfirmation(token, store: library.store)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test(arguments: [false, true]) func resetNeverDiscardsUnprotectedJournal(pendingKey: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        if pendingKey {
            try library.db.pool.write { try $0.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')") }
        }
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func confirmedDiscardResumesAfterInterruptedJournalRemovalWithoutKey() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        _ = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        access.revoke()
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        #expect(throws: (any Error).self) {
            try MissingJournalRecovery.discardLeftoverAfterConfirmation(token, store: library.store, afterJournalRemoved: { throw CocoaError(.fileWriteUnknown) })
        }
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path) && FileManager.default.fileExists(atPath: journal.baseURL.path))
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func explicitlyConfirmedDiscardWithoutKeyIsBoundToFilesAndGeneration() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access(iterations: 100_000)
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        _ = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        access.revoke()
        let token = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        try journal.append(JournalEntry(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(9), .replace(deleteLength: 0, insert: " later")])))
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.discardLeftoverAfterConfirmation(token, store: library.store) }
        #expect(try journal.entries().count == 2)
        let unlocked = try NotePrivacy(store: library.store).unlock(password: "fixture-password")
        _ = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: unlocked)
        unlocked.revoke()
        let retry = try MissingJournalRecovery.prepareDiscard(noteId: note.id, store: library.store, forVaultReset: true)
        try MissingJournalRecovery.discardLeftoverAfterConfirmation(retry, store: library.store)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func unlockedRecoveryCopyStillRequiresVaultAccessForProtectedRetirement() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        try access.removeLock(noteId: saved.note.id)
        #expect(try library.store.note(id: saved.note.id)?.isLocked == false)
        let retry = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        #expect(!retry.created && retry.note.id == saved.note.id && !retry.note.isLocked)
        #expect(throws: JournalProtectionError.keyRequired) { try MissingJournalRecovery.removeLeftover(saved.retirement) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        try MissingJournalRecovery.removeLeftover(saved.retirement, access: access)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func protectedRetirementKeepsRevocationWaitingUntilDeleteCompletes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        final class EventLog: @unchecked Sendable {
            private let lock = NSLock(); private var items: [String] = []
            func append(_ event: String) { lock.withLock { items.append(event) } }
            var events: [String] { lock.withLock { items } }
        }
        let log = EventLog(), entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        try MissingJournalRecovery.removeLeftover(saved.retirement, access: access, beforeJournalRemoved: {
            // A real concurrent revoke on its own thread; the gate makes it start before the unlink.
            Thread { log.append("revoking"); entered.signal(); access.revoke(); log.append("revoked"); finished.signal() }.start()
            #expect(entered.wait(timeout: .now() + 60) == .success)  // deadlock guard only
        }, afterJournalRemoved: { log.append("journal removed") })
        log.append("retirement returned")
        #expect(finished.wait(timeout: .now() + 60) == .success)  // deadlock guard only
        let events = log.events
        #expect(events.firstIndex(of: "revoking")! < events.firstIndex(of: "journal removed")!)
        #expect(events.firstIndex(of: "journal removed")! < events.firstIndex(of: "revoked")!)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func replacedEnvelopeCannotAuthorizeProtectedRetirement() throws {
        let library = try PrivacyTestLibrary(), other = try PrivacyTestLibrary()
        defer { library.cleanup(); other.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        _ = try other.access()
        let otherEnvelope = try #require(try other.db.pool.read { try Data.fetchOne($0, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") })
        try library.db.pool.write { try $0.execute(sql: "UPDATE crypto_envelope SET envelope=? WHERE id=1", arguments: [otherEnvelope]) }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(saved.retirement, access: access) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path) && FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func protectedRecoveryNeverPersistsUnkeyedPlainJournalDigest() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "short")
        let access = try library.access(iterations: 100_000)
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "short"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " secret")])))
        // Base and journal digests, as raw bytes, hex and the base64 that JSON uses for Data.
        let forms = try [journal.baseURL, journal.fileURL].flatMap { url -> [Data] in
            let digest = Data(SHA256.hash(data: try Data(contentsOf: url)))
            return [digest, Data(digest.map { String(format: "%02x", $0) }.joined().utf8), Data(digest.base64EncodedString().utf8)]
        }
        let result = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        let values = try library.db.pool.read { try String.fetchAll($0, sql: "SELECT value FROM setting WHERE key LIKE 'journal.recovery.generation.%'") }
        let settings = Data(values.joined().utf8)
        #expect(forms.allSatisfy { settings.range(of: $0) == nil })
        #expect(throws: (any Error).self) {
            try MissingJournalRecovery.removeLeftover(result.retirement, access: access, beforeJournalRemoved: { throw CocoaError(.fileWriteUnknown) }, afterJournalRemoved: {})
        }
        let markers = try FileManager.default.contentsOfDirectory(at: library.paths.journal, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".retirement-") }
        let markerURL = try #require(markers.first)
        let marker = try Data(contentsOf: markerURL)
        #expect(forms.allSatisfy { marker.range(of: $0) == nil })
        access.revoke()
        #expect(throws: (any Error).self) { try MissingJournalRecovery.removeLeftover(result.retirement, access: access) }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil) }
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
        let unlocked = try NotePrivacy(store: library.store).unlock(password: "fixture-password")
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: unlocked)
        let snapshot = try #require(try LibraryBackup(database: library.db, paths: library.paths).createDailyDatabaseSnapshot())
        let bytes = try Data(contentsOf: snapshot)
        #expect(forms.allSatisfy { bytes.range(of: $0) == nil })
    }
    @Test(arguments: [false, true]) func editedOrTrashedRecoveryIsRecognizedOnRescan(locked: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = locked ? try library.access() : nil
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let first = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        if let access { _ = try access.updateText(id: first.note.id, text: "My edit", expectedRevision: first.note.revision, now: .now) }
        else { _ = try library.store.updateText(id: first.note.id, text: "My edit", expectedRevision: first.note.revision) }
        try library.store.trash([first.note.id])
        let retry = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        #expect(!retry.created && retry.note.id == first.note.id && retry.note.text == "My edit" && retry.note.location == .trash)
    }
    @Test func generationAndCopyCommitTogetherAfterWriterFailure() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "a")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "a"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "b")])))
        try library.db.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_journal_generation BEFORE INSERT ON setting WHEN NEW.key LIKE 'journal.recovery.generation.%' BEGIN SELECT RAISE(ABORT, 'test failure'); END") }
        #expect(throws: (any Error).self) { try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil) }
        #expect(try library.store.allNotes().isEmpty)
        try library.db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_journal_generation") }
        let first = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        let retry = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(first.note.id == retry.note.id && !retry.created)
        #expect(try library.store.allNotes().count == 1)
    }
    @Test(arguments: [false, true]) func deletedRecoveryCopyIsRecreatedUnderNewIdentity(locked: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let access = locked ? try library.access() : nil
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let first = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        try library.store.trash([first.note.id]); try library.store.deletePermanently([first.note.id])
        let second = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access, avoidingRecoveryID: first.note.id)
        #expect(first.note.id != second.note.id && second.note.text == "base text")
        let third = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access, avoidingRecoveryID: first.note.id)
        #expect(!third.created && third.note.id == second.note.id)
        try library.store.trash([second.note.id]); try library.store.deletePermanently([second.note.id])
        let fourth = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access, avoidingRecoveryID: second.note.id)
        #expect(fourth.note.id != first.note.id && fourth.note.id != second.note.id)
        #expect(fourth.note.text == "base text")
    }
    @Test(arguments: [false, true]) func interruptedBeforeJournalRemovalCanResumeOrRetry(changed: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "a")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "a"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "b")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try MissingJournalRecovery.removeLeftover(saved.retirement, beforeJournalRemoved: { throw CocoaError(.fileWriteUnknown) }, afterJournalRemoved: {})
        }
        if changed { try journal.append(JournalEntry(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(2), .replace(deleteLength: 0, insert: "c")]))) }
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        if changed {
            #expect(try journal.entries().count == 2)
            let later = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
            #expect(later.note.text == "abc")
        } else {
            #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
            #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
        }
    }
    @Test func orphanBaseWithoutMarkerIsSavedBeforeRemoval() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "original")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "unmarked base"))
        try FileManager.default.removeItem(at: journal.fileURL)
        try EditJournal.moveAside(noteId: note.id, in: library.paths.journal)
        let base = library.paths.journal.appendingPathComponent("\(note.id).base.unreplayed")
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(try library.store.allNotes().contains { $0.text == "unmarked base" })
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }
    @Test func orphanBaseAfterCrashDoesNotReuseDeletedRecoveryIdentity() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "original")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let baseURL = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        let base = JournalBase(storeRevision: note.revision, baseText: "base survives")
        let bytes = try JSONEncoder().encode(base)
        try bytes.write(to: baseURL)
        let hex = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let key = "journal.recovery.generation." + hex(Data((note.id + "\0.unreplayed").utf8))
        let context = JournalRecoveryContext(key: key, journalHash: "lone-base", baseHash: hex(bytes), avoidingID: nil)
        let saved = try library.store.preserveBrowserRecovery(noteId: note.id, text: base.baseText, baseRevision: base.storeRevision, now: .now, journalContext: context)
        try library.store.trash([saved.note.id]); try library.store.deletePermanently([saved.note.id])
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(try library.store.allNotes().contains { $0.id != saved.note.id && $0.text == "base survives" })
        #expect(!FileManager.default.fileExists(atPath: baseURL.path))
    }
    @Test(arguments: [false, true]) func interruptedRetirementPreservesChangedBaseAndResumes(changed: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " text")])))
        let saved = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try MissingJournalRecovery.removeLeftover(saved.retirement, afterJournalRemoved: { throw CocoaError(.fileWriteUnknown) })
        }
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
        if changed { try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "new base survives")) }
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(!FileManager.default.fileExists(atPath: journal.baseURL.path))
        #expect(try library.store.allNotes().contains { $0.text == "base text" })
        if changed { #expect(try library.store.allNotes().contains { $0.text == "new base survives" }) }
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
    }
    @Test func openWriterAfterRecoveryCannotLoseLaterAcknowledgedText() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "a")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "a"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "b")])))
        let first = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(first.note.text == "ab")
        try journal.append(JournalEntry(txId: "2", baseRevision: 1, changeSet: ChangeSet(sections: [.retain(2), .replace(deleteLength: 0, insert: "c")])))
        #expect(throws: MissingJournalRecovery.RetirementError.changed) { try MissingJournalRecovery.removeLeftover(first.retirement) }
        let second = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil)
        #expect(second.note.text == "abc")
        #expect(try journal.entries().count == 2)
        try MissingJournalRecovery.removeLeftover(second.retirement)
        #expect(!FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func ambiguousMovedAsidePairsStayUntouched() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString
        for name in ["\(id).jsonl.unreplayed", "\(id).base.unreplayed", "\(id).jsonl.unreplayed.1", "\(id).base.unreplayed.1"] {
            try Data("retained".utf8).write(to: library.paths.journal.appendingPathComponent(name))
        }
        #expect(try MissingJournalRecovery.candidates(directory: library.paths.journal).isEmpty)
        #expect(throws: (any Error).self) { try MissingJournalRecovery.recover(noteId: id, directory: library.paths.journal, suffix: ".unreplayed", store: library.store, access: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path).count == 4)
    }
    @Test(arguments: [false, true]) func missingPlainJournalIsRecoveredWithCurrentVaultPolicy(vault: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let access = vault ? try NotePrivacy(store: library.store).setPassword("password") : nil
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " recovered")])))
        let before = try Data(contentsOf: journal.fileURL)
        if vault {
            #expect(throws: JournalProtectionError.keyRequired) { try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: nil) }
            #expect(try Data(contentsOf: journal.fileURL) == before)
        }
        let result = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        #expect(result.note.text == "base recovered" && result.note.isLocked == vault)
        #expect(try Data(contentsOf: journal.fileURL) == before)
        let replay = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, store: library.store, access: access)
        #expect(!replay.created && replay.note.id == result.note.id)
        if vault { #expect(try library.store.note(id: result.note.id)?.text == "") }
    }

    @Test func sealedMovedAsideJournalIsRecoveredAfterUnlock() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "private")
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "private"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(7), .replace(deleteLength: 0, insert: " text")])))
        try journal.moveAside()
        #expect(throws: JournalProtectionError.keyRequired) { try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, suffix: ".unreplayed", store: library.store, access: nil) }
        let recovered = try MissingJournalRecovery.recover(noteId: note.id, directory: library.paths.journal, suffix: ".unreplayed", store: library.store, access: access)
        #expect(recovered.note.isLocked && recovered.note.text == "private text")
    }
}
