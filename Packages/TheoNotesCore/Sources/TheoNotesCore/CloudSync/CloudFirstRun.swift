// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// The first-run steps that touch the library (Task 10, CK-R130, CK-R131): switching uploads on for a CloudKit-bound library and
// clearing the dirty markers that switch created for content the cloud already holds.
//
// `SyncQueue.enable` refuses a CloudKit library on purpose (CK-R12), so the CloudKit binding path has its own counterpart.
// The shape of the Cloudflare original is kept (every semantic row of the six synced tables is marked dirty, so a first
// sync publishes everything this library has), with one change that makes the follow-up cleanup provable:
//
//   Rows created by `enableUploads` carry dirty generation 0. Every trigger that writes `sync_dirty` starts at 1 or
//   counts up from the current value, so a row at generation 0 can only have been created by the enable step and has not
//   been touched by anything since: not by a person's edit, an import, an apply or a stage. The cleanup removes only such
//   rows, and only when their content is what the cloud already holds, all in one write transaction. A marker that a
//   person's edit raised to 1 or more is never touched, whatever the content looks like now (an edit that restores the
//   old text is still an edit; it costs one harmless re-save).

public enum CloudFirstRun {
    /// Starter ids with edits not in the library (`AppPaths.hasPendingJournal`: a non-empty journal or one set aside for recovery). The
    /// first-bind guard leaves them, and so the whole device, alone (STARTER-R11, R15). A folder that cannot be read counts as pending.
    static func startersWithPendingJournal(in paths: AppPaths) -> Set<String> {
        Set(GettingStartedNotes.ids.filter { (try? paths.hasPendingJournal(noteId: $0)) ?? true })
    }

    /// The CloudKit counterpart of `SyncQueue.canEnableAfterInitialDownload`: every fetched version was applied, none waits for
    /// a password, none waits for an attachment that has not arrived. An entity fenced by an unreadable record cannot be
    /// applied by definition and does not hold the library back (that item says so in its own state).
    public static func canEnable(store: CloudSyncStore) throws -> Bool {
        try store.database.pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS(SELECT 1 FROM ck_remote r WHERE NOT EXISTS(
                    SELECT 1 FROM ck_quarantine q WHERE q.entityType=r.entityType AND q.entityId=r.entityId AND q.ignoredByUser=0))
                """) ?? false
        }
    }

    /// True while a note's password is needed before the first sync (the library has protected notes): the
    /// Cloudflare flow asks for it before anything is bound or uploaded.
    public static func requiresNotePassword(library: any CloudSyncLibrary, enabled: Bool) throws -> Bool {
        guard !enabled else { return false }
        return try library.hasNotePassword
    }
}

public struct CloudEnableCleanup: Sendable, Equatable {
    /// Markers removed: unedited since the enable step and identical to what the cloud holds.
    public var cleared = 0
    /// Markers kept: never published, or different from the cloud, or the entity is fenced, paused or has work in flight.
    public var kept = 0
    public init() {}
}

extension CloudSyncStore {
    /// The dirty generation of a row that only the enable step has written (see the header of this file).
    public static let enableGeneration: Int64 = 0

    public func isUploadEnabled() throws -> Bool {
        try database.pool.read { try Bool.fetchOne($0, sql: "SELECT enabled FROM sync_control WHERE id=1") == true }
    }

    /// Switches uploads on for this library and marks every semantic row dirty at `enableGeneration`, in one transaction. A row
    /// that is already dirty (a person's edit or an apply since the library was bound) keeps its own, higher generation.
    /// Repeating it is a no-op once enabled. Returns how many markers it created.
    /// `keeping`: starter ids the first-bind guard must leave alone (an edit journal with text not yet committed, STARTER-R11).
    @discardableResult
    public func enableUploads(keeping: Set<String> = []) throws -> Int {
        try database.pool.write { db in
            let backend = try Self.backend(db)
            guard backend == .cloudkit else { throw CloudSyncStoreError.backendConflict(backend) }
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") != nil else { throw CloudSyncStoreError.accountMismatch }
            if try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true { return 0 }
            // In the same transaction, so a stop between the two can never leave the starters dropped and the uploads still off (STARTER-R4).
            try Self.dropUnpublishedStarters(in: db, keeping: keeping)
            try db.execute(sql: "UPDATE sync_control SET enabled=1 WHERE id=1")
            var created = 0
            for (table, type, key, condition) in [
                ("note", "note", "id", "1"), ("attachment", "attachment", "id", "1"),
                ("tag", "tagPreference", "id", "1"),
                ("setting", "setting", "key", "key IN ('hideMarkdown','showNoteCounts','autoSortTodos','showHeadingLevels','autocomplete','startNoteTemplate','tagPosition','noteSort')"),
                ("external_ref", "externalRef", "json_array(source,externalId)", "1"),
                ("crypto_envelope", "keyBundle", "'lock-vault'", "1"),
            ] {
                try db.execute(sql: """
                    INSERT INTO sync_dirty(entityType,localId,generation,tombstone)
                    SELECT ?,\(key),\(Self.enableGeneration),0 FROM \(table) WHERE \(condition)
                    ON CONFLICT(entityType,localId) DO NOTHING
                    """, arguments: [type])
                created += db.changesCount
            }
            return created
        }
    }

    /// The first-bind guard (STARTER-R4). A library that made its own Getting Started notes (a fresh iPhone) must not publish twelve of
    /// them into a cloud library that has notes but never had them. Runs inside `enableUploads`, after the download-first cycles, and
    /// removes a starter note only when ALL of these hold:
    ///  - its id is one of the fixed starter ids, AND
    ///  - this device holds no record pair, remote version, snapshot in flight, missing mark or quarantine for it (the cloud never
    ///    had it), AND
    ///  - its content is exactly that of a shipped version (never edited, moved, locked or tagged by the person), AND
    ///  - no privacy transition or staged attachment is open for it, AND
    ///  - no upload is pending for it from a write after binding (`sync_dirty` generation 1 or higher; seeding never makes one), AND
    ///  - the cloud holds at least one note record (a first device, with an empty cloud, publishes its starters), AND
    ///  - the device is fresh: EVERY local note the cloud does not know is such an untouched starter. One unpublished note of the
    ///    person's own (a long-standing library joining sync, a note written before switching sync on, an edited or trashed starter)
    ///    and the guard removes nothing; the starters upload as they always did (STARTER-R10).
    /// The write runs with `applying` set, as the applier's own writes do, so no tombstone and no dirty marker is made; the product's own
    /// delete removes the row and the tags only it used. `gettingStartedSeeded` stays set: nothing makes them again, Restore does.
    /// The removed ids are remembered in the device-local setting `droppedStartersKey` (it survives sync off/on and an account change),
    /// so `recordDeletedStarters` never takes them for notes the person deleted (STARTER-R8).
    @discardableResult
    static func dropUnpublishedStarters(in db: Database, keeping: Set<String> = []) throws -> [String] {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM ck_record WHERE entityType='note')") == true else { return [] }
        var drop: [String] = []
        for id in GettingStartedNotes.ids where !keeping.contains(id) {
            let known = try ["ck_record", "ck_remote", "ck_inflight", "ck_missing", "ck_quarantine"].contains {
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \($0) WHERE entityType='note' AND entityId=?)", arguments: [id]) == true
            }
            guard !known else { continue }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)",
                                    arguments: [id, id]) == false else { continue }
            // A pending upload from a write after binding (a Restore while sync was off) is the person's action, not the seed (STARTER-R9).
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND generation>=1)",
                                    arguments: [id]) == false else { continue }
            guard try CloudStarterBase.holdsShippedContent(id, in: db) else { continue }
            drop.append(id)
        }
        let unknownToCloud = try String.fetchAll(db, sql: """
            SELECT id FROM note n WHERE NOT EXISTS(SELECT 1 FROM ck_record WHERE entityType='note' AND entityId=n.id)
              AND NOT EXISTS(SELECT 1 FROM ck_remote WHERE entityType='note' AND entityId=n.id)
              AND NOT EXISTS(SELECT 1 FROM ck_inflight WHERE entityType='note' AND entityId=n.id)
              AND NOT EXISTS(SELECT 1 FROM ck_missing WHERE entityType='note' AND entityId=n.id)
              AND NOT EXISTS(SELECT 1 FROM ck_quarantine WHERE entityType='note' AND entityId=n.id)
            """)
        guard !drop.isEmpty, Set(unknownToCloud) == Set(drop) else { return [] }
        try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
        try NoteStore.delete(drop, in: db)
        for id in drop { try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [id]) }
        try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
        let remembered = Set(Self.decode(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [Self.droppedStartersKey])))
        try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [Self.droppedStartersKey, Self.json(remembered.union(drop).sorted())])
        return drop
    }

    /// Device-local (not in the synced setting allowlist): the starter ids the first-bind guard removed, as opposed to ids the person deleted.
    static let droppedStartersKey = "gettingStartedDroppedBySync"

    /// Switches uploads off. The library stays bound; capture and the dirty journal go on.
    public func disableUploads() throws {
        try database.pool.write { try $0.execute(sql: "UPDATE sync_control SET enabled=0 WHERE id=1") }
    }

    /// Markers only the enable step has written and nothing has touched since.
    public func enableMarkerCount() throws -> Int {
        try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_dirty WHERE generation=?", arguments: [Self.enableGeneration]) ?? 0 }
    }

    /// Removes the dirty markers of the enable step whose entity the cloud already holds with this very content, so a second
    /// device does not publish everything it just downloaded (E0 review point 1).
    ///
    /// ONE write transaction does all of it: the generation of a row, its content and the base pair are read and the row is
    /// deleted `WHERE generation = 0` under the same writer lock, so a person's edit cannot fall between the check and the
    /// delete (the edit either committed before, and raised the generation, or commits after the delete and creates a
    /// new marker). Kept without a decision about content: no base pair (never published), a snapshot in flight, a fetched
    /// version waiting, a pause or a quarantine fence. Equality is `SyncNoteMerge.identical` for notes (the merge's own rule) and
    /// the canonical payload for the rest. Nothing else is ever deleted. Safe to run any number of times, and after a crash
    /// between `enableUploads` and this call (the markers are durable).
    @discardableResult
    public func cleanUpEnableMarkers(accountID: String, vaultKey: SymmetricKey,
                                     boundary: @Sendable (String) throws -> Void = { _ in }) throws -> CloudEnableCleanup {
        let sealer = CloudPayloadSealer(accountID: accountID, vaultKey: vaultKey)
        let reader = CloudRemoteReader(sealer: sealer)
        try boundary("cleanup.beforeTransaction")
        return try database.pool.write { db in
            var result = CloudEnableCleanup()
            let rows = try Row.fetchAll(db, sql: """
                SELECT entityType, localId FROM sync_dirty WHERE generation=? AND tombstone=0 ORDER BY entityType, localId
                """, arguments: [Self.enableGeneration])
            for row in rows {
                guard let type = SyncEntityType(rawValue: row["entityType"]) else { result.kept += 1; continue }
                let localID: String = row["localId"]
                let dirty = SyncDirty(type: type, localID: localID, generation: Self.enableGeneration, tombstone: false)
                let entityID = try CloudPayloadSealer.entityID(for: dirty, vaultKey: vaultKey, in: db)
                let entity = CloudEntityRef(entityType: type.rawValue, entityId: entityID)
                guard let pair = try Self.pair(db, entity),
                      try !Self.isFenced(db, entity), try !Self.isPaused(db, entity), try !Self.hasPendingRemote(db, entity),
                      try Self.fetchInflight(db, sql: "WHERE entityType=? AND entityId=?", [entity.entityType, entity.entityId]).isEmpty
                else { result.kept += 1; continue }
                guard let held = try? reader.read(sealed: pair.ancestor, type: type, entityId: entityID, blobRefs: nil),
                      try Self.matchesLibrary(held, type: type, dirty: dirty, accountID: accountID, vaultKey: vaultKey,
                                              sealer: sealer, reader: reader, entityID: entityID, in: db)
                else { result.kept += 1; continue }
                try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType=? AND localId=? AND generation=?",
                               arguments: [type.rawValue, localID, Self.enableGeneration])
                if db.changesCount > 0 { result.cleared += 1 } else { result.kept += 1 }
            }
            return result
        }
    }

    /// The library's current content of `dirty` is what `held` says.
    private static func matchesLibrary(_ held: SyncRemoteValue, type: SyncEntityType, dirty: SyncDirty, accountID: String, vaultKey: SymmetricKey,
                                       sealer: CloudPayloadSealer, reader: CloudRemoteReader, entityID: String, in db: Database) throws -> Bool {
        // The cloud's last word is a deletion and this library still holds the entity: the preserved last copy a remote
        // tombstone leaves in the Trash (E0 section 5.3). It is deliberately not echoed; only a person's later edit
        // (a Restore, an edit) publishes it again, and that edit raises the generation above the enable marker.
        if case .deleted = held { return type == .note || type == .attachment }
        if type == .attachment { return try attachmentMatches(held, localID: dirty.localID, in: db) }
        let content: SyncContent
        do { content = try CloudPayloadSealer.capture(dirty, accountID: accountID, vaultKey: vaultKey, in: db) }
        catch SyncQueueError.snapshotUnavailable { return false }
        guard let payload = content.payload,
              let local = try? reader.read(sealed: sealer.sealLive(payload, type: type, entityID: entityID), type: type, entityId: entityID, blobRefs: nil)
        else { return false }
        if case .note(let mine) = local, case .note(let theirs) = held { return SyncNoteMerge.identical(mine, theirs) }
        return local.sameContent(as: held)
    }

    /// An attachment's snapshot needs the prepared ciphertext cache, which a clean second device does not have. The row itself
    /// says whether it is the cloud's file: same note, name and, for an open file, the description and the content hash.
    private static func attachmentMatches(_ held: SyncRemoteValue, localID: String, in db: Database) throws -> Bool {
        guard case .attachment(let payload) = held,
              let row = try Row.fetchOne(db, sql: """
                SELECT a.noteId, a.filename, a.uti, a.width, a.height, a.ocrText, a.byteSize, a.sha256, a.deletedAt, n.isLocked
                FROM attachment a JOIN note n ON n.id=a.noteId WHERE a.id=?
                """, arguments: [localID]),
              (row["deletedAt"] as Date?) == nil
        else { return false }
        guard (row["noteId"] as String) == payload.noteId, (row["filename"] as String) == payload.filename,
              (row["isLocked"] as Bool) == payload.isLocked else { return false }
        if payload.isLocked { return true }
        guard (row["uti"] as String?) == payload.uti, (row["width"] as Int?) == payload.width, (row["height"] as Int?) == payload.height,
              (row["ocrText"] as String?) == payload.ocrText else { return false }
        guard let size: Int64 = row["byteSize"], size == payload.fileBytes, let hash: String = row["sha256"], hash == payload.fileHash else { return false }
        return true
    }
}

// MARK: the person's switch and the starter notes deleted before binding (CK-R132, CK-R134)

extension CloudSyncStore {
    /// The person switched sync on and has not switched it off. Survives a restart, so a first sync that is blocked (a password,
    /// the keychain, the account, a dependency) is taken up again without a second `enable()`.
    public func isSwitchedOn() throws -> Bool {
        try database.pool.read { try Bool.fetchOne($0, sql: "SELECT switchedOn FROM ck_state WHERE id=1") == true }
    }

    public func setSwitchedOn(_ on: Bool) throws {
        try database.pool.write { try $0.execute(sql: "UPDATE ck_state SET switchedOn=? WHERE id=1", arguments: [on]) }
    }

    /// Fixed-id Getting Started notes this library was given and no longer has: deleted before it ever met the cloud, so no
    /// tombstone exists for them. Recomputed before the first download (a restored note leaves the list) and then kept: another
    /// device may upload its untouched copy at any later time, and it is only consulted for an entity this device holds no pair for.
    public func recordDeletedStarters() throws {
        try database.pool.write { db in
            let seeded = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key='gettingStartedSeeded'") == "true"
            var missing: [String] = []
            if seeded {
                let present = Set(try String.fetchAll(db, sql: "SELECT id FROM note"))
                // A starter the first-bind guard removed was not deleted by the person (STARTER-R8).
                let dropped = Set(Self.decode(try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key=?", arguments: [Self.droppedStartersKey])))
                missing = GettingStartedNotes.ids.filter { !present.contains($0) && !dropped.contains($0) }
            }
            try db.execute(sql: "UPDATE ck_state SET deletedStarters=? WHERE id=1", arguments: [missing.isEmpty ? nil : Self.json(missing)])
        }
    }

    public func deletedStarters() throws -> Set<String> {
        try database.pool.read { db in
            Set(Self.decode(try String.fetchOne(db, sql: "SELECT deletedStarters FROM ck_state WHERE id=1")))
        }
    }
}
