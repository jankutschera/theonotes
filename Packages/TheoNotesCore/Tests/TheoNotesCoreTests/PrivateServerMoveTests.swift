// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// "Move This Library to iCloud" (MOVE-R1 to MOVE-R6): every refusal and every interruption leaves the library bound to the private
/// server exactly as it was; a finished move leaves it never synced, backend none, notes untouched, and unbindable by the old engine.
@Suite struct PrivateServerMoveTests {
    /// A library in step with a fake private server: one tagged note with an attachment, a second note, everything sent.
    struct Synced {
        let library: SyncMaterializerTests.Library
        let server = SyncEngineTests.Server()
        let engine: SyncEngine
        let noteID: String
        var db: AppDatabase { library.db }

        init() async throws {
            library = try SyncMaterializerTests.Library()
            let note = try library.store.create(text: "# Move me\n#work/plans\nBody [file](f.txt)")
            noteID = note.id
            _ = try AttachmentStore(paths: library.paths, database: library.db).add(data: Data("bytes".utf8), filename: "f.txt", to: note.id)
            _ = try library.store.create(text: "second note #work")
            engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                                transport: server, blobs: SyncPayloadReaderTests.Blobs())
            _ = try await engine.synchronize()
        }

        func cleanup() async { await engine.shutdown(); library.cleanup() }

        func backup() throws -> String {
            let backup = LibraryBackup(database: db, paths: library.paths)
            _ = try backup.createRolling()
            return try #require(try backup.localBackups().first).id
        }

        func move(crash: CrashPoint = .never, finalSync: (@Sendable () async throws -> Void)? = nil, backupID: String? = nil) async throws {
            try await PrivateServerMove.run(database: db, paths: library.paths, finalSync: finalSync ?? { _ = try await engine.synchronize() },
                                            makeBackup: { try backupID ?? backup() }, crash: crash)
        }

        /// The binding and every queue table: what "bound as before" means.
        func binding() throws -> [String] {
            try db.pool.read { db in
                let control = try Row.fetchOne(db, sql: "SELECT enabled, accountId, backend FROM sync_control")!
                var out = ["control|\(control["enabled"] as Int)|\(control["accountId"] as String? ?? "-")|\(control["backend"] as String)"]
                for table in SyncAccountDetach.cloudflareClearedTables + ["sync_conflict", "sync_dirty"] {
                    out.append("\(table)|\(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!)")
                }
                out.append("moved|\(try PrivateServerMove.hasLeft(db))")
                return out
            }
        }

        func notes() throws -> [String] {
            try db.pool.read { try String.fetchAll($0, sql: "SELECT id || '|' || text || '|' || location FROM note ORDER BY id") }
        }
    }

    @Test func aSyncedLibraryMovesAndIsLeftNeverSyncedWithItsNotesUntouched() async throws {
        let s = try await Synced()
        let notes = try s.notes()
        #expect(try PrivateServerMove.refusals(in: s.db, paths: s.library.paths).isEmpty)
        try await s.move()
        #expect(try s.notes() == notes)
        #expect(try CloudSyncStore(database: s.db).backend() == .none)
        let control = try await s.db.pool.read { try String.fetchOne($0, sql: "SELECT enabled || '|' || ifnull(accountId,'-') FROM sync_control") }
        #expect(control == "0|-")
        for table in SyncAccountDetach.cloudflareClearedTables {
            #expect(try await s.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") } == 0, "\(table)")
        }
        #expect(try PrivateServerMove.hasLeft(s.db))
        #expect(await s.server.count() > 0, "the server's copy is not touched")
        await s.cleanup()
    }

    @Test func theOldEngineCanNeverBindAMovedLibraryAgain() async throws {
        let s = try await Synced()
        try await s.move()
        #expect(throws: SyncQueueError.movedToICloud) { try s.library.queue.configure(accountID: "account") }
        #expect(throws: SyncQueueError.movedToICloud) { try s.library.queue.enable(accountID: "account") }
        #expect(try CloudSyncStore(database: s.db).backend() == .none)
        await s.cleanup()
    }

    @Test func theICloudSwitchCanBindAMovedLibrary() async throws {
        let s = try await Synced()
        try await s.move()
        try CloudSyncStore(database: s.db).bind(accountId: "ck-account", containerId: "c", zoneName: "z", cloudUserHash: "u")
        #expect(try CloudSyncStore(database: s.db).backend() == .cloudkit)
        await s.cleanup()
    }

    @Test func aLibraryThatIsNotOnThePrivateServerIsRefused() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_control SET accountId=NULL, backend='none', enabled=0") }
        let synced = LockedBox(false)
        await #expect(throws: PrivateServerMoveRefusal.notBoundToPrivateServer) {
            try await PrivateServerMove.run(database: library.db, paths: library.paths, finalSync: { synced.update { $0 = true } }, makeBackup: { "x" })
        }
        #expect(!synced.value, "nothing is contacted for a library that has nothing to leave")
    }

    @Test func aFirstSyncThatNeverFinishedIsRefused() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false); defer { library.cleanup() }
        #expect(try PrivateServerMove.refusals(in: library.db, paths: library.paths).first == .firstSyncNotFinished)
    }

    @Test func anOfflineFinalSyncRefusesAndChangesNothing() async throws {
        let s = try await Synced()
        let before = try s.binding(), notes = try s.notes()
        await #expect(throws: URLError.self) { try await s.move(finalSync: { throw URLError(.notConnectedToInternet) }) }
        #expect(try s.binding() == before)
        #expect(try s.notes() == notes)
        await s.cleanup()
    }

    @Test func everyQueueStateThatIsNotDoneRefusesAndChangesNothing() async throws {
        let cases: [(String, PrivateServerMoveRefusal, (Synced) throws -> Void)] = [
            ("an edit not yet sent", .unsentChanges(1), { s in
                let note = try #require(try s.library.store.note(id: s.noteID))
                _ = try s.library.store.updateText(id: s.noteID, text: note.text + "\nmore", expectedRevision: note.revision)
            }),
            ("a mutation in the outbox", .unsentChanges(2), { s in
                let note = try #require(try s.library.store.note(id: s.noteID))
                _ = try s.library.store.updateText(id: s.noteID, text: note.text + "\nmore", expectedRevision: note.revision)
                _ = try s.library.queue.prepareNext(vaultKey: s.library.key)
            }),
            ("a received change not applied", .unreceivedChanges(1), { s in
                try s.library.receive([s.library.entity(s.library.payload("# Remote\n", id: "remote-note"), id: "remote-note", sequence: 99)])
            }),
            ("an apply running", .syncRunning, { s in try s.db.pool.write { try $0.execute(sql: "UPDATE sync_control SET applying=1") } }),
            ("a lock half done", .lockOrUnlockInProgress, { s in
                try s.db.pool.write { try $0.execute(sql: "INSERT INTO privacy_transition(noteId,targetLocked,filenames) VALUES(?,1,'[]')", arguments: [s.noteID]) }
            }),
            ("an attachment being saved", .attachmentBeingSaved, { s in
                try s.db.pool.write { db in
                    try db.execute(sql: "UPDATE sync_control SET enabled=0")
                    try db.execute(sql: "INSERT INTO staging_batch(id,noteId,replacing,filenames,createdAt) VALUES('batch',?,0,'[]',0)", arguments: [s.noteID])
                    try db.execute(sql: "UPDATE sync_control SET enabled=1")
                }
            }),
        ]
        for (name, refusal, makeState) in cases {
            let s = try await Synced()
            try makeState(s)
            let before = try s.binding(), notes = try s.notes()
            // The final sync is the caller's; here it does nothing, so the state stays what the case made.
            await #expect(throws: refusal, "\(name)") { try await s.move(finalSync: {}) }
            #expect(try s.binding() == before, "\(name)")
            #expect(try s.notes() == notes, "\(name)")
            await s.cleanup()
        }
    }

    @Test func aBackupTheLibraryDoesNotKnowRefusesInsideTheTransaction() async throws {
        let s = try await Synced()
        let before = try s.binding()
        await #expect(throws: SyncAccountDetachError.backupNotVerified) { try await s.move(backupID: "not-a-backup") }
        await #expect(throws: SyncAccountDetachError.backupNotVerified) { try await s.move(backupID: "") }
        #expect(try s.binding() == before)
        await s.cleanup()
    }

    @Test func anInterruptionAtEveryStepLeavesTheOldBindingAndTheMoveCanBeRepeated() async throws {
        for boundary in ["move.afterFinalSync", "move.afterBackup"] {
            let s = try await Synced()
            let before = try s.binding()
            let crash = CrashPoint(); crash.arm(boundary)
            await #expect(throws: CrashInjected(boundary: boundary)) { try await s.move(crash: crash) }
            #expect(try s.binding() == before, "\(boundary)")
            try await s.move()
            #expect(try CloudSyncStore(database: s.db).backend() == .none && PrivateServerMove.hasLeft(s.db))
            await s.cleanup()
        }
    }

    @Test func anEditTypedAfterTheFinalSyncStaysForICloud() async throws {
        let s = try await Synced()
        try await PrivateServerMove.run(database: s.db, paths: s.library.paths, finalSync: { _ = try await s.engine.synchronize() }, makeBackup: {
            let note = try #require(try s.library.store.note(id: s.noteID))
            _ = try s.library.store.updateText(id: s.noteID, text: note.text + "\ntyped during the backup", expectedRevision: note.revision)
            return try s.backup()
        })
        #expect(try CloudSyncStore(database: s.db).backend() == .none)
        let dirty = try await s.db.pool.read { try String.fetchAll($0, sql: "SELECT localId FROM sync_dirty WHERE entityType='note'") }
        #expect(dirty == [s.noteID], "the edit is kept in the journal and goes to iCloud with the first sync there")
        await s.cleanup()
    }

    @Test func conflictCopyLinksStayWithTheirNotes() async throws {
        let s = try await Synced()
        try await s.db.pool.write { db in
            try db.execute(sql: "UPDATE sync_control SET applying=1")
            try db.execute(sql: "INSERT INTO sync_conflict(noteId,originalNoteId,rejectedMutationId,remoteRevision) VALUES(?,?,'m',1)", arguments: [s.noteID, "original"])
            try db.execute(sql: "UPDATE sync_control SET applying=0")
        }
        try await s.move()
        #expect(try await s.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_conflict") } == 1)
        await s.cleanup()
    }

    @Test func aMissingAttachmentFileHasItsOwnRefusalThatNamesTheNotes() async throws {
        let s = try await Synced()
        for index in 1...7 {
            _ = try s.library.store.create(text: "# Lost file \(index)\n" + AttachmentMarkdown.link(for: "gone-\(index).txt"))
        }
        _ = try await s.engine.synchronize()
        let before = try s.binding()
        let refusals = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths)
        guard case .unavailableAttachments(let notes, let more, _) = refusals.first else { Issue.record("\(refusals)"); await s.cleanup(); return }
        #expect(notes.count == 5 && more == 2 && notes.allSatisfy { $0.hasPrefix("Lost file") })
        #expect(!refusals.contains { if case .unsentChanges = $0 { true } else { false } }, "the missing files are not also counted as unsent")
        await #expect(throws: PrivateServerMoveRefusal.self) { try await s.move() }
        #expect(try s.binding() == before)
        await s.cleanup()
    }

    @Test func thePreflightListsEveryReasonAndChangesNothing() async throws {
        let s = try await Synced()
        let note = try #require(try s.library.store.note(id: s.noteID))
        _ = try s.library.store.updateText(id: s.noteID, text: note.text + "\nunsent", expectedRevision: note.revision)
        try s.library.receive([s.library.entity(s.library.payload("# Remote\n", id: "remote-note"), id: "remote-note", sequence: 99)])
        let before = try s.binding(), notes = try s.notes()
        let found = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths)
        #expect(found == [.unsentChanges(1), .unreceivedChanges(1)])
        #expect(try s.binding() == before && s.notes() == notes)
        await s.cleanup()
    }

    @Test func aFinalSyncThatNeedsTheNotePasswordAgainIsNotFinished() throws {
        var summary = SyncRunSummary()
        try PrivateServerMove.requireFinished(summary)
        summary.passwordRefreshRequired = true
        #expect(throws: NotePrivacyError.accessRevoked) { try PrivateServerMove.requireFinished(summary) }
    }

    @Test func theOtherDevicesNoticeStaysUntilDismissed() async throws {
        let s = try await Synced()
        #expect(try !PrivateServerMove.showsOtherDevicesNotice(s.db))
        try await s.move()
        #expect(try PrivateServerMove.showsOtherDevicesNotice(s.db))
        try CloudSyncStore(database: s.db).bind(accountId: "ck-account", containerId: "c", zoneName: "z", cloudUserHash: "u")
        #expect(try PrivateServerMove.showsOtherDevicesNotice(s.db), "switching iCloud on does not end it")
        try PrivateServerMove.dismissOtherDevicesNotice(s.db)
        #expect(try !PrivateServerMove.showsOtherDevicesNotice(s.db))
        await s.cleanup()
    }

    @Test func theMoveNamesOnlyTheBackupItJustMade() async throws {
        let s = try await Synced()
        let backup = LibraryBackup(database: s.db, paths: s.library.paths)
        let first = try backup.createRolling()
        let id = try #require(try backup.catalogID(of: first))
        #expect(try backup.localBackups().contains { $0.id == id && $0.url.standardizedFileURL == first.standardizedFileURL })
        #expect(try backup.catalogID(of: s.library.paths.backups.appendingPathComponent("not-this-one.theonotesbackup")) == nil,
                "another archive is never taken for the one just made")
        await s.cleanup()
    }

    /// The rehearsal's preflight (MOVE-R8), on a COPY of a library only:
    /// `THEONOTES_MOVE_PREFLIGHT="<library folder>" swift test --package-path Packages/TheoNotesCore --filter preflightOfALibraryCopy`
    /// Prints every reason the move would refuse now and the counts to compare later. The real library folder is refused.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["THEONOTES_MOVE_PREFLIGHT"] != nil))
    func preflightOfALibraryCopy() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THEONOTES_MOVE_PREFLIGHT"]!)
        guard !AppPaths.isRealLibrary(root) else { Issue.record("This is the real library. Copy it into the dev identity first."); return }
        let paths = AppPaths(root: root)
        guard FileManager.default.fileExists(atPath: paths.database.path) else { Issue.record("No library at \(root.path)"); return }
        let db = try AppDatabase(path: paths.database)
        let found = try PrivateServerMove.refusals(in: db, paths: paths)
        print("MOVE-PREFLIGHT", found.isEmpty ? "ready to move" : found.map { String(describing: $0) }.joined(separator: " | "))
        let missing = try db.pool.read { try SyncQueue.unavailableAttachments(paths: paths, in: $0) }
        if !missing.isEmpty {
            let leavable = try db.pool.read { db in try missing.filter { try PrivateServerMove.leavable(db, attachmentID: $0.id) }.count }
            print("MOVE-PREFLIGHT \(leavable) of \(missing.count) attachment rows with a missing file qualify for \"Move Without These Files\"",
                  "(in \(Set(missing.map(\.noteId)).count) notes);", found.first.map { if case .unavailableAttachments(_, _, true) = $0 { "the button is offered" } else { "the button is NOT offered" } } ?? "")
        }
        let counts = try db.pool.read { db in
            try ["SELECT location || ' ' || COUNT(*) FROM note GROUP BY location", "SELECT 'locked ' || COUNT(*) FROM note WHERE isLocked=1",
                 "SELECT 'attachments ' || COUNT(*) FROM attachment WHERE deletedAt IS NULL", "SELECT 'tags ' || COUNT(*) FROM tag",
                 "SELECT 'pinned ' || COUNT(*) FROM note WHERE isPinnedGlobal=1", "SELECT 'dirty ' || COUNT(*) FROM sync_dirty",
                 "SELECT 'outbox ' || COUNT(*) FROM sync_outbox", "SELECT 'inbox ' || COUNT(*) FROM sync_inbox",
                 "SELECT 'conflict copies ' || COUNT(*) FROM sync_conflict WHERE noteId<>originalNoteId",
                 "SELECT 'backend ' || backend || ' enabled ' || enabled FROM sync_control"].flatMap { try String.fetchAll(db, sql: $0) }
        }
        print("MOVE-PREFLIGHT counts:", counts.joined(separator: ", "))
    }

    // MARK: Move Without These Files (MOVE-R10)

    /// Notes from an import whose image files never reached this device: in Notes and in the Trash, each with an image reference,
    /// the attachment rows without bytes, dirty at generation 1 and never received by the server (the owner's nine rows).
    static func addMissingFiles(_ s: Synced) throws -> [String] {
        var ids: [String] = []
        for (index, trash) in [false, true, false, true].enumerated() {
            let note = try s.library.store.create(text: "# Imported \(index)\n![](image-00\(index).jpg)\nbody")
            if trash { try s.library.store.trash([note.id]) }
            ids.append(note.id)
        }
        return ids
    }

    static func missingRows(_ s: Synced) throws -> [String] {
        try s.db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT a.id || '|' || ifnull(a.byteSize,'null') || '|' || d.generation || '|' || d.tombstone
                FROM attachment a JOIN sync_dirty d ON d.entityType='attachment' AND d.localId=a.id ORDER BY a.id
                """)
        }
    }

    @Test func missingFilesTheServerNeverHadMayBeLeftBehindAndEverythingElseStays() async throws {
        let s = try await Synced()
        let ids = try Self.addMissingFiles(s)
        _ = try await s.engine.synchronize()
        let rows = try Self.missingRows(s)
        #expect(rows.count == 4 && rows.allSatisfy { $0.hasSuffix("|null|1|0") }, "\(rows)")
        let refusals = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths)
        guard case .unavailableAttachments(let notes, 0, true) = refusals.first, refusals.count == 1 else { Issue.record("\(refusals)"); await s.cleanup(); return }
        #expect(notes.count == 4)
        let before = try s.binding()
        await #expect(throws: PrivateServerMoveRefusal.self) { try await s.move() }
        #expect(try s.binding() == before, "the plain move still refuses and changes nothing")
        let texts = try s.notes()

        try await PrivateServerMove.run(database: s.db, paths: s.library.paths, finalSync: { _ = try await s.engine.synchronize() },
                                        makeBackup: { try s.backup() }, withoutMissingFiles: true)

        #expect(try CloudSyncStore(database: s.db).backend() == .none)
        #expect(try s.notes() == texts, "every note keeps its text, its image reference and its place")
        #expect(try Self.missingRows(s) == rows, "the attachment rows stay as they are: unsent local rows")
        for id in ids { #expect(try s.library.store.note(id: id)?.text.contains("![](image-") == true) }
        await s.cleanup()
    }

    @Test func aMissingFileTheServerHadOrThatWaitsForADownloadIsNeverLeftBehind() async throws {
        let cases: [(String, (Synced, String) throws -> Void)] = [
            ("acknowledged by the server", { s, id in
                try s.db.pool.write { try $0.execute(sql: "INSERT INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES('attachment',?,?,1)", arguments: [id, id]) }
            }),
            ("a server copy", { s, id in
                try s.db.pool.write { try $0.execute(sql: "INSERT INTO sync_shadow(entityType,entityId,serverRevision,sequence,wireEntity) VALUES('attachment',?,1,1,x'00')", arguments: [id]) }
            }),
            ("a pending download", { s, id in
                try s.db.pool.write { try $0.execute(sql: "INSERT INTO sync_inbox(sequence,entityType,entityId,serverRevision,wireEntity) VALUES(999,'attachment',?,1,x'00')", arguments: [id]) }
            }),
        ]
        for (name, make) in cases {
            let s = try await Synced()
            _ = try Self.addMissingFiles(s)
            _ = try await s.engine.synchronize()
            let id = try #require(try await s.db.pool.read { try String.fetchOne($0, sql: "SELECT a.id FROM attachment a JOIN sync_dirty d ON d.localId=a.id ORDER BY a.id LIMIT 1") })
            try make(s, id)
            let refusals = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths, withoutMissingFiles: true)
            guard case .unavailableAttachments(_, _, false)? = refusals.first else { Issue.record("\(name): \(refusals)"); await s.cleanup(); continue }
            let before = try s.binding()
            await #expect(throws: PrivateServerMoveRefusal.self, "\(name)") {
                try await PrivateServerMove.run(database: s.db, paths: s.library.paths, finalSync: {}, makeBackup: { try s.backup() }, withoutMissingFiles: true)
            }
            #expect(try s.binding() == before, "\(name)")
            await s.cleanup()
        }
    }

    @Test func aFileThatIsBackIsSentAndADeletionIsAnUnsentChangeNotAMissingFile() async throws {
        let s = try await Synced()
        let ids = try Self.addMissingFiles(s)
        _ = try await s.engine.synchronize()
        // The file is back for every note: the final sync sends it, nothing is missing any more.
        for (index, id) in ids.enumerated() {
            let folder = s.library.paths.attachments.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("image \(index)".utf8).write(to: folder.appendingPathComponent("image-00\(index).jpg"))
        }
        _ = try await s.engine.synchronize()
        #expect(try PrivateServerMove.refusals(in: s.db, paths: s.library.paths).isEmpty)
        await s.cleanup()

        let t = try await Synced()
        _ = try Self.addMissingFiles(t)
        _ = try await t.engine.synchronize()
        try await t.db.pool.write { try $0.execute(sql: "UPDATE sync_dirty SET tombstone=1 WHERE entityType='attachment'") }
        let refusals = try PrivateServerMove.refusals(in: t.db, paths: t.library.paths, withoutMissingFiles: true)
        #expect(refusals == [.unsentChanges(4)], "a deletion is a change the server must get: no second button")
        await t.cleanup()
    }

    @Test func anotherReasonIsShownFirstAndTheMissingFilesWithTheButtonComeBackWhenItIsGone() async throws {
        let s = try await Synced()
        _ = try Self.addMissingFiles(s)
        _ = try await s.engine.synchronize()
        let note = try #require(try s.library.store.note(id: s.noteID))
        _ = try s.library.store.updateText(id: s.noteID, text: note.text + "\nunsent", expectedRevision: note.revision)
        let refusals = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths)
        #expect(refusals.first == .unsentChanges(1), "the person sees the reason that really blocks: \(refusals)")
        guard case .unavailableAttachments(_, _, false)? = refusals.last else { Issue.record("\(refusals)"); await s.cleanup(); return }
        await #expect(throws: PrivateServerMoveRefusal.unsentChanges(1)) {
            try await PrivateServerMove.run(database: s.db, paths: s.library.paths, finalSync: {}, makeBackup: { try s.backup() })
        }
        _ = try await s.engine.synchronize()     // the edit reaches the server
        let next = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths)
        guard case .unavailableAttachments(_, _, true)? = next.first, next.count == 1 else { Issue.record("\(next)"); await s.cleanup(); return }
        await s.cleanup()
    }

    /// Review r2 probe, now a test: with the `Attachments` folder unreadable every file looks missing; none of them may be left
    /// behind. A file whose bytes the app once saw (a size and a hash) is never left behind either, whatever the folder.
    @Test func anUnreadableAttachmentsFolderOrBytesTheAppOnceSawNeverOfferTheButton() async throws {
        let s = try await Synced()
        _ = try Self.addMissingFiles(s)
        _ = try await s.engine.synchronize()
        let fm = FileManager.default
        let hidden = s.library.paths.root.appendingPathComponent("Attachments-hidden")
        try fm.moveItem(at: s.library.paths.attachments, to: hidden)
        let away = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths, withoutMissingFiles: true)
        guard case .unavailableAttachments(_, _, false)? = away.first else { Issue.record("folder away: \(away)"); await s.cleanup(); return }
        let before = try s.binding()
        await #expect(throws: PrivateServerMoveRefusal.self) {
            try await PrivateServerMove.run(database: s.db, paths: s.library.paths, finalSync: {}, makeBackup: { try s.backup() }, withoutMissingFiles: true)
        }
        #expect(try s.binding() == before)
        try fm.moveItem(at: hidden, to: s.library.paths.attachments)
        guard case .unavailableAttachments(_, _, true)? = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths).first else {
            Issue.record("folder back"); await s.cleanup(); return
        }
        // A real file added and not sent, then lost: the app saw its bytes, so it is not "never reached any device".
        let photo = try s.library.store.create(text: "# Fresh photo\n![](fresh.png)")
        _ = try await s.engine.synchronize()
        _ = try AttachmentStore(paths: s.library.paths, database: s.db).add(data: Data("real bytes".utf8), filename: "fresh.png", to: photo.id)
        // The app's file reader (text recognition) records size and hash when it reads a file, as it did for the owner's other files.
        try await s.db.pool.write { try $0.execute(sql: "UPDATE attachment SET byteSize=10, sha256='ab' WHERE noteId=?", arguments: [photo.id]) }
        try fm.removeItem(at: s.library.paths.attachments.appendingPathComponent(photo.id))
        let seen = try PrivateServerMove.refusals(in: s.db, paths: s.library.paths, withoutMissingFiles: true)
        guard case .unavailableAttachments(_, _, false)? = seen.first else { Issue.record("bytes once seen: \(seen)"); await s.cleanup(); return }
        await s.cleanup()
    }
}
