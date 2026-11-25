// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct WatchNoteCommandTests {
    @Test(arguments: [NoteLocation.archive, .trash]) func replayReportsSavedLocation(location: NoteLocation) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch()
        let note = try library.store.create(text: "Existing")
        let append = WatchNoteCommand(id: UUID(), epoch: epoch, action: .append(noteID: note.id, revision: note.revision, text: "Text"))
        let create = WatchNoteCommand(id: UUID(), epoch: epoch, action: .create(text: "Created"))
        guard case .applied(let createdID, let createdRevision) = try library.store.applyWatchCommand(create) else { Issue.record("Create failed"); return }
        guard case .applied(_, let appendedRevision) = try library.store.applyWatchCommand(append) else { Issue.record("Append failed"); return }
        if location == .archive { try library.store.archive([note.id, createdID]) }
        else { try library.store.trash([note.id, createdID]) }
        let expectedAppend: WatchNoteResult = location == .archive ? .appliedArchived(noteID: note.id, revision: appendedRevision) : .appliedTrashed(noteID: note.id, revision: appendedRevision)
        let expectedCreate: WatchNoteResult = location == .archive ? .appliedArchived(noteID: createdID, revision: createdRevision) : .appliedTrashed(noteID: createdID, revision: createdRevision)
        #expect(try library.store.applyWatchCommand(append) == expectedAppend)
        #expect(try library.store.applyWatchCommand(create) == expectedCreate)
    }

    @Test func receiptRetentionStartsNoEarlierThanCommandCreation() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let now = Date(), createdAt = now.addingTimeInterval(4)
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), createdAt: createdAt, action: .create(text: "Future skew"))
        _ = try library.store.applyWatchCommand(command, now: now)
        let recorded = try library.db.pool.read { try Date.fetchOne($0, sql: "SELECT recordedAt FROM watch_command_receipt WHERE commandID=?", arguments: [command.id.uuidString]) }
        #expect(try #require(recorded).timeIntervalSince1970 >= createdAt.timeIntervalSince1970 - 0.001)
    }
    @Test func receiptsContainOnlyNonContentMetadataAndBindKindAndCreationTime() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "Target"), other = try library.store.create(text: "Other")
        let text = "Private dictation \(UUID())"
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(),
            action: .append(noteID: note.id, revision: note.revision, text: text))
        let result = try library.store.applyWatchCommand(command)
        let metadata = try library.db.pool.read { try String.fetchOne($0, sql: "SELECT requestMetadata FROM watch_command_receipt WHERE commandID=?", arguments: [command.id.uuidString]) }
        let stored = try #require(metadata)
        let object = try #require(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["kind", "epoch", "createdAt"])
        #expect(!stored.contains(note.id))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(!stored.contains(text))
        #expect(!stored.contains(WatchNoteCommand.fingerprint(text)))
        #expect(!stored.contains(WatchNoteCommand.fingerprint(String(decoding: try encoder.encode(command), as: UTF8.self))))
        let changedText = WatchNoteCommand(id: command.id, epoch: command.epoch, createdAt: command.createdAt,
            action: .append(noteID: note.id, revision: note.revision, text: "Not stored or applied"))
        #expect(try library.store.applyWatchCommand(changedText) == result)
        let changedTarget = WatchNoteCommand(id: command.id, epoch: command.epoch, createdAt: command.createdAt,
            action: .append(noteID: other.id, revision: other.revision, text: text))
        let changedKind = WatchNoteCommand(id: command.id, epoch: command.epoch, createdAt: command.createdAt, action: .create(text: text))
        let changedTime = WatchNoteCommand(id: command.id, epoch: command.epoch, createdAt: command.createdAt.addingTimeInterval(1),
            action: command.action)
        // Retargeting an existing UUID does not mutate the second target; normal Watch retries preserve the original command.
        #expect(try library.store.applyWatchCommand(changedTarget) == .applied(noteID: other.id, revision: note.revision + 1))
        #expect(try library.store.applyWatchCommand(changedKind) == .refused(.invalidCommand))
        #expect(try library.store.applyWatchCommand(changedTime) == .refused(.invalidCommand))
        #expect(try library.store.note(id: note.id)?.text == "Target\n" + text)
        #expect(try library.store.note(id: other.id)?.text == "Other")
    }

    @Test func nonUUIDTargetIsNotStoredInMetadataOrOutcomeAndReplays() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let marker = "private-target-" + UUID().uuidString
        let note = try library.db.pool.write { db in try NoteStore.insert(id: marker, text: "Fixture", now: .now, in: db) }
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(),
            action: .append(noteID: note.id, revision: note.revision, text: "additional text"))
        let first = try library.store.applyWatchCommand(command)
        #expect(first == .applied(noteID: marker, revision: note.revision + 1))
        #expect(try library.store.applyWatchCommand(command) == first)
        let row = try library.db.pool.read { db in try #require(try Row.fetchOne(db, sql: "SELECT requestMetadata,result FROM watch_command_receipt WHERE commandID=?", arguments: [command.id.uuidString])) }
        #expect(!(row["requestMetadata"] as String).contains(marker))
        #expect(!String(decoding: row["result"] as Data, as: UTF8.self).contains(marker))
        #expect(try library.store.note(id: marker)?.text == "Fixture\nadditional text")
    }

    @Test func savedTaskCannotBeAcknowledgedAsAppliedAfterEpochChanges() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "- [ ] Task")
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), action: .setTask(noteID: note.id,
            revision: note.revision, sourceSHA256: WatchNoteCommand.fingerprint(note.text), utf16Offset: 2, expectedMarker: "[ ]", checked: true))
        let applied = try library.store.applyWatchCommand(command)
        let stored = try library.db.pool.read { try String.fetchOne($0, sql: "SELECT requestMetadata FROM watch_command_receipt WHERE commandID=?", arguments: [command.id.uuidString]) }
        let taskMetadata = try #require(stored)
        #expect(!taskMetadata.contains(WatchNoteCommand.fingerprint(note.text)))
        #expect(try library.store.applyWatchCommand(command) == applied)
        try library.store.rotateWatchEpoch()
        #expect(try library.store.applyWatchCommand(command) == .refused(.epochMismatch))
        #expect(try library.store.note(id: note.id)?.text == "- [x] Task")
    }

    @Test func stableLibraryIdentitySurvivesContainerMoveAndEpochRotation() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let identity = try library.store.watchLibraryID()
        #expect(identity.utf8.count == 64)
        try library.store.rotateWatchEpoch()
        #expect(try library.store.watchLibraryID() == identity)
        try library.db.pool.close()
        let moved = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("moved-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: moved.root) }
        try FileManager.default.moveItem(at: library.paths.root, to: moved.root)
        let database = try AppDatabase.openExisting(path: moved.database)
        defer { try? database.pool.close() }
        let store = NoteStore(db: database, notifier: nil, paths: moved)
        #expect(try store.watchLibraryID() == identity)
    }

    @Test func corruptStableIdentityIsNeverSilentlyRegenerated() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        try Settings(db: library.db).set(SettingKey<String>("watch.libraryID", default: ""), to: "invalid")
        #expect(throws: WatchNoteError.self) { try library.store.watchLibraryID() }
    }

    @Test(arguments: [BackupRestoreMode.merge, .replaceAll])
    func portableRestoreKeepsDestinationIdentityInsteadOfImportingSourceIdentity(mode: BackupRestoreMode) throws {
        let source = try PrivacyTestLibrary(), destination = try PrivacyTestLibrary()
        defer { source.cleanup(); destination.cleanup() }
        let sourceID = try source.store.watchLibraryID(), targetID = try destination.store.watchLibraryID()
        #expect(sourceID != targetID)
        _ = try source.store.create(text: "Portable content")
        let archive = source.paths.root.appendingPathComponent("identity.theonotes-backup")
        try LibraryBackup(database: source.db, paths: source.paths).create(at: archive)
        _ = try LibraryBackup(database: destination.db, paths: destination.paths).restore(archive, mode: mode)
        #expect(try destination.store.watchLibraryID() == targetID)
        #expect(try destination.store.allNotes().count == 1)
    }

    @Test func receiptCannotAcknowledgeADeletedTargetAcrossEpochOrExpiry() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), createdAt: start, action: .create(text: "Later deleted"))
        let result = try library.store.applyWatchCommand(command, now: start)
        guard case .applied(let id, _) = result else { Issue.record("Expected applied"); return }
        try library.store.trash([id]); try library.store.deletePermanently([id])
        try library.store.rotateWatchEpoch()
        #expect(try library.store.applyWatchCommand(command, now: start.addingTimeInterval(8 * 86_400)) == .refused(.missingTarget))
        #expect(try library.store.allNotes().isEmpty)
    }

    @Test func correctedClockAllowsFreshCommandsInsideHighWaterWindowAndSmallFutureSkew() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let jumped = start.addingTimeInterval(2 * 86_400)
        _ = try library.store.applyWatchCommand(.init(id: UUID(), epoch: epoch, createdAt: jumped, action: .create(text: "Before clock correction")), now: jumped)
        let corrected = start.addingTimeInterval(86_400)
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: corrected.addingTimeInterval(3), action: .create(text: "Fresh after correction"))
        let result = try library.store.applyWatchCommand(current, now: corrected)
        guard case .applied = result else { Issue.record("A current command must not be blocked until the clock catches up"); return }
        let json = try library.db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key='watch.commandClock'") }
        let storedClock = try #require(json)
        let highWater = try JSONDecoder().decode(Date.self, from: Data(storedClock.utf8))
        #expect(highWater == jumped)
        let future = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: corrected.addingTimeInterval(6), action: .create(text: "Too far ahead"))
        #expect(throws: WatchNoteError.self) { try library.store.applyWatchCommand(future, now: corrected) }
        #expect(try library.store.allNotes().count == 2)
    }

    @Test func exactlySevenDaysIsValidAndSavedReceiptStillReplaysAfterward() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), createdAt: start, action: .create(text: "Boundary"))
        let boundary = start.addingTimeInterval(7 * 86_400)
        let result = try library.store.applyWatchCommand(command, now: boundary)
        guard case .applied = result else { Issue.record("Exactly seven days must still apply"); return }
        #expect(try library.store.applyWatchCommand(command, now: boundary.addingTimeInterval(0.001)) == result)
        let unseen = WatchNoteCommand(id: UUID(), epoch: command.epoch, createdAt: start, action: .create(text: "Never accepted"))
        #expect(try library.store.applyWatchCommand(unseen, now: boundary.addingTimeInterval(0.001)) == .refused(.expired))
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func receiptIsRetainedAtExactlyFourteenDaysAndPrunedOnlyAfterward() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let start = Date(timeIntervalSince1970: 1_800_000_000), epoch = try library.store.watchEpoch()
        let old = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start, action: .create(text: "Old receipt"))
        _ = try library.store.applyWatchCommand(old, now: start)
        let boundary = start.addingTimeInterval(14 * 86_400)
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: boundary, action: .create(text: "At boundary"))
        _ = try library.store.applyWatchCommand(current, now: boundary)
        let atBoundary = try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM watch_command_receipt WHERE commandID=?", arguments: [old.id.uuidString]) }
        #expect(atBoundary == 1)
        let after = boundary.addingTimeInterval(0.001)
        _ = try library.store.applyWatchCommand(.init(id: UUID(), epoch: epoch, createdAt: after, action: .create(text: "After boundary")), now: after)
        let afterBoundary = try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM watch_command_receipt WHERE commandID=?", arguments: [old.id.uuidString]) }
        #expect(afterBoundary == 0)
        #expect(try library.store.applyWatchCommand(old, now: after) == .refused(.expired))
        #expect(try library.store.allNotes().count == 3)
    }

    @Test func evictedReceiptCannotReplayAfterFifteenDaysOrClockRollback() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let old = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start, action: .create(text: "Original capture"))
        _ = try library.store.applyWatchCommand(old, now: start)
        let later = start.addingTimeInterval(15 * 86_400)
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: later, action: .create(text: "Current capture"))
        _ = try library.store.applyWatchCommand(current, now: later)
        let retained = try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM watch_command_receipt WHERE commandID=?", arguments: [old.id.uuidString]) }
        #expect(retained == 0)
        #expect(try library.store.applyWatchCommand(old, now: later) == .refused(.expired))
        #expect(try library.store.applyWatchCommand(old, now: start.addingTimeInterval(1)) == .refused(.expired))
        #expect(try library.store.allNotes().count == 2)
        try library.db.pool.close()
        let reopened = try AppDatabase.openExisting(path: library.paths.database)
        defer { try? reopened.pool.close() }
        let store = NoteStore(db: reopened, notifier: nil, paths: library.paths)
        #expect(try store.applyWatchCommand(old, now: start.addingTimeInterval(1)) == .refused(.expired))
        #expect(try store.applyWatchCommand(old, now: later) == .refused(.expired))
        #expect(try store.allNotes().count == 2)
    }

    @Test func expiryPersistsClockFenceAndFutureCommandsRemainUnacknowledgedUntilTimeIsValid() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let future = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start.addingTimeInterval(60), action: .create(text: "Future"))
        #expect(throws: WatchNoteError.self) { try library.store.applyWatchCommand(future, now: start) }
        let initialReceipts = try library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM watch_command_receipt") }
        #expect(initialReceipts == 0)
        _ = try library.store.applyWatchCommand(future, now: start.addingTimeInterval(60))
        let expired = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start, action: .create(text: "Too old"))
        #expect(try library.store.applyWatchCommand(expired, now: start.addingTimeInterval(8 * 86_400)) == .refused(.expired))
        #expect(try library.store.applyWatchCommand(expired, now: start.addingTimeInterval(1)) == .refused(.expired))
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func liveReceiptReserveIsNonterminalAndOnlyOlderThanSevenDaysCanMakeRoom() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), start = Date(timeIntervalSince1970: 1_800_000_000)
        let known = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start, action: .create(text: "Known receipt"))
        let knownResult = try library.store.applyWatchCommand(known, now: start)
        let result = try JSONEncoder().encode(WatchNoteResult.refused(.readOnly))
        try library.db.pool.write { db in
            for _ in 0..<4095 {
                try db.execute(sql: "INSERT INTO watch_command_receipt(epoch,commandID,requestMetadata,result,recordedAt) VALUES(?,?,?,?,?)",
                    arguments: [epoch.uuidString, UUID().uuidString, String(repeating: "0", count: 64), result, start])
            }
        }
        #expect(try library.store.applyWatchCommand(known, now: start) == knownResult)
        let blocked = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: start, action: .create(text: "Capacity retry"))
        #expect(throws: WatchNoteError.self) { try library.store.applyWatchCommand(blocked, now: start) }
        #expect(throws: WatchNoteError.self) { try library.store.applyWatchCommand(blocked, now: start.addingTimeInterval(7 * 86_400)) }
        #expect(try library.store.applyWatchCommand(known, now: start.addingTimeInterval(7 * 86_400)) == knownResult)
        #expect(try library.store.allNotes().count == 1)
        let later = start.addingTimeInterval(8 * 86_400)
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, createdAt: later, action: .create(text: "After safe eviction"))
        _ = try library.store.applyWatchCommand(current, now: later)
        #expect(try library.store.applyWatchCommand(blocked, now: later) == .refused(.expired))
        #expect(try library.store.allNotes().count == 2)
    }

    private func legacyLibrary(at paths: AppPaths) throws {
        try paths.createDirectories()
        let queue = try DatabaseQueue(path: paths.database.path)
        defer { try? queue.close() }
        try Migrations.migrator.migrate(queue, upTo: "v19-note-type")
        try queue.write { db in
            _ = try NoteStore.insert(id: "legacy-note", text: "# Old note\nPreserved", now: Date(timeIntervalSince1970: 100), captureSource: .share, in: db)
        }
    }

    @Test func recoverySwitchMigratesV19DestinationsBeforeSelectingAndPreservesTheirData() throws {
        let base = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("watch-v19-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: base.root) }
        try legacyLibrary(at: base)
        let id = UUID().uuidString.lowercased()
        let recovery = AppPaths(root: base.root.deletingLastPathComponent().appendingPathComponent(base.root.lastPathComponent + "-Recovery-" + id))
        defer { try? FileManager.default.removeItem(at: recovery.root) }
        try legacyLibrary(at: recovery)
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "origin": base.root.lastPathComponent])
            .write(to: recovery.root.appendingPathComponent(".sync-recovery-library.json"))
        let prepared = PreparedRecoveryLibrary(paths: recovery, base: base, id: id)
        try SyncRecoveryLibrary.select(prepared)
        let migratedRecovery = try AppDatabase.openExisting(path: recovery.database)
        defer { try? migratedRecovery.pool.close() }
        let recoveredStore = NoteStore(db: migratedRecovery, notifier: nil, paths: recovery)
        #expect(try recoveredStore.note(id: "legacy-note")?.text == "# Old note\nPreserved")
        #expect(try recoveredStore.captureSource(noteId: "legacy-note") == .share)
        _ = try recoveredStore.watchEpoch()
        try SyncRecoveryLibrary.selectOriginal(for: recovery)
        let migratedOriginal = try AppDatabase.openExisting(path: base.database)
        defer { try? migratedOriginal.pool.close() }
        let originalStore = NoteStore(db: migratedOriginal, notifier: nil, paths: base)
        #expect(try originalStore.note(id: "legacy-note")?.text == "# Old note\nPreserved")
        #expect(try originalStore.captureSource(noteId: "legacy-note") == .share)
        _ = try originalStore.watchEpoch()
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: base).root, base.root))
    }

    @Test(arguments: ["missing", "empty", "corrupt", "foreign"])
    func invalidRecoveryDatabaseNeverGetsInitializedOrSelected(kind: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString.lowercased()
        let recovery = AppPaths(root: library.paths.root.deletingLastPathComponent().appendingPathComponent(library.paths.root.lastPathComponent + "-Recovery-" + id))
        defer { try? FileManager.default.removeItem(at: recovery.root) }
        try recovery.createDirectories()
        try JSONSerialization.data(withJSONObject: ["version": 1, "id": id, "origin": library.paths.root.lastPathComponent])
            .write(to: recovery.root.appendingPathComponent(".sync-recovery-library.json"))
        if kind == "empty" { try Data().write(to: recovery.database) }
        if kind == "corrupt" { try Data("not a SQLite database".utf8).write(to: recovery.database) }
        if kind == "foreign" {
            let foreign = try DatabaseQueue(path: recovery.database.path)
            try foreign.write { try $0.execute(sql: "CREATE TABLE unrelated(value TEXT)") }
            try foreign.close()
        }
        let before = try? Data(contentsOf: recovery.database)
        #expect(throws: (any Error).self) { try SyncRecoveryLibrary.select(.init(paths: recovery, base: library.paths, id: id)) }
        let after = try? Data(contentsOf: recovery.database)
        #expect(after == before)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: library.paths).root, library.paths.root))
    }

    @Test func wrongEpochFloodCannotConsumeReceiptsOrBlockCurrentCommand() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch()
        for _ in 0..<4100 {
            let stale = WatchNoteCommand(id: UUID(), epoch: UUID(), action: .create(text: "Wrong epoch"))
            #expect(try library.store.applyWatchCommand(stale) == .refused(.epochMismatch))
        }
        #expect(try library.store.allNotes().isEmpty)
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, action: .create(text: "Current intent"))
        let applied = try library.store.applyWatchCommand(current)
        #expect(try library.store.applyWatchCommand(current) == applied)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func savedReceiptReplaysAcrossEpochRotationWithoutOverwritingIt() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let old = try library.store.watchEpoch()
        let command = WatchNoteCommand(id: UUID(), epoch: old, action: .create(text: "Applied only once"))
        let applied = try library.store.applyWatchCommand(command)
        try library.store.rotateWatchEpoch()
        #expect(try library.store.applyWatchCommand(command) == applied)
        #expect(try library.store.allNotes().count == 1)
        // Restore only the fixture's epoch to observe the original receipt, never its replacement.
        try Settings(db: library.db).set(SettingKey<UUID>("watch.epoch", default: old), to: old)
        #expect(try library.store.applyWatchCommand(command) == applied)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func dailySQLiteSnapshotRetainsReceiptAndEpochAsOneDatabaseSnapshot() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch()
        let command = WatchNoteCommand(id: UUID(), epoch: epoch, action: .create(text: "Daily snapshot"))
        let result = try library.store.applyWatchCommand(command)
        let snapshot = try #require(try LibraryBackup(database: library.db, paths: library.paths).createDailyDatabaseSnapshot())
        let database = try AppDatabase.openExisting(path: snapshot)
        defer { try? database.pool.close() }
        let stored = NoteStore(db: database, notifier: nil, paths: library.paths)
        #expect(try stored.watchEpoch() == epoch)
        #expect(try stored.applyWatchCommand(command) == result)
        #expect(try stored.allNotes().count == 1)
    }

    @Test func recoverySelectionRotatesDestinationEpochWithAlreadyOpenDatabaseAndReturnToOriginal() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        _ = try library.store.create(text: "Original")
        let originalEpoch = try library.store.watchEpoch()
        let originalIdentity = try library.store.watchLibraryID()
        let archive = library.paths.root.appendingPathComponent("recovery.theonotes-backup")
        try LibraryBackup(database: library.db, paths: library.paths).create(at: archive)
        let prepared = try SyncRecoveryLibrary.prepare(source: library.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        let recoveryDB = try AppDatabase.openExisting(path: prepared.paths.database)
        defer { try? recoveryDB.pool.close() }
        let recovery = NoteStore(db: recoveryDB, notifier: nil, paths: prepared.paths)
        let recoveryIdentity = try recovery.watchLibraryID()
        #expect(recoveryIdentity != originalIdentity)
        let old = try recovery.watchEpoch()
        try SyncRecoveryLibrary.select(prepared)
        #expect(try recovery.watchEpoch() != old)
        #expect(try recovery.watchLibraryID() == recoveryIdentity)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: library.paths).root, prepared.paths.root))
        #expect(try recovery.applyWatchCommand(.init(id: UUID(), epoch: old, action: .create(text: "Stale recovery intent"))) == .refused(.epochMismatch))
        try SyncRecoveryLibrary.selectOriginal(for: prepared.paths)
        #expect(try library.store.watchEpoch() != originalEpoch)
        #expect(try library.store.watchLibraryID() == originalIdentity)
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: library.paths).root, library.paths.root))
        #expect(try library.store.applyWatchCommand(.init(id: UUID(), epoch: originalEpoch, action: .create(text: "Stale original intent"))) == .refused(.epochMismatch))
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func recoverySelectionCannotChangeWhenDestinationEpochCannotBeCommitted() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let archive = library.paths.root.appendingPathComponent("recovery.theonotes-backup")
        try LibraryBackup(database: library.db, paths: library.paths).create(at: archive)
        let prepared = try SyncRecoveryLibrary.prepare(source: library.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }
        let saved = prepared.paths.root.appendingPathComponent("database.saved")
        try FileManager.default.moveItem(at: prepared.paths.database, to: saved)
        try FileManager.default.createDirectory(at: prepared.paths.database, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try SyncRecoveryLibrary.select(prepared) }
        #expect(AppPaths.isSameDirectory(try SyncRecoveryLibrary.activePaths(base: library.paths).root, library.paths.root))
        #expect(!FileManager.default.fileExists(atPath: library.paths.root.appendingPathComponent(".active-recovery-library.json").path))
    }

    @Test func receiptAndMutationRollbackTogetherWhenCommitIsRejected() throws {
        enum Failure: Error { case rejected }
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), action: .create(text: "Atomic"))
        let guarded = library.store.guarded { _, stage in if case .beforeCommit = stage { throw Failure.rejected } }
        #expect(throws: Failure.self) { try guarded.applyWatchCommand(command) }
        #expect(try library.store.allNotes().isEmpty)
        let result = try library.store.applyWatchCommand(command)
        #expect(try library.store.applyWatchCommand(command) == result)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func appLockRefusalIsDurableAndDoesNotChangeExistingCaptureSources() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let existing = try library.store.create(text: "Old value", captureSource: .share)
        let original = try library.store.note(id: existing.id)
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), action: .create(text: "Denied"))
        let key = SettingKey<Bool>("mobile.appLock", default: false)
        let settings = Settings(db: library.db)
        try settings.set(key, to: true)
        #expect(try library.store.applyWatchCommand(command) == .refused(.privacy))
        try settings.set(key, to: false)
        #expect(try library.store.applyWatchCommand(command) == .refused(.privacy))
        #expect(try library.store.note(id: existing.id) == original)
        #expect(try library.store.captureSource(noteId: existing.id) == .share)
        #expect(try library.store.allNotes().count == 1)
    }

    @Test func corruptPrivacySettingFailsClosedAndCorruptEpochIsNeverSilentlyReplaced() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch()
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES('mobile.appLock','broken-json')")
        }
        let command = WatchNoteCommand(id: UUID(), epoch: epoch, action: .create(text: "Denied"))
        #expect(try library.store.applyWatchCommand(command) == .refused(.privacy))
        try library.db.pool.write { db in
            try db.execute(sql: "UPDATE setting SET value='broken-json' WHERE key='watch.epoch'")
        }
        #expect(throws: WatchNoteError.self) { try library.store.watchEpoch() }
        #expect(throws: WatchNoteError.self) {
            try library.store.applyWatchCommand(.init(id: UUID(), epoch: epoch, action: .create(text: "No implicit reset")))
        }
        #expect(try library.store.allNotes().isEmpty)
    }

    @Test(arguments: ["locked", "readOnly", "trash", "deleted", "revision"])
    func ineligibleTargetsNeverChangeTheirContent(reason: String) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "Untouched")
        let command = WatchNoteCommand(id: UUID(), epoch: try library.store.watchEpoch(), action: .append(noteID: note.id, revision: note.revision, text: "Wrong"))
        let expected: WatchNoteRefusal
        switch reason {
        case "locked": try library.access().lock(noteId: note.id); expected = .privacy
        case "readOnly": try library.store.setReadOnly(note.id, readOnly: true); expected = .readOnly
        case "trash": try library.store.trash([note.id]); expected = .missingTarget
        case "deleted": try library.store.trash([note.id]); try library.store.deletePermanently([note.id]); expected = .missingTarget
        default: _ = try library.store.updateText(id: note.id, text: "Newer", expectedRevision: note.revision); expected = .staleTarget
        }
        let before = try library.store.note(id: note.id)
        #expect(try library.store.applyWatchCommand(command) == .refused(expected))
        #expect(try library.store.note(id: note.id) == before)
    }

    @Test func taskUsesExactRevisionHashMarkerAndMarkdownParserWithoutRetargeting() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), text = "😀\n- [ ] First\n- [ ] Second"
        let note = try library.store.create(text: text)
        func task(hash: String, offset: Int, marker: String = "[ ]", revision: Int? = nil) -> WatchNoteCommand {
            .init(id: UUID(), epoch: epoch, action: .setTask(noteID: note.id, revision: revision ?? note.revision,
                sourceSHA256: hash, utf16Offset: offset, expectedMarker: marker, checked: true))
        }
        #expect(try library.store.applyWatchCommand(task(hash: "wrong", offset: 5)) == .refused(.staleTarget))
        #expect(try library.store.applyWatchCommand(task(hash: WatchNoteCommand.fingerprint(text), offset: 1)) == .refused(.staleTarget))
        #expect(try library.store.applyWatchCommand(task(hash: WatchNoteCommand.fingerprint(text), offset: 5, marker: "[x]")) == .refused(.staleTarget))
        let exact = task(hash: WatchNoteCommand.fingerprint(text), offset: 5)
        #expect(try library.store.applyWatchCommand(exact) == .applied(noteID: note.id, revision: note.revision + 1))
        #expect(try library.store.applyWatchCommand(exact) == .applied(noteID: note.id, revision: note.revision + 1))
        #expect(try library.store.note(id: note.id)?.text == "😀\n- [x] First\n- [ ] Second")
        let fenced = try library.store.create(text: "```\n- [ ] Fake\n```")
        let fake = WatchNoteCommand(id: UUID(), epoch: epoch, action: .setTask(noteID: fenced.id, revision: fenced.revision,
            sourceSHA256: WatchNoteCommand.fingerprint(fenced.text), utf16Offset: 6, expectedMarker: "[ ]", checked: true))
        #expect(try library.store.applyWatchCommand(fake) == .refused(.staleTarget))
        #expect(try library.store.note(id: fenced.id)?.text == fenced.text)
    }

    @Test func syncMaterializationPreservesLocalEpochAndWatchReceipt() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch()
        let capture = WatchNoteCommand(id: UUID(), epoch: epoch, action: .create(text: "Local Watch"))
        let result = try library.store.applyWatchCommand(capture)
        let remote = try library.entity(library.payload("# Remote normal sync"))
        try library.receive([remote])
        _ = try await library.materializer().apply(remote)
        #expect(try library.store.watchEpoch() == epoch)
        #expect(try library.store.applyWatchCommand(capture) == result)
        #expect(try library.store.allNotes().count == 2)
    }

    @Test func lostAckReplaySurvivesReopenAndPayloadReuseCannotChangeReceipt() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), id = UUID()
        let command = WatchNoteCommand(id: id, epoch: epoch, action: .create(text: "# Watch thought"))
        let result = try library.store.applyWatchCommand(command)
        let reopenedDB = try AppDatabase(path: library.paths.database)
        defer { try? reopenedDB.pool.close() }
        let reopened = NoteStore(db: reopenedDB, notifier: nil, paths: library.paths)
        #expect(try reopened.applyWatchCommand(command) == result)
        #expect(try reopened.allNotes().count == 1)
        let note = try #require(try reopened.allNotes().first)
        #expect(try reopened.captureSource(noteId: note.id) == .voice)
        let changed = WatchNoteCommand(id: id, epoch: epoch, createdAt: command.createdAt, action: .create(text: "Changed"))
        #expect(try reopened.applyWatchCommand(changed) == result)
        #expect(try reopened.applyWatchCommand(command) == result)
        #expect(try reopened.note(id: note.id)?.text == "# Watch thought")
    }

    @Test(arguments: [BackupRestoreMode.merge, .replaceAll], [false, true])
    func restoreRotatesEpochAndOldCommandsCannotMutateRestoredLibrary(mode: BackupRestoreMode, hasReceipt: Bool) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Original", captureSource: .shortcut)
        let backup = LibraryBackup(database: library.db, paths: library.paths)
        let archive = library.paths.root.appendingPathComponent("fixture.theonotes-backup")
        try backup.create(at: archive)
        let old = try library.store.watchEpoch()
        let command = WatchNoteCommand(id: UUID(), epoch: old, action: .append(noteID: note.id, revision: note.revision, text: "Old intent"))
        if hasReceipt {
            let previous = try library.store.applyWatchCommand(command)
            #expect(try library.store.applyWatchCommand(command) == previous)
        }
        _ = try backup.restore(archive, mode: mode)
        let restored = try library.store.allNotes()
        #expect(try library.store.watchEpoch() != old)
        #expect(try library.store.applyWatchCommand(command) == .refused(.epochMismatch))
        #expect(try library.store.applyWatchCommand(command) == .refused(.epochMismatch))
        #expect(try library.store.allNotes() == restored)
        #expect(try library.store.captureSource(noteId: note.id) == .shortcut)
        let currentNote = try #require(restored.first(where: { $0.id == note.id }))
        if case .replaceAll = mode { #expect(currentNote.text == note.text) }
        else if hasReceipt { #expect(currentNote.text == note.text + "\nOld intent") }
        let current = WatchNoteCommand(id: command.id, epoch: try library.store.watchEpoch(),
            action: .append(noteID: note.id, revision: currentNote.revision, text: "New epoch intent"))
        #expect(try library.store.applyWatchCommand(current) == .applied(noteID: note.id, revision: currentNote.revision + 1))
        #expect(try library.store.note(id: note.id)?.text == currentNote.text + "\nNew epoch intent")
    }

    @Test func ordinaryStoreWritesDoNotRotateEpochAndStaleAppendNeverOverwritesThem() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let epoch = try library.store.watchEpoch(), note = try library.store.create(text: "Original")
        let newer = try library.store.updateText(id: note.id, text: "Synced edit", expectedRevision: note.revision)
        #expect(try library.store.watchEpoch() == epoch)
        let stale = WatchNoteCommand(id: UUID(), epoch: epoch, action: .append(noteID: note.id, revision: note.revision, text: "Stale"))
        #expect(try library.store.applyWatchCommand(stale) == .refused(.staleTarget))
        let current = WatchNoteCommand(id: UUID(), epoch: epoch, action: .append(noteID: note.id, revision: newer.revision, text: "Watch append"))
        #expect(try library.store.applyWatchCommand(current) == .applied(noteID: note.id, revision: newer.revision + 1))
        #expect(try library.store.note(id: note.id)?.text == "Synced edit\nWatch append")
    }
}
