// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import ZIPFoundation
import GRDB

public enum BackupError: Error, Equatable {
    case pendingEdits, pendingFiles, invalidManifest, checksumMismatch, missingAttachment, unsupportedVersion
    case passwordsRequired, attachmentIdentityCollision, restoreFilesPending
    /// Creating a backup found a note whose saved history does not match its lock state (FOC-R277).
    case inconsistentHistory
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pendingEdits: "Some edits have not been recovered or saved. Unlock the notes vault, or reopen and save the affected notes, then try again."
        case .pendingFiles: "Attachment files are still being saved or recovered. Try again when they finish."
        case .invalidManifest: "This backup is incomplete or has invalid contents. The library has not been replaced."
        case .checksumMismatch: "The backup failed its integrity check. Choose another copy."
        case .missingAttachment: "An attachment is missing or has a conflicting identifier. The backup cannot be used safely."
        case .unsupportedVersion: "This backup was made with an unsupported format. Update Theo Notes before restoring it."
        case .passwordsRequired: "Enter the backup’s note password and your current note password to merge locked notes."
        case .attachmentIdentityCollision: "An attachment identifier is already used by another note. The restore was cancelled and your library was kept."
        case .inconsistentHistory: "A note's saved history does not match its lock state, so no backup was made. Lock or unlock the note again, then try once more."
        case .restoreFilesPending: "The notes were restored, but some attachment files still need recovery. Restart Theo Notes to finish installing the saved files."
        }
    }
}

struct BackupFile: Codable, Sendable { let path: String; let bytes: Int64; let sha256: String }
struct BackupManifest: Codable, Sendable {
    /// 2 since the focus state (FOC-R5); the reader accepts 1 and 2.
    var version = 2
    let createdAt: Int64
    let noteIds: [String]
    let files: [BackupFile]
}
struct BackupAttachment: Codable, Sendable {
    let id: String, filename: String
    let createdAt: Int64, updatedAt: Int64
    let uti: String?, width: Int?, height: Int?, ocrText: String?
    let deletedAt: Int64?
    var isMissing: Bool? = nil
}
/// A reminder (`note_ping`). Dates are milliseconds since 1970.
struct BackupPing: Codable, Sendable {
    let id: String
    var anchorLine: Int? = nil
    var anchorHash: String? = nil
    let fireAt: Int64
    var firedAt: Int64? = nil
    let createdAt: Int64
}
/// A Next Up hide of the record's own note (`focus_hide` with a note).
struct BackupHide: Codable, Sendable { let candidateKey: String; let hiddenUntil: Int64 }
/// One history entry (`note_snapshot`): `text` for an unlocked note, `sealedText` (the ciphertext
/// as stored, never opened for the archive) for a locked one.
struct BackupSnapshot: Codable, Sendable {
    let id: String
    let takenAt: Int64
    var text: String? = nil
    var sealedText: Data? = nil
}
struct BackupNoteRecord: Codable, Sendable {
    let note: SyncNotePayload
    let attachments: [BackupAttachment]
    let selection: String?, foldState: String?, scrollTop: Double?
    // Backup v2 (FOC-R5). All nil in a v1 archive.
    var captureSource: String? = nil
    var lastOpenedAt: Int64? = nil
    var pings: [BackupPing]? = nil
    var hides: [BackupHide]? = nil
    var snapshots: [BackupSnapshot]? = nil
}
struct BackupLibraryMetadata: Codable, Sendable {
    var version = 2
    let lockEnvelope: Data?
    let tagPreferences: [SyncTagPreferencePayload]
    let settings: [SyncSettingPayload]
    let externalRefs: [SyncExternalRefPayload]
    /// The end of the library-wide "Not Today" hide (the `pool` row of `focus_hide`). Backup v2.
    var notTodayUntil: Int64? = nil
}

public struct BackupSummary: Sendable, Equatable {
    public let createdAt: Date
    public let noteCount: Int
    public let lockedNoteCount: Int
    /// Mutually exclusive current locations from validated records, including locked notes.
    /// Historical timestamps do not determine membership; lockedNoteCount can overlap either.
    public let trashedNoteCount: Int
    public let archivedNoteCount: Int
    public let attachmentCount: Int
    public let missingAttachmentCount: Int
}

public struct LocalLibraryBackup: Identifiable, Sendable {
    public let id: String
    public let createdAt: Date
    public let url: URL
}

/// Portable TextBundles plus an exact-source record and a SHA-256 manifest. Protected records
/// and assets retain their password ciphertext. Device/session credentials are never exported.
/// Call off the main actor after flushing all sessions; the writer is held for a consistent
/// snapshot while files are copied and verified, so a concurrent lock cannot race a plaintext
/// backup into existence after its privacy cleanup.
public struct LibraryBackup: Sendable {
    let database: AppDatabase
    let paths: AppPaths
    public init(database: AppDatabase, paths: AppPaths) { self.database = database; self.paths = paths }

    public func createRolling() throws -> URL {
        let destination = paths.backups.appendingPathComponent("baerchen-\(UUIDv7.make()).\(LegacyNames.backupExtension)")
        try create(at: destination)
        return destination
    }

    /// The catalogue id of exactly this archive, or nil: a caller that just made and verified a backup names that one, never
    /// another (MOVE-R2).
    public func catalogID(of archive: URL) throws -> String? {
        try localBackups().first { $0.url.standardizedFileURL == archive.standardizedFileURL }?.id
    }

    public func localBackups() throws -> [LocalLibraryBackup] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,filename,createdAt FROM backup_catalog ORDER BY createdAt DESC").compactMap { row in
                let name: String = row["filename"]
                guard Self.isManagedName(name) else { throw BackupError.invalidManifest }
                guard name.hasSuffix("." + LegacyNames.backupExtension) else { return nil }
                let url = paths.backups.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return LocalLibraryBackup(id: row["id"], createdAt: row["createdAt"], url: url)
            }
        }
    }

    public func create(at destination: URL) throws {
        // This namespace identifies internally generated restore safety copies. A chosen
        // export must never acquire retention semantics, or look like an abandoned copy.
        if AppPaths.isSameDirectory(destination.deletingLastPathComponent(), paths.backups),
           Self.isSafetyName(destination.lastPathComponent) { throw CocoaError(.fileWriteInvalidFileName) }
        try create(at: destination, completingLock: false)
    }

    /// Keep the newest three verified pre-restore copies. An older selected input is an
    /// explicit exception until the next restore; legacy rolling copies have no known role.
    func createRestoreSafetyBackup(preserving archive: URL) throws -> URL {
        let destination = paths.backups.appendingPathComponent("baerchen-safety-\(UUIDv7.make()).\(LegacyNames.backupExtension)")
        try create(at: destination, completingLock: false, safetyInput: archive)
        return destination
    }

    /// Only the durable privacy cleanup path may snapshot committed lock transitions.
    /// Their staging must be settled and every transitioning note must already be locked.
    private func create(at destination: URL, completingLock: Bool, safetyInput: URL? = nil) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let stage = paths.backups.appendingPathComponent(".snapshot-\(UUID())")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        var created = false, committed = false
        defer { if created && !committed { try? fm.removeItem(at: destination) } }
        try database.pool.writeWithoutTransaction { db in
            try db.inTransaction {
                for file in try fm.contentsOfDirectory(at: paths.journal, includingPropertiesForKeys: [.fileSizeKey]) {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    if file.lastPathComponent.contains(".unreplayed") || (file.pathExtension == "jsonl" && size > 0) { throw BackupError.pendingEdits }
                }
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM staging_batch") == 0 else { throw BackupError.pendingFiles }
                let transitions = completingLock
                    ? "SELECT COUNT(*) FROM privacy_transition p LEFT JOIN note n ON n.id=p.noteId WHERE p.targetLocked=0 OR n.isLocked IS NOT 1"
                    : "SELECT COUNT(*) FROM privacy_transition"
                guard try Int.fetchOne(db, sql: transitions) == 0 else { throw BackupError.pendingFiles }
                let notes = try Note.fetchAll(db, sql: "SELECT * FROM note WHERE deletedAt IS NULL ORDER BY id")
                let encoder = SyncPayloadCodec.encoder()
                for note in notes {
                    try Task.checkCancellation(); try SyncWire.validateID(note.id)
                    guard let payload = try SyncNotePayload.capture(id: note.id, in: db) else { throw BackupError.invalidManifest }
                    try payload.validate()
                    let folder = stage.appendingPathComponent(note.id + ".textbundle"), assets = folder.appendingPathComponent("assets")
                    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
                    var attachments: [BackupAttachment] = []
                    var copiedNames = Set<String>()
                    for row in try Row.fetchAll(db, sql: "SELECT * FROM attachment WHERE noteId=? ORDER BY id", arguments: [note.id]) {
                        let filename: String = row["filename"], id: String = row["id"]
                        let deletedAt: Date? = row["deletedAt"]
                        try SyncWire.validateID(id); try AttachmentFiles.validate(filename)
                        if note.isLocked, filename != id + ".bch" { throw BackupError.invalidManifest }
                        let source = try sourceAttachmentIfPresent(noteID: note.id, filename: filename)
                        if let source {
                            try fm.copyItem(at: source, to: assets.appendingPathComponent(filename))
                            copiedNames.insert(AttachmentFiles.fileSystemKey(filename))
                        }
                        var attachment = BackupAttachment(id: id, filename: filename,
                            createdAt: SyncNotePayload.milliseconds(row["createdAt"] as Date), updatedAt: SyncNotePayload.milliseconds(row["updatedAt"] as Date),
                            uti: note.isLocked ? nil : row["uti"], width: note.isLocked ? nil : row["width"], height: note.isLocked ? nil : row["height"], ocrText: note.isLocked ? nil : row["ocrText"], deletedAt: deletedAt.map(SyncNotePayload.milliseconds))
                        attachment.isMissing = source == nil ? true : nil
                        attachments.append(attachment)
                    }
                    // Preserve files retained for undo or referenced by a plain relative link too.
                    // Locked payloads can still name such files even when their index row is a tombstone.
                    if let directory = try sourceDirectoryIfPresent(noteID: note.id) {
                        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                            where !copiedNames.contains(AttachmentFiles.fileSystemKey(file.lastPathComponent)) {
                            let filename = file.lastPathComponent
                            try AttachmentFiles.validate(filename)
                            let id = note.isLocked ? String(filename.dropLast(4)) : UUIDv7.make()
                            if note.isLocked, !filename.hasSuffix(".bch") || UUID(uuidString: id) == nil { throw BackupError.invalidManifest }
                            try fm.copyItem(at: sourceAttachment(noteID: note.id, filename: filename), to: assets.appendingPathComponent(filename))
                            let now = SyncNotePayload.milliseconds(.now)
                            attachments.append(BackupAttachment(id: id, filename: filename, createdAt: now, updatedAt: now,
                                                                uti: nil, width: nil, height: nil, ocrText: nil, deletedAt: now))
                        }
                    }
                    let state = try Row.fetchOne(db, sql: "SELECT selection,foldState,scrollTop FROM note_ui_state WHERE noteId=?", arguments: [note.id])
                    let focus = try Self.focusState(of: note, in: db)
                    let record = BackupNoteRecord(note: payload, attachments: attachments,
                        selection: note.isLocked ? nil : state?["selection"], foldState: note.isLocked ? nil : state?["foldState"], scrollTop: note.isLocked ? nil : state?["scrollTop"],
                        captureSource: focus.captureSource, lastOpenedAt: focus.lastOpenedAt, pings: focus.pings, hides: focus.hides, snapshots: focus.snapshots)
                    try encoder.encode(record).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
                    if !note.isLocked { try Data(NoteExport.textBundleSource(note.text).utf8).write(to: folder.appendingPathComponent("text.md"), options: .atomic) }
                    let dates = ISO8601DateFormatter()
                    let info: [String: Any] = ["version": 2, "type": "net.daringfireball.markdown", "creatorIdentifier": "com.truebrewbirdie.baerchen",
                        "creationDate": dates.string(from: note.createdAt), "modificationDate": dates.string(from: note.modifiedAt), "baerchenLocked": note.isLocked]
                    try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
                }
                let tags = try Row.fetchAll(db, sql: "SELECT * FROM tag ORDER BY pathKey").map { SyncTagPreferencePayload(path: $0["displayPath"], iconName: $0["iconName"], isPinned: $0["isPinned"], sortIndex: $0["sortIndex"]) }
                let settings = try Row.fetchAll(db, sql: "SELECT key,value FROM setting ORDER BY key").compactMap { row -> SyncSettingPayload? in
                    let key: String = row["key"]
                    return SyncPayloadCodec.portableSettings.contains(key) ? SyncSettingPayload(key: key, value: row["value"]) : nil
                }
                let refs = try Row.fetchAll(db, sql: "SELECT json_array(source,externalId) AS id FROM external_ref ORDER BY source,externalId").map { row -> SyncExternalRefPayload in
                    let content = try SyncPayloadCodec.capture(SyncDirty(type: .externalRef, localID: row["id"], generation: 0, tombstone: false), in: db)
                    guard let data = content.payload else { throw BackupError.invalidManifest }
                    return try SyncPayloadCodec.decode(SyncExternalRefPayload.self, from: data)
                }
                let notToday = try Date.fetchOne(db, sql: "SELECT hiddenUntil FROM focus_hide WHERE candidateKey='pool' AND noteId IS NULL")
                let metadata = BackupLibraryMetadata(lockEnvelope: try Data.fetchOne(db, sql: "SELECT envelope FROM crypto_envelope WHERE id=1"), tagPreferences: tags, settings: settings, externalRefs: refs,
                                                     notTodayUntil: notToday.map(SyncNotePayload.milliseconds))
                try encoder.encode(metadata).write(to: stage.appendingPathComponent("library.json"), options: .atomic)
                let manifest = BackupManifest(createdAt: SyncNotePayload.milliseconds(.now), noteIds: notes.map(\.id), files: try Self.fileManifest(stage))
                try encoder.encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
                try Self.validateExtracted(stage)
                try PortableZIP.create(from: stage, at: destination)
                created = true
                if completingLock || safetyInput != nil { _ = try inspect(destination) }
                if AppPaths.isSameDirectory(destination.deletingLastPathComponent(), paths.backups), Self.isManagedName(destination.lastPathComponent) {
                    try db.execute(sql: "INSERT INTO backup_catalog(id,filename,createdAt,plaintextNoteIds) VALUES(?,?,?,?)", arguments: [UUIDv7.make(), destination.lastPathComponent, Date(), String(decoding: try encoder.encode(notes.filter { !$0.isLocked }.map(\.id)), as: UTF8.self)])
                }
                return .commit
            }
            // Publish the verified replacement before deleting anything. A separate
            // immediate transaction serializes pruning against other database writers.
            committed = true
            if let safetyInput {
                try db.inTransaction(.immediate) {
                    // Another process may have completed privacy cleanup between transactions.
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM backup_catalog WHERE filename=?)", arguments: [destination.lastPathComponent]) == true,
                          fm.fileExists(atPath: destination.path) else { throw BackupError.pendingFiles }
                    try pruneRestoreSafetyCopies(in: db, preserving: safetyInput)
                    return .commit
                }
            }
        }
    }

    /// What one note carries besides its text (FOC-R5). A locked note exports only what it may:
    /// no open time, no hides, and its snapshots as the ciphertext the database holds. A row that
    /// breaks the rule "sealed if and only if locked" fails the backup (`inconsistentHistory`).
    struct FocusState {
        var captureSource: String?
        var lastOpenedAt: Int64?
        var pings: [BackupPing]?
        var hides: [BackupHide]?
        var snapshots: [BackupSnapshot]?
    }

    static func focusState(of note: Note, in db: Database) throws -> FocusState {
        func ms(_ date: Date) -> Int64 { SyncNotePayload.milliseconds(date) }
        let capture = try String.fetchOne(db, sql: "SELECT captureSource FROM note WHERE id=?", arguments: [note.id])
        let opened = note.isLocked ? nil
            : try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM note_ui_state WHERE noteId=?", arguments: [note.id])
        let pings = try Row.fetchAll(db, sql: "SELECT * FROM note_ping WHERE noteId=? ORDER BY id", arguments: [note.id]).map { row in
            BackupPing(id: row["id"], anchorLine: row["anchorLine"], anchorHash: row["anchorHash"], fireAt: ms(row["fireAt"] as Date),
                       firedAt: (row["firedAt"] as Date?).map(ms), createdAt: ms(row["createdAt"] as Date))
        }
        let pingIDs = Set(pings.map(\.id))
        // A hide of a reminder that is gone has nothing to hide any more.
        let hides = note.isLocked ? [] : try Row.fetchAll(db, sql: "SELECT candidateKey,hiddenUntil FROM focus_hide WHERE noteId=? ORDER BY candidateKey", arguments: [note.id])
            .compactMap { row -> BackupHide? in
                let key: String = row["candidateKey"]
                if key.hasPrefix("ping:"), !pingIDs.contains(String(key.dropFirst("ping:".count))) { return nil }
                return BackupHide(candidateKey: key, hiddenUntil: ms(row["hiddenUntil"] as Date))
            }
        // "Sealed if and only if locked" is kept by the lock paths. A row that breaks it is never
        // written in the clear and never dropped silently: the backup fails and nothing is left.
        let snapshots = try Row.fetchAll(db, sql: "SELECT id,takenAt,text,sealedText FROM note_snapshot WHERE noteId=? ORDER BY id", arguments: [note.id])
            .map { row -> BackupSnapshot in
                let text: String? = row["text"], sealed: Data? = row["sealedText"]
                if note.isLocked {
                    guard text == nil, let sealed else { throw BackupError.inconsistentHistory }
                    return BackupSnapshot(id: row["id"], takenAt: ms(row["takenAt"] as Date), sealedText: sealed)
                }
                guard sealed == nil, let text else { throw BackupError.inconsistentHistory }
                return BackupSnapshot(id: row["id"], takenAt: ms(row["takenAt"] as Date), text: text)
            }
        return FocusState(captureSource: capture, lastOpenedAt: opened.map(ms), pings: pings.isEmpty ? nil : pings,
                          hides: hides.isEmpty ? nil : hides, snapshots: snapshots.isEmpty ? nil : snapshots)
    }

    private func pruneRestoreSafetyCopies(in db: Database, preserving archive: URL) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT id,filename FROM backup_catalog ORDER BY createdAt DESC,rowid DESC")
            .filter { Self.isSafetyName($0["filename"]) }
        for row in rows.dropFirst(3) {
            let filename: String = row["filename"]
            let url = paths.backups.appendingPathComponent(filename)
            guard url.resolvingSymlinksInPath().standardizedFileURL != archive.resolvingSymlinksInPath().standardizedFileURL else { continue }
            // A failure may roll back catalog removal after deleting an old file. The new
            // verified copy was committed separately; stale old rows are harmless and retryable.
            try Self.removeManagedCopy(url)
            try db.execute(sql: "DELETE FROM backup_catalog WHERE id=?", arguments: [row["id"] as String])
        }
    }

    public func inspect(_ archive: URL) throws -> BackupSummary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-verify-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.extractBackupArchive(archive, to: folder)
        return try Self.validateExtracted(folder)
    }

    /// Translate only archive-format failures. IO and cancellation keep their original errors.
    static func extractBackupArchive(_ archive: URL, to folder: URL) throws {
        do { try PortableZIP.extract(archive, to: folder) }
        catch let error as Archive.ArchiveError {
            switch error {
            case .invalidCRC32: throw BackupError.checksumMismatch
            case .missingEndOfCentralDirectoryRecord, .invalidEntryPath, .invalidCompressionMethod,
                 .invalidEntrySize, .invalidLocalHeaderDataOffset, .invalidLocalHeaderSize,
                 .invalidCentralDirectoryOffset, .invalidCentralDirectorySize,
                 .invalidCentralDirectoryEntryCount, .uncontainedSymlink:
                throw BackupError.invalidManifest
            default: throw error
            }
        } catch let error as PortableZIP.Failure {
            switch error {
            case .invalidChecksum: throw BackupError.checksumMismatch
            case .unsafePath, .duplicatePath, .symbolicLink, .limitExceeded: throw BackupError.invalidManifest
            case .nonemptyDestination: throw error
            }
        }
    }

    /// Called by durable lock cleanup, including after an interrupted lock at next launch.
    /// Only app-created, catalogued rolling copies are removed; external exports are untouched.
    func prunePlaintextCopies(noteID: String) throws {
        let affected = try database.pool.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM backup_catalog WHERE EXISTS(SELECT 1 FROM json_each(plaintextNoteIds) WHERE value=?))", arguments: [noteID])!
        }
        guard affected else {
            try recoverAbandonedCopies()
            return
        }
        // A portable snapshot preserves attachments and the password envelope as well as notes.
        // The catalog does not distinguish safety archives from ordinary rolling copies: this
        // replacement therefore also replaces any affected first-sync/restore safety archive.
        // Keep the transition marker on every failure so launch recovery retries the operation.
        let replacement = paths.backups.appendingPathComponent("baerchen-\(UUIDv7.make()).\(LegacyNames.backupExtension)")
        try create(at: replacement, completingLock: true)
        try database.pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id=?", arguments: [noteID]) == true,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM backup_catalog WHERE filename=? AND NOT EXISTS(SELECT 1 FROM json_each(plaintextNoteIds) WHERE value=?))", arguments: [replacement.lastPathComponent, noteID]) == true else {
                throw BackupError.pendingFiles
            }
            try removeOrphanCopies(in: db)
            let rows = try Row.fetchAll(db, sql: "SELECT id,filename FROM backup_catalog WHERE EXISTS(SELECT 1 FROM json_each(plaintextNoteIds) WHERE value=?)", arguments: [noteID])
            for row in rows {
                let filename: String = row["filename"]
                guard Self.isManagedName(filename) else { throw BackupError.invalidManifest }
                let url = paths.backups.appendingPathComponent(filename)
                try Self.removeManagedCopy(url)
                try db.execute(sql: "DELETE FROM backup_catalog WHERE id=?", arguments: [row["id"] as String])
            }
        }
    }

    /// A process can exit after writing an archive but before its catalog transaction commits.
    /// Such app-owned copies and abandoned snapshot directories cannot survive a later lock.
    public func recoverAbandonedCopies() throws {
        try database.pool.write { try removeOrphanCopies(in: $0) }
    }

    private func removeOrphanCopies(in db: Database) throws {
        let names = Set(try String.fetchAll(db, sql: "SELECT filename FROM backup_catalog"))
        for file in try FileManager.default.contentsOfDirectory(at: paths.backups, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            let abandonedStage = name.hasPrefix(".snapshot-") && UUID(uuidString: String(name.dropFirst(".snapshot-".count))) != nil
            let abandonedArchive = name.hasPrefix(".archive-") && name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropFirst(".archive-".count).dropLast(4))) != nil
            let base = ["-wal", "-shm", "-journal"].first(where: { name.hasSuffix($0) }).map { String(name.dropLast($0.count)) } ?? name
            if abandonedStage || abandonedArchive { try FileManager.default.removeItem(at: file) }
            else if Self.isManagedName(base) && !names.contains(base) { try Self.removeManagedCopy(paths.backups.appendingPathComponent(base)) }
        }
    }

    static func removeManagedCopy(_ url: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The archive's manifest: its version is read first, so a future format with another shape
    /// reports `unsupportedVersion`; anything that is not a v1 or v2 manifest is `invalidManifest`.
    static func readManifest(_ folder: URL) throws -> BackupManifest {
        struct VersionProbe: Decodable { let version: Int? }
        let data = try boundedData(folder.appendingPathComponent("manifest.json"))
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), let version = probe.version else {
            throw BackupError.invalidManifest
        }
        guard version == 1 || version == 2 else { throw BackupError.unsupportedVersion }
        do { return try SyncPayloadCodec.decode(BackupManifest.self, from: data) }
        catch is DecodingError { throw BackupError.invalidManifest }
    }

    @discardableResult static func validateExtracted(_ folder: URL) throws -> BackupSummary {
        do { return try validateExtractedContents(folder) }
        catch is DecodingError { throw BackupError.invalidManifest }
        // A sealed snapshot or payload that is not canonical base64url.
        catch SyncProtocolError.invalidEncoding { throw BackupError.invalidManifest }
    }

    private static func validateExtractedContents(_ folder: URL) throws -> BackupSummary {
        let manifest = try readManifest(folder)
        guard Set(manifest.noteIds).count == manifest.noteIds.count, Set(manifest.files.map(\.path)).count == manifest.files.count else { throw BackupError.invalidManifest }
        let actual = try fileManifest(folder).filter { $0.path != "manifest.json" }
        let wanted = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        guard actual.count == wanted.count else { throw BackupError.invalidManifest }
        for file in actual {
            guard let expected = wanted[file.path], expected.bytes == file.bytes, expected.sha256 == file.sha256 else { throw BackupError.checksumMismatch }
        }
        let metadataData = try boundedData(folder.appendingPathComponent("library.json"))
        let metadata = try SyncPayloadCodec.decode(BackupLibraryMetadata.self, from: metadataData)
        guard metadata.version == 1 || metadata.version == 2 else { throw BackupError.unsupportedVersion }
        // The two files of one archive were written together: they name the same format.
        guard metadata.version == manifest.version else { throw BackupError.invalidManifest }
        let isV2 = manifest.version == 2
        if try JSONDecoder().decode(KeyProbe.self, from: metadataData).keys.contains("notTodayUntil") { guard isV2 else { throw BackupError.invalidManifest } }
        if let until = metadata.notTodayUntil { guard inRevisionRange(until) else { throw BackupError.invalidManifest } }
        var focusIDs = Set<String>()
        if let data = metadata.lockEnvelope {
            let envelope = try JSONDecoder().decode(CryptoEnvelope.self, from: data)
            guard envelope.version == 1, envelope.kdf == CryptoEnvelope.kdfName,
                  CryptoEnvelope.publicIterationRange.contains(envelope.iterations), envelope.salt.count == 16,
                  envelope.wrappedVaultKey.count == 60 else { throw BackupError.invalidManifest }
        }
        guard Set(metadata.settings.map(\.key)).count == metadata.settings.count,
              Set(metadata.tagPreferences.map { CanonicalKey.make($0.path) }).count == metadata.tagPreferences.count else { throw BackupError.invalidManifest }
        for setting in metadata.settings {
            try setting.validate()
        }
        for tag in metadata.tagPreferences {
            guard tag.version == 1 else { throw BackupError.unsupportedVersion }
            _ = try NoteStore.tagToken(tag.path)
        }
        var refKeys = Set<[String]>()
        for ref in metadata.externalRefs {
            guard ref.version == 1, !ref.source.isEmpty, !ref.externalId.isEmpty,
                  refKeys.insert([ref.source, ref.externalId]).inserted,
                  ref.noteId == nil || manifest.noteIds.contains(ref.noteId!) else { throw BackupError.invalidManifest }
        }
        var allowedFiles: Set<String> = ["library.json"]
        var locked = 0, trashed = 0, archived = 0, attachments = 0, missing = 0, attachmentIDs = Set<String>()
        for id in manifest.noteIds {
            try SyncWire.validateID(id)
            let recordData = try boundedData(folder.appendingPathComponent(id + ".textbundle/record.json"))
            let record = try SyncPayloadCodec.decode(BackupNoteRecord.self, from: recordData)
            let recordKeys = try JSONDecoder().decode(KeyProbe.self, from: recordData).keys
            try record.note.validate()
            if record.note.location == .trash { trashed += 1 }
            if record.note.location == .archive { archived += 1 }
            let live = record.attachments.filter { $0.deletedAt == nil }
            guard record.note.id == id, Set(record.note.attachmentIds) == Set(live.map(\.id)), live.count == record.note.attachmentIds.count else { throw BackupError.invalidManifest }
            allowedFiles.formUnion([id + ".textbundle/record.json", id + ".textbundle/info.json"])
            for tag in record.note.directTags + record.note.pinnedTags { _ = try NoteStore.tagToken(tag) }
            try validateFocus(record, keys: recordKeys, isV2: isV2, hasEnvelope: metadata.lockEnvelope != nil, ids: &focusIDs)
            if record.note.isLocked {
                locked += 1
                guard record.selection == nil, record.foldState == nil, record.scrollTop == nil,
                      record.note.encryptedPayload == nil || metadata.lockEnvelope != nil else { throw BackupError.invalidManifest }
            } else {
                let textPath = id + ".textbundle/text.md"
                allowedFiles.insert(textPath)
                guard try boundedData(folder.appendingPathComponent(textPath)) == Data(NoteExport.textBundleSource(record.note.text).utf8) else { throw BackupError.invalidManifest }
            }
            for json in [record.selection, record.foldState].compactMap({ $0 }) {
                _ = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            }
            var filenames = Set<String>()
            for attachment in record.attachments {
                try SyncWire.validateID(attachment.id); try AttachmentFiles.validate(attachment.filename)
                let path = id + ".textbundle/assets/" + attachment.filename
                guard attachmentIDs.insert(attachment.id).inserted,
                      filenames.insert(AttachmentFiles.fileSystemKey(attachment.filename)).inserted else { throw BackupError.missingAttachment }
                if attachment.isMissing == true {
                    guard wanted[path] == nil else { throw BackupError.invalidManifest }
                    missing += 1
                } else {
                    allowedFiles.insert(path)
                    guard wanted[path] != nil else { throw BackupError.missingAttachment }
                    attachments += 1
                }
                if record.note.isLocked {
                    guard UUID(uuidString: attachment.id) != nil, attachment.filename == attachment.id + ".bch", attachment.ocrText == nil,
                          attachment.uti == nil, attachment.width == nil, attachment.height == nil else { throw BackupError.invalidManifest }
                    if attachment.isMissing != true {
                        let reader = try FileHandle(forReadingFrom: folder.appendingPathComponent(path))
                        defer { try? reader.close() }
                        guard try reader.read(upToCount: 4) == Data("BCH1".utf8) else { throw BackupError.invalidManifest }
                    }
                }
            }
        }
        guard Set(wanted.keys) == allowedFiles else { throw BackupError.invalidManifest }
        return BackupSummary(createdAt: Date(timeIntervalSince1970: Double(manifest.createdAt) / 1000), noteCount: manifest.noteIds.count, lockedNoteCount: locked, trashedNoteCount: trashed, archivedNoteCount: archived, attachmentCount: attachments, missingAttachmentCount: missing)
    }
    static let maximumPingsPerNote = 1000, maximumHidesPerNote = 1000, maximumSnapshotsPerNote = 100
    static let maximumSnapshotUnits = 500_000, maximumAnchorLine = 1_000_000

    /// The dates SQLite text can hold and GRDB reads back: 0001-01-01 to 9999-12-31, in milliseconds.
    /// That is narrower than the sync revision range, which a stored year 287396 would satisfy and
    /// which no later read of the row could decode (FOC-R275).
    static let earliestDate: Int64 = -62_135_596_800_000, latestDate: Int64 = 253_402_300_799_999

    private static func inRevisionRange(_ value: Int64) -> Bool {
        value >= max(-SyncWire.maximumRevision, earliestDate) && value <= min(SyncWire.maximumRevision, latestDate)
    }

    private static func isValidID(_ id: String) -> Bool { (try? SyncWire.validateID(id)) != nil }

    /// The keys an object has, whatever their values: an explicit `null` counts as present.
    private struct KeyProbe: Decodable {
        let keys: Set<String>
        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        init(from decoder: Decoder) throws {
            keys = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
        }
    }
    private static let focusRecordKeys: Set<String> = ["captureSource", "lastOpenedAt", "pings", "hides", "snapshots"]

    /// Every focus field of a record is hostile input (FOC-R5, FOC-R272). `ids` holds the ping and
    /// snapshot ids of the whole archive so far: they are unique across it.
    private static func validateFocus(_ record: BackupNoteRecord, keys: Set<String>, isV2: Bool, hasEnvelope: Bool, ids: inout Set<String>) throws {
        let invalid = BackupError.invalidManifest
        // In a v1 archive the fields are absent: present as `null` is a v2 field in a v1 archive too.
        guard isV2 || keys.isDisjoint(with: focusRecordKeys) else { throw invalid }
        let noteId = record.note.id, locked = record.note.isLocked
        if let source = record.captureSource { guard CaptureSource(rawValue: source) != nil else { throw invalid } }
        if let opened = record.lastOpenedAt { guard !locked, inRevisionRange(opened) else { throw invalid } }
        let pings = record.pings ?? [], hides = record.hides ?? [], snapshots = record.snapshots ?? []
        guard pings.count <= maximumPingsPerNote, hides.count <= maximumHidesPerNote, snapshots.count <= maximumSnapshotsPerNote else { throw invalid }

        var targets = Set<String>()
        for ping in pings {
            guard isValidID(ping.id), ids.insert(ping.id).inserted,
                  (ping.anchorLine == nil) == (ping.anchorHash == nil),
                  targets.insert("\(ping.anchorLine ?? 0):\(ping.anchorHash ?? "")").inserted,
                  [ping.fireAt, ping.firedAt ?? 0, ping.createdAt].allSatisfy(inRevisionRange) else { throw invalid }
            if let line = ping.anchorLine, let hash = ping.anchorHash {
                guard (1...maximumAnchorLine).contains(line), LineAnchor.isValidHash(hash) else { throw invalid }
            }
        }
        // A locked note keeps one reminder and it names no line (FOC-R10).
        if locked { guard pings.count <= 1, pings.allSatisfy({ $0.anchorLine == nil }) else { throw invalid } }

        var keys = Set<String>()
        let pingIDs = Set(pings.map(\.id))
        for hide in hides {
            guard !locked, keys.insert(hide.candidateKey).inserted, inRevisionRange(hide.hiddenUntil),
                  isValidHideKey(hide.candidateKey, noteId: noteId, pingIDs: pingIDs) else { throw invalid }
        }

        for snapshot in snapshots {
            guard isValidID(snapshot.id), ids.insert(snapshot.id).inserted, inRevisionRange(snapshot.takenAt) else { throw invalid }
            switch (snapshot.text, snapshot.sealedText) {
            case let (text?, nil):
                guard !locked, text.utf16.count <= maximumSnapshotUnits else { throw invalid }
            case let (nil, sealed?):
                guard locked, hasEnvelope, sealed.prefix(NoteCipher.magic.count) == NoteCipher.magic else { throw invalid }
            default:
                throw invalid
            }
        }
    }

    /// FOC-R8's grammar, for the hides of one note. `pool` belongs to `library.json`.
    private static func isValidHideKey(_ key: String, noteId: String, pingIDs: Set<String>) -> Bool {
        if key.hasPrefix("note:") { return key == "note:" + noteId }
        if key.hasPrefix("ping:") { return pingIDs.contains(String(key.dropFirst("ping:".count))) }
        if key.hasPrefix("todo:") {
            let parts = key.dropFirst("todo:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == noteId, let line = Int(parts[1]), String(line) == parts[1],
                  (1...maximumAnchorLine).contains(line) else { return false }
            return LineAnchor.isValidHash(String(parts[2]))
        }
        return false
    }

    /// A file of the extracted archive; one that is missing or not a regular file is a format
    /// failure of the archive, not an IO error.
    static func boundedData(_ url: URL) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw BackupError.invalidManifest }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024 else { throw BackupError.invalidManifest }
        return try Data(contentsOf: url)
    }
    static func fileManifest(_ folder: URL) throws -> [BackupFile] {
        var files: [BackupFile] = []
        func walk(_ directory: URL, prefix: String) throws {
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                let facts = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard facts.isSymbolicLink != true else { throw BackupError.invalidManifest }
                let path = prefix + item.lastPathComponent
                if facts.isDirectory == true { try walk(item, prefix: path + "/") }
                else {
                    guard facts.isRegularFile == true else { throw BackupError.invalidManifest }
                    let hash = try SyncAttachmentPreparer.hashFile(item)
                    files.append(BackupFile(path: path, bytes: hash.size, sha256: hash.hash))
                }
            }
        }
        try walk(folder, prefix: "")
        return files.sorted { $0.path < $1.path }
    }
    private func sourceAttachment(noteID: String, filename: String) throws -> URL {
        guard let file = try sourceAttachmentIfPresent(noteID: noteID, filename: filename) else { throw BackupError.missingAttachment }
        return file
    }
    private func sourceAttachmentIfPresent(noteID: String, filename: String) throws -> URL? {
        guard let directory = try sourceDirectoryIfPresent(noteID: noteID) else { return nil }
        let file = directory.appendingPathComponent(filename)
        do {
            // attributesOfItem uses lstat semantics: a dangling symlink is still an entry,
            // whereas URL resource lookup can report only its missing destination.
            let fileType = try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            guard fileType == .typeRegular else { throw BackupError.missingAttachment }
            return file
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }
    private func sourceDirectoryIfPresent(noteID: String) throws -> URL? {
        let directory = paths.attachments.appendingPathComponent(noteID)
        do {
            let type = try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw BackupError.missingAttachment }
            return directory
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }
    static func isManagedName(_ name: String) -> Bool {
        if isSafetyName(name) { return true }
        for suffix in ["." + LegacyNames.backupExtension, ".sqlite"] where name.hasPrefix("baerchen-") && name.hasSuffix(suffix) {
            if UUID(uuidString: String(name.dropFirst("baerchen-".count).dropLast(suffix.count))) != nil { return true }
        }
        return false
    }

    static func isSafetyName(_ name: String) -> Bool {
        let prefix = "baerchen-safety-", suffix = "." + LegacyNames.backupExtension
        return name.hasPrefix(prefix) && name.hasSuffix(suffix)
            && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }

    /// The file extension of an export the person chooses (REN2-R37): `.theonotes-backup`. Archives made by the
    /// first release (`.baerchen-backup`) restore the same way; the format inside is unchanged.
    /// The copies the app keeps itself (rolling, restore safety, daily snapshots, all in `backup_catalog`) keep the
    /// legacy `baerchen-<id>.baerchen-backup` / `.sqlite` names on purpose (REN2-R50): an older build after a
    /// rollback treats an unknown catalog name as an invalid manifest. // LegacyNames (A2)
    public static let backupExtension = "theonotes-backup"
}
