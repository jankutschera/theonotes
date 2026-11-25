// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

/// Writer-only facts: absence of historical body is not evidence of a plaintext local
/// state, especially after an unsent lock and deletion. Only no vault and no pending vault
/// publication/import positively rules out an unknown local lock.
enum SyncDeletedRecoveryPolicy {
    /// B5: this device's own outgoing key-bundle tombstone (written when the password is deleted,
    /// dirty or already queued) means "vault deleted", not "vault pending". Any envelope, any
    /// non-tombstone key bundle and any key bundle arriving from another device still count.
    /// S6: a dirty tombstone is exempt only while uploads run (`enabled = 1`); before the first
    /// sync completes it never reaches the outbox and "dirty wins" could swallow a remote vault.
    static func hasNoVaultOrPendingVault(in db: Database, cloud: Bool) throws -> Bool {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM crypto_envelope) OR EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='keyBundle'
                AND (tombstone=0 OR COALESCE((SELECT enabled FROM sync_control WHERE id=1),0)=0))
            """) == false else { return false }
        let pending: Bool
        if cloud {
            pending = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ck_remote WHERE entityType='keyBundle')
                    OR EXISTS(SELECT 1 FROM ck_inflight f WHERE f.entityType='keyBundle' AND NOT EXISTS(
                        SELECT 1 FROM sync_dirty d WHERE f.localId='lock-vault' AND f.generationOfAccount=(SELECT generation FROM ck_state WHERE id=1)
                            AND d.entityType=f.entityType AND d.localId=f.localId
                            AND d.generation=f.generation AND d.tombstone=1
                            AND COALESCE((SELECT enabled FROM sync_control WHERE id=1),0)=1))
                    OR EXISTS(SELECT 1 FROM ck_missing WHERE entityType='keyBundle')
                    OR EXISTS(SELECT 1 FROM ck_quarantine WHERE entityType='keyBundle' AND ignoredByUser=0)
                """) == true
        } else {
            pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_inbox WHERE entityType='keyBundle') OR EXISTS(SELECT 1 FROM sync_outbox WHERE entityType='keyBundle' AND COALESCE(json_extract(CAST(wireMutation AS TEXT),'$.tombstone'),0)=0)") == true
        }
        return !pending
    }

    static func requiresProtection(priorLocked: Bool?, remoteLocked: Bool, unsentDeletion: Bool, noVault: Bool) -> Bool {
        remoteLocked || priorLocked == true || (!noVault && (unsentDeletion || priorLocked == nil))
    }

    static func sameFile(_ incoming: SyncAttachmentPayload, as base: SyncRemoteValue?) -> Bool {
        guard case .attachment(let old) = base else { return false }
        return old.id == incoming.id && old.noteId == incoming.noteId && old.isLocked == incoming.isLocked
            && old.fileHash == incoming.fileHash && old.fileBytes == incoming.fileBytes
    }
}

extension SyncLockedNoteMerge {
    /// Missing history is not an empty ancestor when a local permanent-delete tombstone
    /// proves authored intent. Retain the remote document as a protected copy instead of
    /// adopting it at the deleted identity (the ordinary nil-base merge would do that).
    static func deletedUnknownParentConflict(remote: SyncNotePayload, entityID: String,
                                            mutationID: String, revision: Int64, key: SymmetricKey?, sourceNames: [String: String] = [:]) throws -> SyncNoteMergeResult {
        if remote.isLocked {
            guard let key else { throw NotePrivacyError.accessRevoked }
            return try deletedProtectedConflict(remote: remote, entityID: entityID, mutationID: mutationID, revision: revision, key: key)
        }
        var copy = remote
        copy.id = SyncNoteMerge.conflictID(entityID: entityID, mutationID: mutationID, remoteRevision: revision)
        copy.conflict = SyncConflictInfo(originalNoteId: entityID, rejectedMutationId: mutationID, remoteRevision: revision)
        copy.attachmentSnapshots = nil
        if let key { copy = try protectDeletedRecovery(copy, key: key, sourceNames: sourceNames) }
        return .conflict(local: nil, remoteCopy: copy)
    }

    /// A deleted protected parent must never turn a concurrently received plain recovery
    /// document into public text. The source names remain solely an internal staging map;
    /// the persisted encrypted manifest uses destination clone identities.
    static func protectDeletedRecovery(_ copy: SyncNotePayload, key: SymmetricKey, sourceNames: [String: String] = [:]) throws -> SyncNotePayload {
        guard !copy.isLocked else { return copy }
        let names = copy.attachmentNames ?? sourceNames
        guard Set(names.keys) == Set(copy.attachmentIds) else {
            throw SyncQueueError.snapshotUnavailable
        }
        var identities: [String: String] = [:], blobs: [String: String] = [:]
        for (id, name) in names {
            let clone = SyncMaterializer.copyAttachmentID(id, noteID: copy.id)
            identities[name] = clone; blobs[name] = clone + ".bch"
        }
        let body = LockedNotePayload(text: copy.text, attachments: blobs, attachmentIDs: identities)
        var protected = copy
        protected.text = ""; protected.title = "Locked note"; protected.isLocked = true
        protected.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(body), vaultKey: key, context: copy.id)
        protected.attachmentNames = names
        protected.attachmentSnapshots = nil
        return protected
    }
}
