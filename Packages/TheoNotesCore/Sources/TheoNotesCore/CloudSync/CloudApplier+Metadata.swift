// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// Copies (class c) of `applyMetadata`, `authorizePasswordEnvelope`, `requireUnpublishedProtectedLibrary` and `reconcileImport`.
extension CloudApplier {
    struct PasswordAuthorization: Sendable {
        let localEnvelope: Data
        let conversionKeys: (SymmetricKey, SymmetricKey)?
    }

    // MARK: tags, settings, external references, the password envelope

    func applyMetadata(_ input: CloudApplyInput, authorized: PasswordAuthorization?, commit: @escaping CloudApplyCommit) throws -> CloudApplyOutcome {
        let type = input.version.entityType
        let value = input.value
        let files = AttachmentFiles(paths: paths, database: database)
        let scratch = CloudApplyScratch()
        defer { if !scratch.committed { for batch in scratch.staged { files.discard(batch) } } }
        let converted = CloudApplyScratch()
        do {
            try commit { db in
                try input.precondition(db)
                try requireAccount(db)
                var mapped = try String.fetchOne(db, sql: "SELECT localId FROM sync_entity_state WHERE entityType=? AND entityId=?",
                                                 arguments: [type.rawValue, input.version.entityId])
                // A tag preference is identified by its path: the entity id is derived from it. When the tag row was recreated under
                // a new local id (it left every note and came back), the id map still names the old row and the original would
                // report an identity collision for ever. The map follows the current row instead (a change against the original).
                if case .tag(let tag) = value, let stale = mapped,
                   let current = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE pathKey=?", arguments: [CanonicalKey.make(tag.path)]), current != stale {
                    try db.execute(sql: "DELETE FROM sync_entity_state WHERE entityType=? AND entityId=? AND localId<>?",
                                   arguments: [type.rawValue, input.version.entityId, current])
                    try db.execute(sql: "INSERT OR IGNORE INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES(?,?,?,0)",
                                   arguments: [type.rawValue, current, input.version.entityId])
                    mapped = current
                }
                let localID = try SyncMaterializer.localID(value, mapped: mapped, in: db) ?? (type == .keyBundle ? "lock-vault" : nil)
                let dirty = try localID.map { try Self.isDirty(type.rawValue, $0, in: db) } ?? false
                let hasLockedNotes = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true
                let preservingPasswordEnvelope = type == .keyBundle && value.isDeleted && hasLockedNotes
                var adoptingPasswordChange = false
                if case .lockEnvelope(let remote) = value,
                   let local = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"), local != remote, hasLockedNotes {
                    guard authorized?.localEnvelope == local, let noteAccess = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                    _ = try noteAccess.journalKey()
                    adoptingPasswordChange = true
                }
                var reconcileReference = false
                if case .externalRef(let ref) = value, let id = ref.noteId {
                    guard try Note.fetchOne(db, key: id) != nil else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                    if let existing = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?", arguments: [ref.source, ref.externalId]), existing != id {
                        reconcileReference = true
                    }
                }
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                // Pending local preferences win and are rebased onto the received version. Their dirty generation is retained; a
                // later publish on the new pair makes that resolution portable.
                if preservingPasswordEnvelope {
                    // Removing the password on a device with no protected notes cannot erase the key envelope another device's
                    // offline protected notes still need.
                    guard try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") != nil else { throw NotePrivacyError.passwordNotSet }
                    try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0")
                } else if input.independent, !reconcileReference, [.setting, .tagPreference, .externalRef].contains(type), let localID,
                          try Self.localMetadataDiffers(from: value, type: type, localID: localID, in: db) {
                    // An independent incarnation: metadata has no conflict copies, so the local value stays and goes out
                    // again on the new incarnation. Losing a remote change made during a recovery race is the accepted cost.
                    try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES(?,?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0",
                                   arguments: [type.rawValue, localID])
                } else if reconcileReference, case .externalRef(let ref) = value, let localID {
                    let resolved = try reconcileImport(ref, identity: input.mergeIdentity, isUnpublished: input.isUnpublishedNote, in: db)
                    try SyncMaterializer.writeMetadata(.externalRef(resolved), type: type, localID: localID, in: db)
                    if resolved == ref {
                        try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='externalRef' AND localId=?", arguments: [localID])
                    } else {
                        try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0", arguments: [localID])
                    }
                } else if adoptingPasswordChange {
                    if let (from, to) = authorized?.conversionKeys {
                        try input.requireUnpublishedProtectedLibrary(db)
                        try materializer.stageInitialVaultConversion(from: from, to: to, files: files, staged: &scratch.staged, in: db)
                        _ = try input.noteAccess?.journalKey()
                        converted.committed = true
                    }
                    try SyncMaterializer.writeMetadata(value, type: type, localID: localID, in: db)
                    try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='keyBundle' AND localId=?", arguments: [localID])
                } else if !dirty { try SyncMaterializer.writeMetadata(value, type: type, localID: localID, in: db) }
                if let localID { try Self.markEntity(type: type, localID: localID, entityID: input.version.entityId, in: db) }
                try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            }
        } catch let wait as CloudApplyWait {
            return wait.outcome
        }
        scratch.committed = true
        for batch in scratch.staged { files.install(batch) }
        let pending = try database.pool.read { db in
            try scratch.staged.contains { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE id=?)", arguments: [$0.batchID]) == true }
        }
        guard !pending else { throw BackupError.restoreFilesPending }
        try SyncMaterializer.recoverImportCleanup(database: database, paths: paths)
        return converted.committed ? .passwordChanged : .applied(consumed: [])
    }

    // MARK: the guard before a password change or vault conversion

    /// PBKDF2 and key verification happen outside the SQLite writer; the exact local envelope is checked again at commit.
    /// The guard of the original reads the Cloudflare engine's outbox and shadow tables, both always empty in a library synced
    /// another way, so it would pass vacuously; the caller supplies the guard that asks its own state (`requireUnpublished`).
    func authorizePasswordEnvelope(_ value: SyncRemoteValue, access: LockedNoteAccess?, password: String?,
                                   requireUnpublished: @Sendable (Database) throws -> Void) async throws -> PasswordAuthorization? {
        guard case .lockEnvelope(let remote) = value, let access, let password else { return nil }
        let local = try await database.pool.read { db -> Data? in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true else { return nil }
            return try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1")
        }
        guard let local, local != remote else { return nil }
        let key = try access.journalKey()
        let remoteKey = try JSONDecoder().decode(CryptoEnvelope.self, from: remote).unwrap(password: password)
        let different = key.withUnsafeBytes({ Data($0) }) != remoteKey.withUnsafeBytes({ Data($0) })
        if different {
            try await database.pool.read { try requireUnpublished($0) }
        }
        // Access from an unrelated library must not authorize replacement of this vault.
        let proof = try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).restoreAccess(
            vaultKey: key, matching: JSONDecoder().decode(CryptoEnvelope.self, from: local))
        proof.revoke()
        _ = try access.journalKey()
        if different { _ = try LibraryBackup(database: database, paths: paths).createRolling() }
        return PasswordAuthorization(localEnvelope: local, conversionKeys: different ? (key, remoteKey) : nil)
    }

    /// True when this library holds a local value of the entity that differs from the remote value (a remote deletion differs from
    /// any local value). False when there is no local value: the remote one is simply taken.
    static func localMetadataDiffers(from value: SyncRemoteValue, type: SyncEntityType, localID: String, in db: Database) throws -> Bool {
        let content = try SyncPayloadCodec.capture(SyncDirty(type: type, localID: localID, generation: 1, tombstone: false), in: db)
        guard let bytes = content.payload else { return false }
        switch value {
        case .setting(let remote): return try SyncPayloadCodec.decode(SyncSettingPayload.self, from: bytes) != remote
        case .tag(let remote): return try SyncPayloadCodec.decode(SyncTagPreferencePayload.self, from: bytes) != remote
        case .externalRef(let remote): return try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: bytes) != remote
        case .deleted: return true
        default: return false
        }
    }

    // MARK: external references

    /// The source identity, not a coincidentally equal title, establishes that two independently imported notes are related.
    /// Only an unpublished exact duplicate may be collapsed ("unpublished" is the caller's `isUnpublishedNote`, not the outbox).
    func reconcileImport(_ remote: SyncExternalRefPayload, identity: (mutationID: String, revision: Int64), isUnpublished: @Sendable (Database, String) throws -> Bool,
                         in db: Database) throws -> SyncExternalRefPayload {
        guard let remoteID = remote.noteId,
              let localID = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?", arguments: [remote.source, remote.externalId]), localID != remoteID,
              var local = try SyncNotePayload.capture(id: localID, in: db),
              let received = try SyncNotePayload.capture(id: remoteID, in: db) else { return remote }
        let enabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true
        let pendingEdits = try paths.hasPendingJournal(noteId: localID)
        let unpublished = try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM sync_entity_state WHERE entityType='note' AND localId=?)
              AND NOT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?)
              AND NOT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)
            """, arguments: [localID, localID, localID]) == true && (try isUnpublished(db, localID))
        var comparable = local
        comparable.id = remoteID; comparable.attachmentIds = received.attachmentIds
        comparable.attachmentNames = received.attachmentNames
        comparable.attachmentSnapshots = received.attachmentSnapshots
        let equal = !local.isLocked && !received.isLocked && comparable == received &&
            TextNormalization.identical(comparable.text, received.text)
        if !enabled && unpublished && !pendingEdits && equal,
           try materializer.importedFilesMatch(localID, remoteID, in: db) {
            try db.execute(sql: """
                INSERT OR IGNORE INTO note_ui_state(noteId,foldState,selection,scrollTop)
                SELECT ?,foldState,selection,scrollTop FROM note_ui_state WHERE noteId=?
                """, arguments: [remoteID, localID])
            try db.execute(sql: "UPDATE external_ref SET noteId=?,importedRevision=NULL WHERE noteId=?", arguments: [remoteID, localID])
            // Old rolling backups still contain the original id. Mark the canonical identity too, so locking it later prunes
            // those earlier plaintext copies.
            for row in try Row.fetchAll(db, sql: "SELECT id,plaintextNoteIds FROM backup_catalog") {
                var ids = try JSONDecoder().decode([String].self, from: Data((row["plaintextNoteIds"] as String).utf8))
                if ids.contains(localID), !ids.contains(remoteID) {
                    ids.append(remoteID)
                    try db.execute(sql: "UPDATE backup_catalog SET plaintextNoteIds=? WHERE id=?",
                                   arguments: [String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self), row["id"] as String])
                }
            }
            try db.execute(sql: "DELETE FROM note WHERE id=?", arguments: [localID])
            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [localID])
            try db.execute(sql: "INSERT OR IGNORE INTO sync_import_cleanup(noteId) VALUES(?)", arguments: [localID])
            return remote
        }
        // No trusted ancestor, differing metadata or files, or already-published ids: preserve both notes. Active clients select
        // the same source owner deterministically to prevent ping-pong, while first sync adopts the established mapping.
        let canonical = enabled ? min(localID, remoteID) : remoteID
        local.conflict = SyncConflictInfo(originalNoteId: canonical == localID ? remoteID : canonical,
                                          rejectedMutationId: identity.mutationID, remoteRevision: identity.revision)
        try SyncMaterializer.recordConflict(local, in: db)
        try SyncMaterializer.markNote(localID, deleted: false, in: db)
        if canonical == remoteID { return remote }
        let localRef = try SyncPayloadCodec.capture(SyncDirty(type: .externalRef,
            localID: String.fetchOne(db, sql: "SELECT json_array(?,?)", arguments: [remote.source, remote.externalId])!,
            generation: 1, tombstone: false), in: db)
        guard let bytes = localRef.payload else { throw SyncProtocolError.invalidPayload }
        return try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: bytes)
    }
}

extension SyncRemoteValue {
    var isDeleted: Bool { if case .deleted = self { return true }; return false }
}
