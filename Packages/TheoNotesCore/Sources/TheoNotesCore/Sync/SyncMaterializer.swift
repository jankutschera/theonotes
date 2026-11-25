// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public enum SyncApplyResult: Equatable, Sendable {
    case applied, unchanged, waitingForUpload, waitingForDependencies, waitingForUnlock, passwordChanged
}

enum SyncApplyError: Error {
    case changedDuringDownload, identityCollision
    /// A remote lock reached a note whose voice capture still has text in the journal: the note waits.
    case waitingForCapture
}

/// Applies authenticated semantic records. Network reads happen before the writer; the
/// encrypted ancestor is compared again inside the transaction before any local change.
public struct SyncMaterializer: Sendable {
    let database: AppDatabase
    let paths: AppPaths
    let reader: SyncPayloadReader
    let coordinator: (any SyncCommitCoordinator)?

    public init(database: AppDatabase, paths: AppPaths, accountID: String,
                vaultKey: SymmetricKey, blobs: any SyncBlobTransport, coordinator: (any SyncCommitCoordinator)? = nil) {
        self.database = database; self.paths = paths; self.coordinator = coordinator
        reader = SyncPayloadReader(accountID: accountID, vaultKey: vaultKey, blobs: blobs)
    }

    /// A rejected ID may only be supplied for an explicit CAS rejection from the transport.
    /// Ordinary pulls leave immutable in-flight uploads alone until their outcome is known.
    public func apply(_ entity: SyncEntity, rejectedMutationID: String? = nil, noteAccess: LockedNoteAccess? = nil, remoteNotePassword: String? = nil) async throws -> SyncApplyResult {
        let wire = try JSONEncoder().encode(entity)
        _ = try JSONDecoder().decode(SyncEntity.self, from: wire)
        let ancestor = try await database.pool.read { try Self.shadow(entity, in: $0) }
        if let ancestor {
            let previous = try JSONDecoder().decode(SyncEntity.self, from: ancestor)
            if previous.revision >= entity.revision {
                if previous.revision == entity.revision && previous != entity { throw SyncInboxError.sequenceCollision }
                try await database.pool.write { db in
                    if let rejectedMutationID,
                       let queued = try Data.fetchOne(db, sql: "SELECT wireMutation FROM sync_outbox WHERE mutationId=?", arguments: [rejectedMutationID]) {
                        let mutation = try JSONDecoder().decode(SyncMutation.self, from: queued)
                        guard mutation.entityId == entity.mutation.entityId, mutation.entityType == entity.mutation.entityType,
                              mutation.parentRevision < entity.revision else { throw SyncQueueError.invalidReceipt }
                        try db.execute(sql: "DELETE FROM sync_outbox WHERE mutationId=?", arguments: [rejectedMutationID])
                    }
                    try Self.consume(entity, in: db)
                }
                return .unchanged
            }
        }
        let value = try await reader.read(entity)
        let base: SyncRemoteValue?
        if let ancestor { base = try await reader.read(JSONDecoder().decode(SyncEntity.self, from: ancestor)) }
        else { base = nil }
        if entity.mutation.entityType == .note {
            return try await applyNote(entity, value: value, base: base, ancestor: ancestor, rejectedMutationID: rejectedMutationID, noteAccess: noteAccess)
        }
        if entity.mutation.entityType == .attachment {
            return try await applyAttachment(entity, value: value, ancestor: ancestor, rejectedMutationID: rejectedMutationID, noteAccess: noteAccess, base: base)
        }
        let authorizedEnvelope = try await authorizePasswordEnvelope(value, access: noteAccess, password: remoteNotePassword)
        return try await coordinatedCommit(scope: .metadata(entity.mutation.entityType)) {
            try applyMetadata(entity, value: value, base: base, ancestor: ancestor, rejectedMutationID: rejectedMutationID,
                authorizedEnvelope: authorizedEnvelope, noteAccess: noteAccess)
        }
    }

    func coordinatedCommit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
        try Task.checkCancellation()
        if let coordinator { return try await coordinator.commit(scope: scope, change) }
        return try change()
    }

    static func shadow(_ entity: SyncEntity, in db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType=? AND entityId=?",
                          arguments: [entity.mutation.entityType.rawValue, entity.mutation.entityId])
    }

    func applyMetadata(_ entity: SyncEntity, value: SyncRemoteValue, base: SyncRemoteValue?, ancestor: Data?,
                       rejectedMutationID: String?, authorizedEnvelope: PasswordAuthorization?, noteAccess: LockedNoteAccess?) throws -> SyncApplyResult {
        let files = AttachmentFiles(paths: paths, database: database)
        var staged: [AttachmentFiles.Staged] = [], committed = false
        defer { if !committed { for batch in staged { files.discard(batch) } } }
        let result = try database.pool.write { db -> SyncApplyResult in
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE id=1") == reader.accountID else { throw SyncQueueError.accountMismatch }
            guard try Self.shadow(entity, in: db) == ancestor else { throw SyncApplyError.changedDuringDownload }
            if let ancestor {
                let previous = try JSONDecoder().decode(SyncEntity.self, from: ancestor)
                if previous.revision >= entity.revision {
                    if previous.revision == entity.revision && previous != entity { throw SyncInboxError.sequenceCollision }
                    try Self.consume(entity, in: db)
                    return .unchanged
                }
            }
            let type = entity.mutation.entityType
            let mapped = try String.fetchOne(db, sql: "SELECT localId FROM sync_entity_state WHERE entityType=? AND entityId=?",
                                             arguments: [type.rawValue, entity.mutation.entityId])
            let localID = try Self.localID(value, mapped: mapped, in: db) ?? (type == .keyBundle ? "lock-vault" : nil)
            if let localID,
               let pending = try String.fetchOne(db, sql: "SELECT mutationId FROM sync_outbox WHERE entityType=? AND localId=?", arguments: [type.rawValue, localID]),
               pending != rejectedMutationID { return .waitingForUpload }
            // Unsupported dependencies remain durably encrypted in the inbox.
            if type == .note || type == .attachment { return .waitingForDependencies }
            let dirty = try localID.map { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType=? AND localId=?)", arguments: [type.rawValue, $0]) == true } ?? false
            let preservingPasswordEnvelope = try type == .keyBundle && entity.mutation.tombstone &&
                (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true)
            var adoptingPasswordChange = false
            if case .lockEnvelope(let remote) = value,
               let local = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"), local != remote,
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == true {
                guard authorizedEnvelope?.localEnvelope == local, let noteAccess else {
                    try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                    return .waitingForUnlock
                }
                _ = try noteAccess.journalKey()
                adoptingPasswordChange = true
            }
            var reconcileReference = false
            if case .externalRef(let ref) = value, let id = ref.noteId {
                guard try Note.fetchOne(db, key: id) != nil else { return .waitingForDependencies }
                if let existing = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?", arguments: [ref.source, ref.externalId]), existing != id {
                    reconcileReference = true
                }
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            // Pending local preferences win and are rebased onto the received revision. Their
            // dirty generation is retained; a later upload makes that resolution portable.
            if preservingPasswordEnvelope {
                // Removing the password on a device with no protected notes cannot erase
                // the key envelope still needed by another device's offline protected notes.
                guard try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") != nil else { throw NotePrivacyError.passwordNotSet }
                try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('keyBundle','lock-vault',1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0")
            } else if reconcileReference, case .externalRef(let ref) = value, let localID {
                let resolved = try reconcileImport(ref, entity: entity, in: db)
                try Self.writeMetadata(.externalRef(resolved), type: type, localID: localID, in: db)
                if resolved == ref {
                    try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='externalRef' AND localId=?", arguments: [localID])
                } else {
                    try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('externalRef',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0", arguments: [localID])
                }
            } else if adoptingPasswordChange {
                if let (from, to) = authorizedEnvelope?.conversionKeys {
                    try stageInitialVaultConversion(from: from, to: to, files: files, staged: &staged, in: db)
                    _ = try noteAccess?.journalKey()
                }
                try Self.writeMetadata(value, type: type, localID: localID, in: db)
                try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='keyBundle' AND localId=?", arguments: [localID])
            } else if !dirty { try Self.writeMetadata(value, type: type, localID: localID, in: db) }
            try Self.finish(entity, localID: localID, rejectedMutationID: rejectedMutationID, in: db)
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return adoptingPasswordChange && authorizedEnvelope?.conversionKeys != nil ? .passwordChanged : .applied
        }
        committed = true
        for batch in staged { files.install(batch) }
        let pending = try database.pool.read { db in
            try staged.contains { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE id=?)", arguments: [$0.batchID]) == true }
        }
        guard !pending else { throw BackupError.restoreFilesPending }
        try Self.recoverImportCleanup(database: database, paths: paths)
        return result
    }

    static func localID(_ value: SyncRemoteValue, mapped: String?, in db: Database) throws -> String? {
        let semantic: String?
        switch value {
        case .deleted: semantic = mapped
        case .note(let note): semantic = note.id
        case .attachment(let attachment): semantic = attachment.id
        case .setting(let setting): semantic = setting.key
        case .lockEnvelope: semantic = "lock-vault"
        case .externalRef(let ref):
            semantic = try String.fetchOne(db, sql: "SELECT json_array(?,?)", arguments: [ref.source, ref.externalId])
        case .tag(let tag):
            semantic = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE pathKey=?", arguments: [CanonicalKey.make(tag.path)]) ?? mapped ?? UUIDv7.make()
        }
        if let mapped, let semantic, mapped != semantic { throw SyncApplyError.identityCollision }
        return semantic
    }

    static func writeMetadata(_ value: SyncRemoteValue, type: SyncEntityType, localID: String?, in db: Database) throws {
        switch value {
        case .setting(let setting):
            try db.execute(sql: "INSERT INTO setting(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [setting.key, setting.value])
        case .tag(let tag):
            guard let localID else { throw SyncApplyError.identityCollision }
            try db.execute(sql: """
                INSERT INTO tag(id,pathKey,displayPath,iconName,isPinned,sortIndex) VALUES(?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET pathKey=excluded.pathKey,displayPath=excluded.displayPath,
                  iconName=excluded.iconName,isPinned=excluded.isPinned,sortIndex=excluded.sortIndex
                """, arguments: [localID, CanonicalKey.make(tag.path), tag.path, tag.iconName, tag.isPinned, tag.sortIndex])
        case .lockEnvelope(let data):
            try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET envelope=excluded.envelope", arguments: [data])
        case .externalRef(let ref):
            try db.execute(sql: """
                INSERT INTO external_ref(source,externalId,noteId,lastSeenModified,lastSeenHash,lastSeenTextHash,lastSeenMeta,importedTextHash)
                VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(source,externalId) DO UPDATE SET
                  noteId=excluded.noteId,lastSeenModified=excluded.lastSeenModified,lastSeenHash=excluded.lastSeenHash,
                  lastSeenTextHash=excluded.lastSeenTextHash,lastSeenMeta=excluded.lastSeenMeta,
                  importedTextHash=excluded.importedTextHash,importedRevision=NULL
                """, arguments: [ref.source, ref.externalId, ref.noteId, ref.lastSeenModified.map(Self.date), ref.lastSeenHash,
                                  ref.lastSeenTextHash, ref.lastSeenMeta, ref.importedTextHash])
        case .deleted:
            guard let localID else { return }
            switch type {
            case .setting: try db.execute(sql: "DELETE FROM setting WHERE key=?", arguments: [localID])
            case .tagPreference:
                // Tag membership is derived from note Markdown; deleting preferences must not
                // erase tags from notes that still use them.
                try db.execute(sql: "UPDATE tag SET iconName=NULL,isPinned=0,sortIndex=NULL WHERE id=?", arguments: [localID])
            case .externalRef:
                let keys = try JSONDecoder().decode([String].self, from: Data(localID.utf8))
                guard keys.count == 2 else { throw SyncProtocolError.invalidPayload }
                try db.execute(sql: "DELETE FROM external_ref WHERE source=? AND externalId=?", arguments: [keys[0], keys[1]])
            case .keyBundle:
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE isLocked=1)") == false else { throw SyncQueueError.snapshotUnavailable }
                try db.execute(sql: "DELETE FROM crypto_envelope")
            case .note, .attachment: throw SyncQueueError.snapshotUnavailable
            }
        case .note, .attachment: throw SyncQueueError.snapshotUnavailable
        }
    }

    static func finish(_ entity: SyncEntity, localID: String?, rejectedMutationID: String?, in db: Database) throws {
        let type = entity.mutation.entityType.rawValue
        if let localID {
            try db.execute(sql: """
                INSERT INTO sync_entity_state(entityType,localId,entityId,serverRevision) VALUES(?,?,?,?)
                ON CONFLICT(entityType,localId) DO UPDATE SET serverRevision=excluded.serverRevision
                WHERE entityId=excluded.entityId
                """, arguments: [type, localID, entity.mutation.entityId, entity.revision])
            guard db.changesCount == 1 else { throw SyncApplyError.identityCollision }
            if let rejectedMutationID {
                try db.execute(sql: "DELETE FROM sync_outbox WHERE mutationId=? AND entityType=? AND localId=?", arguments: [rejectedMutationID, type, localID])
            }
        }
        try db.execute(sql: """
            INSERT INTO sync_shadow(entityType,entityId,serverRevision,sequence,wireEntity) VALUES(?,?,?,?,?)
            ON CONFLICT(entityType,entityId) DO UPDATE SET serverRevision=excluded.serverRevision,
              sequence=excluded.sequence,wireEntity=excluded.wireEntity
            """, arguments: [type, entity.mutation.entityId, entity.revision, entity.sequence, try JSONEncoder().encode(entity)])
        try consume(entity, in: db)
    }

    static func consume(_ entity: SyncEntity, in db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_inbox WHERE entityType=? AND entityId=? AND serverRevision<=?",
                       arguments: [entity.mutation.entityType.rawValue, entity.mutation.entityId, entity.revision])
    }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
