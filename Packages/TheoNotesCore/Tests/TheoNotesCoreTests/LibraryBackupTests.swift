// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct LibraryBackupTests {
    struct Library {
        let paths: AppPaths, db: AppDatabase, store: NoteStore
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID())"))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        var backup: LibraryBackup { LibraryBackup(database: db, paths: paths) }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
    }

    /// Cancel is checked at the boundaries of the transaction, not only per record: the restoring
    /// task cancels itself from inside its own transaction (a SQL trace on the library
    /// connection) at a point where no record is left to check, and the restore still rolls back.
    @Test func aRestoreCancelledInsideItsTransactionRollsBackWithoutRecords() async throws {
        let empty = try Library(), library = try Library()
        defer { empty.cleanup(); library.cleanup() }
        let note = try library.store.create(text: "keep me")
        let emptyArchive = library.paths.root.appendingPathComponent("empty.baerchen-backup")
        try empty.backup.create(at: emptyArchive) // no note at all

        // The first marker is read before the destructive block, the second one is its last write.
        for marker in ["SELECT (SELECT COUNT(*) FROM staging_batch)+(SELECT COUNT(*) FROM privacy_transition)", "DELETE FROM external_ref"] {
            let reached = Reached()
            try await library.db.pool.write { db in
                db.trace { event in
                    if "\(event)".contains(marker) {
                        reached.set()
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            let backup = library.backup
            let task = Task.detached { try backup.restore(emptyArchive, mode: .replaceAll) }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(reached.isSet, "\(marker) was reached")
            #expect(try library.store.note(id: note.id)?.text == "keep me", "rolled back after \(marker)")
            try await library.db.pool.write { db in db.trace(nil) }
        }
        // Not cancelled, the same Replace All with an empty backup does empty the library.
        _ = try library.backup.restore(emptyArchive, mode: .replaceAll)
        #expect(try library.store.note(id: note.id) == nil)
    }

    final class Reached: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    @Test func replaceAllRetainsNewestThreeSafetyArchivesAndPreservesOtherCopies() throws {
        let source = try Library(), destination = try Library(), recovered = try Library()
        defer { source.cleanup(); destination.cleanup(); recovered.cleanup() }
        let incoming = try source.store.create(text: "incoming")
        let archive = try source.backup.createRolling()
        let local = try destination.store.create(text: "before restore")
        let rolling = try destination.backup.createRolling()
        let daily = try #require(try destination.backup.createDailyDatabaseSnapshot())
        let chosen = destination.paths.root.appendingPathComponent("chosen.baerchen-backup")
        try source.backup.create(at: chosen)
        let custom = destination.paths.backups.appendingPathComponent("my-copy.baerchen-backup")
        try source.backup.create(at: custom)
        // Even a reserved-looking but uncatalogued file is not a retention candidate.
        let unregistered = destination.paths.backups.appendingPathComponent("baerchen-safety-\(UUID()).baerchen-backup")
        try Data("user copy".utf8).write(to: unregistered)
        var safety: [URL] = []
        for index in 0..<5 {
            if let note = try destination.store.note(id: incoming.id) {
                _ = try destination.store.updateText(id: note.id, text: "before \(index)", expectedRevision: note.revision)
            }
            let result = try destination.backup.restore(index == 0 ? chosen : archive, mode: .replaceAll)
            safety.append(try #require(result.safetyBackup))
        }
        #expect(safety.allSatisfy { $0.lastPathComponent.hasPrefix("baerchen-safety-") })
        let catalog = try destination.backup.localBackups().map(\.url)
        #expect(Set(catalog) == Set([rolling] + Array(safety.suffix(3))))
        for old in safety.prefix(2) { #expect(!FileManager.default.fileExists(atPath: old.path)) }
        for kept in [rolling, daily, chosen, custom, unregistered] + Array(safety.suffix(3)) {
            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
        let newest = try #require(safety.last)
        _ = try recovered.backup.restore(newest)
        #expect(try recovered.store.note(id: incoming.id)?.text == "before 4")
        #expect(try destination.store.note(id: local.id) == nil)
    }

    @Test func selectedOlderSafetyArchiveSurvivesUntilAnUnprotectedRestore() throws {
        let library = try Library()
        defer { library.cleanup() }
        _ = try library.store.create(text: "original")
        let external = library.paths.root.appendingPathComponent("chosen.baerchen-backup")
        try library.backup.create(at: external)
        let selected = try #require(try library.backup.restore(external, mode: .replaceAll).safetyBackup)
        for _ in 0..<2 { _ = try library.backup.restore(external, mode: .replaceAll) }
        _ = try library.backup.restore(selected, mode: .replaceAll)
        #expect(FileManager.default.fileExists(atPath: selected.path))
        #expect(try library.backup.localBackups().count == 4)
        _ = try library.backup.restore(external, mode: .replaceAll)
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(try library.backup.localBackups().count == 3)
    }

    @Test func failedSafetyValidationAndPublicationPreserveEarlierCopiesAndLibrary() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        _ = try source.store.create(text: "incoming")
        let archive = try source.backup.createRolling()
        _ = try destination.store.create(text: "keep this library")
        let original = try destination.store.allNotes()
        let rolling = try destination.backup.createRolling()
        // Existing safety copies must not be pruned when preparing the next one fails.
        for index in 0..<3 {
            let url = destination.paths.backups.appendingPathComponent("baerchen-safety-\(UUID()).baerchen-backup")
            try FileManager.default.copyItem(at: rolling, to: url)
            try destination.db.pool.write {
                try $0.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES(?,?,?,?)",
                               arguments: [UUID().uuidString, url.lastPathComponent, Date(timeIntervalSince1970: Double(index)), "[]"])
            }
        }
        let earlier = try destination.backup.localBackups().map(\.url)
        try destination.db.pool.write {
            try $0.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?)", arguments: [Data("invalid envelope".utf8)])
        }
        #expect(throws: BackupError.invalidManifest) { try destination.backup.restore(archive, mode: .replaceAll) }
        try destination.db.pool.write {
            try $0.execute(sql: "DELETE FROM crypto_envelope")
            // This abort occurs after ZIP creation and inspection, before publication.
            try $0.execute(sql: "CREATE TRIGGER fail_backup BEFORE INSERT ON backup_catalog BEGIN SELECT RAISE(ABORT, 'injected backup failure'); END")
        }
        #expect(throws: (any Error).self) { try destination.backup.restore(archive, mode: .replaceAll) }
        #expect(try destination.store.allNotes() == original)
        #expect(Set(try destination.backup.localBackups().map(\.url)) == Set(earlier))
        let remainingNames = Set(try FileManager.default.contentsOfDirectory(at: destination.paths.backups, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        #expect(remainingNames == Set(earlier.map(\.lastPathComponent)))
        for url in earlier { #expect(try destination.backup.inspect(url).noteCount == 1) }
    }

    @Test func failedSafetyPruningKeepsPublishedRecoveryAndRetriesStaleCatalog() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "original")
        let archive = library.paths.root.appendingPathComponent("input.baerchen-backup")
        try library.backup.create(at: archive)
        var older: [URL] = []
        for _ in 0..<3 { older.append(try #require(try library.backup.restore(archive, mode: .replaceAll).safetyBackup)) }
        _ = try library.store.updateText(id: note.id, text: "latest local changes", expectedRevision: try #require(try library.store.note(id: note.id)).revision)
        try library.db.pool.write {
            try $0.execute(sql: "CREATE TRIGGER fail_backup_delete BEFORE DELETE ON backup_catalog BEGIN SELECT RAISE(ABORT, 'injected prune failure'); END")
        }
        #expect(throws: (any Error).self) { try library.backup.restore(archive, mode: .replaceAll) }
        #expect(try library.store.note(id: note.id)?.text == "latest local changes")
        #expect(!FileManager.default.fileExists(atPath: older[0].path))
        let surviving = try library.backup.localBackups()
        #expect(surviving.count == 3)
        let latest = try #require(surviving.first).url
        let tree = library.paths.root.appendingPathComponent("verified-newest")
        try PortableZIP.extract(latest, to: tree)
        #expect(try LibraryBackup.validateExtracted(tree).noteCount == 1)
        let record = try SyncPayloadCodec.decode(BackupNoteRecord.self, from: Data(contentsOf: tree.appendingPathComponent(note.id + ".textbundle/record.json")))
        #expect(record.note.text == "latest local changes")
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM backup_catalog") } == 4)
        try library.db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_backup_delete") }
        _ = try library.backup.restore(archive, mode: .replaceAll)
        #expect(try library.backup.localBackups().count == 3)
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM backup_catalog") } == 3)
    }

    @Test func reservedSafetyNamespaceRejectsChosenManagedExportButAllowsExternalCopy() throws {
        let library = try Library()
        defer { library.cleanup() }
        _ = try library.store.create(text: "export")
        let filename = "baerchen-safety-\(UUID()).baerchen-backup"
        let reserved = library.paths.backups.appendingPathComponent(filename)
        #expect(throws: CocoaError(.fileWriteInvalidFileName)) { try library.backup.create(at: reserved) }
        #expect(!FileManager.default.fileExists(atPath: reserved.path))
        let external = library.paths.root.appendingPathComponent(filename)
        try library.backup.create(at: external)
        try library.backup.recoverAbandonedCopies()
        #expect(try library.backup.inspect(external).noteCount == 1)
        #expect(try library.backup.localBackups().isEmpty)
    }

    @Test func summaryCountsCurrentLocationsIncludingLockedAndEmptyArchives() throws {
        let library = try Library()
        defer { library.cleanup() }
        let empty = try library.backup.inspect(library.backup.createRolling())
        #expect(empty.noteCount == 0 && empty.trashedNoteCount == 0 && empty.archivedNoteCount == 0 && empty.lockedNoteCount == 0)
        _ = try library.store.create(text: "active")
        let archived = try library.store.create(text: "archived")
        let trashed = try library.store.create(text: "trashed")
        let formerlyArchived = try library.store.create(text: "archived then trashed")
        try library.store.archive([archived.id, formerlyArchived.id])
        try library.store.trash([trashed.id, formerlyArchived.id])
        #expect(try library.store.note(id: formerlyArchived.id)?.archivedAt != nil)
        let access = try NotePrivacy(store: library.store).setPassword("password")
        try access.lock(noteId: archived.id)
        try access.lock(noteId: formerlyArchived.id)
        let summary = try library.backup.inspect(library.backup.createRolling())
        #expect(summary.noteCount == 4)
        #expect(summary.archivedNoteCount == 1)
        #expect(summary.trashedNoteCount == 2)
        #expect(summary.lockedNoteCount == 2)
    }

    @Test func lockingReplacesAllRecoveryCopiesWithRestorableProtectedArchive() throws {
        let source = try Library(), restored = try Library()
        defer { source.cleanup(); restored.cleanup() }
        let note = try source.store.create(text: "# Secret\nprivate body\n[asset](private.bin)")
        let bytes = Data("private attachment".utf8)
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: bytes, filename: "private.bin", to: note.id)
        let external = source.paths.root.appendingPathComponent("restore-input.baerchen-backup")
        try source.backup.create(at: external)
        let safety = try #require(try source.backup.restore(external, mode: .replaceAll).safetyBackup)
        #expect(safety.lastPathComponent.hasPrefix("baerchen-safety-"))
        let daily = try #require(try source.backup.createDailyDatabaseSnapshot())
        try NotePrivacy(store: source.store).setPassword("password").lock(noteId: note.id)
        #expect(!FileManager.default.fileExists(atPath: safety.path))
        #expect(!FileManager.default.fileExists(atPath: daily.path))
        let replacements = try source.backup.localBackups()
        #expect(replacements.count == 1)
        let replacement = try #require(replacements.first).url
        #expect(try source.backup.inspect(replacement).lockedNoteCount == 1)
        _ = try restored.backup.restore(replacement)
        let access = try NotePrivacy(store: restored.store).unlock(password: "password")
        #expect(try access.note(id: note.id)?.text == note.text)
        let output = restored.paths.root.appendingPathComponent("verified.bin")
        try access.decryptAttachment("private.bin", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        // Repeated cleanup of a received locked revision must not grow recovery archives.
        try NotePrivacy(store: source.store).cleanup(noteId: note.id)
        #expect(try source.backup.localBackups().count == 1)
    }

    @Test func receivedLockReplacesRecoveryBackupWithoutRepeatedGrowth() async throws {
        let library = try SyncMaterializerTests.Library()
        defer { library.cleanup() }
        let plain = library.payload("# Secret\nprivate body")
        let first = try library.entity(plain)
        try library.receive([first])
        _ = try await library.materializer().apply(first)
        let privacy = NotePrivacy(store: library.store)
        let access = try privacy.setPassword("password")
        let backup = LibraryBackup(database: library.db, paths: library.paths)
        let old = try backup.createRolling()
        var locked = plain
        locked.isLocked = true; locked.text = ""
        locked.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(LockedNotePayload(text: plain.text, attachments: [:])), vaultKey: access.journalKey(), context: plain.id)
        let incoming = try library.entity(locked, revision: 2, sequence: 2)
        try library.receive([incoming])
        #expect(try await library.materializer().apply(incoming) == .applied)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let replacements = try backup.localBackups()
        #expect(replacements.count == 1)
        #expect(try backup.inspect(try #require(replacements.first).url).lockedNoteCount == 1)
        let again = try library.entity(locked, revision: 3, sequence: 3)
        try library.receive([again])
        _ = try await library.materializer().apply(again)
        #expect(try backup.localBackups().count == 1)
    }

    @Test func failedReplacementKeepsOldBackupsAndTransitionUntilRetry() throws {
        let source = try Library()
        defer { source.cleanup() }
        let note = try source.store.create(text: "private body")
        let old = try source.backup.createRolling()
        let privacy = NotePrivacy(store: source.store)
        let access = try privacy.setPassword("password")
        // Fail catalog publication after writing and verifying the replacement archive.
        try source.db.pool.write {
            try $0.execute(sql: "CREATE TRIGGER fail_backup BEFORE INSERT ON backup_catalog BEGIN SELECT RAISE(ABORT, 'injected backup failure'); END")
        }
        #expect(throws: (any Error).self) { try access.lock(noteId: note.id) }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try source.backup.inspect(old).lockedNoteCount == 0)
        #expect(try source.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition") } == 1)
        #expect(try source.backup.localBackups().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(at: source.paths.backups, includingPropertiesForKeys: nil).count == 1)
        try source.db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_backup") }
        try privacy.finishPendingCleanup()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try source.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM privacy_transition") } == 0)
        let replacement = try #require(try source.backup.localBackups().first).url
        #expect(try source.backup.inspect(replacement).lockedNoteCount == 1)
    }

    @Test func roundTripPreservesIDsMetadataAssetsAndExactSource() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let note = try source.store.create(text: "# Heading\n#work/sub\n![](photo.bin)\n\nText 🐻", now: Date(timeIntervalSince1970: 1_700_000_000.123))
        let bytes = Data(repeating: 237, count: 230_123)
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: bytes, filename: "photo.bin", to: note.id)
        try source.store.setPinned([note.id], pinned: true)
        try source.store.setPinned([note.id], pinned: true, inTag: "work")
        try source.store.archive([note.id])
        try source.db.pool.write { db in
            try db.execute(sql: "INSERT INTO note_ui_state(noteId,selection,foldState,scrollTop) VALUES(?,?,?,?)", arguments: [note.id, "{\"anchor\":2,\"head\":2}", "[1]", 42])
            try db.execute(sql: "UPDATE tag SET iconName='briefcase',isPinned=1 WHERE pathKey='work'")
            try db.execute(sql: "INSERT INTO external_ref(source,externalId,noteId) VALUES('bear','original-id',?)", arguments: [note.id])
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES('hideMarkdown','true')")
        }
        let expected = try source.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) }
        let archive = try source.backup.createRolling()
        let summary = try source.backup.inspect(archive)
        #expect(summary.noteCount == 1 && summary.attachmentCount == 1)
        let result = try destination.backup.restore(archive)
        #expect(result.restored == 1 && result.keptExisting == 0)
        #expect(try destination.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) } == expected)
        #expect(try Data(contentsOf: destination.paths.attachments.appendingPathComponent(note.id + "/photo.bin")) == bytes)
        try destination.db.pool.read { db throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source='bear'") == note.id)
            #expect(try Double.fetchOne(db, sql: "SELECT scrollTop FROM note_ui_state WHERE noteId=?", arguments: [note.id]) == 42)
            #expect(try String.fetchOne(db, sql: "SELECT iconName FROM tag WHERE pathKey='work'") == "briefcase")
            #expect(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key='hideMarkdown'") == "true")
        }
        let current = try #require(try destination.store.note(id: note.id))
        _ = try destination.store.updateText(id: note.id, text: "local wins", expectedRevision: current.revision)
        let merged = try destination.backup.restore(archive)
        #expect(merged.restored == 0 && merged.keptExisting == 1)
        #expect(try destination.store.note(id: note.id)?.text == "local wins")
        let local = try destination.store.create(text: "only here")
        let replaced = try destination.backup.restore(archive, mode: .replaceAll)
        #expect(replaced.restored == 1)
        let safety = try #require(replaced.safetyBackup)
        #expect(try destination.backup.inspect(safety).noteCount == 2)
        #expect(try destination.store.note(id: local.id) == nil)
        #expect(try destination.store.note(id: note.id)?.text == note.text)
    }

    @Test func lockedArchiveRestoresAndMergesAcrossPasswordVaultsWithoutPlaintextFiles() throws {
        let source = try Library(), destination = try Library(), empty = try Library()
        defer { source.cleanup(); destination.cleanup(); empty.cleanup() }
        let secret = "private-secret-\(UUID())"
        let note = try source.store.create(text: "# Private\n\(secret)\n[asset](confidential.txt)\n#visible")
        let bytes = Data((secret + " attachment").utf8)
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: bytes, filename: "confidential.txt", to: note.id)
        let plaintextRolling = try source.backup.createRolling()
        let external = source.paths.root.appendingPathComponent("external.baerchen-backup")
        try source.backup.create(at: external)
        let access = try NotePrivacy(store: source.store).setPassword("source password")
        try access.lock(noteId: note.id)
        #expect(!FileManager.default.fileExists(atPath: plaintextRolling.path))
        #expect(FileManager.default.fileExists(atPath: external.path))
        let archive = try source.backup.createRolling()
        let checked = try source.backup.inspect(archive)
        #expect(checked.lockedNoteCount == 1)
        #expect(checked.attachmentCount == 1)
        let extracted = source.paths.root.appendingPathComponent("extracted")
        try PortableZIP.extract(archive, to: extracted)
        for file in try LibraryBackup.fileManifest(extracted) {
            let data = try Data(contentsOf: extracted.appendingPathComponent(file.path))
            #expect(data.range(of: Data(secret.utf8)) == nil)
            #expect(data.range(of: Data("confidential.txt".utf8)) == nil)
        }
        _ = try empty.backup.restore(archive)
        let adopted = try NotePrivacy(store: empty.store).unlock(password: "source password")
        #expect(try adopted.note(id: note.id)?.text == note.text)
        let adoptedOutput = empty.paths.root.appendingPathComponent("decrypted")
        try adopted.decryptAttachment("confidential.txt", noteId: note.id, to: adoptedOutput)
        #expect(try Data(contentsOf: adoptedOutput) == bytes)
        let local = try destination.store.create(text: "local private")
        let existingAccess = try NotePrivacy(store: destination.store).setPassword("destination password")
        try existingAccess.lock(noteId: local.id)
        #expect(throws: BackupError.passwordsRequired) { try destination.backup.restore(archive) }
        #expect(try destination.store.note(id: note.id) == nil)
        #expect(throws: CryptoError.wrongPassword) {
            try destination.backup.restore(archive, backupPassword: "wrong", currentPassword: "destination password")
        }
        _ = try destination.backup.restore(archive, backupPassword: "source password", currentPassword: "destination password")
        let reopened = try NotePrivacy(store: destination.store).unlock(password: "destination password")
        #expect(try reopened.note(id: note.id)?.text == note.text)
        #expect(try reopened.note(id: local.id)?.text == local.text)
        let output = destination.paths.root.appendingPathComponent("decrypted")
        try reopened.decryptAttachment("confidential.txt", noteId: note.id, to: output)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(try destination.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_search_content") } == 0)
    }

    @Test func missingFilesRoundTripWithoutInventingContentsOrLosingStableIDs() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let note = try source.store.create(text: "# Incomplete import\n![photo](missing.png)\n[available](present.txt)")
        _ = try AttachmentStore(paths: source.paths, database: source.db).add(data: Data("available".utf8), filename: "present.txt", to: note.id)
        let before = try source.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) }
        let archive = try source.backup.createRolling()
        let summary = try source.backup.inspect(archive)
        #expect(summary.attachmentCount == 1)
        #expect(summary.missingAttachmentCount == 1)
        _ = try destination.backup.restore(archive)
        #expect(try destination.db.pool.read { try SyncNotePayload.capture(id: note.id, in: $0) } == before)
        #expect(!FileManager.default.fileExists(atPath: destination.paths.attachments.appendingPathComponent(note.id + "/missing.png").path))
        #expect(try Data(contentsOf: destination.paths.attachments.appendingPathComponent(note.id + "/present.txt")) == Data("available".utf8))
        let second = try destination.backup.createRolling()
        #expect(try destination.backup.inspect(second).missingAttachmentCount == 1)
    }

    @Test func danglingAttachmentSymlinksAreRejectedRatherThanDeclaredMissing() throws {
        let source = try Library()
        defer { source.cleanup() }
        let note = try source.store.create(text: "[file](missing.txt)")
        let directory = source.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("missing.txt"), withDestinationURL: source.paths.root.appendingPathComponent("does-not-exist"))
        #expect(throws: BackupError.missingAttachment) { try source.backup.createRolling() }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: source.paths.root.appendingPathComponent("missing-directory"))
        #expect(throws: BackupError.missingAttachment) { try source.backup.createRolling() }
    }

    @Test func corruptedArchiveAndUnflushedJournalNeverMutateTheDestination() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let note = try source.store.create(text: "source")
        let local = try destination.store.create(text: "keep me")
        let archive = try source.backup.createRolling()
        let folder = source.paths.root.appendingPathComponent("tamper")
        try PortableZIP.extract(archive, to: folder)
        try Data("tampered".utf8).write(to: folder.appendingPathComponent(note.id + ".textbundle/text.md"))
        let corrupted = source.paths.root.appendingPathComponent("corrupted.baerchen-backup")
        try PortableZIP.create(from: folder, at: corrupted)
        #expect(throws: BackupError.checksumMismatch) { try destination.backup.restore(corrupted, mode: .replaceAll) }
        #expect(try destination.store.note(id: local.id)?.text == local.text)
        try Data("unflushed".utf8).write(to: destination.paths.journal.appendingPathComponent(local.id + ".jsonl"))
        #expect(throws: BackupError.pendingEdits) { try destination.backup.restore(archive) }
        #expect(throws: BackupError.pendingEdits) { try destination.backup.createRolling() }
        #expect(try destination.store.note(id: note.id) == nil)
    }

    @Test func malformedAndTruncatedArchivesFailReadablyWithoutChangingExistingLibrary() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        _ = try source.store.create(text: "Valid backup fixture")
        let existing = try destination.store.create(text: "Keep this exact note 🐻")
        let valid = try source.backup.createRolling()
        let validBytes = try Data(contentsOf: valid)
        let malformed = source.paths.root.appendingPathComponent("malformed.baerchen-backup")
        let truncated = source.paths.root.appendingPathComponent("truncated.baerchen-backup")
        try Data("This is not a ZIP archive".utf8).write(to: malformed)
        try Data(validBytes.dropLast(22)).write(to: truncated)
        for archive in [malformed, truncated] {
            #expect(throws: BackupError.invalidManifest) { try destination.backup.inspect(archive) }
            for mode in [BackupRestoreMode.merge, .replaceAll] {
                #expect(throws: BackupError.invalidManifest) { try destination.backup.restore(archive, mode: mode) }
                #expect(try destination.store.allNotes() == [existing])
                #expect(try destination.backup.localBackups().isEmpty)
            }
        }
        #expect(try destination.backup.inspect(valid).noteCount == 1)
        #expect(try destination.backup.restore(valid).restored == 1)
        #expect(try destination.store.note(id: existing.id) == existing)
        let missing = source.paths.root.appendingPathComponent("missing.baerchen-backup")
        #expect(throws: (any Error).self) {
            do { _ = try destination.backup.inspect(missing) }
            catch let error as BackupError { Issue.record("Missing file incorrectly mapped to backup format error: \(error)") }
        }
    }

    @Test func dailyOnlineSnapshotsKeepSevenAndLockingReplacesRecoveryBeforePruningPlaintextCopies() throws {
        let library = try Library()
        defer { library.cleanup() }
        let note = try library.store.create(text: "daily snapshot secret")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(try library.backup.createDailyDatabaseSnapshot(now: start))
        #expect(try library.backup.createDailyDatabaseSnapshot(now: start.addingTimeInterval(60)) == nil)
        let snapshot = try DatabaseQueue(path: first.path)
        #expect(try snapshot.read { try String.fetchOne($0, sql: "SELECT text FROM note WHERE id=?", arguments: [note.id]) } == note.text)
        try snapshot.close()
        for day in 1...8 { _ = try library.backup.createDailyDatabaseSnapshot(now: start.addingTimeInterval(Double(day) * 86_400)) }
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM backup_catalog WHERE filename LIKE '%.sqlite'") } == 7)
        let orphan = library.paths.backups.appendingPathComponent("baerchen-\(UUID()).baerchen-backup")
        try Data("orphan plaintext".utf8).write(to: orphan)
        let orphanSafety = library.paths.backups.appendingPathComponent("baerchen-safety-\(UUID()).baerchen-backup")
        try Data("orphan safety plaintext".utf8).write(to: orphanSafety)
        let abandoned = library.paths.backups.appendingPathComponent(".snapshot-\(UUID())")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("abandoned plaintext".utf8).write(to: abandoned.appendingPathComponent("text.md"))
        let access = try NotePrivacy(store: library.store).setPassword("daily password")
        try access.lock(noteId: note.id)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(!FileManager.default.fileExists(atPath: orphanSafety.path))
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM backup_catalog") } == 1)
        let replacement = try #require(try library.backup.localBackups().first).url
        let summary = try library.backup.inspect(replacement)
        #expect(summary.noteCount == 1 && summary.lockedNoteCount == 1)
    }
}

// MARK: - Backup v2: focus state (C9)

extension LibraryBackupTests {
    static func fixtureArchive(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/backup/" + name)
    }

    /// A library with a plain note and a locked note, both carrying focus state.
    struct FocusLibrary {
        let library: Library
        let seeded: FocusBackupSupport.Seeded
        init() throws {
            library = try Library()
            let plain = try library.store.create(text: "# Plan\n- [ ] call Anna\nthird line", now: FocusBackupSupport.t0)
            let secret = try library.store.create(text: "# Secret\nthe vault line", now: FocusBackupSupport.t0)
            seeded = try FocusBackupSupport.seed(store: library.store, plain: plain, secret: secret)
        }
        func cleanup() { seeded.access.revoke(); library.cleanup() }
    }

    @Test func manifestVersionIsTwo() throws {
        let library = try Library()
        defer { library.cleanup() }
        _ = try library.store.create(text: "# One")
        let tree = try FocusBackupSupport.extract(try library.backup.createRolling(), into: library.paths.root)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: tree.appendingPathComponent("manifest.json"))) as? [String: Any])
        let metadata = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: tree.appendingPathComponent("library.json"))) as? [String: Any])
        #expect(manifest["version"] as? Int == 2)
        #expect(metadata["version"] as? Int == 2)
        // A library without focus state writes none of the new fields.
        let record = try FocusBackupSupport.record(tree, try #require(try library.store.allNotes().first).id)
        for key in ["captureSource", "lastOpenedAt", "pings", "hides", "snapshots"] { #expect(record[key] == nil, "\(key)") }
        #expect(metadata["notTodayUntil"] == nil)
    }

    @Test func focusStateRoundTripsInV2() throws {
        let source = try FocusLibrary(), merged = try Library(), replaced = try Library()
        defer { source.cleanup(); merged.cleanup(); replaced.cleanup() }
        let seeded = source.seeded
        let before = try FocusBackupSupport.dump(source.library.db)
        // The dump really holds everything: 2 capture sources, 1 open time, 3 reminders, 4 hides, 4 snapshots.
        #expect(before.filter { $0.hasPrefix("ping") }.count == 3)
        #expect(before.filter { $0.hasPrefix("hide") }.count == 4)
        #expect(before.filter { $0.hasPrefix("snapshot") }.count == 4)
        let archive = try source.library.backup.createRolling()
        let summary = try source.library.backup.inspect(archive)
        #expect(summary.noteCount == 2 && summary.lockedNoteCount == 1)

        // Merge into an empty library adopts the backup's note password envelope.
        _ = try merged.backup.restore(archive)
        #expect(try FocusBackupSupport.dump(merged.db) == before)
        #expect(try merged.store.captureSource(noteId: seeded.plain.id) == .voice)
        #expect(try merged.store.captureSource(noteId: seeded.secret.id) == .command)
        #expect(try merged.store.lastOpenedAt(noteId: seeded.plain.id) == FocusBackupSupport.millis(10))
        #expect(try merged.store.lastOpenedAt(noteId: seeded.secret.id) == nil)
        let access = try NotePrivacy(store: merged.store).unlock(password: FocusBackupSupport.password)
        let restoredSealed = try merged.store.snapshots(noteId: seeded.secret.id)
        #expect(restoredSealed.count == 2 && restoredSealed.allSatisfy(\.isSealed))
        #expect(Set(try restoredSealed.map { try access.snapshotText(id: $0.id) }) == Set(seeded.secretSnapshots))
        #expect(Set(try merged.store.snapshots(noteId: seeded.plain.id).map { try merged.store.snapshotText(id: $0.id) }) == Set(seeded.plainSnapshots))

        // Replace All replaces what was there, focus state included.
        let local = try replaced.store.create(text: "# Local only")
        _ = try replaced.store.takeSnapshot(noteId: local.id, text: "# Local only\nolder", now: FocusBackupSupport.millis(5))
        try replaced.db.pool.write { try $0.execute(sql: "INSERT INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES('pool',NULL,?)", arguments: [FocusBackupSupport.millis(99)]) }
        _ = try replaced.backup.restore(archive, mode: .replaceAll)
        #expect(try FocusBackupSupport.dump(replaced.db) == before)
    }

    @Test func v1ArchiveStillRestores() throws {
        let fixture = Self.fixtureArchive("v1-minimal.baerchen-backup")
        let merged = try Library(), replaced = try Library()
        defer { merged.cleanup(); replaced.cleanup() }
        let summary = try merged.backup.inspect(fixture)
        #expect(summary.noteCount == 2 && summary.lockedNoteCount == 1)
        for (library, mode) in [(merged, BackupRestoreMode.merge), (replaced, .replaceAll)] {
            let result = try library.backup.restore(fixture, mode: mode)
            #expect(result.restored == 2)
            let notes = try library.store.allNotes()
            #expect(notes.count == 2)
            #expect(notes.contains { $0.text.contains("fixture-plain-body") })
            let locked = try #require(notes.first { $0.isLocked })
            let access = try NotePrivacy(store: library.store).unlock(password: "fixture-password")
            #expect(try access.note(id: locked.id)?.text.contains("fixture-locked-body") == true)
            // Nothing in the archive says anything about focus state: there are no focus rows.
            try library.db.pool.read { db throws -> Void in
                for table in ["note_ping", "focus_hide", "note_snapshot"] {
                    #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
                }
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note WHERE captureSource IS NOT NULL") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_ui_state WHERE lastOpenedAt IS NOT NULL") == 0)
            }
        }
        // A backup written by this build from the restored library is v2 and restores again.
        let again = try merged.backup.createRolling()
        #expect(try merged.backup.inspect(again).noteCount == 2)
    }

    @Test func lockedNoteSnapshotsStayCiphertextInTheArchive() throws {
        let source = try FocusLibrary()
        defer { source.cleanup() }
        let seeded = source.seeded
        let tree = try FocusBackupSupport.extract(try source.library.backup.createRolling(), into: source.library.paths.root)
        let locked = try FocusBackupSupport.record(tree, seeded.secret.id)
        let snapshots = try #require(locked["snapshots"] as? [[String: Any]])
        #expect(snapshots.count == 2)
        for snapshot in snapshots {
            #expect(snapshot["text"] == nil)
            let sealed = try SyncWire.decode64(try #require(snapshot["sealedText"] as? String))
            #expect(sealed.prefix(4) == Data("BNC1".utf8))
        }
        // Not in any file of the archive in the clear (the archive never opens a snapshot).
        let files = try LibraryBackup.fileManifest(tree)
        for file in files {
            let data = try Data(contentsOf: tree.appendingPathComponent(file.path))
            #expect(data.range(of: Data("secret snapshot".utf8)) == nil, "\(file.path)")
            #expect(data.range(of: Data("the vault line".utf8)) == nil, "\(file.path)")
        }
        // Control: the plain note's snapshots are readable text.
        let plain = try FocusBackupSupport.record(tree, seeded.plain.id)
        let texts = Set(try #require(plain["snapshots"] as? [[String: Any]]).compactMap { $0["text"] as? String })
        #expect(texts == Set(seeded.plainSnapshots))
        // The archive's sealed bytes are the database's bytes.
        let stored = try source.library.db.pool.read {
            Set(try Data.fetchAll($0, sql: "SELECT sealedText FROM note_snapshot WHERE noteId=?", arguments: [seeded.secret.id]))
        }
        #expect(Set(try snapshots.map { try SyncWire.decode64($0["sealedText"] as! String) }) == stored)
    }

    @Test func mergeWithAForeignEnvelopeResealsSnapshots() throws {
        let source = try FocusLibrary(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let seeded = source.seeded
        let archive = try source.library.backup.createRolling()
        let local = try destination.store.create(text: "# Local private")
        try NotePrivacy(store: destination.store).setPassword("destination password").lock(noteId: local.id)
        #expect(throws: BackupError.passwordsRequired) { try destination.backup.restore(archive) }
        #expect(try destination.store.snapshots(noteId: seeded.secret.id).isEmpty)

        _ = try destination.backup.restore(archive, backupPassword: FocusBackupSupport.password, currentPassword: "destination password")

        let reopened = try NotePrivacy(store: destination.store).unlock(password: "destination password")
        let restored = try destination.store.snapshots(noteId: seeded.secret.id)
        #expect(restored.count == 2 && restored.allSatisfy(\.isSealed))
        #expect(Set(try restored.map { try reopened.snapshotText(id: $0.id) }) == Set(seeded.secretSnapshots))
        // Re-sealed: not the bytes of the source library.
        let sourceBytes = try source.library.db.pool.read { Set(try Data.fetchAll($0, sql: "SELECT sealedText FROM note_snapshot WHERE noteId=?", arguments: [seeded.secret.id])) }
        let destinationBytes = try destination.db.pool.read { Set(try Data.fetchAll($0, sql: "SELECT sealedText FROM note_snapshot WHERE noteId=?", arguments: [seeded.secret.id])) }
        #expect(destinationBytes.count == 2 && destinationBytes.isDisjoint(with: sourceBytes))
        // The plain note's focus state came along unchanged, and the local locked note is untouched.
        #expect(try destination.store.captureSource(noteId: seeded.plain.id) == .voice)
        #expect(try reopened.note(id: local.id)?.text == local.text)
    }

    @Test func skippedLockedNotesSkipTheirSnapshots() throws {
        let source = try FocusLibrary(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let seeded = source.seeded
        let archive = try source.library.backup.createRolling()
        // The destination already has a note with the locked note's id, locked under its own vault.
        try destination.db.pool.write { db in
            _ = try NoteStore.insert(id: seeded.secret.id, text: "# Local twin\nbody", now: FocusBackupSupport.millis(1), in: db)
        }
        try NotePrivacy(store: destination.store).setPassword("destination password").lock(noteId: seeded.secret.id)
        let before = try FocusBackupSupport.dump(destination.db).filter { $0.contains(seeded.secret.id) }

        // The twin is skipped, so no password for the foreign vault is asked for.
        let result = try destination.backup.restore(archive)

        #expect(result.restored == 1 && result.keptExisting == 1)
        #expect(try FocusBackupSupport.dump(destination.db).filter { $0.contains(seeded.secret.id) } == before)
        #expect(try destination.store.snapshots(noteId: seeded.secret.id).isEmpty)
        #expect(try destination.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_ping WHERE noteId=?", arguments: [seeded.secret.id]) } == 0)
        #expect(try destination.store.captureSource(noteId: seeded.secret.id) == nil)
        // The added note's state came along.
        #expect(try destination.store.snapshots(noteId: seeded.plain.id).count == 2)
    }

    @Test func mergeKeepsTheFocusStateOfNotesThatAlreadyExist() throws {
        let source = try FocusLibrary(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let seeded = source.seeded
        let archive = try source.library.backup.createRolling()
        _ = try destination.backup.restore(archive)
        let after = try FocusBackupSupport.dump(destination.db)
        // Local changes to the existing plain note's focus state survive another merge.
        try destination.db.pool.write { db in
            try db.execute(sql: "DELETE FROM note_snapshot WHERE noteId=?", arguments: [seeded.plain.id])
            try db.execute(sql: "UPDATE note_ping SET fireAt=? WHERE noteId=?", arguments: [FocusBackupSupport.millis(1), seeded.plain.id])
        }
        let edited = try FocusBackupSupport.dump(destination.db)
        #expect(edited != after)
        let result = try destination.backup.restore(archive)
        #expect(result.restored == 0 && result.keptExisting == 2)
        #expect(try FocusBackupSupport.dump(destination.db) == edited)
    }

    @Test func notTodayUntilFollowsTheRestoreMode() throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        _ = try source.store.create(text: "# One")
        func pool(_ library: Library) throws -> [Date] {
            try library.db.pool.read { try Date.fetchAll($0, sql: "SELECT hiddenUntil FROM focus_hide WHERE candidateKey='pool'") }
        }
        func setPool(_ library: Library, _ seconds: Double?) throws {
            try library.db.pool.write { db in
                try db.execute(sql: "DELETE FROM focus_hide WHERE candidateKey='pool'")
                if let seconds {
                    try db.execute(sql: "INSERT INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES('pool',NULL,?)", arguments: [FocusBackupSupport.millis(seconds)])
                }
            }
        }
        try setPool(source, 1000)
        let withPool = try source.backup.createRolling()
        try setPool(source, nil)
        let withoutPool = try source.backup.createRolling()
        let tree = try FocusBackupSupport.extract(withoutPool, into: source.paths.root)
        let library = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: tree.appendingPathComponent("library.json"))) as? [String: Any])
        #expect(library["notTodayUntil"] == nil)

        _ = try destination.backup.restore(withPool)
        #expect(try pool(destination) == [FocusBackupSupport.millis(1000)])
        // Merge keeps a hide that is already there; Replace All takes the archive's, also when it has none.
        try setPool(destination, 5)
        _ = try destination.backup.restore(withPool)
        #expect(try pool(destination) == [FocusBackupSupport.millis(5)])
        _ = try destination.backup.restore(withPool, mode: .replaceAll)
        #expect(try pool(destination) == [FocusBackupSupport.millis(1000)])
        _ = try destination.backup.restore(withoutPool, mode: .replaceAll)
        #expect(try pool(destination).isEmpty)
    }

    @Test func backupAfterRemoteUnlockValidates() throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        let destination = try Library()
        defer { library.cleanup(); destination.cleanup() }
        let note = try library.store.create(text: "# Permitted title\ncurrent")
        _ = try SnapshotPrivacyTests.seedSnapshots(library.store, noteId: note.id, markers: SnapshotPrivacyTests.markers(2))
        let access = LockedNoteAccess(store: library.store, key: library.key)
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        func sealedCount() throws -> Int {
            try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_snapshot WHERE sealedText IS NOT NULL")! }
        }
        #expect(try sealedCount() == 2)
        var unlocked = library.payload("# Permitted title\nremote", id: note.id)
        unlocked.isLocked = false
        try SnapshotPrivacyTests.write(unlocked, in: library)
        #expect(try library.store.note(id: note.id)?.isLocked == false)
        #expect(try sealedCount() == 0)
        _ = try library.store.takeSnapshot(noteId: note.id, text: "# Permitted title\nafter", now: SnapshotPrivacyTests.start + 900)

        let archive = library.paths.root.appendingPathComponent("remote-unlock.baerchen-backup")
        try LibraryBackup(database: library.db, paths: library.paths).create(at: archive)

        let tree = try FocusBackupSupport.extract(archive, into: library.paths.root)
        #expect(try LibraryBackup.validateExtracted(tree).lockedNoteCount == 0)
        _ = try destination.backup.restore(archive)
        #expect(try FocusBackupSupport.dump(destination.db).filter { $0.hasPrefix("snapshot") }
                == FocusBackupSupport.dump(library.db).filter { $0.hasPrefix("snapshot") })
        #expect(try destination.store.snapshots(noteId: note.id).count == 1)
    }

    @Test func ledgerIsNotInTheArchive() throws {
        let source = try FocusLibrary()
        defer { source.cleanup() }
        let seeded = source.seeded
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let identifier = "reminder:ledger-" + token, contentHash = "hash-" + token, receipt = "receipt-" + token
        try source.library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO notification_ledger(identifier,kind,pingId,noteId,contentHash,recordedAt) VALUES(?,?,?,?,?,?)",
                           arguments: [identifier, "reminder", seeded.anchoredPing.id, seeded.plain.id, contentHash, FocusBackupSupport.t0])
            try db.execute(sql: "INSERT INTO capture_receipt(itemId,noteId,processedAt) VALUES(?,?,?)", arguments: [receipt, seeded.plain.id, FocusBackupSupport.t0])
        }
        #expect(try source.library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notification_ledger") } == 1)
        let tree = try FocusBackupSupport.extract(try source.library.backup.createRolling(), into: source.library.paths.root)
        var names = [tree.appendingPathComponent("library.json"), tree.appendingPathComponent("manifest.json")]
        names += [seeded.plain.id, seeded.secret.id].map { tree.appendingPathComponent($0 + ".textbundle/record.json") }
        for url in names {
            let data = try Data(contentsOf: url)
            for canary in [identifier, contentHash, receipt, "notification_ledger", "contentHash", "capture_receipt"] {
                #expect(data.range(of: Data(canary.utf8)) == nil, "\(canary) in \(url.lastPathComponent)")
            }
        }
        // A restore leaves the destination's ledger alone and writes none.
        let destination = try Library()
        defer { destination.cleanup() }
        _ = try destination.backup.restore(try source.library.backup.createRolling())
        #expect(try destination.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notification_ledger") } == 0)
        #expect(try destination.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_receipt") } == 0)
    }

    /// The invariant "sealed rows only on locked notes" is kept by the lock paths. A row that breaks it
    /// anyway (a damaged library) is never written in the clear and never dropped silently: the
    /// backup fails with a clear error and nothing is left behind.
    @Test func anInconsistentSnapshotRowFailsTheBackupAndLeavesNothing() throws {
        let source = try FocusLibrary()
        defer { source.cleanup() }
        let seeded = source.seeded
        let backups = source.library.paths.backups
        func listing() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted() }
        func expectFailure(_ what: String, canary: String) throws {
            let before = try listing()
            let external = source.library.paths.root.appendingPathComponent("external-\(UUID()).baerchen-backup")
            for attempt in 0..<2 {
                do {
                    if attempt == 0 { _ = try source.library.backup.createRolling() } else { try source.library.backup.create(at: external) }
                    Issue.record("\(what): attempt \(attempt) reported success")
                } catch {
                    #expect("\(error)" == "inconsistentHistory", "\(what): attempt \(attempt) threw \(error)")
                    #expect((error as? BackupError)?.errorDescription?.isEmpty == false)
                }
            }
            #expect(try listing() == before, "\(what): nothing was left in the backups folder")
            #expect(!FileManager.default.fileExists(atPath: external.path), "\(what): no archive at the chosen place")
            #expect(try source.library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM backup_catalog") } == 0, "\(what): nothing catalogued")
            _ = canary
        }
        // A plaintext row on the locked note.
        let canary = "stray-plaintext-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try source.library.db.pool.write {
            try $0.execute(sql: "INSERT INTO note_snapshot(id,noteId,takenAt,text) VALUES('stray-plain',?,?,?)", arguments: [seeded.secret.id, FocusBackupSupport.t0, canary])
        }
        try expectFailure("plaintext row on a locked note", canary: canary)
        for file in try FileManager.default.contentsOfDirectory(at: source.library.paths.root, includingPropertiesForKeys: nil)
        where file.pathExtension == "baerchen-backup" {
            #expect(try Data(contentsOf: file).range(of: Data(canary.utf8)) == nil)
        }
        try source.library.db.pool.write { try $0.execute(sql: "DELETE FROM note_snapshot WHERE id='stray-plain'") }
        // The same library without it backs up, and the locked note's snapshots are sealed in it.
        let archive = try source.library.backup.createRolling()
        let tree = try FocusBackupSupport.extract(archive, into: source.library.paths.root)
        let snapshots = try #require(try FocusBackupSupport.record(tree, seeded.secret.id)["snapshots"] as? [[String: Any]])
        #expect(snapshots.count == 2 && snapshots.allSatisfy { $0["sealedText"] != nil && $0["text"] == nil })
        try FileManager.default.removeItem(at: archive)
        try source.library.db.pool.write { try $0.execute(sql: "DELETE FROM backup_catalog") }

        // A sealed row on an unlocked note.
        try source.library.db.pool.write {
            try $0.execute(sql: "INSERT INTO note_snapshot(id,noteId,takenAt,sealedText) VALUES('stray-sealed',?,?,?)",
                           arguments: [seeded.plain.id, FocusBackupSupport.t0, Data("BNC1".utf8) + Data(repeating: 1, count: 100)])
        }
        try expectFailure("sealed row on an unlocked note", canary: "")
    }

    @Test func aPingOrSnapshotIdOwnedByAnotherNoteRefusesTheMergeBeforeWritingAnything() throws {
        let source = try FocusLibrary(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let seeded = source.seeded
        let archive = try source.library.backup.createRolling()
        let other = try destination.store.create(text: "# Someone else")
        let snapshotID = try #require(try source.library.db.pool.read { try String.fetchOne($0, sql: "SELECT id FROM note_snapshot WHERE noteId=? LIMIT 1", arguments: [seeded.plain.id]) })
        for (table, id) in [("note_ping", seeded.anchoredPing.id), ("note_snapshot", snapshotID)] {
            try destination.db.pool.write { db in
                if table == "note_ping" {
                    try db.execute(sql: "INSERT INTO note_ping(id,noteId,fireAt,createdAt) VALUES(?,?,?,?)", arguments: [id, other.id, FocusBackupSupport.t0, FocusBackupSupport.t0])
                } else {
                    try db.execute(sql: "INSERT INTO note_snapshot(id,noteId,takenAt,text) VALUES(?,?,?,'old')", arguments: [id, other.id, FocusBackupSupport.t0])
                }
            }
            let before = try FocusBackupSupport.dump(destination.db)
            #expect(throws: BackupError.invalidManifest) { try destination.backup.restore(archive) }
            #expect(try FocusBackupSupport.dump(destination.db) == before)
            #expect(try destination.store.note(id: seeded.plain.id) == nil)
            try destination.db.pool.write { try $0.execute(sql: "DELETE FROM \(table) WHERE id=?", arguments: [id]) }
        }
    }

    // MARK: - Captures during a restore (C11 review, Minor 1)

    /// A destination that has `note` unlocked, and an archive of the same note locked.
    private func lockedElsewhere() throws -> (destination: Library, source: Library, note: Note, locked: URL) {
        let source = try Library(), destination = try Library()
        let note = try source.store.create(text: "# Voice target\nbody")
        _ = try destination.backup.restore(try source.backup.createRolling())
        try NotePrivacy(store: source.store).setPassword("source password").lock(noteId: note.id)
        return (destination, source, note, try source.backup.createRolling())
    }

    @Test func replaceAllStopsACaptureOnANoteTheBackupLocks() throws {
        let (destination, source, note, locked) = try lockedElsewhere()
        defer { destination.cleanup(); source.cleanup() }
        let folder = destination.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        let guardian = try CaptureLockGuard.register(noteId: note.id, store: destination.store, recording: recording, discardsJournal: false) {}
        defer { guardian.end() }
        #expect(!guardian.isLocked)

        _ = try destination.backup.restore(locked, mode: .replaceAll)

        #expect(try destination.store.note(id: note.id)?.isLocked == true)
        #expect(guardian.isLocked, "the capture was stopped before the locked row was written")
        #expect(guardian.isCleanedUp)
        // The capture's next journal write does not run.
        #expect(try guardian.ifUnlocked { true } == nil)
        #expect(!FileManager.default.fileExists(atPath: recording.path))
    }

    @Test func replaceAllLeavesANewNoteCaptureNoRoomToJournalIntoALockedNote() throws {
        let (destination, source, note, locked) = try lockedElsewhere()
        defer { destination.cleanup(); source.cleanup() }
        let folder = destination.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        let guardian = try CaptureLockGuard.register(noteId: note.id, store: destination.store, recording: recording, discardsJournal: true) {}
        defer { guardian.end() }

        _ = try destination.backup.restore(locked, mode: .replaceAll)

        // The capture's next result would journal text of a note that is locked now: it does not run.
        let canary = "journal-canary-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let journal = destination.paths.journal.appendingPathComponent(note.id + ".jsonl")
        let ran = try guardian.ifUnlocked { try Data(canary.utf8).write(to: journal) }
        #expect(ran == nil)
        #expect(try destination.store.note(id: note.id)?.isLocked == true)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: recording.path))
    }

    @Test func aMergeLeavesACaptureOnAnExistingNoteRunning() throws {
        let (destination, source, note, locked) = try lockedElsewhere()
        defer { destination.cleanup(); source.cleanup() }
        let folder = destination.paths.recordings.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("Voice Note.m4a")
        try Data("audio".utf8).write(to: recording)
        let guardian = try CaptureLockGuard.register(noteId: note.id, store: destination.store, recording: recording, discardsJournal: false) {}
        defer { guardian.end() }

        // The existing unlocked note wins the merge, so nothing locks it.
        let result = try destination.backup.restore(locked)

        #expect(result.keptExisting == 1)
        #expect(try destination.store.note(id: note.id)?.isLocked == false)
        #expect(!guardian.isLocked)
    }
}
