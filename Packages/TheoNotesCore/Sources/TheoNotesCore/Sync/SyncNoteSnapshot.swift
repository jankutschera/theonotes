// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

enum SyncNoteSnapshot {
    static func capture(_ dirty: SyncDirty, accountID: String, vaultKey: SymmetricKey, in db: Database) throws -> SyncContent {
        let content = try SyncPayloadCodec.capture(dirty, in: db)
        guard let payload = content.payload else { return content }
        var note = try SyncPayloadCodec.decode(SyncNotePayload.self, from: payload)
        var snapshots: [String: SyncAttachmentPayload] = [:]
        for id in note.attachmentIds {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.encryptedDescriptor,c.generation,d.generation AS pendingGeneration FROM sync_attachment_cache c
                LEFT JOIN sync_dirty d ON d.entityType='attachment' AND d.localId=c.attachmentId
                WHERE c.attachmentId=? AND EXISTS(SELECT 1 FROM sync_blob_state b WHERE b.hash=c.blobHash)
                """, arguments: [id]) else { continue }
            if let pending: Int64 = row["pendingGeneration"], pending != row["generation"] as Int64 { continue }
            let context = try SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: id)
            let (_, descriptor) = try SyncAttachmentPreparer.decodeCached(row["encryptedDescriptor"], vaultKey: vaultKey, context: context)
            guard descriptor.id == id, descriptor.noteId == note.id,
                  descriptor.isLocked == note.isLocked, descriptor.filename == note.attachmentNames?[id] else { continue }
            snapshots[id] = descriptor
        }
        note.attachmentSnapshots = snapshots
        try note.validate()
        let refs = Set(snapshots.values.map(\.blobHash)).sorted()
        // Reserve one wire reference for the encrypted note payload when it exceeds inline size.
        guard refs.count < 1000 else { throw SyncProtocolError.responseTooLarge }
        return SyncContent(payload: try SyncPayloadCodec.encoder().encode(note), blobRefs: refs)
    }
}
