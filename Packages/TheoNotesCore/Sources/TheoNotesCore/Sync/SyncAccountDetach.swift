// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

/// Which engine a library is bound to (`sync_control.backend`). A library binds to
/// one backend; changing it goes through `SyncAccountDetach` after a verified backup.
public enum SyncBackend: String, Sendable, Equatable {
    case none, cloudflare, cloudkit
}

public enum SyncAccountDetachError: Error, Equatable {
    /// The id is empty or names no backup in this library's catalog.
    case backupNotVerified
    case nothingToDetach
    case backendMismatch(expected: SyncBackend, actual: SyncBackend)
    /// A sync apply is running (`applying = 1`).
    case applying
    /// A lock or unlock is half done (`privacy_transition` has a row).
    case privacyTransitionInProgress
}

/// Ends a library's binding to one sync account without touching a single note, attachment or
/// tag, and without touching `sync_dirty` (the journal of local edits stays, so a later first
/// sync still publishes everything). Only engine bookkeeping is cleared; the Keychain and the
/// cloud are not touched. It only reads and writes tables: no existing function changes.
public enum SyncAccountDetach {
    /// Cloudflare queue state, children before parents (`sync_attachment_cache` references `sync_blob_state`).
    /// `sync_conflict` stays: it is not queue state but the "conflict copy of" link of a note, part of the note's synced content
    /// that the iCloud engine publishes too.
    static let cloudflareClearedTables = [
        "sync_attachment_cache", "sync_blob_state", "sync_outbox", "sync_shadow", "sync_inbox",
        "sync_receipt", "sync_entity_state", "sync_device",
    ]
    /// Every `ck_*` table except `ck_state`, which is reset in place (its generation only grows).
    static let cloudKitClearedTables = [
        "ck_record", "ck_inflight", "ck_send_result", "ck_remote", "ck_quarantine", "ck_missing", "ck_blob_part",
    ]
    /// The tables CloudKit shares with the Cloudflare engine. Their rows are keyed by ids
    /// derived from the old account's key, so they cannot outlive the binding either.
    static let sharedTables = ["sync_attachment_cache", "sync_blob_state", "sync_entity_state"]

    public struct Result: Sendable, Equatable {
        /// Pinned quarantine files that no row names any more; the caller deletes them after the commit.
        public var pinnedFilesToRemove: [String]
    }

    @discardableResult
    public static func detach(database: AppDatabase, expectedBackend: SyncBackend, verifiedBackupID: String) throws -> Result {
        try database.pool.write { try detach($0, expectedBackend: expectedBackend, verifiedBackupID: verifiedBackupID) }
    }

    /// The same inside the caller's write transaction.
    static func detach(_ db: Database, expectedBackend: SyncBackend, verifiedBackupID: String) throws -> Result {
        guard expectedBackend != .none else { throw SyncAccountDetachError.nothingToDetach }
        guard !verifiedBackupID.isEmpty,
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM backup_catalog WHERE id=?)", arguments: [verifiedBackupID]) == true
        else { throw SyncAccountDetachError.backupNotVerified }
        let actual = try CloudSyncStore.backend(db)
        guard actual == expectedBackend else { throw SyncAccountDetachError.backendMismatch(expected: expectedBackend, actual: actual) }
        if try Bool.fetchOne(db, sql: "SELECT applying FROM sync_control WHERE id=1") == true { throw SyncAccountDetachError.applying }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition)") == true {
            throw SyncAccountDetachError.privacyTransitionInProgress
        }
        var pinned: [String] = []
        switch expectedBackend {
        case .cloudflare:
            for table in cloudflareClearedTables { try db.execute(sql: "DELETE FROM \(table)") }
            try db.execute(sql: "UPDATE sync_cursor SET sequence=0 WHERE id=1")
        case .cloudkit:
            for row in try Row.fetchAll(db, sql: "SELECT pinnedAssets FROM ck_quarantine") {
                pinned += CloudSyncStore.decodeAssets(row["pinnedAssets"]).map(\.path)
            }
            pinned += try String.fetchAll(db, sql: "SELECT sealedPath FROM ck_remote WHERE sealedPath IS NOT NULL")
            for table in sharedTables { try db.execute(sql: "DELETE FROM \(table)") }
            for table in cloudKitClearedTables { try db.execute(sql: "DELETE FROM \(table)") }
            try db.execute(sql: """
                UPDATE ck_state SET containerId=NULL, zoneName=NULL, accountId=NULL, cloudUserHash=NULL,
                  generation=generation+1, zoneState='unknown', zoneRemovedReason=NULL, fenced=0, engineState=NULL,
                  bundleRevision=0, recoveryState='none', fetchEpoch=0,
                  switchedOn=0, deletedStarters=NULL, keyBundleCache=NULL WHERE id=1
                """)
        case .none: break
        }
        try db.execute(sql: "UPDATE sync_control SET enabled=0, accountId=NULL, backend='none' WHERE id=1")
        return Result(pinnedFilesToRemove: pinned)
    }
}

/// Why "Move This Library to iCloud" refuses. Every refusal leaves the library bound to the private server, as it was.
public enum PrivateServerMoveRefusal: Error, Equatable, Sendable {
    case notBoundToPrivateServer
    /// The app has no working connection to the server (signed out, waiting for approval or recovery words): no final sync.
    case notConnected
    /// The owner paused sync with the server: no final sync.
    case syncPaused
    /// The library's first sync with the server never finished (uploads were never switched on).
    case firstSyncNotFinished
    /// Attachments waiting to be sent whose file is on this device in no form: they can never be sent. `notes` holds the titles of
    /// up to five notes they belong to, `moreNotes` how many other notes are affected. Retrying does not help.
    /// `canMoveWithout`: every such row was never received by the server and waits for no download, and nothing else stops the
    /// move, so "Move Without These Files" may leave them behind.
    case unavailableAttachments(notes: [String], moreNotes: Int, canMoveWithout: Bool)
    /// Local changes the server has not confirmed (dirty journal and outbox), the unavailable attachments not counted.
    case unsentChanges(Int)
    /// Changes received from the server and not yet applied (waiting for a file, the note password or a dependency).
    case unreceivedChanges(Int)
    /// A received change is being applied right now.
    case syncRunning
    case lockOrUnlockInProgress
    case attachmentBeingSaved
}

/// "Move This Library to iCloud": leave the private server so that the iCloud switch can take the library.
/// The order is fixed: one final sync (the caller's), the check that nothing is left in either direction, a verified backup, then in
/// ONE write transaction the check again, the detach and the mark that stops the private-server engine from binding this library
/// again. A failure before the transaction changes nothing; the transaction is all or nothing. The server's copy is not touched.
public enum PrivateServerMove {
    /// Device-local setting (not in the synced allowlist): when this library left the private server.
    static let movedKey = "privateServerMovedToICloud"

    /// The whole operation. `finalSync` runs one complete sync with the server and throws when it cannot (offline, signed out,
    /// paused); `makeBackup` returns the id of a verified backup.
    @discardableResult
    /// `withoutMissingFiles`: the owner chose "Move Without These Files"; attachments that qualify no longer stop the move.
    public static func run(database: AppDatabase, paths: AppPaths, finalSync: @Sendable () async throws -> Void, makeBackup: @Sendable () async throws -> String,
                           withoutMissingFiles: Bool = false, crash: CrashPoint = .never, now: Date = Date()) async throws -> SyncAccountDetach.Result {
        guard try CloudSyncStore(database: database).backend() == .cloudflare else { throw PrivateServerMoveRefusal.notBoundToPrivateServer }
        try await finalSync()
        try crash.hit("move.afterFinalSync")
        if let refusal = try refusals(in: database, paths: paths, withoutMissingFiles: withoutMissingFiles).first { throw refusal }
        let backup = try await makeBackup()
        guard !backup.isEmpty else { throw SyncAccountDetachError.backupNotVerified }
        try crash.hit("move.afterBackup")
        return try leave(database: database, verifiedBackupID: backup, now: now)
    }

    /// Every reason the library cannot move right now, most specific first; empty when it can. Read after the final sync. It only
    /// reads, so it is also the preflight a rehearsal runs on a copy of a library.
    public static func refusals(in database: AppDatabase, paths: AppPaths, withoutMissingFiles: Bool = false) throws -> [PrivateServerMoveRefusal] {
        try database.pool.read { try refusals($0, paths: paths, includingLocalEdits: true, withoutMissingFiles: withoutMissingFiles) }
    }

    /// The missing-file attachments that "Move Without These Files" may leave behind: the file is on this device in no form (the
    /// unavailable rows), the app never saw its bytes (no size, no hash recorded: an import that brought only the reference), the
    /// row is a change, not a deletion, the server never received this attachment (no server revision, no server copy) and no
    /// download for it waits. Such an attachment exists on no device and on no server. The caller also requires that the
    /// `Attachments` folder can be opened: an unreadable folder makes every file look missing.
    static func leavable(_ db: Database, attachmentID id: String) throws -> Bool {
        let entityIDs = [id] + (try String.fetchAll(db, sql: "SELECT entityId FROM sync_entity_state WHERE entityType='attachment' AND localId=?", arguments: [id]))
        let marks = entityIDs.map { _ in "?" }.joined(separator: ",")
        return try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM sync_entity_state WHERE entityType='attachment' AND localId=? AND serverRevision>0)
              AND NOT EXISTS(SELECT 1 FROM sync_shadow WHERE entityType='attachment' AND entityId IN (\(marks)))
              AND NOT EXISTS(SELECT 1 FROM sync_inbox WHERE entityType='attachment' AND entityId IN (\(marks)))
              AND EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=0)
              AND EXISTS(SELECT 1 FROM attachment WHERE id=? AND byteSize IS NULL AND sha256 IS NULL)
            """, arguments: StatementArguments([id] + entityIDs + entityIDs + [id, id])) ?? false
    }

    /// `includingLocalEdits: false` is the re-check inside the detach: an edit typed after the final sync is a dirty row that stays
    /// and goes to iCloud with the first sync there, like any edit made after the move.
    static func refusals(_ db: Database, paths: AppPaths?, includingLocalEdits: Bool, withoutMissingFiles: Bool = false) throws -> [PrivateServerMoveRefusal] {
        guard try CloudSyncStore.backend(db) == .cloudflare else { return [.notBoundToPrivateServer] }
        func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
        var found: [PrivateServerMoveRefusal] = []
        let control = try Row.fetchOne(db, sql: "SELECT enabled, applying FROM sync_control WHERE id=1")
        if control?["enabled"] as Bool? != true { found.append(.firstSyncNotFinished) }
        if control?["applying"] as Bool? == true { found.append(.syncRunning) }
        var missing: [(id: String, noteId: String)] = []
        if includingLocalEdits, let paths { missing = try SyncQueue.unavailableAttachments(paths: paths, in: db) }
        let folderOpens = paths.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.attachments.path)) != nil } ?? false
        let allLeavable = try folderOpens && missing.allSatisfy { try leavable(db, attachmentID: $0.id) }
        var missingRefusal: PrivateServerMoveRefusal?
        if !missing.isEmpty, !(withoutMissingFiles && allLeavable) {
            var seen = Set<String>()
            let ids = missing.map(\.noteId).filter { seen.insert($0).inserted }
            let titles = try ids.prefix(5).map { id in
                let title = try String.fetchOne(db, sql: "SELECT title FROM note WHERE id=?", arguments: [id]) ?? ""
                return title.isEmpty ? "Untitled" : title
            }
            missingRefusal = .unavailableAttachments(notes: titles, moreNotes: max(0, ids.count - 5), canMoveWithout: allLeavable)
        }
        let unsent = try count("sync_outbox") + (includingLocalEdits ? count("sync_dirty") - missing.count : 0)
        if unsent > 0 { found.append(.unsentChanges(unsent)) }
        let unreceived = try count("sync_inbox")
        if unreceived > 0 { found.append(.unreceivedChanges(unreceived)) }
        if try count("privacy_transition") > 0 { found.append(.lockOrUnlockInProgress) }
        if try count("staging_batch") > 0 { found.append(.attachmentBeingSaved) }
        // Missing files that may be left behind come last, so the person first sees what else stops the move; once that is gone,
        // the missing-files refusal with its second button is first. Missing files that may not be left behind come first.
        if case .unavailableAttachments(let notes, let more, let leavable)? = missingRefusal {
            if leavable { found.append(.unavailableAttachments(notes: notes, moreNotes: more, canMoveWithout: found.isEmpty)) }
            else { found.insert(.unavailableAttachments(notes: notes, moreNotes: more, canMoveWithout: false), at: 0) }
        }
        return found
    }

    /// The final sync's summary must say the sync finished: a run that needs the note password again did not.
    public static func requireFinished(_ summary: SyncRunSummary) throws {
        if summary.passwordRefreshRequired { throw NotePrivacyError.accessRevoked }
    }

    /// The last step on its own: re-check, detach and mark, in one transaction.
    @discardableResult
    public static func leave(database: AppDatabase, verifiedBackupID: String, now: Date = Date()) throws -> SyncAccountDetach.Result {
        try database.pool.write { db in
            if let refusal = try refusals(db, paths: nil, includingLocalEdits: false).first { throw refusal }
            let result = try SyncAccountDetach.detach(db, expectedBackend: .cloudflare, verifiedBackupID: verifiedBackupID)
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           arguments: [movedKey, ISO8601DateFormatter().string(from: now)])
            return result
        }
    }

    /// This library moved from the private server to iCloud: the private-server engine must never bind it again.
    public static func hasLeft(_ database: AppDatabase) throws -> Bool {
        try database.pool.read { try hasLeft($0) }
    }

    /// Device-local: the owner dismissed the "move your other devices now" notice.
    static let noticeDismissedKey = "privateServerMoveNoticeDismissed"

    /// After a move the sync settings keep telling the owner to move the other devices, until the owner dismisses it.
    public static func showsOtherDevicesNotice(_ database: AppDatabase) throws -> Bool {
        try database.pool.read { db in
            try hasLeft(db) && Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM setting WHERE key=?)", arguments: [noticeDismissedKey]) == false
        }
    }

    public static func dismissOtherDevicesNotice(_ database: AppDatabase) throws {
        try database.pool.write {
            try $0.execute(sql: "INSERT INTO setting(key,value) VALUES(?, 'true') ON CONFLICT(key) DO NOTHING", arguments: [noticeDismissedKey])
        }
    }

    static func hasLeft(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM setting WHERE key=?)", arguments: [movedKey]) ?? false
    }
}
