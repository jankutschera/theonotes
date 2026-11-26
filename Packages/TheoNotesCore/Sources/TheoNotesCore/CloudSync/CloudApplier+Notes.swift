// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

// Copies (class c of the E0 record) of `applyNote`, `commitNoteTransaction`, `applyAttachment` and `commitAttachment`. Everything
// that touches the library is the reused code; the shadow, inbox and outbox parts became the `CloudApplyInput` seam.
extension CloudApplier {
    // MARK: notes

    func applyNote(_ input: CloudApplyInput, commit: @escaping CloudApplyCommit) async throws -> CloudApplyOutcome {
        let remote: SyncNotePayload?
        switch input.value { case .note(let note): remote = note; case .deleted: remote = nil; default: throw SyncProtocolError.invalidPayload }
        let old: SyncNotePayload?
        switch input.base { case .note(let note): old = note; case nil, .deleted: old = nil; default: throw SyncProtocolError.invalidPayload }
        // A note and all its referenced files become visible together. Descriptors can precede their parent note,
        // because attachment foreign keys prevent early inserts.
        let (downloads, blocked) = try await downloads(for: remote, noteID: input.version.entityId, input: input)
        if blocked { return .waitingForDependencies }
        return try await coordinated(scope: .note(input.version.entityId)) { try commitNote(input, remote: remote, old: old, downloads: downloads, commit: commit) }
    }

    /// First contact with a starter note: the shipped versions are `shipped`, oldest first. A side that equals one of them
    /// was never edited. The older of the two shipped versions is the base when both are untouched (the newer one wins, as an edit
    /// of the older would); the untouched side's version when only one is (it follows the other side, deletion included); and the
    /// oldest shipped version when neither is (an edit on both sides: the three-way rules as before, possibly one conflict copy).
    static func startingBase(shipped: [SyncNotePayload], local: SyncNotePayload?, remote: SyncNotePayload?) -> SyncNotePayload? {
        let l = local.flatMap { note in shipped.firstIndex { SyncNoteMerge.identical(note, $0) } }
        let r = remote.flatMap { note in shipped.firstIndex { SyncNoteMerge.identical(note, $0) } }
        switch (l, r) {
        case let (l?, r?): return shipped[min(l, r)]
        case let (l?, nil): return shipped[l]
        case let (nil, r?): return shipped[r]
        case (nil, nil): return shipped.first
        }
    }

    func commitNote(_ input: CloudApplyInput, remote: SyncNotePayload?, old: SyncNotePayload?, downloads: [CloudDownload],
                    commit: @escaping CloudApplyCommit) throws -> CloudApplyOutcome {
        let id = input.version.entityId
        let files = AttachmentFiles(paths: paths, database: database)
        let scratch = CloudApplyScratch()
        defer { if !scratch.committed { for batch in scratch.staged { files.discard(batch) } } }
        let materialized = downloads.map(\.materialized)
        do {
            try commit { db in
                try input.precondition(db)
                try requireAccount(db)
                let journal = paths.journal.appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: journal.path),
                   (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 { throw CloudApplyWait(outcome: .waitingForDependencies) }
                LockTestHooks.runAfterRemoteJournalCheck(id)
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)",
                                        arguments: [id, id]) == false else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                if remote?.isLocked == true {
                    guard try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1") != nil, !input.lockEnvelopeWaiting else {
                        throw CloudApplyWait(outcome: .waitingForUnlock)
                    }
                }
                let local = try SyncNotePayload.capture(id: id, includeRetained: true, in: db)
                let dirty = try Self.isDirty("note", id, in: db)
                let unsentDeletion = try local == nil && (Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [id]) == true)
                let noVault = try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true)
                // The base: the version this device holds a base pair for, or on first contact the shipped version a side is still at.
                let startBase = input.firstContact && !input.shipped.isEmpty ? Self.startingBase(shipped: input.shipped, local: local, remote: remote) : old
                var merged: SyncNoteMergeResult
                var noteKey: SymmetricKey?
                // Before the first sync, existing local notes are still meaningful edits (empty base).
                if input.locallyDeleted, local == nil, let remote, let startBase, SyncNoteMerge.identical(remote, startBase) {
                    // Deleted here before the first binding and untouched in the cloud since the shipped text: the deletion stands (and is
                    // published as a tombstone below). A cloud version that someone edited is not this case: the edit wins.
                    merged = .merged(nil)
                } else if dirty || ((!input.hasBase || input.firstContact) && local != nil) {
                    merged = try SyncNoteMerge.reconcile(base: startBase, local: local, remote: remote, entityID: id,
                                                         rejectedMutationID: input.mergeIdentity.mutationID, remoteRevision: input.mergeIdentity.revision)
                } else { merged = .merged(remote) }
                if local == nil, startBase == nil, let remote, unsentDeletion {
                    let protect = SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: nil, remoteLocked: remote.isLocked, unsentDeletion: true, noVault: noVault)
                    let key: SymmetricKey?
                    if protect {
                        guard let access = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                        key = try access.journalKey()
                    } else { key = nil }
                    merged = try SyncLockedNoteMerge.deletedUnknownParentConflict(remote: remote, entityID: id,
                        mutationID: input.mergeIdentity.mutationID, revision: input.mergeIdentity.revision, key: key, sourceNames: Dictionary(uniqueKeysWithValues: downloads.map { ($0.payload.id, $0.payload.filename) }))
                    noteKey = key
                }
                if case .needsUnlock = merged, let noteAccess = input.noteAccess {
                    let key = try noteAccess.journalKey()
                    merged = try SyncLockedNoteMerge.reconcile(base: startBase, local: local, remote: remote, entityID: id,
                                                               mutationID: input.mergeIdentity.mutationID, revision: input.mergeIdentity.revision, key: key)
                    noteKey = key
                }
                if case .needsUnlock = merged { throw CloudApplyWait(outcome: .waitingForUnlock) }
                if case .merged(let note) = merged, let note, let local, local.isLocked != note.isLocked {
                    let ready = downloads.filter { note.attachmentIds.contains($0.payload.id) && $0.payload.isLocked == note.isLocked &&
                        (note.attachmentNames == nil || note.attachmentNames?[$0.payload.id] == $0.payload.filename) }
                    if ready.count < note.attachmentIds.count { throw CloudApplyWait(outcome: .waitingForDependencies) }
                }
                if local == nil, SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: startBase?.isLocked,
                    remoteLocked: remote?.isLocked == true, unsentDeletion: unsentDeletion, noVault: noVault),
                   case .conflict(let kept, let copy) = merged, let copy, !copy.isLocked {
                    guard let access = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                    let key = try access.journalKey()
                    merged = .conflict(local: kept, remoteCopy: try SyncLockedNoteMerge.protectDeletedRecovery(copy, key: key, sourceNames: Dictionary(uniqueKeysWithValues: downloads.map { ($0.payload.id, $0.payload.filename) })))
                    noteKey = key
                }
                // A permanently deleted local note cannot upload a surviving attachment first:
                // the file is intentionally gone. Follow the existing delete-vs-edit result ONLY
                // when it durably recovers the complete remote note, rather than resurrecting or
                // overwriting local data. The copy and exact sibling version commit together below.
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
                // Do not overwrite a concurrently changing attachment: its snapshot must first be saved or merged. And a sibling
                // that is no longer the newest version of its entity is not applied (the version check for downloads).
                for download in downloads {
                    if try Self.isDirty("attachment", download.payload.id, in: db) {
                        let attachmentID = download.payload.id
                        guard deletedNoteRecoveryIDs.contains(attachmentID),
                              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [attachmentID]) == false,
                              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=1)", arguments: [attachmentID]) == true
                        else { throw CloudApplyWait(outcome: .waitingForUpload) }
                    }
                    if let sibling = download.sibling, sibling.pending, let siblingId = download.siblingId,
                       try !input.siblingStillCurrent(db, .attachment, siblingId, sibling) { throw CloudApplyRetry(reason: "attachment-moved") }
                }
                try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                var consumable: [CloudDownload] = downloads
                switch merged {
                case .merged(let note):
                    if let note {
                        // A file of an independent incarnation that differs from the local one is not installed over it: the local
                        // bytes stay (marked dirty below) and the version stays pending, so the attachment's own apply keeps the
                        // remote bytes in an attachment-conflict note.
                        let selected = downloads.filter { download in
                            note.attachmentIds.contains(download.payload.id) && download.payload.isLocked == note.isLocked &&
                                (note.attachmentNames == nil || note.attachmentNames?[download.payload.id] == download.payload.filename) &&
                                !(download.sibling?.independent == true && localAttachmentDiffers(download.payload, noteId: id))
                        }
                        consumable = selected
                        try materializer.writeNote(note, downloads: selected.map(\.materialized), copying: false, noteKey: noteKey,
                                                   files: files, staged: &scratch.staged, in: db)
                        // `writeNote` reads "no cloud entity" as "this file arrived only as a pinned snapshot: publish it again".
                        // A file applied from its own cloud entity is not new local work (E0 5.4).
                        for download in selected where download.sibling != nil {
                            try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='attachment' AND localId=?", arguments: [download.payload.id])
                        }
                        for skipped in downloads where !selected.contains(where: { $0.payload.id == skipped.payload.id }) {
                            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [skipped.payload.id]) == true {
                                try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0",
                                               arguments: [skipped.payload.id])
                            }
                        }
                    } else {
                        // A remote tombstone must not destroy the last local recovery copy: the complete note and its file
                        // references go to Trash. That local state is deliberately not echoed (E0 section 5.3).
                        try db.execute(sql: "UPDATE note SET location='trash', trashedAt=?, revision=revision+1 WHERE id=? AND location!='trash'",
                                       arguments: [NoteStore.roundedToMillis(.now), id])
                    }
                    // The merge's own equality (E0 5.1): a collapsed identical copy is not an edit and is not republished.
                    if !SyncNoteMerge.identical(note, remote) { try SyncMaterializer.markNote(id, deleted: note == nil, in: db) }
                    else { try db.execute(sql: "DELETE FROM sync_dirty WHERE entityType='note' AND localId=?", arguments: [id]) }
                case .conflict(let mine, let copy):
                    // The original keeps local content. A deterministic copy preserves the entire remote document and clones
                    // attachment identities into that copy's namespace.
                    if let mine { try SyncMaterializer.recordConflict(mine, in: db) }
                    if let copy, try Note.fetchOne(db, key: copy.id) == nil {
                        try materializer.writeNote(copy, downloads: materialized, copying: true, noteKey: noteKey, files: files, staged: &scratch.staged, in: db)
                        try SyncMaterializer.markNote(copy.id, deleted: false, in: db)
                    }
                    for download in downloads {
                        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [download.payload.id]) == true {
                            try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1",
                                           arguments: [download.payload.id])
                        }
                    }
                    try SyncMaterializer.markNote(id, deleted: mine == nil, in: db)
                case .needsUnlock: preconditionFailure("handled before mutation")
                }
                for download in downloads where download.sibling != nil {
                    try Self.markEntity(type: .attachment, localID: download.payload.id, entityID: download.payload.id, in: db)
                }
                // The attachment versions this note consumed advance with it, in this transaction, by the exact version downloaded.
                try input.consumeSiblings(db, consumable.compactMap { download in
                    guard let sibling = download.sibling, sibling.pending, let id = download.siblingId else { return nil }
                    return (id: id, sibling: sibling)
                })
                try Self.markEntity(type: .note, localID: id, entityID: id, in: db)
                try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            }
        } catch let wait as CloudApplyWait {
            return wait.outcome
        } catch SyncQueueError.snapshotUnavailable {
            return .waitingForDependencies
        } catch SyncApplyError.waitingForCapture {
            // A voice capture still holds text in this note's journal: the note waits, the pass goes on.
            return .waitingForDependencies
        }
        scratch.committed = true
        for batch in scratch.staged { files.install(batch) }
        try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).finishPendingCleanup()
        ChangeNotifier().post()
        return .applied(consumed: [])
    }

    /// A local file of the attachment exists and its bytes are not the ones the payload describes.
    func localAttachmentDiffers(_ payload: SyncAttachmentPayload, noteId: String) -> Bool {
        let url = AttachmentFiles(paths: paths, database: database).directory(for: noteId).appendingPathComponent(payload.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? SyncAttachmentPreparer.hashFile(url).hash) != payload.fileHash
    }

    // MARK: attachments

    func applyAttachment(_ input: CloudApplyInput, commit: @escaping CloudApplyCommit) async throws -> CloudApplyOutcome {
        let download: CloudDownload?
        var parentHistory: CloudSibling?
        switch input.value {
        case .attachment(let payload):
            // Nothing is downloaded for a file whose note is not here yet.
            let parent = try await database.pool.read { try Note.fetchOne($0, key: payload.noteId) }
            if parent == nil {
                parentHistory = input.parentHistory(payload.noteId)
                let history = parentHistory
                guard try await database.pool.read({ db in
                    try Self.hasDeletedParentRecoveryProof(input, payload: payload, history: history, in: db)
                }) else { return .waitingForDependencies }
            }
            if parent == nil, SyncDeletedRecoveryPolicy.sameFile(payload, as: input.base),
               try await database.pool.read({ db in try Self.isDirty("attachment", payload.id, in: db) }) {
                let history = parentHistory
                return try await coordinated(scope: .note(payload.noteId)) {
                    try commitAttachment(input, download: nil, commit: commit, parentHistory: history, unchangedPayload: payload)
                }
            }
            if let parent, input.mergingInflight, parent.isLocked != payload.isLocked {
                // An immutable upload can precede a newer offline edit. Recovery must snapshot
                // that current generation before entering the coordinated writer transaction.
                do {
                    _ = try await SyncAttachmentPreparer(database: database, paths: paths,
                        accountID: accountID, vaultKey: vaultKey).prepare(id: payload.id)
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); return .waitingForDependencies }
            }
            guard let cipher = try await localCipher(payload) else { return .waitingForDependencies }
            download = CloudDownload(sibling: nil, siblingId: nil, payload: payload, cipher: cipher)
        case .deleted: download = nil
        default: throw SyncProtocolError.invalidPayload
        }
        let history = parentHistory
        return try await coordinated(scope: download.map { .note($0.payload.noteId) } ?? .unknown) { try commitAttachment(input, download: download, commit: commit, parentHistory: history) }
    }

    /// Checked before asset I/O and again in the committing writer. An ordinary missing
    /// parent is delivery ordering, not evidence of deletion and never triggers downloads.
    private static func hasDeletedParentRecoveryProof(_ input: CloudApplyInput, payload: SyncAttachmentPayload,
                                                     history: CloudSibling?, in db: Database) throws -> Bool {
        let acceptedParentDeletion: Bool
        if let history, !history.privacyUnknown, case .deleted = history.value { acceptedParentDeletion = true }
        else { acceptedParentDeletion = false }
        let acceptedAttachmentDeletion: Bool
        if input.hasBase, case .deleted = input.base { acceptedAttachmentDeletion = true }
        else { acceptedAttachmentDeletion = false }
        let noteTombstone = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [payload.noteId]) == true
        let attachmentTombstone = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=1)", arguments: [payload.id]) == true
        return try (noteTombstone || acceptedParentDeletion) && (attachmentTombstone || acceptedAttachmentDeletion)
            && (try input.parentHistoryStillCurrent(db, payload.noteId, history))
            && (try Note.fetchOne(db, key: payload.noteId)) == nil
            && (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [payload.id])) == false
    }

    func commitAttachment(_ input: CloudApplyInput, download: CloudDownload?, commit: @escaping CloudApplyCommit, parentHistory: CloudSibling? = nil, unchangedPayload: SyncAttachmentPayload? = nil) throws -> CloudApplyOutcome {
        let id = input.version.entityId
        let files = AttachmentFiles(paths: paths, database: database)
        let scratch = CloudApplyScratch()
        defer { if !scratch.committed { for batch in scratch.staged { files.discard(batch) } } }
        do {
            try commit { db in
                try input.precondition(db)
                try requireAccount(db)
                var dirty = try Self.isDirty("attachment", id, in: db)
                if let payload = unchangedPayload {
                    guard dirty, SyncDeletedRecoveryPolicy.sameFile(payload, as: input.base) else { throw CloudApplyRetry(reason: "attachment-dirty-moved") }
                    // A restored/live parent needs ordinary derived-metadata reconciliation;
                    // the no-copy shortcut applies only to positive permanent deletion.
                    guard try Note.fetchOne(db, key: payload.noteId) == nil,
                          try Self.hasDeletedParentRecoveryProof(input, payload: payload, history: parentHistory, in: db)
                    else { throw CloudApplyRetry(reason: "attachment-parent-restored") }
                    try Self.markEntity(type: .attachment, localID: id, entityID: id, in: db)
                    return
                }
                if let download {
                    let payload = download.payload
                    if try Note.fetchOne(db, key: payload.noteId) == nil {
                        guard try Self.hasDeletedParentRecoveryProof(input, payload: payload, history: parentHistory, in: db)
                        else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                        let key: SymmetricKey?
                        let priorLock: Bool?
                        if let parentHistory, case .note(let parent) = parentHistory.value,
                           parent.id == payload.noteId, parent.attachmentIds.contains(id) { priorLock = parent.isLocked }
                        else { priorLock = nil }
                        let unsent = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_dirty WHERE entityType='note' AND localId=? AND tombstone=1)", arguments: [payload.noteId]) == true
                        let noVault = try SyncDeletedRecoveryPolicy.hasNoVaultOrPendingVault(in: db, cloud: true)
                        if SyncDeletedRecoveryPolicy.requiresProtection(priorLocked: priorLock, remoteLocked: payload.isLocked, unsentDeletion: unsent, noVault: noVault) {
                            guard let access = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                            key = try access.journalKey()
                        } else { key = nil }
                        let identity = input.mergeIdentity
                        let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: identity.mutationID, remoteRevision: identity.revision)
                        try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                        if try Note.fetchOne(db, key: copyID) == nil {
                            let record: SyncNotePayload
                            if let key {
                                record = try cloudPrivacyAttachmentConflict(payload, copyID: copyID, originalNoteID: payload.noteId,
                                    mutationID: identity.mutationID, revision: identity.revision, key: key)
                            } else {
                                let copy = Note(id: copyID, text: "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: payload.filename) + "\n",
                                    title: "Attachment conflict", titleKey: "attachment conflict", createdAt: .now, modifiedAt: .now)
                                record = SyncNotePayload(note: copy, directTags: [], pinnedTags: [], attachmentIds: [id],
                                    conflict: SyncConflictInfo(originalNoteId: payload.noteId, rejectedMutationId: identity.mutationID, remoteRevision: identity.revision))
                            }
                            try materializer.writeNote(record, downloads: [download.materialized], copying: true, noteKey: key,
                                files: files, staged: &scratch.staged, in: db)
                            try SyncMaterializer.markNote(copyID, deleted: false, in: db)
                        }
                        try Self.markEntity(type: .attachment, localID: id, entityID: id, in: db)
                        try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
                        return
                    }
                    guard let note = try Note.fetchOne(db, key: payload.noteId),
                          try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?) OR EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?)",
                                            arguments: [note.id, note.id]) == false else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                    if note.isLocked != payload.isLocked {
                        // The note bundle owns the privacy transition. Before acknowledging an
                        // incompatible attachment snapshot, preserve independently recoverable copies
                        // of BOTH versions: a later note apply may replace the original file.
                        guard input.mergingInflight else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                        guard let access = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                        let key = try access.journalKey()
                        guard let localName = try String.fetchOne(db, sql: "SELECT filename FROM attachment WHERE id=? AND noteId=?",
                            arguments: [id, note.id]) else { throw CloudApplyWait(outcome: .waitingForDependencies) }
                        let localURL = files.directory(for: note.id).appendingPathComponent(localName)
                        let equal: Bool
                        do { equal = try cloudSameAttachmentAcrossPrivacy(download, localURL: localURL, localName: localName, key: key) }
                        catch NotePrivacyError.attachmentTooLarge { equal = false }
                        catch is CancellationError { throw CancellationError() }
                        catch { try Task.checkCancellation(); throw SyncQueueError.snapshotUnavailable }
                        try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                        if !equal {
                            let local: CloudDownload
                            do { local = try cloudLocalAttachmentRecovery(id: id, note: note, filename: localName, source: localURL, in: db) }
                            catch is CancellationError { throw CancellationError() }
                            catch { try Task.checkCancellation(); throw SyncQueueError.snapshotUnavailable }
                            for (identity, recovery) in [(id, download), ("local:" + id, local)] {
                                let copyID = SyncNoteMerge.conflictID(entityID: identity,
                                    mutationID: input.mergeIdentity.mutationID, remoteRevision: input.mergeIdentity.revision)
                                if try Note.fetchOne(db, key: copyID) == nil {
                                    let record = try cloudPrivacyAttachmentConflict(recovery.payload, copyID: copyID,
                                        originalNoteID: note.id, mutationID: input.mergeIdentity.mutationID,
                                        revision: input.mergeIdentity.revision, key: key)
                                    try materializer.writeNote(record, downloads: [recovery.materialized], copying: true,
                                        noteKey: key, files: files, staged: &scratch.staged, in: db)
                                    try SyncMaterializer.markNote(copyID, deleted: false, in: db)
                                }
                            }
                        }
                        try Self.markEntity(type: .attachment, localID: id, entityID: id, in: db)
                        try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
                        return
                    }
                    // Lock/unlock renames files and note links together; let the note bundle own it.
                    if let oldName = try String.fetchOne(db, sql: "SELECT filename FROM attachment WHERE id=?", arguments: [id]), oldName != payload.filename {
                        throw CloudApplyWait(outcome: .waitingForDependencies)
                    }
                    if let owner = try String.fetchOne(db, sql: "SELECT noteId FROM attachment WHERE id=?", arguments: [id]), owner != note.id { throw SyncApplyError.identityCollision }
                    if let sameName = try String.fetchOne(db, sql: "SELECT id FROM attachment WHERE noteId=? AND filenameKey=?",
                                                          arguments: [note.id, AttachmentFiles.fileSystemKey(payload.filename)]), sameName != id { throw SyncApplyError.identityCollision }
                    let localURL = files.directory(for: note.id).appendingPathComponent(payload.filename)
                    // Across independent incarnations the local bytes stay, whatever they are: the attachment is treated
                    // as having a local edit, so the existing path keeps the remote bytes in an attachment-conflict note and the
                    // local file is published again.
                    if input.independent, !dirty, localAttachmentDiffers(payload, noteId: note.id) {
                        dirty = true
                        try db.execute(sql: "INSERT INTO sync_dirty(entityType,localId,generation,tombstone) VALUES('attachment',?,1,0) ON CONFLICT(entityType,localId) DO UPDATE SET generation=generation+1,tombstone=0",
                                       arguments: [id])
                    }
                    let sameBytes = dirty && (try? SyncAttachmentPreparer.hashFile(localURL).hash) == payload.fileHash
                    var noteKey: SymmetricKey?
                    if dirty && payload.isLocked && !sameBytes {
                        guard let noteAccess = input.noteAccess else { throw CloudApplyWait(outcome: .waitingForUnlock) }
                        noteKey = try noteAccess.journalKey()
                    }
                    try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                    if dirty {
                        if !sameBytes {
                            // An attachment has no text merge. The remote bytes are preserved in a deterministic conflict note;
                            // the local file stays at its original id.
                            let mutation = input.mergeIdentity.mutationID
                            let copyID = SyncNoteMerge.conflictID(entityID: id, mutationID: mutation, remoteRevision: input.mergeIdentity.revision)
                            if try Note.fetchOne(db, key: copyID) == nil {
                                let text = "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: payload.filename) + "\n"
                                let copy = Note(id: copyID, text: text, title: "Attachment conflict", titleKey: "attachment conflict", createdAt: .now, modifiedAt: .now)
                                let info = SyncConflictInfo(originalNoteId: note.id, rejectedMutationId: mutation, remoteRevision: input.mergeIdentity.revision)
                                let record: SyncNotePayload
                                if let noteKey {
                                    guard let protected = try SyncNotePayload.capture(id: note.id, includeRetained: true, in: db) else { throw SyncProtocolError.invalidPayload }
                                    record = try SyncLockedNoteMerge.attachmentConflict(note: protected, attachmentID: id, copyID: copyID, info: info, key: noteKey)
                                } else { record = SyncNotePayload(note: copy, directTags: [], pinnedTags: [], attachmentIds: [id], conflict: info) }
                                try materializer.writeNote(record, downloads: [download.materialized], copying: true, noteKey: noteKey,
                                                           files: files, staged: &scratch.staged, in: db)
                                try SyncMaterializer.markNote(copyID, deleted: false, in: db)
                            }
                        }
                    } else {
                        let batch = try files.stageTransformed([payload.filename], noteId: note.id) { _, output in
                            try materializer.reader.writeAttachment(payload, cipher: download.cipher, to: output)
                        }
                        scratch.staged.append(batch)
                        try AttachmentFiles.record(batch, in: db)
                        // Restore the verified received metadata after staging reset the derived facts, so an identical OCR
                        // completion does not manufacture a new authored edit.
                        try db.execute(sql: """
                            INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,uti,width,height,ocrText,ocrState,sha256,byteSize)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                              updatedAt=excluded.updatedAt,uti=excluded.uti,width=excluded.width,height=excluded.height,
                              ocrText=excluded.ocrText,ocrState=excluded.ocrState,deletedAt=NULL,
                              sha256=excluded.sha256,byteSize=excluded.byteSize,fileModifiedAt=NULL
                            """, arguments: [id, note.id, payload.filename, AttachmentFiles.fileSystemKey(payload.filename),
                                              SyncMaterializer.date(payload.createdAt), SyncMaterializer.date(payload.updatedAt), payload.uti, payload.width,
                                              payload.height, payload.ocrText, payload.isLocked ? "locked" : (payload.ocrText == nil ? "pending" : "done"),
                                              payload.isLocked ? nil : payload.fileHash, payload.isLocked ? nil : payload.fileBytes])
                        if !payload.isLocked, payload.ocrText != nil {
                            try AttachmentTextStore.adoptRemoteOCR(attachmentID: id, staged: batch, filename: payload.filename, in: db)
                        }
                        try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
                        try materializer.cacheDownloadedAttachment(download.materialized, in: db)
                    }
                } else {
                    try db.execute(sql: "UPDATE sync_control SET applying=1 WHERE id=1")
                    if !dirty {
                        // Keep the file bytes until the note no longer references them and the orphan collector runs. A tombstone
                        // alone must not break an open editor.
                        try db.execute(sql: "UPDATE attachment SET deletedAt=? WHERE id=?", arguments: [Date(), id])
                    }
                }
                try Self.markEntity(type: .attachment, localID: id, entityID: id, in: db)
                try db.execute(sql: "UPDATE sync_control SET applying=0 WHERE id=1")
            }
        } catch let wait as CloudApplyWait {
            return wait.outcome
        } catch SyncQueueError.snapshotUnavailable {
            return .waitingForDependencies
        }
        scratch.committed = true
        for batch in scratch.staged { files.install(batch) }
        try NotePrivacy(store: NoteStore(db: database, notifier: nil, paths: paths)).finishPendingCleanup()
        ChangeNotifier().post()
        return .applied(consumed: [])
    }
    /// Validate the CURRENT cache generation and source bytes inside the committing writer.
    /// A stale/missing descriptor cannot authorize dropping the immutable snapshot in flight.
    private func cloudLocalAttachmentRecovery(id: String, note: Note, filename: String, source: URL,
                                               in db: Database) throws -> CloudDownload {
        guard let generation = try Int64.fetchOne(db, sql: "SELECT generation FROM sync_dirty WHERE entityType='attachment' AND localId=? AND tombstone=0",
            arguments: [id]) else { throw SyncQueueError.snapshotUnavailable }
        let content = try SyncAttachmentPreparer.capture(SyncDirty(type: .attachment, localID: id, generation: generation, tombstone: false),
            accountID: accountID, vaultKey: vaultKey, in: db)
        guard let body = content.payload else { throw SyncQueueError.snapshotUnavailable }
        let payload = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: body)
        let measured = try SyncAttachmentPreparer.hashFile(source)
        guard payload.noteId == note.id, payload.filename == filename, payload.isLocked == note.isLocked,
              payload.fileHash == measured.hash, payload.fileBytes == measured.size,
              let stored = try String.fetchOne(db, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [payload.blobHash])
        else { throw SyncQueueError.snapshotUnavailable }
        let cipher = try SyncBlobLocation.verified(stored, paths: paths, hash: payload.blobHash, size: payload.cipherBytes).url
        return CloudDownload(sibling: nil, siblingId: nil, payload: payload, cipher: cipher)
    }

    private func cloudSameAttachmentAcrossPrivacy(_ download: CloudDownload, localURL: URL,
                                                   localName: String, key: SymmetricKey) throws -> Bool {
        let maximumBytes = 16 * 1024 * 1024
        if !download.payload.isLocked {
            let local = try ChunkedCipher.decrypt(input: localURL, keyEncryptionKey: key,
                context: localName, maximumBytes: maximumBytes)
            return SyncWire.hash(local) == download.payload.fileHash
        }
        // No decrypted protected bytes on disk: this temporary file contains inner ciphertext.
        let inner = paths.root.appendingPathComponent("cloud-privacy-compare-" + UUID().uuidString + ".bch")
        defer { try? FileManager.default.removeItem(at: inner) }
        try materializer.reader.writeAttachment(download.payload, cipher: download.cipher, to: inner)
        let remote = try ChunkedCipher.decrypt(input: inner, keyEncryptionKey: key,
            context: download.payload.filename, maximumBytes: maximumBytes)
        return SyncWire.hash(remote) == (try SyncAttachmentPreparer.hashFile(localURL).hash)
    }

    private func cloudPrivacyAttachmentConflict(_ attachment: SyncAttachmentPayload, copyID: String,
                                                 originalNoteID: String, mutationID: String, revision: Int64,
                                                 key: SymmetricKey) throws -> SyncNotePayload {
        let name = attachment.isLocked ? "Attachment" : attachment.filename
        let text = "# Attachment conflict\n\n" + AttachmentMarkdown.link(for: name) + "\n"
        // A privacy mismatch means at least one side is protected. Both recovery copies
        // inherit that stronger privacy state, including the formerly plaintext bytes.
        let assetID = SyncMaterializer.copyAttachmentID(attachment.id, noteID: copyID)
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
