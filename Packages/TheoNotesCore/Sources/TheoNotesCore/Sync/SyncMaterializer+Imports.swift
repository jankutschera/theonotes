// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

extension SyncMaterializer {
    /// The source identity, not a coincidentally equal title, establishes that two independently
    /// imported notes are related. Only an unpublished exact duplicate may be collapsed.
    func reconcileImport(_ remote: SyncExternalRefPayload, entity: SyncEntity, in db: Database) throws -> SyncExternalRefPayload {
        guard let remoteID = remote.noteId,
              let localID = try String.fetchOne(db, sql: "SELECT noteId FROM external_ref WHERE source=? AND externalId=?", arguments: [remote.source, remote.externalId]), localID != remoteID,
              var local = try SyncNotePayload.capture(id: localID, in: db),
              let received = try SyncNotePayload.capture(id: remoteID, in: db) else { return remote }
        let enabled = try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true
        let journal = paths.journal.appendingPathComponent(localID + ".jsonl")
        let journalEmpty = try !FileManager.default.fileExists(atPath: journal.path) || (journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == 0
        let recoveryFiles = try FileManager.default.contentsOfDirectory(atPath: paths.journal.path)
            .contains { $0.hasPrefix(localID + ".") && $0.contains(".unreplayed") }
        let unpublished = try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM sync_entity_state WHERE entityType='note' AND localId=?)
              AND NOT EXISTS(SELECT 1 FROM sync_outbox WHERE entityType='note' AND localId=?)
              AND NOT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?)
              AND NOT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)
            """, arguments: [localID, localID, localID, localID]) == true
        var comparable = local
        comparable.id = remoteID; comparable.attachmentIds = received.attachmentIds
        comparable.attachmentNames = received.attachmentNames
        comparable.attachmentSnapshots = received.attachmentSnapshots
        let equal = !local.isLocked && !received.isLocked && comparable == received &&
            TextNormalization.identical(comparable.text, received.text)
        if !enabled && unpublished && journalEmpty && !recoveryFiles && equal,
           try importedFilesMatch(localID, remoteID, in: db) {
            try db.execute(sql: """
                INSERT OR IGNORE INTO note_ui_state(noteId,foldState,selection,scrollTop)
                SELECT ?,foldState,selection,scrollTop FROM note_ui_state WHERE noteId=?
                """, arguments: [remoteID, localID])
            try db.execute(sql: "UPDATE external_ref SET noteId=?,importedRevision=NULL WHERE noteId=?", arguments: [remoteID, localID])
            // Old rolling backups still contain the original ID. Mark the canonical identity
            // too, so subsequently locking it prunes those earlier plaintext copies.
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
        // No trusted ancestor, differing metadata/files, or already-published IDs: preserve both
        // notes. Active clients select the same source owner deterministically to prevent CAS
        // ping-pong, while first sync adopts the established server source mapping.
        let canonical = enabled ? min(localID, remoteID) : remoteID
        local.conflict = SyncConflictInfo(originalNoteId: canonical == localID ? remoteID : canonical,
            rejectedMutationId: entity.mutation.mutationId, remoteRevision: entity.revision)
        try Self.recordConflict(local, in: db)
        try Self.markNote(localID, deleted: false, in: db)
        if canonical == remoteID { return remote }
        let localRef = try SyncPayloadCodec.capture(SyncDirty(type: .externalRef,
            localID: String.fetchOne(db, sql: "SELECT json_array(?,?)", arguments: [remote.source, remote.externalId])!,
            generation: 1, tombstone: false), in: db)
        guard let bytes = localRef.payload else { throw SyncProtocolError.invalidPayload }
        return try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: bytes)
    }

    func importedFilesMatch(_ local: String, _ remote: String, in db: Database) throws -> Bool {
        let left = try Row.fetchAll(db, sql: "SELECT filename,filenameKey FROM attachment WHERE noteId=? AND deletedAt IS NULL ORDER BY filenameKey", arguments: [local])
        let right = try Row.fetchAll(db, sql: "SELECT filename,filenameKey FROM attachment WHERE noteId=? AND deletedAt IS NULL ORDER BY filenameKey", arguments: [remote])
        guard left.count == right.count else { return false }
        for (a, b) in zip(left, right) {
            guard a["filenameKey"] as String == b["filenameKey"] as String else { return false }
            let first = paths.attachments.appendingPathComponent(local).appendingPathComponent(a["filename"] as String)
            let second = paths.attachments.appendingPathComponent(remote).appendingPathComponent(b["filename"] as String)
            guard let ah = try? SyncAttachmentPreparer.hashFile(first), let bh = try? SyncAttachmentPreparer.hashFile(second), ah == bh else { return false }
        }
        func inventory(_ id: String) throws -> [String: String] {
            let folder = paths.attachments.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
            var hashes: [String: String] = [:]
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let facts = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard facts.isRegularFile == true, facts.isSymbolicLink != true else { throw SyncQueueError.snapshotUnavailable }
                hashes[AttachmentFiles.fileSystemKey(file.lastPathComponent)] = try SyncAttachmentPreparer.hashFile(file).hash
            }
            return hashes
        }
        guard let leftFiles = try? inventory(local), let rightFiles = try? inventory(remote), leftFiles == rightFiles else { return false }
        return true
    }

    func recoverImportCleanup() throws { try Self.recoverImportCleanup(database: database, paths: paths) }

    public static func recoverImportCleanup(database: AppDatabase, paths: AppPaths) throws {
        try database.pool.write { db in
            for id in try String.fetchAll(db, sql: "SELECT noteId FROM sync_import_cleanup") {
                try SyncWire.validateID(id)
                if try Note.fetchOne(db, key: id) == nil {
                    for url in [paths.attachments.appendingPathComponent(id), paths.thumbnails.appendingPathComponent(id),
                                paths.journal.appendingPathComponent(id + ".base"), paths.journal.appendingPathComponent(id + ".jsonl")] {
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    }
                }
                try db.execute(sql: "DELETE FROM sync_import_cleanup WHERE noteId=?", arguments: [id])
            }
        }
    }
}
