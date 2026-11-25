// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB
import Testing
@testable import TheoNotesCore

@Suite @MainActor struct JournalRecoveryCoordinatorTests {
    @Test func missingSyncKeyCanOfferSealedFilesForConfirmedMoveAside() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access()
        do {
            let journal = try EditJournal(directory: library.paths.journal, noteId: "orphan", encryptionKey: access.journalKey())
            try journal.writeBase(JournalBase(storeRevision: 0, baseText: "secret"))
            try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: " edit")])))
        }
        access.revoke()
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            try db.execute(sql: "DELETE FROM crypto_envelope; DELETE FROM sync_dirty")
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
        }
        let baseline = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(baseline.keyState == .waitingForSyncKey && baseline.quarantineFiles.isEmpty)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [], allowSealedMoveAside: true)
        #expect(report.keyState == .waitingForSyncKey && Set(report.quarantineFiles) == Set(["orphan.base", "orphan.jsonl"]))
        #expect(Set(report.keyUnavailableFiles) == Set(report.quarantineFiles))
        let bases = [
            "The files will be moved unchanged. Portable backups do not include them.",
            "The selected recovery files will be moved unchanged into this library's Recovery/Quarantine folder. Their edits may not appear in your notes until recovered. Encrypted files may still be recoverable with an older key or on another device. Back up these files separately; portable backups do not include them. Files: orphan.base, orphan.jsonl"
        ]
        for base in bases {
            #expect(JournalQuarantine.confirmationMessage(base: base, includesUnavailableKeyFiles: false) == base)
            #expect(JournalQuarantine.confirmationMessage(base: base, includesUnavailableKeyFiles: true) == base + " These files stay encrypted. If the notes key arrives later, Theo Notes cannot recover them automatically. If another device still has your notes password, keep waiting.")
        }
        let before = try Data(contentsOf: library.paths.journal.appendingPathComponent("orphan.base"))
        let selection = try JournalQuarantine.inspect(libraryRoot: library.paths.root, fileNames: report.quarantineFiles)
        let moved = try JournalQuarantine.moveAfterConfirmation(selection, store: library.store)
        #expect(try Data(contentsOf: moved.appendingPathComponent("orphan.base")) == before)
        let done = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(!done.hasUncommittedRecovery && done.keyState == nil)
    }
    private func seedPair(_ id: String, paths: AppPaths) throws {
        let journal = try EditJournal(directory: paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")])))
    }
    @Test(arguments: [false, true]) func loneBaseOfDeletedNoteIsRecoveredOnceAndUnblocks(movedAside: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "lone base text"))
        // A sync-style row delete keeps the files; the journal stays empty.
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        if movedAside { try EditJournal.moveAside(noteId: note.id, in: library.paths.journal) }
        for _ in 0..<2 {
            let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
            #expect(!report.hasUncommittedRecovery && report.failedSourceIDs.isEmpty && !report.cleanupPending)
        }
        #expect(try library.store.allNotes().filter { $0.text.contains("lone base text") }.count == 1)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func damagedAbortedMarkerMovesWithItsNoteFilesOnlyWithoutLiveSession() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "existing")
        var holder: NoteSession? = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        let leftover = note.id + ".base.unreplayed", leftoverBytes = try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "kept"))
        try leftoverBytes.write(to: library.paths.journal.appendingPathComponent(leftover))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = ".variant-aborted-\(hash).json"
        try Data("bad marker".utf8).write(to: library.paths.journal.appendingPathComponent(marker))
        let held = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(held.markerMoves.isEmpty && held.cleanupPending)
        #expect(holder != nil); holder = nil
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(report.markerMoves == [marker])
        let directory = try JournalQuarantine.moveAfterConfirmation(try JournalQuarantine.inspectMarker(store: library.store, markerName: marker), store: library.store)
        #expect(try Data(contentsOf: directory.appendingPathComponent(leftover)) == leftoverBytes)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path))
        let after = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(after.markerMoves.isEmpty && !after.cleanupPending && !after.hasUncommittedRecovery && after.keyState == nil)
        _ = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func damagedDiscardMarkerMovesAloneAndUnblocks() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let name = ".discard-" + String(repeating: "b", count: 64) + ".json"
        try Data("bad marker".utf8).write(to: library.paths.journal.appendingPathComponent(name))
        let before = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(before.markerMoves == [name] && before.hasUncommittedRecovery)
        let directory = try JournalQuarantine.moveAfterConfirmation(try JournalQuarantine.inspectMarker(store: library.store, markerName: name), store: library.store)
        #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == Data("bad marker".utf8))
        let after = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(after.markerMoves.isEmpty && !after.cleanupPending && !after.hasUncommittedRecovery && after.keyState == nil)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func unlockedReplayFailureOfSealedPairIsRetryableNotUnlock() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), note = try library.store.create(text: "base")
        try access.lock(noteId: note.id)
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: try #require(try library.store.note(id: note.id)).revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: access, liveSessionIDs: [], dirtyLiveSessionIDs: [],
                                                            existingReplayFailureIDs: [note.id])
        #expect(report.keyState == nil && report.failedSourceIDs == [note.id] && report.hasUncommittedRecovery)
    }
    @Test func ownKeyBundleTombstoneAfterResetMeansNoVaultAndIsPushed() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let server = SyncEngineTests.Server()
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: server, blobs: SyncPayloadReaderTests.Blobs())
        try NotePrivacy(store: library.store).setPassword("password").revoke()
        _ = try await engine.synchronize()  // the vault is published
        let note = try library.store.create(text: "plain")
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        #expect(holder.apply(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: "!")]), origin: nil) == .acked(revision: 1))
        try await library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        for name in [note.id + ".jsonl", note.id + ".base"] { try? FileManager.default.removeItem(at: library.paths.journal.appendingPathComponent(name)) }
        try NotePrivacy(store: library.store).deletePassword()
        // Our own outgoing tombstone means "vault deleted": the plain path saves, nothing is gated.
        #expect(try library.store.canRecoverMissingJournalPlain())
        let saved = try holder.preserveBrowserRecoveryResult(text: holder.text, baseRevision: holder.revision)
        #expect(saved.note.text == "plain!" && !saved.note.isLocked)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(report.keyState == nil && !report.hasUncommittedRecovery)
        _ = try await engine.synchronize()
        #expect(await server.history.contains { $0.mutation.entityType == .keyBundle && $0.mutation.tombstone })
        #expect(try library.store.canRecoverMissingJournalPlain())
        // A key bundle genuinely arriving from another device still counts as pending.
        try await library.db.pool.write { try $0.execute(sql: "INSERT INTO sync_inbox(sequence,entityType,entityId,serverRevision,wireEntity) VALUES(9999,'keyBundle','other',9,x'00')") }
        #expect(try !library.store.canRecoverMissingJournalPlain())
    }
    @Test func dirtyOwnTombstoneWithUploadsClosedStillLetsARemoteVaultCount() async throws {
        // S6: before the first sync completes (enabled = 0) the tombstone never reaches the outbox,
        // so "dirty wins" would swallow a newer remote vault; the dirty exemption must not apply.
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        try NotePrivacy(store: library.store).setPassword("password").revoke()
        try await library.db.pool.write { try $0.execute(sql: "DELETE FROM sync_dirty; DELETE FROM sync_outbox") }  // as if published
        try NotePrivacy(store: library.store).deletePassword()
        let (envelope, _) = try CryptoEnvelope.create(password: "other device")
        let bundle = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)), type: .keyBundle,
                                        id: "account-note-key", revision: 5, sequence: 10)
        try library.receive([bundle])
        _ = try await library.materializer().apply(bundle)
        #expect(try !library.store.canRecoverMissingJournalPlain())
    }
    @Test func loneBaseAfterResetInSyncedLibraryIsRecoveredWithoutBlocking() throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        try NotePrivacy(store: library.store).setPassword("password").revoke()
        let note = try library.store.create(text: "base")
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "synced lone base"))
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        try NotePrivacy(store: library.store).deletePassword()
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(report.keyState == nil && !report.hasUncommittedRecovery && report.failedSourceIDs.isEmpty && !report.cleanupPending)
        #expect(try library.store.allNotes().filter { $0.text.contains("synced lone base") }.count == 1)
    }
    @Test(arguments: ["", ".unreplayed"]) func crashAfterLoneBaseUnlinkBeforeMarkerRemovalFinishes(suffix: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "crash window base"))
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        if !suffix.isEmpty { try EditJournal.moveAside(noteId: note.id, in: library.paths.journal) }
        _ = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        let copyID = try #require(try library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM note WHERE text LIKE '%crash window base%'") })
        // The crash window: base unlinked, the empty journal and the marker still there.
        try Data().write(to: library.paths.journal.appendingPathComponent("\(note.id).jsonl\(suffix)"))
        let hash = SHA256.hash(data: Data((note.id + "\0" + suffix).utf8)).map { String(format: "%02x", $0) }.joined()
        let json = "{\"noteId\":\"\(note.id)\",\"suffix\":\"\(suffix)\",\"recoveryId\":\"\(copyID)\",\"journalHash\":\"\",\"baseHash\":\"AAAA\",\"isProtected\":false}"
        let marker = library.paths.journal.appendingPathComponent(".retirement-\(hash).json")
        try Data(json.utf8).write(to: marker)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(!report.hasUncommittedRecovery && !report.cleanupPending)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    /// Q4 (option b): a session save (Mac deleted-session step, iOS orphan gate) and the journal pass
    /// can share an id. If the user edits or trashes that copy, journal recovery moves to the next
    /// generation instead of failing with "file exists"; a crash before its commit stays idempotent.
    @Test(arguments: ["edit", "trash"]) func journalRecoveryMovesPastAnEditedCopyAtItsId(change: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "Original")
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal, commitDelay: .seconds(60))
        #expect(holder.apply(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 8, insert: "Typed text")]), origin: nil) == .acked(revision: 1))
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        // The session save uses the local revision (1), equal to the journal base's store revision (1).
        let copy = try holder.preserveBrowserRecoveryResult(text: holder.text, baseRevision: holder.revision).note
        try holder.invalidate()  // the closed session holds no writer
        if change == "edit" { _ = try library.store.updateText(id: copy.id, text: "Edited copy", expectedRevision: copy.revision) }
        else { try library.store.trash([copy.id]) }
        // A crash before the journal pass commits: nothing is written.
        try library.db.pool.write { try $0.execute(sql: "CREATE TRIGGER crash_recovery BEFORE INSERT ON note BEGIN SELECT RAISE(ABORT, 'crash'); END") }
        _ = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        try library.db.pool.write { try $0.execute(sql: "DROP TRIGGER crash_recovery") }
        var reports: [JournalRecoveryCoordinator.Report] = []
        for _ in 0..<2 {
            reports.append(try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: []))
        }
        for report in reports { #expect(report.keyState == nil && !report.hasUncommittedRecovery && report.failedSourceIDs.isEmpty) }
        let recovered = try library.store.allNotes().filter { $0.text == "Typed text" && $0.id != copy.id }
        #expect(recovered.count == 1 && reports.allSatisfy { $0.singles.map(\.note.id) == recovered.map(\.id) })
        let kept = try #require(try library.store.note(id: copy.id))
        #expect(change == "edit" ? kept.text == "Edited copy" : kept.location == .trash)
        try MissingJournalRecovery.removeLeftover(try #require(reports.last?.singles.first).retirement)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func damagedMarkerIsOfferedForMoveAsideAndTheMoveClearsTheBlock() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let name = ".retirement-" + String(repeating: "a", count: 64) + ".json"
        let bytes = Data("not a marker".utf8)
        try bytes.write(to: library.paths.journal.appendingPathComponent(name))
        let before = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(before.markerMoves == [name] && before.cleanupPending)
        let selection = try JournalQuarantine.inspectMarker(store: library.store, markerName: name)
        let directory = try JournalQuarantine.moveAfterConfirmation(selection, store: library.store)
        #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes)
        let after = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(after.markerMoves.isEmpty && !after.cleanupPending && !after.hasUncommittedRecovery)
    }
    @Test func interruptedVariantMarkerWithDamagedBaseIsOfferedForMoveAside() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString.lowercased()
        try seedPair(id, paths: library.paths)
        let saved = try JournalVariantRecovery.recover(noteId: id, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil,
                                                               afterRemove: { throw CocoaError(.fileWriteUnknown) })
        }
        let base = library.paths.journal.appendingPathComponent("\(id).base")
        try Data("damaged".utf8).write(to: base)
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        let marker = try #require(report.markerMoves.first)
        #expect(marker.hasPrefix(".variant-confirm-"))
        let directory = try JournalQuarantine.moveAfterConfirmation(try JournalQuarantine.inspectMarker(store: library.store, markerName: marker), store: library.store)
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(id).base")) == Data("damaged".utf8))
        let after = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(after.markerMoves.isEmpty && !after.variantMarkerNeedsAttention)
    }
    @Test func committedCopyAndNoticeDoNotDeleteOriginal() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString.lowercased()
        try seedPair(id, paths: library.paths)
        let journal = library.paths.journal.appendingPathComponent("\(id).jsonl")
        let before = try Data(contentsOf: journal)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(report.singles.count == 1)
        let copy = try #require(report.singles.first)
        #expect(copy.note.text == "Base edit")
        #expect(try Data(contentsOf: journal) == before)
        #expect(!report.hasUncommittedRecovery)
    }
    @Test func confirmedMarkerDoesNotAutoUnlinkWhileAnySessionIsLive() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString.lowercased()
        try seedPair(id, paths: library.paths)
        let saved = try JournalVariantRecovery.recover(noteId: id, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil,
                                                               afterRemove: { throw CocoaError(.fileWriteUnknown) })
        }
        let remaining = library.paths.journal.appendingPathComponent("\(id).base")
        let before = try Data(contentsOf: remaining)
        let held = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [id], dirtyLiveSessionIDs: [id])
        #expect(!held.hasUncommittedRecovery && held.keyState == nil)
        #expect(held.variantMarkerNeedsAttention)
        #expect(try Data(contentsOf: remaining) == before)
        _ = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(!FileManager.default.fileExists(atPath: remaining.path))
    }
    @Test func malformedAbortedMarkerDoesNotBlockAnotherSourceRecovery() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let bad = try library.store.create(text: "existing")
        let hash = SHA256.hash(data: Data(bad.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("bad marker".utf8).write(to: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let other = UUID().uuidString.lowercased()
        try seedPair(other, paths: library.paths)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [], dirtyLiveSessionIDs: [])
        #expect(report.singles.contains { $0.sourceID == other && $0.note.text == "Base edit" })
        #expect(report.variantMarkerNeedsAttention)
        #expect(FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json").path))
    }
    @Test func pendingKeyWithLiveDirtyOrphanDoesNotTouchSessionFiles() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString.lowercased()
        try seedPair(id, paths: library.paths)
        try library.db.pool.write { db in try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId) VALUES('keyBundle','fixture')") }
        let journal = library.paths.journal.appendingPathComponent("\(id).jsonl")
        let before = try Data(contentsOf: journal)
        let report = try JournalRecoveryCoordinator.recover(store: library.store, access: nil, liveSessionIDs: [id], dirtyLiveSessionIDs: [id])
        #expect(report.keyState == .waitingForSyncKey)
        #expect(report.hasUncommittedRecovery && report.singles.isEmpty)
        #expect(try Data(contentsOf: journal) == before)
    }
}
