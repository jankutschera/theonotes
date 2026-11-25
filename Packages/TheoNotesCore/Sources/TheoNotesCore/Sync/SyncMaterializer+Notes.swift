// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

extension SyncMaterializer {
    struct DownloadedAttachment: Sendable {
        let entity: SyncEntity?
        let payload: SyncAttachmentPayload
        let cipher: URL
    }

    func applyNote(_ entity: SyncEntity, value: SyncRemoteValue, base: SyncRemoteValue?, ancestor: Data?,
                   rejectedMutationID: String?, noteAccess: LockedNoteAccess?) async throws -> SyncApplyResult {
        let remote: SyncNotePayload?
        switch value { case .note(let note): remote = note; case .deleted: remote = nil; default: throw SyncProtocolError.invalidPayload }
        let old: SyncNotePayload?
        switch base { case .note(let note): old = note; case nil, .deleted: old = nil; default: throw SyncProtocolError.invalidPayload }
        var downloads: [DownloadedAttachment] = []
        // A note and all its referenced files become visible together. Descriptors can precede
        // their parent note in the inbox because attachment foreign keys prevent early inserts.
        for id in remote?.attachmentIds ?? [] {
            let wire = try await database.pool.read { db in
                try Data.fetchOne(db, sql: """
                    SELECT wireEntity FROM (
                      SELECT serverRevision,wireEntity FROM sync_inbox WHERE entityType='attachment' AND entityId=?
                      UNION ALL SELECT serverRevision,wireEntity FROM sync_shadow WHERE entityType='attachment' AND entityId=?
                    ) ORDER BY serverRevision DESC LIMIT 1
                    """, arguments: [id, id])
            }
            var selected: (SyncEntity?, SyncAttachmentPayload)?
            if let wire {
                let latest = try JSONDecoder().decode(SyncEntity.self, from: wire)
                if case .attachment(let attachment) = try await reader.read(latest),
                   attachment.noteId == entity.mutation.entityId, attachment.isLocked == remote?.isLocked,
                   remote?.attachmentNames?[id].map({ $0 == attachment.filename }) ?? true {
                    selected = (latest, attachment)
                }
            }
            if selected == nil, let pinned = remote?.attachmentSnapshots?[id] { selected = (nil, pinned) }
            guard let (attachmentEntity, attachment) = selected else {
                // A known but incompatible representation is not a genuinely missing file.
                if wire == nil, remote?.attachmentNames?[id] != nil { continue }
                if let wire, try JSONDecoder().decode(SyncEntity.self, from: wire).mutation.tombstone,
                   remote?.attachmentNames?[id] != nil { continue }
                return .waitingForDependencies
            }
            downloads.append(DownloadedAttachment(entity: attachmentEntity, payload: attachment,
                                                  cipher: try await preparedAttachmentCipher(attachment)))
        }
        let readyDownloads = downloads
        return try await coordinatedCommit(scope: .note(entity.mutation.entityId)) {
            try commitNote(entity, remote: remote, old: old, ancestor: ancestor,
                rejectedMutationID: rejectedMutationID, downloads: readyDownloads, noteAccess: noteAccess)
        }
    }

    func commitNote(_ entity: SyncEntity, remote: SyncNotePayload?, old: SyncNotePayload?, ancestor: Data?,
                    rejectedMutationID: String?, downloads: [DownloadedAttachment], noteAccess: LockedNoteAccess?) throws -> SyncApplyResult {
        do {
            return try commitNoteTransaction(entity, remote: remote, old: old, ancestor: ancestor,
                rejectedMutationID: rejectedMutationID, downloads: downloads, noteAccess: noteAccess)
        } catch SyncApplyError.waitingForCapture {
            // A voice capture still holds text in this note's journal (FOC-R303). The transaction
            // rolled back and its staged files were discarded: this note waits, and the pass goes
            // on with the other notes and the uploads.
            return .waitingForDependencies
        }
    }

    private func commitNoteTransaction(_ entity: SyncEntity, remote: SyncNotePayload?, old: SyncNotePayload?, ancestor: Data?,
                    rejectedMutationID: String?, downloads: [DownloadedAttachment], noteAccess: LockedNoteAccess?) throws -> SyncApplyResult {
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
                    try Self.consume(entity, in: db); return .unchanged
                }
            }
            let id = entity.mutation.entityId
            let journal = paths.journal.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: journal.path),
               (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { return .waitingForDependencies }
            LockTestHooks.runAfterRemoteJournalCheck(id)
            if let pending = try String.fetchOne(db, sql: "SELECT mutationId FROM sync_outbox WHERE entityType='note' AND localId=?", arguments: [id]), pending != rejectedMutationID { return .waitingForUpload }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)", arguments: [id, id]) == false else { return .waitingForDependencies }
            if remote?.isLocked == true {
                guard try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") != nil,
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_inbox WHERE entityType='keyBundle' AND waitingForUnlock=1)") == false else {
                    try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                    return .waitingForUnlock
                }
            }
            let local = try SyncNotePayload.capture(id: id, includeRetained: true, in: db)
            let dirty = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=?)", arguments: [id]) == true
            let unsentDeletion = try local == nil && (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [id]) == true)
            let noVault = try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: false)
            var merged: SyncNoteMergeResult
            var noteKey: SymmetricKey?
            // Before capture is enabled, existing local notes are still meaningful edits.
            if dirty || (ancestor == nil && local != nil) {
                merged = try SyncNoteMerge.reconcile(base: old, local: local, remote: remote, entityID: id,
                    rejectedMutationID: rejectedMutationID ?? entity.mutation.mutationId, remoteRevision: entity.revision)
            } else { merged = .merged(remote) }
            if local == nil, old == nil, let remote, unsentDeletion {
                let protect = SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: nil, remoteLocked: remote.isLocked, unsentDeletion: true, noVault: noVault)
                let key: SymmetricKey?
                if protect {
                    guard let noteAccess else {
                        try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                        return .waitingForUnlock
                    }
                    key = try noteAccess.journalKey()
                } else { key = nil }
                merged = try SyncLockedNoteMerge.deletedUnknownParentConflict(remote: remote, entityID: id,
                    mutationID: rejectedMutationID ?? entity.mutation.mutationId, revision: entity.revision, key: key, sourceNames: Dictionary(uniqueKeysWithValues: downloads.map { ($0.payload.id, $0.payload.filename) }))
                noteKey = key
            }
            if case .needsUnlock = merged, let noteAccess {
                let key = try noteAccess.journalKey()
                merged = try SyncLockedNoteMerge.reconcile(base: old, local: local, remote: remote,
                    entityID: id, mutationID: rejectedMutationID ?? entity.mutation.mutationId,
                    revision: entity.revision, key: key)
                noteKey = key
            }
            if case .needsUnlock = merged {
                try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                return .waitingForUnlock
            }
            if case .merged(let note) = merged, let note, let local, local.isLocked != note.isLocked {
                let ready = downloads.filter { note.attachmentIds.contains($0.payload.id) && $0.payload.isLocked == note.isLocked && (note.attachmentNames == nil || note.attachmentNames?[$0.payload.id] == $0.payload.filename) }
                if ready.count < note.attachmentIds.count { return .waitingForDependencies }
            }
            if local == nil, SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: old?.isLocked,
                remoteLocked: remote?.isLocked == true, unsentDeletion: unsentDeletion, noVault: noVault),
               case .conflict(let kept, let copy) = merged, let copy, !copy.isLocked {
                guard let noteAccess else {
                    try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                    return .waitingForUnlock
                }
                let key = try noteAccess.journalKey()
                merged = .conflict(local: kept, remoteCopy: try SyncLockedNoteMerge.protectDeletedRecovery(copy, key: key, sourceNames: Dictionary(uniqueKeysWithValues: downloads.map { ($0.payload.id, $0.payload.filename) })))
                noteKey = key
            }
            // Mirror the note delete-vs-edit result, without acknowledging or discarding an
            // incompatible standalone attachment. A complete remote-note recovery copy is staged
            // in this transaction before its downloaded attachment version advances below.
            var deletedNoteRecoveryIDs = Set<String>()
            if local == nil, case .conflict(let kept, let copy) = merged, kept == nil, let copy,
               try Note.fetchOne(db, key: id) == nil,
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [id]) == true,
               copy.attachmentIds.allSatisfy({ attachmentID in
                   downloads.contains { download in download.payload.id == attachmentID && download.payload.isLocked == remote?.isLocked &&
                       (copy.attachmentNames?[attachmentID].map { $0 == download.payload.filename } ?? true) }
               }) {
                deletedNoteRecoveryIDs = Set(copy.attachmentIds)
            }
            // Do not overwrite a concurrently changing attachment. Its immutable upload must
            // first receive a receipt (or be reconciled against a CAS rejection).
            for download in downloads {
                let attachment = download.payload
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)", arguments: [attachment.id]) == true {
                    guard deletedNoteRecoveryIDs.contains(attachment.id),
                          try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [attachment.id]) == false,
                          try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=1)", arguments: [attachment.id]) == true
                    else { return .waitingForUpload }
                }
                if let wire = download.entity, let previous = try Self.shadow(wire, in: db),
                   try JSONDecoder().decode(SyncEntity.self, from: previous).revision > wire.revision { throw SyncApplyError.changedDuringDownload }
            }
            try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
            switch merged {
            case .merged(let note):
                if let note {
                    let selected = downloads.filter { download in
                        note.attachmentIds.contains(download.payload.id) && download.payload.isLocked == note.isLocked &&
                            (note.attachmentNames == nil || note.attachmentNames?[download.payload.id] == download.payload.filename)
                    }
                    try writeNote(note, downloads: selected,
                                  copying: false, noteKey: noteKey, files: files, staged: &staged, in: db)
                    for skipped in downloads where !selected.contains(where: { $0.payload.id == skipped.payload.id }) {
                        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [skipped.payload.id]) == true {
                            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0", arguments: [skipped.payload.id])
                        }
                    }
                } else {
                    // A remote tombstone must not destroy the last local recovery copy.
                    // Retain the complete note and its file references in Trash. The tombstone
                    // in sync_shadow records its remote origin; this local recovery state is
                    // deliberately not echoed. An explicit Restore is a new local mutation
                    // rebased against that tombstone by the ordinary capture/queue path.
                    // Use local time, not untrusted receivedAt, and do not reset retention or
                    // bump the editor revision again for a repeated remote deletion.
                    try db.execute(sql: """
                        UPDATE note SET location='trash', trashedAt=?, revision=revision+1
                        WHERE id=? AND location!='trash'
                        """, arguments: [NoteStore.roundedToMillis(.now), id])
                }
                if note != remote { try Self.markNote(id, deleted: note == nil, in: db) }
                else { try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [id]) }
            case .conflict(let mine, let copy):
                // The original keeps local content. A deterministic copy preserves the entire
                // remote document and clones attachment identities into that copy's namespace.
                if let mine { try Self.recordConflict(mine, in: db) }
                if let copy, try Note.fetchOne(db, key: copy.id) == nil {
                    try writeNote(copy, downloads: downloads, copying: true, noteKey: noteKey, files: files, staged: &staged, in: db)
                    try Self.markNote(copy.id, deleted: false, in: db)
                }
                for download in downloads {
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [download.payload.id]) == true {
                        try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1", arguments: [download.payload.id])
                    }
                }
                try Self.markNote(id, deleted: mine == nil, in: db)
            case .needsUnlock: preconditionFailure("handled before mutation")
            }
            for download in downloads {
                if let wire = download.entity { try Self.finish(wire, localID: download.payload.id, rejectedMutationID: nil, in: db) }
            }
            try Self.finish(entity, localID: id, rejectedMutationID: rejectedMutationID, in: db)
            try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            return .applied
        }
        committed = true
        for batch in staged { files.install(batch) }
        if result == .applied {
            try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).finishPendingCleanup()
            ChangeNotifier().post()
        }
        return result
    }

    func writeNote(_ payload: SyncNotePayload, downloads: [DownloadedAttachment], copying: Bool, noteKey: SymmetricKey? = nil,
                   files: AttachmentFiles, staged: inout [AttachmentFiles.Staged], in db: Database) throws {
        // A locked note stops its voice captures before anything is written (FOC-R199 addendum 3).
        if payload.isLocked {
            do { try CaptureLockGuard.noteWillLock(payload.id) } catch NotePrivacyError.pendingEdits {
                throw SyncApplyError.waitingForCapture
            }
        }
        let previous = try Note.fetchOne(db, key: payload.id)
        let note = Note(id: payload.id, text: payload.text, title: payload.title, titleKey: TitleKey.make(payload.title),
                        createdAt: Self.date(payload.createdAt), modifiedAt: Self.date(payload.modifiedAt), location: payload.location,
                        trashedAt: payload.trashedAt.map(Self.date), archivedAt: payload.archivedAt.map(Self.date),
                        isPinnedGlobal: payload.isPinnedGlobal, isReadOnly: payload.isReadOnly, isLocked: payload.isLocked,
                        encryptedPayload: payload.encryptedPayload, revision: (previous?.revision ?? 0) + 1)
        func destinationName(_ attachment: SyncAttachmentPayload) -> String {
            copying && note.isLocked ? Self.copyAttachmentID(attachment.id, noteID: note.id) + ".bch" : attachment.filename
        }
        var batch = try files.stageTransformed(downloads.map { destinationName($0.payload) }, noteId: note.id) { name, output in
            guard let download = downloads.first(where: { destinationName($0.payload) == name }) else { throw SyncProtocolError.invalidPayload }
            if copying && note.isLocked {
                guard let noteKey else { throw NotePrivacyError.accessRevoked }
                if download.payload.isLocked {
                    // This temporary file contains only inner BCH1 ciphertext. Rebinding streams
                    // plaintext through memory and authenticates it to the copy's opaque name.
                    let inner = output.appendingPathExtension("source-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: inner) }
                    try reader.writeAttachment(download.payload, cipher: download.cipher, to: inner)
                    try ChunkedCipher.reencrypt(input: inner, output: output, fromKey: noteKey, toKey: noteKey,
                        fromContext: download.payload.filename, toContext: name)
                } else {
                    try reader.writeProtectedAttachment(download.payload, cipher: download.cipher, to: output,
                        noteKey: noteKey, context: name)
                }
            } else { try reader.writeAttachment(download.payload, cipher: download.cipher, to: output) }
        }
        let privacyChanged = previous.map { $0.isLocked != note.isLocked } ?? note.isLocked
        batch.replacing = privacyChanged
        staged.append(batch)
        try note.save(db)
        try AttachmentFiles.record(batch, in: db)
        for id in payload.attachmentIds where !downloads.contains(where: { $0.payload.id == id }) {
            let localID = copying ? Self.copyAttachmentID(id, noteID: note.id) : id
            guard let sourceName = payload.attachmentNames?[id] else {
                // Old wire payloads can still refer to a locally retained attachment after a
                // clean merge. Its existing identity remains authoritative.
                guard try String.fetchOne(db, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [localID]) == note.id else { throw SyncQueueError.snapshotUnavailable }
                continue
            }
            let name = copying && note.isLocked ? localID + ".bch" : sourceName
            if let owner = try String.fetchOne(db, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [localID]), owner != note.id { throw SyncApplyError.identityCollision }
            if let namedID = try String.fetchOne(db, sql: "SELECT id FROM attachment WHERE noteId=? AND filenameKey=?", arguments: [note.id, AttachmentFiles.fileSystemKey(name)]), namedID != localID { throw SyncApplyError.identityCollision }
            try db.execute(sql: """
                INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,ocrState)
                VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET filename=excluded.filename,
                  filenameKey=excluded.filenameKey,deletedAt=NULL
                """, arguments: [localID, note.id, name, AttachmentFiles.fileSystemKey(name),
                                  Self.date(payload.createdAt), Self.date(payload.modifiedAt), note.isLocked ? "locked" : "pending"])
        }
        for download in downloads {
            let attachment = download.payload
            let attachmentID = copying ? Self.copyAttachmentID(attachment.id, noteID: note.id) : attachment.id
            let filename = destinationName(attachment)
            if let owner = try String.fetchOne(db, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [attachmentID]), owner != note.id { throw SyncApplyError.identityCollision }
            if let sameName = try String.fetchOne(db, sql: "SELECT id FROM attachment WHERE noteId=? AND filenameKey=?", arguments: [note.id, AttachmentFiles.fileSystemKey(filename)]), sameName != attachmentID { throw SyncApplyError.identityCollision }
            try db.execute(sql: """
                INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,uti,width,height,ocrText,ocrState,sha256,byteSize)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                  filename=excluded.filename,filenameKey=excluded.filenameKey,updatedAt=excluded.updatedAt,
                  uti=excluded.uti,width=excluded.width,height=excluded.height,ocrText=excluded.ocrText,
                  ocrState=excluded.ocrState,deletedAt=NULL,sha256=excluded.sha256,byteSize=excluded.byteSize,fileModifiedAt=NULL
                """, arguments: [attachmentID, note.id, filename, AttachmentFiles.fileSystemKey(filename),
                                  Self.date(attachment.createdAt), Self.date(attachment.updatedAt), note.isLocked ? nil : attachment.uti,
                                  note.isLocked ? nil : attachment.width, note.isLocked ? nil : attachment.height,
                                  note.isLocked ? nil : attachment.ocrText, note.isLocked ? "locked" : (attachment.ocrText == nil ? "pending" : "done"),
                                  note.isLocked ? nil : attachment.fileHash, note.isLocked ? nil : attachment.fileBytes])
            if !note.isLocked, attachment.ocrText != nil {
                try AttachmentTextStore.adoptRemoteOCR(attachmentID: attachmentID, staged: batch, filename: filename, in: db)
            }
            if !copying { try cacheDownloadedAttachment(download, in: db) }
            if copying || download.entity == nil {
                try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0", arguments: [attachmentID])
            }
        }
        if privacyChanged {
            let keep = Set(payload.attachmentIds.map { copying ? Self.copyAttachmentID($0, noteID: note.id) : $0 })
            for id in try String.fetchAll(db, sql: "SELECT id FROM attachment WHERE noteId=?", arguments: [note.id]) where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM attachment WHERE id=?", arguments: [id])
            }
        }
        try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
        if note.isLocked {
            try NoteIndexer.writeLockedTags(payload.directTags, noteId: note.id, in: db)
            try db.execute(sql: "DELETE FROM note_ui_state WHERE noteId=?", arguments: [note.id])
            try FocusPurge.purgeRemoteLock(noteId: note.id, in: db)
        } else if previous?.isLocked == true {
            try FocusPurge.purgeRemoteUnlock(noteId: note.id, in: db)
        }
        if privacyChanged || note.isLocked {
            let names = try String.fetchAll(db, sql: "SELECT filename FROM attachment WHERE noteId=?", arguments: [note.id])
            try db.execute(sql: "INSERT INTO privacy_transition(noteId,targetLocked,filenames) VALUES(?,?,?) ON CONFLICT(noteId) DO UPDATE SET targetLocked=excluded.targetLocked,filenames=excluded.filenames",
                           arguments: [note.id, note.isLocked, String(decoding: try JSONEncoder().encode(names), as: UTF8.self)])
        }
        try db.execute(sql: "DELETE FROM note_pin WHERE noteId=?", arguments: [note.id])
        for path in payload.pinnedTags {
            try db.execute(sql: "INSERT OR IGNORE INTO note_pin(noteId,tagId) SELECT ?,id FROM tag WHERE pathKey=?", arguments: [note.id, CanonicalKey.make(path)])
        }
        try Self.recordConflict(payload, in: db)
    }

    static func markNote(_ id: String, deleted: Bool, in db: Database) throws {
        try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('note',?,1,?) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=excluded.tombstone", arguments: [id, deleted])
    }
    static func recordConflict(_ note: SyncNotePayload, in db: Database) throws {
        if let conflict = note.conflict {
            try db.execute(sql: "INSERT INTO sync_conflict(noteId,originalNoteId,rejectedMutationId,remoteRevision) VALUES(?,?,?,?) ON CONFLICT(noteId) DO UPDATE SET originalNoteId=excluded.originalNoteId,rejectedMutationId=excluded.rejectedMutationId,remoteRevision=excluded.remoteRevision",
                           arguments: [note.id, conflict.originalNoteId, conflict.rejectedMutationId, conflict.remoteRevision])
        } else { try db.execute(sql: "DELETE FROM sync_conflict WHERE noteId=?", arguments: [note.id]) }
    }
    static func copyAttachmentID(_ id: String, noteID: String) -> String {
        // Privacy attachment manifests use UUID names. Deterministic copies must retain that
        // format so a later Lock Note operation can encrypt and reopen their files.
        SyncNoteMerge.conflictID(entityID: "attachment:" + id, mutationID: noteID, remoteRevision: 1)
    }
}
