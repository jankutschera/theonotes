// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Darwin
import Foundation
import GRDB
import OSLog

private let attachmentSyncLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "sync")

extension SyncMaterializer {
    func applyAttachment(_ entity: SyncEntity, value: SyncRemoteValue, ancestor: Data?, rejectedMutationID: String?, noteAccess: LockedNoteAccess?, base: SyncRemoteValue? = nil) async throws -> SyncApplyResult {
        let payload: SyncAttachmentPayload?
        switch value {
        case .attachment(let attachment): payload = attachment
        case .deleted: payload = nil
        default: throw SyncProtocolError.invalidPayload
        }
        // Keep the exact authenticated parent history across download; a pending remote note
        // is not evidence of this device's previous privacy state.
        let parentState = try await database.pool.read { db in
            (missing: try Note.fetchOne(db, key: payload?.noteId ?? "") == nil,
             wire: try Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType='note' AND entityId=?", arguments: [payload?.noteId ?? ""]))
        }
        var deletedParent: (wire: Data?, note: SyncNotePayload?, deleted: Bool)?
        if let payload, parentState.missing {
            var prior: SyncNotePayload?, acceptedDeletion = false
            if let wire = parentState.wire {
                do {
                    let previous = try JSONDecoder().decode(SyncEntity.self, from: wire)
                    guard previous.mutation.entityType == .note, previous.mutation.entityId == payload.noteId else { throw SyncProtocolError.invalidPayload }
                    switch try await reader.read(previous) {
                    case .note(let note) where note.id == payload.noteId && note.attachmentIds.contains(payload.id): prior = note
                    case .deleted: acceptedDeletion = true
                    default: break
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Unusable privacy history defaults to protected recovery. */ }
            }
            deletedParent = (parentState.wire, prior, acceptedDeletion)
        }
        let parentHistory = deletedParent
        if let payload, parentState.missing {
            guard try await database.pool.read({ db in
                try Self.hasDeletedParentRecoveryProof(entity, payload: payload, ancestor: ancestor, history: parentHistory, in: db)
            }) else { return .waitingForDependencies }
        }
        if let payload, parentState.missing, SyncDeletedRecoveryPolicy.sameFile(payload, as: base),
           try await database.pool.read({ db in
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)", arguments: [payload.id]) == true
           }) {
            return try await coordinatedCommit(scope: .note(payload.noteId)) {
                try commitAttachment(entity, download: nil, ancestor: ancestor, rejectedMutationID: rejectedMutationID,
                    noteAccess: noteAccess, deletedParent: parentHistory, base: base, unchangedPayload: payload)
            }
        }
        if let payload, rejectedMutationID != nil {
            let localLocked = try await database.pool.read {
                try Bool.fetchOne($0, sql: "SELECT isLocked FROM note WHERE id=?", arguments: [payload.noteId])
            }
            if let localLocked, localLocked != payload.isLocked {
                // Ordinary preparation skips immutable uploads; recovery needs any newer local generation too.
                let preparer = SyncAttachmentPreparer(database: database, paths: paths, accountID: reader.accountID, vaultKey: reader.vaultKey)
                do { _ = try await preparer.prepare(id: payload.id) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    let kind = String(describing: type(of: error))
                    attachmentSyncLogger.error("Attachment recovery preparation deferred (\(kind, privacy: .public))")
                    return .waitingForDependencies
                }
            }
        }
        let download: DownloadedAttachment?
        if let payload { download = DownloadedAttachment(entity: entity, payload: payload, cipher: try await preparedAttachmentCipher(payload)) }
        else { download = nil }
        do {
            return try await coordinatedCommit(scope: download.map { .note($0.payload.noteId) } ?? .unknown) {
                try commitAttachment(entity, download: download, ancestor: ancestor, rejectedMutationID: rejectedMutationID, noteAccess: noteAccess, deletedParent: parentHistory)
            }
        } catch SyncQueueError.snapshotUnavailable {
            try Task.checkCancellation()
            return .waitingForDependencies
        }
    }

    /// Proof before blob I/O is repeated by the committing writer; missing foreign keys
    /// alone are ordinary delivery ordering, never permanent-deletion evidence.
    private static func hasDeletedParentRecoveryProof(_ entity: SyncEntity, payload: SyncAttachmentPayload, ancestor: Data?,
        history: (wire: Data?, note: SyncNotePayload?, deleted: Bool)?, in db: Database) throws -> Bool {
        guard let history, try Self.shadow(entity, in: db) == ancestor else { return false }
        let noteTombstone = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [payload.noteId]) == true
        let attachmentTombstone = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=1)", arguments: [payload.id]) == true
        let acceptedAttachmentDeletion: Bool
        if let ancestor {
            let prior = try JSONDecoder().decode(SyncEntity.self, from: ancestor)
            acceptedAttachmentDeletion = prior.mutation.entityType == .attachment && prior.mutation.entityId == payload.id && prior.mutation.tombstone
        } else { acceptedAttachmentDeletion = false }
        return try (noteTombstone || history.deleted) && (attachmentTombstone || acceptedAttachmentDeletion)
            && Data.fetchOne(db, sql: "SELECT wireEntity FROM sync_shadow WHERE entityType='note' AND entityId=?", arguments: [payload.noteId]) == history.wire
            && Note.fetchOne(db, key: payload.noteId) == nil
            && Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [payload.id]) == false
    }

    func commitAttachment(_ entity: SyncEntity, download: DownloadedAttachment?, ancestor: Data?, rejectedMutationID: String?, noteAccess: LockedNoteAccess?, deletedParent: (wire: Data?, note: SyncNotePayload?, deleted: Bool)? = nil, base: SyncRemoteValue? = nil, unchangedPayload: SyncAttachmentPayload? = nil) throws -> SyncApplyResult {
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
            if let pending = try String.fetchOne(db, sql: "SELECT mutationId FROM sync_outbox WHERE entityType='attachment' AND localId=?", arguments: [id]), pending != rejectedMutationID { return .waitingForUpload }
            var dirty = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=?)", arguments: [id]) == true
            if let payload = unchangedPayload {
                guard dirty, SyncDeletedRecoveryPolicy.sameFile(payload, as: base) else { throw SyncApplyError.changedDuringDownload }
                // The shortcut is exclusively for a permanently deleted parent. A live
                // parent must use the ordinary ancestor/metadata merge (including join proof).
                guard try Note.fetchOne(db, key: payload.noteId) == nil,
                      try Self.hasDeletedParentRecoveryProof(entity, payload: payload, ancestor: ancestor, history: deletedParent, in: db)
                else { throw SyncApplyError.changedDuringDownload }
                try Self.finish(entity, localID: id, rejectedMutationID: rejectedMutationID, in: db)
                return .applied
            }
            if let download {
                let payload = download.payload
                if try Note.fetchOne(db, key: payload.noteId) == nil {
                    let noteTombstone = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [payload.noteId]) == true
                    guard let deletedParent,
                          try Self.hasDeletedParentRecoveryProof(entity, payload: payload, ancestor: ancestor, history: deletedParent, in: db)
                    else { return .waitingForDependencies }
                    let noVault = try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: false)
                    let locked = SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: deletedParent.note?.isLocked,
                        remoteLocked: payload.isLocked, unsentDeletion: noteTombstone, noVault: noVault)
                    let key: SymmetricKey?
                    if locked {
                        guard let noteAccess else {
                            try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                            return .waitingForUnlock
                        }
                        key = try noteAccess.journalKey()
                    } else { key = nil }
                    let mutation = rejectedMutationID ?? entity.mutation.mutationId
                    let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: mutation, remoteRevision: entity.revision)
                    try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                    if try Note.fetchOne(db, key: copyID) == nil {
                        let record: SyncNotePayload
                        if let key {
                            record = try privacyAttachmentConflict(payload, copyID: copyID, originalNoteID: payload.noteId,
                                mutationID: mutation, revision: entity.revision, key: key)
                        } else {
                            let copy = Note(id: copyID, text: "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: payload.filename) + "\n",
                                title: "Attachment conflict", titleKey: "attachment conflict", createdAt: .now, modifiedAt: .now)
                            record = SyncNotePayload(note: copy, directTags: [], pinnedTags: [], attachmentIds: [id],
                                conflict: SyncConflictInfo(originalNoteId: payload.noteId, rejectedMutationId: mutation, remoteRevision: entity.revision))
                        }
                        try writeNote(record, downloads: [download], copying: true, noteKey: key, files: files, staged: &staged, in: db)
                        try Self.markNote(copyID, deleted: false, in: db)
                    }
                    try Self.finish(entity, localID: id, rejectedMutationID: rejectedMutationID, in: db)
                    try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
                    return .applied
                }
                guard let note = try Note.fetchOne(db, key: payload.noteId),
                      try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)", arguments: [note.id, note.id]) == false else { return .waitingForDependencies }
                if note.isLocked != payload.isLocked {
                    guard rejectedMutationID != nil else { return .waitingForDependencies }
                    guard let noteAccess else {
                        try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence])
                        return .waitingForUnlock
                    }
                    let key = try noteAccess.journalKey()
                    guard let localName = try String.fetchOne(db, sql: "SELECT filename FROM attachment WHERE id=?", arguments: [id]) else { return .waitingForDependencies }
                    let localURL = files.directory(for: note.id).appendingPathComponent(localName)
                    let equal: Bool
                    do { equal = try sameAttachmentAcrossPrivacy(download, localURL: localURL, localName: localName, key: key) }
                    catch NotePrivacyError.attachmentTooLarge { equal = false }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        let kind = String(describing: type(of: error))
                        attachmentSyncLogger.error("Attachment privacy comparison deferred (\(kind, privacy: .public))")
                        throw SyncQueueError.snapshotUnavailable
                    }
                    try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                    if !equal {
                        let mutation = rejectedMutationID ?? entity.mutation.mutationId
                        let local: DownloadedAttachment
                        do { local = try localAttachmentRecovery(id: id, note: note, filename: localName, source: localURL, in: db) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            let kind = String(describing: type(of: error))
                            attachmentSyncLogger.error("Attachment local recovery deferred (\(kind, privacy: .public))")
                            // Throw through the writer so deferred recovery rolls back every staged change.
                            throw SyncQueueError.snapshotUnavailable
                        }
                        // A later note lock transition may replace the original file; keep both sides independently.
                        for (identity, recovery) in [(id, download), ("local:" + id, local)] {
                            let copyID = SyncNoteMerge.conflictID(entityID: identity, mutationID: mutation, remoteRevision: entity.revision)
                            if try Note.fetchOne(db, key: copyID) == nil {
                                let record = try privacyAttachmentConflict(recovery.payload, copyID: copyID, originalNoteID: note.id,
                                    mutationID: mutation, revision: entity.revision, key: key)
                                try writeNote(record, downloads: [recovery], copying: true, noteKey: key, files: files, staged: &staged, in: db)
                                try Self.markNote(copyID, deleted: false, in: db)
                            }
                        }
                    }
                    // Rebase only after equal content or durable, readable copies of both versions.
                    try Self.finish(entity, localID: id, rejectedMutationID: rejectedMutationID, in: db)
                    try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
                    return .applied
                }
                // Lock/unlock renames files and note links together; let the note bundle own it.
                if let oldName = try String.fetchOne(db, sql: "SELECT filename FROM attachment WHERE id=?", arguments: [id]), oldName != payload.filename { return .waitingForDependencies }
                if let owner = try String.fetchOne(db, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [id]), owner != note.id { throw SyncApplyError.identityCollision }
                if let sameName = try String.fetchOne(db, sql: "SELECT id FROM attachment WHERE noteId=? AND filenameKey=?", arguments: [note.id, AttachmentFiles.fileSystemKey(payload.filename)]), sameName != id { throw SyncApplyError.identityCollision }
                let localURL = files.directory(for: note.id).appendingPathComponent(payload.filename)
                var redundantGeneration: Int64?
                if dirty, let rejectedMutationID, let ancestor {
                    do {
                        try Task.checkCancellation()
                        redundantGeneration = try unchangedRejectedAttachment(id: id, ancestor: ancestor,
                            rejectedMutationID: rejectedMutationID, in: db)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        let kind = String(describing: type(of: error))
                        Logger(subsystem: "com.truebrewbirdie.baerchen", category: "sync").error("Attachment ancestor proof unavailable (\(kind, privacy: .public))")
                    }
                }
                if let generation = redundantGeneration {
                    // A definitive rejection permits replacing only the unchanged ancestor generation.
                    try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='attachment' AND localId=? AND generation=? AND tombstone=0",
                        arguments: [id, generation])
                    guard db.changesCount == 1 else { throw SyncApplyError.changedDuringDownload }
                    dirty = false
                }
                let sameBytes = dirty && (try? SyncAttachmentPreparer.hashFile(localURL).hash) == payload.fileHash
                var noteKey: SymmetricKey?
                if dirty && payload.isLocked && !sameBytes {
                    guard let noteAccess else {
                        try db.execute(sql: "UPDATE sync_inbox SET waitingForUnlock=1 WHERE sequence=?", arguments: [entity.sequence]); return .waitingForUnlock
                    }
                    noteKey = try noteAccess.journalKey()
                }
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                if dirty {
                    if !sameBytes {
                        // An attachment has no text merge. Preserve its remote bytes in a
                        // deterministic conflict note; the local file stays at its original ID.
                        let mutation = rejectedMutationID ?? entity.mutation.mutationId
                        let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: mutation, remoteRevision: entity.revision)
                        if try Note.fetchOne(db, key: copyID) == nil {
                            let text = "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: payload.filename) + "\n"
                            let copy = Note(id: copyID, text: text, title: "Attachment conflict", titleKey: "attachment conflict", createdAt: .now, modifiedAt: .now)
                            let info = SyncConflictInfo(originalNoteId: note.id, rejectedMutationId: mutation, remoteRevision: entity.revision)
                            let record: SyncNotePayload
                            if let noteKey {
                                guard let protected = try SyncNotePayload.capture(id: note.id, includeRetained: true, in: db) else { throw SyncProtocolError.invalidPayload }
                                record = try SyncLockedNoteMerge.attachmentConflict(note: protected, attachmentID: id, copyID: copyID, info: info, key: noteKey)
                            } else { record = SyncNotePayload(note: copy, directTags: [], pinnedTags: [], attachmentIds: [id], conflict: info) }
                            try writeNote(record, downloads: [download], copying: true, noteKey: noteKey, files: files, staged: &staged, in: db)
                            try Self.markNote(copyID, deleted: false, in: db)
                        }
                    }
                } else {
                    let batch = try files.stageTransformed([payload.filename], noteId: note.id) { _, output in
                        try reader.writeAttachment(payload, cipher: download.cipher, to: output)
                    }
                    staged.append(batch)
                    try AttachmentFiles.record(batch, in: db)
                    // Restore verified received metadata after staging resets derived facts.
                    // Identical OCR completion must not manufacture a new authored edit.
                    try db.execute(sql: """
                        INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,uti,width,height,ocrText,ocrState,sha256,byteSize)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                          updatedAt=excluded.updatedAt,uti=excluded.uti,width=excluded.width,height=excluded.height,
                          ocrText=excluded.ocrText,ocrState=excluded.ocrState,deletedAt=NULL,
                          sha256=excluded.sha256,byteSize=excluded.byteSize,fileModifiedAt=NULL
                        """, arguments: [id, note.id, payload.filename, AttachmentFiles.fileSystemKey(payload.filename),
                                          Self.date(payload.createdAt), Self.date(payload.updatedAt), payload.uti, payload.width,
                                          payload.height, payload.ocrText, payload.isLocked ? "locked" : (payload.ocrText == nil ? "pending" : "done"),
                                          payload.isLocked ? nil : payload.fileHash, payload.isLocked ? nil : payload.fileBytes])
                    if !payload.isLocked, payload.ocrText != nil {
                        try AttachmentTextStore.adoptRemoteOCR(attachmentID: id, staged: batch, filename: payload.filename, in: db)
                    }
                    try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
                    try cacheDownloadedAttachment(download, in: db)
                }
            } else {
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                if !dirty {
                    // Keep file bytes until the note no longer references them and the normal
                    // orphan collector runs. A tombstone alone must not break an open editor.
                    try db.execute(sql: "UPDATE attachment SET deletedAt=? WHERE id=?", arguments: [Date(), id])
                }
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

    private func unchangedRejectedAttachment(id: String, ancestor: Data, rejectedMutationID: String,
                                             in db: Database) throws -> Int64? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT a.*,n.isLocked,d.generation,o.wireMutation,c.fingerprint,s.serverRevision
            FROM attachment a JOIN note n ON n.id=a.noteId
            JOIN sync_dirty d ON d.entityType='attachment' AND d.localId=a.id AND d.tombstone=0
            JOIN sync_outbox o ON o.entityType=d.entityType AND o.localId=d.localId AND o.generation=d.generation
            JOIN sync_attachment_cache c ON c.attachmentId=a.id AND c.generation=d.generation
            JOIN sync_entity_state s ON s.entityType=d.entityType AND s.localId=a.id AND s.entityId=a.id
            WHERE a.id=? AND o.mutationId=? AND a.deletedAt IS NULL
            """, arguments: [id, rejectedMutationID]) else { return nil }
        let previous = try JSONDecoder().decode(SyncEntity.self, from: ancestor)
        let queued = try JSONDecoder().decode(SyncMutation.self, from: row["wireMutation"])
        guard queued.mutationId == rejectedMutationID, queued.entityType == .attachment,
              queued.entityId == id, previous.mutation.entityType == .attachment,
              previous.mutation.entityId == id, previous.revision == queued.parentRevision,
              previous.revision == row["serverRevision"] as Int64,
              try Bool.fetchOne(db, sql: "SELECT enabled FROM sync_control WHERE id=1") == true else { return nil }
        // shortcut: blob-backed descriptors retain ordinary conflict recovery; add async proof if needed.
        func open(_ mutation: SyncMutation) throws -> Data? {
            try mutation.validate()
            guard !mutation.tombstone, let inline = mutation.ciphertext else { return nil }
            return try NoteCipher.open(SyncWire.decode64(inline), vaultKey: reader.vaultKey,
                context: SyncWire.cipherContext(accountID: reader.accountID, type: .attachment, entityID: id))
        }
        guard let baseBytes = try open(previous.mutation), let queuedBytes = try open(queued) else { return nil }
        let descriptor = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: queuedBytes)
        let base = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: baseBytes)
        try descriptor.validate(); try base.validate()
        guard queued.blobRefs.contains(descriptor.blobHash), previous.mutation.blobRefs.contains(base.blobHash) else { return nil }
        let current = SyncAttachmentPayload(id: id, noteId: row["noteId"], filename: row["filename"],
            isLocked: row["isLocked"], blobHash: descriptor.blobHash, cipherBytes: descriptor.cipherBytes,
            fileBytes: descriptor.fileBytes, fileHash: descriptor.fileHash, uti: row["uti"],
            width: row["width"], height: row["height"], ocrText: row["ocrText"],
            createdAt: SyncNotePayload.milliseconds(row["createdAt"] as Date),
            updatedAt: SyncNotePayload.milliseconds(row["updatedAt"] as Date))
        func semantic(_ data: Data, excludingDerived: Bool = false) throws -> Data {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncProtocolError.invalidPayload }
            object.removeValue(forKey: "blobHash"); object.removeValue(forKey: "cipherBytes")
            if excludingDerived {
                // OCR and measured facts do not turn an unchanged join copy into a file edit.
                for key in ["ocrText", "updatedAt", "uti", "width", "height"] { object.removeValue(forKey: key) }
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let expected = try semantic(queuedBytes)
        guard try semantic(baseBytes, excludingDerived: true) == semantic(queuedBytes, excludingDerived: true),
              try semantic(SyncPayloadCodec.encoder().encode(current)) == expected else { return nil }
        // Hash the current no-follow source, and bind it to the exact file staged for this generation.
        try SyncWire.validateID(current.noteId); try AttachmentFiles.validate(current.filename)
        let root = Darwin.open(paths.attachments.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }; defer { close(root) }
        let directory = openat(root, current.noteId, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }; defer { close(directory) }
        let fd = openat(directory, current.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        func fingerprint(_ fd: Int32) -> String? {
            var facts = stat()
            guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG else { return nil }
            return "\(facts.st_dev):\(facts.st_ino):\(facts.st_size):\(facts.st_mtimespec.tv_sec):\(facts.st_mtimespec.tv_nsec):\(facts.st_ctimespec.tv_sec):\(facts.st_ctimespec.tv_nsec)"
        }
        guard let before = fingerprint(fd), before == row["fingerprint"] as String else { return nil }
        var hash = SHA256(), size: Int64 = 0
        while let chunk = try file.read(upToCount: ChunkedCipher.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk); size += Int64(chunk.count)
        }
        let reopened = openat(directory, current.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard reopened >= 0 else { return nil }; defer { close(reopened) }
        guard fingerprint(fd) == before, fingerprint(reopened) == before,
              size == descriptor.fileBytes,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == descriptor.fileHash else { return nil }
        return row["generation"]
    }

    private func localAttachmentRecovery(id: String, note: Note, filename: String, source: URL,
                                         in db: Database) throws -> DownloadedAttachment {
        guard let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=0", arguments: [id]) else { throw SyncQueueError.snapshotUnavailable }
        let content = try SyncAttachmentPreparer.capture(SyncDirty(type: .attachment, localID: id, generation: generation, tombstone: false),
            accountID: reader.accountID, vaultKey: reader.vaultKey, in: db)
        guard let bytes = content.payload else { throw SyncQueueError.snapshotUnavailable }
        let payload = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: bytes)
        let measured = try SyncAttachmentPreparer.hashFile(source)
        guard payload.noteId == note.id, payload.filename == filename, payload.isLocked == note.isLocked,
              payload.fileHash == measured.hash, payload.fileBytes == measured.size,
              let stored = try String.fetchOne(db, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [payload.blobHash]) else { throw SyncQueueError.snapshotUnavailable }
        let cipher = try SyncBlobLocation.verified(stored, paths: paths, hash: payload.blobHash, size: payload.cipherBytes).url
        return DownloadedAttachment(entity: nil, payload: payload, cipher: cipher)
    }

    private func sameAttachmentAcrossPrivacy(_ download: DownloadedAttachment, localURL: URL,
                                             localName: String, key: SymmetricKey) throws -> Bool {
        // shortcut: above 16 MiB preserve a conflict copy; use streaming comparison to avoid large equal-file copies.
        let maximumBytes = 16 * 1024 * 1024
        if !download.payload.isLocked {
            let local = try ChunkedCipher.decrypt(input: localURL, keyEncryptionKey: key,
                context: localName, maximumBytes: maximumBytes)
            return SyncWire.hash(local) == download.payload.fileHash
        }
        // Only inner ciphertext reaches disk; decrypted protected content stays in memory.
        let inner = paths.root.appendingPathComponent("privacy-compare-" + UUID().uuidString + ".bch")
        defer { try? FileManager.default.removeItem(at: inner) }
        try reader.writeAttachment(download.payload, cipher: download.cipher, to: inner)
        let remote = try ChunkedCipher.decrypt(input: inner, keyEncryptionKey: key,
            context: download.payload.filename, maximumBytes: maximumBytes)
        return SyncWire.hash(remote) == (try SyncAttachmentPreparer.hashFile(localURL).hash)
    }

    private func privacyAttachmentConflict(_ attachment: SyncAttachmentPayload, copyID: String,
                                           originalNoteID: String, mutationID: String, revision: Int64,
                                           key: SymmetricKey) throws -> SyncNotePayload {
        let name = attachment.isLocked ? "Attachment" : attachment.filename
        let text = "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: name) + "\n"
        // A privacy mismatch means at least one side is protected. Both recovery copies
        // inherit that stronger privacy state, including the formerly plaintext bytes.
        let assetID = Self.copyAttachmentID(attachment.id, noteID: copyID)
        let body = LockedNotePayload(text: text, attachments: [name: assetID + ".bch"], attachmentIDs: [name: assetID])
        let note = Note(id: copyID, text: "", title: "Attachment conflict", titleKey: "attachment conflict",
            createdAt: .now, modifiedAt: .now, isLocked: true,
            encryptedPayload: try NoteCipher.seal(JSONEncoder().encode(body), vaultKey: key, context: copyID))
        let info = SyncConflictInfo(originalNoteId: originalNoteID, rejectedMutationId: mutationID, remoteRevision: revision)
        var result = SyncNotePayload(note: note, directTags: [], pinnedTags: [], attachmentIds: [attachment.id], conflict: info)
        result.attachmentNames = [attachment.id: attachment.filename]
        return result
    }

}
