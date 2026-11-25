// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB

public enum BackupRestoreMode: Sendable { case merge, replaceAll }
public struct BackupRestoreResult: Sendable {
    public let restored: Int
    public let keptExisting: Int
    public let safetyBackup: URL?
}

extension LibraryBackup {
    /// The caller closes editor sessions first. Merge preserves local notes and their metadata.
    /// Replace All first creates a verified safety copy, retaining the newest three (plus
    /// an older selected input). Legacy rolling archives are preserved. A different password vault requires
    /// both passwords to merge; ciphertext is streamed directly into the current vault.
    /// Cancelling the calling task stops the restore with `CancellationError` until the database
    /// transaction commits (the library is then unchanged); after that it always finishes.
    /// `afterCommit` runs once, right after the commit, so a UI can stop offering Cancel.
    public func restore(_ archive: URL, mode: BackupRestoreMode = .merge,
                        backupPassword: String? = nil, currentPassword: String? = nil,
                        afterCommit: (@Sendable () -> Void)? = nil) throws -> BackupRestoreResult {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("baerchen-restore-\(UUID())")
        defer { try? fm.removeItem(at: folder) }
        try Self.extractBackupArchive(archive, to: folder)
        try Self.validateExtracted(folder)
        let manifest = try Self.readManifest(folder)
        let metadata = try SyncPayloadCodec.decode(BackupLibraryMetadata.self, from: Self.boundedData(folder.appendingPathComponent("library.json")))
        let records = try manifest.noteIds.map { id in
            try SyncPayloadCodec.decode(BackupNoteRecord.self, from: Self.boundedData(folder.appendingPathComponent(id + ".textbundle/record.json")))
        }
        let safety = mode == .replaceAll ? try createRestoreSafetyBackup(preserving: archive) : nil
        let files = AttachmentFiles(paths: paths, database: database)
        var batches: [AttachmentFiles.Staged] = [], committed = false
        defer { if !committed { for batch in batches { files.discard(batch) } } }
        var restored = 0, kept = 0, removedIDs: [String] = []
        try database.pool.write { db in
            // Replace All writes `isLocked` rows without the lock transaction, so it stops the voice
            // captures of the notes it locks first, as a lock does (FOC-R274, C11 review). A merge
            // only adds notes that do not exist, and nothing captures into those.
            if mode == .replaceAll {
                for record in records where record.note.isLocked { try CaptureLockGuard.noteWillLock(record.note.id) }
            }
            for file in try fm.contentsOfDirectory(at: paths.journal, includingPropertiesForKeys: [.fileSizeKey]) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if file.lastPathComponent.contains(".unreplayed") || (file.pathExtension == "jsonl" && size > 0) { throw BackupError.pendingEdits }
            }
            guard try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM staging_batch)+(SELECT COUNT(*) FROM privacy_transition)") == 0 else { throw BackupError.pendingFiles }
            let existingNotes = try Note.fetchAll(db)
            let revisions = Dictionary(uniqueKeysWithValues: existingNotes.map { ($0.id, $0.revision) })
            let existingTags = Set(try String.fetchAll(db, sql: "SELECT pathKey FROM tag"))
            let incoming = mode == .replaceAll ? records : records.filter { revisions[$0.note.id] == nil }
            kept = records.count - incoming.count
            let oldEnvelope = try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1")
            var rekey: (SymmetricKey, SymmetricKey)?
            if mode == .merge, incoming.contains(where: { $0.note.encryptedPayload != nil || ($0.snapshots ?? []).contains { $0.sealedText != nil } }),
               let oldEnvelope, let sourceEnvelope = metadata.lockEnvelope {
                let current = try JSONDecoder().decode(CryptoEnvelope.self, from: oldEnvelope)
                let source = try JSONDecoder().decode(CryptoEnvelope.self, from: sourceEnvelope)
                if current != source {
                    guard let backupPassword, let currentPassword else { throw BackupError.passwordsRequired }
                    rekey = (try source.unwrap(password: backupPassword), try current.unwrap(password: currentPassword))
                }
            }
            // Last cancellation point before anything is written; another one follows right before the commit.
            try Task.checkCancellation()
            if mode == .replaceAll {
                removedIDs = existingNotes.map(\.id).filter { !manifest.noteIds.contains($0) }
                // Normal deletion triggers retain local sync tombstones. The sync queue and its
                // immutable in-flight mutations are never reset by a library restore.
                try db.execute(sql: "DELETE FROM note")
                try db.execute(sql: "DELETE FROM external_ref")
                try db.execute(sql: "DELETE FROM tag")
                try db.execute(sql: "DELETE FROM crypto_envelope")
                // Hides of notes went with their notes; the library-wide one has no note.
                try db.execute(sql: "DELETE FROM focus_hide WHERE noteId IS NULL")
                for key in SyncPayloadCodec.portableSettings { try db.execute(sql: "DELETE FROM setting WHERE key=?", arguments: [key]) }
            }
            if mode == .replaceAll || oldEnvelope == nil {
                if let envelope = metadata.lockEnvelope {
                    try db.execute(sql: "INSERT INTO crypto_envelope(id,envelope) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET envelope=excluded.envelope", arguments: [envelope])
                }
            }
            for record in incoming {
                try Task.checkCancellation()
                var payload = record.note
                for attachment in record.attachments {
                    guard try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [attachment.id])! else { throw BackupError.attachmentIdentityCollision }
                }
                // Reminder and snapshot ids belong to the whole library; one that another note already
                // owns would otherwise fail halfway through as a constraint error.
                for id in (record.pings ?? []).map(\.id) + (record.snapshots ?? []).map(\.id) {
                    let owned = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note_ping WHERE id=?) OR EXISTS(SELECT 1 FROM note_snapshot WHERE id=?)", arguments: [id, id])!
                    guard !owned else { throw BackupError.invalidManifest }
                }
                if let (from, to) = rekey, let cipher = payload.encryptedPayload {
                    let plain = try NoteCipher.open(cipher, vaultKey: from, context: payload.id)
                    payload.encryptedPayload = try NoteCipher.seal(plain, vaultKey: to, context: payload.id)
                }
                var batch = try files.stageTransformed(record.attachments.filter { $0.isMissing != true }.map(\.filename), noteId: payload.id) { name, output in
                    let source = folder.appendingPathComponent(payload.id + ".textbundle/assets/" + name)
                    if payload.isLocked, let (from, to) = rekey {
                        try ChunkedCipher.reencrypt(input: source, output: output, fromKey: from, toKey: to, fromContext: name, toContext: name)
                    } else { try fm.copyItem(at: source, to: output) }
                }
                batch.replacing = true
                batches.append(batch)
                let note = Note(id: payload.id, text: payload.text, title: payload.title, titleKey: TitleKey.make(payload.title),
                                createdAt: Self.date(payload.createdAt), modifiedAt: Self.date(payload.modifiedAt), location: payload.location,
                                trashedAt: payload.trashedAt.map(Self.date), archivedAt: payload.archivedAt.map(Self.date),
                                isPinnedGlobal: payload.isPinnedGlobal, isReadOnly: payload.isReadOnly, isLocked: payload.isLocked,
                                encryptedPayload: payload.encryptedPayload, revision: (revisions[payload.id] ?? 0) + 1)
                try note.insert(db)
                if let source = record.captureSource {
                    try db.execute(sql: "UPDATE note SET captureSource=? WHERE id=?", arguments: [source, note.id])
                }
                try AttachmentFiles.record(batch, in: db)
                for attachment in record.attachments {
                    try db.execute(sql: """
                        INSERT INTO attachment(id,noteId,filename,filenameKey,createdAt,updatedAt,uti,width,height,ocrState,ocrText,deletedAt)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [attachment.id, note.id, attachment.filename, AttachmentFiles.fileSystemKey(attachment.filename),
                                          Self.date(attachment.createdAt), Self.date(attachment.updatedAt), attachment.uti, attachment.width, attachment.height,
                                          note.isLocked ? "locked" : (attachment.ocrText == nil ? "pending" : "done"), attachment.ocrText, attachment.deletedAt.map(Self.date)])
                }
                try NoteIndexer.index(noteId: note.id, text: note.text, in: db)
                if note.isLocked {
                    try NoteIndexer.writeLockedTags(payload.directTags, noteId: note.id, in: db)
                    let names = String(decoding: try JSONEncoder().encode(record.attachments.filter { $0.isMissing != true }.map(\.filename)), as: UTF8.self)
                    try db.execute(sql: "INSERT INTO privacy_transition(noteId,targetLocked,filenames) VALUES(?,1,?)", arguments: [note.id, names])
                } else {
                    try db.execute(sql: "INSERT INTO note_ui_state(noteId,selection,foldState,scrollTop,lastOpenedAt) VALUES(?,?,?,?,?)",
                                   arguments: [note.id, record.selection, record.foldState, record.scrollTop, record.lastOpenedAt.map(Self.date)])
                }
                for ping in record.pings ?? [] {
                    try db.execute(sql: "INSERT INTO note_ping(id,noteId,anchorLine,anchorHash,fireAt,firedAt,createdAt) VALUES(?,?,?,?,?,?,?)",
                                   arguments: [ping.id, note.id, ping.anchorLine, ping.anchorHash, Self.date(ping.fireAt), ping.firedAt.map(Self.date), Self.date(ping.createdAt)])
                }
                for hide in record.hides ?? [] {
                    try db.execute(sql: "INSERT INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES(?,?,?)",
                                   arguments: [hide.candidateKey, note.id, Self.date(hide.hiddenUntil)])
                }
                for snapshot in record.snapshots ?? [] {
                    var sealed = snapshot.sealedText
                    // A snapshot is sealed under its own context, so a merge into another vault opens and
                    // seals it again exactly like the note's body.
                    if let (from, to) = rekey, let cipher = sealed {
                        let plain = try NoteCipher.open(cipher, vaultKey: from, context: NoteSnapshots.context(snapshot.id))
                        sealed = try NoteCipher.seal(plain, vaultKey: to, context: NoteSnapshots.context(snapshot.id))
                    }
                    try db.execute(sql: "INSERT INTO note_snapshot(id,noteId,takenAt,text,sealedText) VALUES(?,?,?,?,?)",
                                   arguments: [snapshot.id, note.id, Self.date(snapshot.takenAt), snapshot.text, sealed])
                }
                for path in payload.pinnedTags {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO note_pin(noteId,tagId)
                        SELECT ?,t.id FROM tag t JOIN note_tag nt ON nt.tagId=t.id WHERE nt.noteId=? AND t.pathKey=?
                        """, arguments: [note.id, note.id, CanonicalKey.make(path)])
                }
                if let conflict = payload.conflict {
                    try db.execute(sql: "INSERT INTO sync_conflict(noteId,originalNoteId,rejectedMutationId,remoteRevision) VALUES(?,?,?,?)",
                                   arguments: [note.id, conflict.originalNoteId, conflict.rejectedMutationId, conflict.remoteRevision])
                }
                restored += 1
            }
            for tag in metadata.tagPreferences where mode == .replaceAll || !existingTags.contains(CanonicalKey.make(tag.path)) {
                try db.execute(sql: """
                    INSERT INTO tag(id,pathKey,displayPath,iconName,isPinned,sortIndex) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(pathKey) DO UPDATE SET iconName=excluded.iconName,isPinned=excluded.isPinned,sortIndex=excluded.sortIndex
                    """, arguments: [UUIDv7.make(), CanonicalKey.make(tag.path), tag.path, tag.iconName, tag.isPinned, tag.sortIndex])
            }
            for setting in metadata.settings {
                try db.execute(sql: "INSERT OR IGNORE INTO setting(key,value) VALUES(?,?)", arguments: [setting.key, setting.value])
            }
            // A merge keeps the hide the library already has.
            if let until = metadata.notTodayUntil {
                try db.execute(sql: "INSERT OR IGNORE INTO focus_hide(candidateKey,noteId,hiddenUntil) VALUES('pool',NULL,?)", arguments: [Self.date(until)])
            }
            for ref in metadata.externalRefs {
                // A retained local note was not imported from this backup. Do not claim its
                // current optimistic revision as the source's base for a later Bear pull.
                let retained = mode == .merge && ref.noteId.map { revisions[$0] != nil } == true
                let revision = retained ? nil : try ref.noteId.flatMap { try Int.fetchOne(db, sql: "SELECT revision FROM note WHERE id=?", arguments: [$0]) }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO external_ref(source,externalId,noteId,lastSeenModified,lastSeenHash,lastSeenTextHash,lastSeenMeta,importedRevision,importedTextHash)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, arguments: [ref.source, ref.externalId, ref.noteId, ref.lastSeenModified.map(Self.date), ref.lastSeenHash, ref.lastSeenTextHash,
                                      ref.lastSeenMeta, revision, ref.importedTextHash])
            }
            // Even merge invalidates pending remote intents; receipts stay local and are never imported.
            try NoteStore.rotateWatchEpoch(in: db)
            // The last point where Cancel still rolls everything back: the commit follows the return.
            try Task.checkCancellation()
        }
        committed = true
        afterCommit?()
        for batch in batches { files.install(batch) }
        let pending = try database.pool.read { db in
            try batches.contains { try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE id=?)", arguments: [$0.batchID]) == true }
        }
        guard !pending else { throw BackupError.restoreFilesPending }
        for id in removedIDs {
            for directory in [paths.attachments, paths.thumbnails] {
                let url = directory.appendingPathComponent(id)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
            for suffix in [".base", ".jsonl"] {
                let url = paths.journal.appendingPathComponent(id + suffix)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
        }
        let store = NoteStore(db: database, notifier: nil, paths: paths)
        try NotePrivacy(store: store).finishPendingCleanup()
        ChangeNotifier().post()
        return BackupRestoreResult(restored: restored, keptExisting: kept, safetyBackup: safety)
    }

    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
