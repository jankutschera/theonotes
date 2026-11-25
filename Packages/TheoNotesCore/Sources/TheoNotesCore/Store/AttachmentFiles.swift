// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import GRDB
import Synchronization

/// One attachment to write: the filename it gets in `Attachments/<noteId>/` and its bytes.
public struct ImportedAttachment: Equatable, Sendable {
    public var filename: String
    public var data: Data
    /// The file the bytes were read from, if any: its quarantine record is copied
    /// (`AttachmentQuarantine`); without one the file gets a fresh record.
    public var source: URL?

    public init(filename: String, data: Data, source: URL? = nil) {
        self.filename = filename
        self.data = data
        self.source = source
    }
}

/// An exclusive flock(2) on a batch's `.lock` file, held from staging until the batch is finished
/// or discarded. Released explicitly or when the last reference goes (a crashed process loses it).
public final class BatchLock: Sendable {
    private let fd: Mutex<Int32>

    private init(fd: Int32) {
        self.fd = Mutex(fd)
    }

    /// Opens (creating) `path` and locks it; nil when another holder keeps it for all `attempts`
    /// (10 ms apart). More than one attempt rides out a lock that is only held transiently: a
    /// process spawned meanwhile (e.g. `bearcli`) references every open descriptor of its parent
    /// until its exec closes them, so a just-released lock can look held for a moment.
    static func acquire(_ path: String, attempts: Int = 1) throws -> BatchLock? {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        for attempt in 1...max(1, attempts) {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return BatchLock(fd: fd) }
            guard errno == EWOULDBLOCK, attempt < attempts else { break }
            usleep(10_000)
        }
        close(fd)
        return nil
    }

    public func release() {
        fd.withLock { fd in
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}

/// The attachment write rule (spec §3.4): bytes are written and fsynced under
/// `Attachments/.staging/`, then the database transaction that references them commits, then
/// each file is renamed atomically into `Attachments/<noteId>/<filename>`. If the transaction
/// fails the staged files are removed.
///
/// Staging layout: every batch is `.staging/<batchID>/<noteId>/<staged name>`, the staged name
/// being the filename with `%` written as `%25` (`decodeStagedName` reverses it), plus
/// `.staging/<batchID>/.lock` (see Locking) and, for a copy that needs repair,
/// `.staging/<batchID>/copy-source` (the id of the note the files are copied from).
///
/// Commit marker: the transaction that references the files also inserts a `staging_batch` row
/// (`record`, batch id, note id, whether it replaces the note's files, the full filename list).
/// The row therefore exists exactly when that transaction committed. After every file is in
/// place (and, when replacing, stale files are removed) the batch directory and then the row are
/// deleted. A batch with no files that does not replace has no row and no directory.
///
/// Supersession (M2 ruling R9): `record` deletes the rows of older batches of the same note, so
/// an older batch never overwrites a newer one: `install` of a batch whose row is gone discards
/// it, and recovery discards its directory.
///
/// Locking (R9): `stage` takes an exclusive flock(2) on `.staging/<batch>/.lock` and holds it
/// until `install` or `discard`. Recovery takes the same lock before touching a batch and skips
/// batches it cannot lock, so a CLI or MCP process can write while the app recovers.
///
/// Quarantine: every file gets a quarantine record when it is staged (copied from its source URL,
/// or fresh), and on its way into place if it has none (`AttachmentQuarantine`).
///
/// Recovery contract (`recover`, at launch): for each unlocked batch with a row, newest first,
/// whose note still exists and has no newer batch, the copy is repaired if needed, the remaining
/// staged files are renamed into place (stale-file cleanup when replacing) and the row deleted;
/// a batch whose rename fails keeps its row and directory for the next run. A batch with a row
/// whose note is gone, an older batch of the same note, and a batch directory without a row
/// (never committed) are deleted. Entries of `.staging` that are not batch directories (no UUID
/// name) are left alone.
public struct AttachmentFiles: Sendable {
    public enum FileError: Error, Equatable, CustomStringConvertible {
        /// Empty, `.`/`..`, contains `/` or NUL, or longer than 255 UTF-8 bytes (also once staged).
        case invalidFilename(String)
        /// Two files in one set that the (case-insensitive) file system would treat as one.
        case duplicateFilename(String)
        /// Another process holds the batch (only for a just-created batch: recovery raced it).
        case batchLocked

        public var description: String {
            switch self {
            case .invalidFilename(let name): "invalid attachment filename '\(name)'"
            case .duplicateFilename(let name): "duplicate attachment filename '\(name)'"
            case .batchLocked: "attachment batch locked by another process"
            }
        }
    }

    /// Files written to staging, not yet in place.
    public struct Staged: Sendable {
        struct Entry: Sendable {
            var filename: String
            /// Built by string concatenation so the bytes of the name are kept (URL paths are NFD).
            var path: String
        }

        public let noteId: String
        public let batchID: String
        /// Set by `write`; the default for `record`.
        public var replacing = false
        var entries: [Entry]
        /// The filename list the row records; nil = the staged names. A copy records every file
        /// of its source, also those that failed to copy (`copySource` then names the source).
        var recordedNames: [String]?
        /// A copy with files still missing (repaired by `install` and recovery).
        var copySource: String?
        /// Nil for a batch without files.
        public let lock: BatchLock?
        public var count: Int { entries.count }

        var names: [String] { recordedNames ?? entries.map(\.filename) }

        func hasRow(replacing: Bool) -> Bool { !names.isEmpty || replacing }
    }

    public struct Recovery: Equatable, Sendable {
        public var installed = 0
        public var discarded = 0
        /// Batches another process still holds (locked).
        public var skipped = 0
        /// Staged files that could not be renamed into place (their batch is retried next time).
        public var failedRenames = 0
        /// Copied files still missing because the copy from the source failed again.
        public var failedCopies = 0

        public init(installed: Int = 0, discarded: Int = 0, skipped: Int = 0, failedRenames: Int = 0, failedCopies: Int = 0) {
            self.installed = installed
            self.discarded = discarded
            self.skipped = skipped
            self.failedRenames = failedRenames
            self.failedCopies = failedCopies
        }
    }

    public let root: URL
    private let database: AppDatabase

    public init(paths: AppPaths, database: AppDatabase) {
        root = paths.attachments
        self.database = database
    }

    public var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }

    public func directory(for noteId: String) -> URL {
        root.appendingPathComponent(noteId, isDirectory: true)
    }

    private func batchPath(_ batchID: String) -> String { staging.path + "/" + batchID }

    private static let copySourceName = "copy-source"
    /// Up to 200 ms per batch before recovery counts it as held by another writer.
    static let recoveryLockAttempts = 20

    /// Stages `files`, runs `transaction` inside one database write transaction that also
    /// records the batch (`record`), then moves the files into place. With `replacing`, files in
    /// the note's directory that are not in `files` are removed after the move.
    public func write<T>(
        _ files: [ImportedAttachment], noteId: String, replacing: Bool, transaction: (Database) throws -> T
    ) throws -> T {
        var staged = try stage(files, noteId: noteId)
        staged.replacing = replacing
        let result: T
        do {
            result = try database.pool.write { db in
                try Self.record(staged, in: db)
                return try transaction(db)
            }
        } catch {
            discard(staged)
            throw error
        }
        install(staged)
        return result
    }

    /// The commit marker; call inside the transaction that references the staged files. Deletes
    /// the rows of older batches of the same note (they are superseded). No-op for an empty
    /// batch when not replacing.
    public static func record(_ staged: Staged, replacing: Bool? = nil, in db: Database) throws {
        try NotePrivacy.requireNoPendingTransition(staged.noteId, in: db)
        let replacing = replacing ?? staged.replacing
        guard staged.hasRow(replacing: replacing) else { return }
        let names = String(decoding: try JSONEncoder().encode(staged.names), as: UTF8.self)
        try db.execute(sql: "DELETE FROM staging_batch WHERE noteId = ? AND id <> ?", arguments: [staged.noteId, staged.batchID])
        try db.execute(
            sql: "INSERT INTO staging_batch (id, noteId, replacing, filenames, createdAt) VALUES (?, ?, ?, ?, ?)",
            arguments: [staged.batchID, staged.noteId, replacing, names, Date()])
        // New bytes under these names: whatever was known about the old file (hash, size, date,
        // recognized text) is stale, so the rows go back to `pending`. A name without a row is
        // created pending by the indexer.
        let now = Date()
        var reset = false
        for name in staged.names {
            try db.execute(
                sql: """
                    UPDATE attachment SET ocrState = 'pending', ocrText = NULL, ocrAt = NULL, ocrVersion = NULL,
                        sha256 = NULL, byteSize = NULL, fileModifiedAt = NULL, updatedAt = ?
                    WHERE noteId = ? AND filenameKey = ? AND ocrState != 'locked'
                    """,
                arguments: [now, staged.noteId, fileSystemKey(name)])
            reset = reset || db.changesCount > 0
        }
        if reset, let text = try String.fetchOne(
            db, sql: "SELECT text FROM note WHERE id = ? AND isLocked = 0", arguments: [staged.noteId]
        ) {
            try NoteIndexer.refreshOCRSearchText(noteId: staged.noteId, text: text, in: db)
        }
    }

    /// Validates the names, then writes and fsyncs each file into a new, locked batch directory.
    /// On any failure the batch is removed.
    public func stage(_ files: [ImportedAttachment], noteId: String) throws -> Staged {
        try Self.validate(noteId)
        var seen = Set<String>()
        for file in files {
            try Self.validate(file.filename)
            guard Self.stagedName(file.filename).utf8.count <= 255 else { throw FileError.invalidFilename(file.filename) }
            guard seen.insert(Self.fileSystemKey(file.filename)).inserted else {
                throw FileError.duplicateFilename(file.filename)
            }
        }
        guard !files.isEmpty else { return Staged(noteId: noteId, batchID: UUID().uuidString, entries: [], lock: nil) }
        var staged = try newBatch(noteId: noteId)
        do {
            for file in files {
                let path = batchPath(staged.batchID) + "/" + noteId + "/" + Self.stagedName(file.filename)
                staged.entries.append(.init(filename: file.filename, path: path))
                try Self.writeSynced(file.data, to: path)
                AttachmentQuarantine.apply(AttachmentQuarantine.properties(from: file.source), to: path)
            }
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// Streams transformed files directly into a durable batch. The writer must create only
    /// its supplied destination; no plaintext temporary copy is needed for encryption.
    func stageTransformed(_ names: [String], noteId: String,
                          writer: (String, URL) throws -> Void) throws -> Staged {
        try Self.validate(noteId)
        var seen = Set<String>()
        for name in names {
            try Self.validate(name)
            guard Self.stagedName(name).utf8.count <= 255 else { throw FileError.invalidFilename(name) }
            guard seen.insert(Self.fileSystemKey(name)).inserted else { throw FileError.duplicateFilename(name) }
        }
        guard !names.isEmpty else { return Staged(noteId: noteId, batchID: UUID().uuidString, entries: [], lock: nil) }
        var staged = try newBatch(noteId: noteId)
        do {
            for name in names {
                let path = batchPath(staged.batchID) + "/" + noteId + "/" + Self.stagedName(name)
                staged.entries.append(.init(filename: name, path: path))
                try writer(name, URL(fileURLWithPath: path))
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.synchronize()
                try handle.close()
                AttachmentQuarantine.ensure(path)
            }
        } catch {
            discard(staged)
            throw error
        }
        return staged
    }

    /// An empty batch directory with its lock held and the note's subdirectory created.
    private func newBatch(noteId: String) throws -> Staged {
        let batchID = UUID().uuidString
        let dir = batchPath(batchID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        let lock: BatchLock
        do {
            // Recovery may lock (and remove) the new directory before we do; then this fails.
            guard let acquired = try BatchLock.acquire(dir + "/.lock") else { throw FileError.batchLocked }
            lock = acquired
            try FileManager.default.createDirectory(atPath: dir + "/" + noteId, withIntermediateDirectories: false)
        } catch {
            try? FileManager.default.removeItem(atPath: dir)
            throw error
        }
        return Staged(noteId: noteId, batchID: batchID, entries: [], lock: lock)
    }

    /// Removes a batch whose transaction did not commit, and releases its lock.
    public func discard(_ staged: Staged) {
        defer { staged.lock?.release() }
        guard staged.lock != nil else { return }
        try? FileManager.default.removeItem(atPath: batchPath(staged.batchID))
    }

    /// After the commit: renames each staged file into place (a copy first fetches what it is
    /// missing from its source), removes stale files when replacing, then deletes the batch
    /// directory and its row, and releases the lock. A batch superseded by a newer one (row gone)
    /// is discarded instead. A failed rename or copy is logged and leaves both for `recover`.
    public func install(_ staged: Staged) {
        defer { staged.lock?.release() }
        guard staged.hasRow(replacing: staged.replacing) else { return }
        guard rowExists(staged.batchID) else {
            storeLogger.notice("staging batch \(staged.batchID, privacy: .public) superseded by a newer one; discarded")
            if staged.lock != nil { try? FileManager.default.removeItem(atPath: batchPath(staged.batchID)) }
            return
        }
        var complete = true
        if let source = staged.copySource {
            complete = repairCopy(batchID: staged.batchID, noteId: staged.noteId, source: source, names: staged.names) == 0
        }
        let failed = moveIntoPlace(stagedEntries(batchID: staged.batchID, noteId: staged.noteId), noteId: staged.noteId)
        if staged.replacing { removeStale(noteId: staged.noteId, keeping: staged.names) }
        guard failed == 0, complete else { return }
        finish(batchID: staged.batchID, hasDirectory: staged.lock != nil)
    }

    /// See the recovery contract above. Safe while other processes write attachments.
    public func recover() throws -> Recovery {
        let fm = FileManager.default
        var result = Recovery()
        let rows = try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.id, b.noteId, b.replacing, b.filenames, EXISTS (SELECT 1 FROM note WHERE note.id = b.noteId)
                FROM staging_batch b ORDER BY b.rowid DESC
                """)
        }
        var committed = Set<String>()
        var installedNotes = Set<String>()
        for row in rows {
            let id: String = row[0], noteId: String = row[1], replacing: Bool = row[2]
            let filenames = (try? JSONDecoder().decode([String].self, from: Data((row[3] as String).utf8))) ?? []
            committed.insert(id)
            // Newest first: a later row of the same note supersedes this one, even while locked.
            let superseded = !installedNotes.insert(noteId).inserted
            let hasDirectory = fm.fileExists(atPath: batchPath(id))
            var lock: BatchLock?
            if hasDirectory {
                guard let acquired = try? BatchLock.acquire(batchPath(id) + "/.lock", attempts: Self.recoveryLockAttempts) else {
                    result.skipped += 1
                    continue
                }
                lock = acquired
            }
            defer { lock?.release() }
            guard row[4] as Bool, !superseded else {
                finish(batchID: id, hasDirectory: hasDirectory)
                result.discarded += 1
                continue
            }
            var missing = 0
            if let source = try? String(contentsOfFile: batchPath(id) + "/" + Self.copySourceName, encoding: .utf8) {
                missing = repairCopy(batchID: id, noteId: noteId, source: source, names: filenames)
                result.failedCopies += missing
            }
            let failed = moveIntoPlace(stagedEntries(batchID: id, noteId: noteId), noteId: noteId)
            result.failedRenames += failed
            if replacing { removeStale(noteId: noteId, keeping: filenames) }
            if failed == 0, missing == 0 { finish(batchID: id, hasDirectory: hasDirectory) }
            result.installed += 1
        }
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where !committed.contains(name) {
            var isDirectory: ObjCBool = false
            guard UUID(uuidString: name) != nil, fm.fileExists(atPath: batchPath(name), isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let lock = try? BatchLock.acquire(batchPath(name) + "/.lock", attempts: Self.recoveryLockAttempts) else {
                result.skipped += 1
                continue
            }
            // Its writer may have committed between the row query and the lock: then it is not
            // ours to remove (its writer, or the next recovery, installs it).
            guard !rowExists(name) else {
                lock.release()
                continue
            }
            try? fm.removeItem(atPath: batchPath(name))
            lock.release()
            result.discarded += 1
        }
        return result
    }

    /// Whether a batch directory in `.staging` holds files for `noteId` (being written or
    /// waiting for recovery).
    public func hasStagedFiles(for noteId: String) -> Bool {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).contains {
            UUID(uuidString: $0) != nil && fm.fileExists(atPath: batchPath($0) + "/" + noteId)
        }
    }

    /// Whether a pending copy batch still reads files from `noteId` (its `copy-source`).
    public func isCopySource(_ noteId: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).contains { name in
            guard UUID(uuidString: name) != nil,
                  let source = try? String(contentsOfFile: batchPath(name) + "/" + Self.copySourceName, encoding: .utf8)
            else { return false }
            return source.trimmingCharacters(in: .whitespacesAndNewlines) == noteId
        }
    }

    // MARK: - Copies (duplicate, conflict copy)

    /// Stages a copy of every file in `Attachments/<source>/` for the new note `target`
    /// (APFS clones), before the transaction that creates `target` records it. A file that cannot
    /// be copied is still recorded, and the batch remembers its source (`copy-source`), so
    /// `install` and later recoveries copy it again. Nil when the source has no files or no batch
    /// could be created (logged; the copy's links then dangle).
    public func stageCopy(from source: String, to target: String) -> Staged? {
        let fm = FileManager.default
        let sourceDir = directory(for: source).path
        let names = ((try? fm.contentsOfDirectory(atPath: sourceDir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return nil }
        var staged: Staged
        do {
            try Self.validate(source)
            staged = try newBatch(noteId: target)
        } catch {
            storeLogger.error("note \(target, privacy: .public): attachment copy not staged: \(error)")
            return nil
        }
        staged.recordedNames = names
        var failed = false
        for name in names {
            let path = batchPath(staged.batchID) + "/" + target + "/" + Self.stagedName(name)
            do {
                try fm.copyItem(atPath: sourceDir + "/" + name, toPath: path)
                AttachmentQuarantine.ensure(path)
                staged.entries.append(.init(filename: name, path: path))
            } catch {
                failed = true
                storeLogger.error("note \(target, privacy: .public): attachment not copied: \(error)")
            }
        }
        if failed {
            do {
                try Data(source.utf8).write(to: URL(fileURLWithPath: batchPath(staged.batchID) + "/" + Self.copySourceName))
                staged.copySource = source
            } catch {
                storeLogger.error("note \(target, privacy: .public): copy repair not recorded: \(error)")
            }
        }
        return staged
    }

    /// Copies into the batch the recorded files that are neither in place nor staged, from the
    /// source's directory. A file the source no longer has cannot be repaired and is dropped.
    /// Returns how many could not be copied; at 0 the `copy-source` marker is removed.
    private func repairCopy(batchID: String, noteId: String, source: String, names: [String]) -> Int {
        let fm = FileManager.default
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Self.validate(source)) != nil else { return 0 }
        let stagedDir = batchPath(batchID) + "/" + noteId
        let present = Set((((try? fm.contentsOfDirectory(atPath: directory(for: noteId).path)) ?? [])
            + ((try? fm.contentsOfDirectory(atPath: stagedDir)) ?? []).map(Self.decodeStagedName)).map(Self.fileSystemKey))
        var failed = 0
        for name in names where !present.contains(Self.fileSystemKey(name)) {
            let from = directory(for: source).path + "/" + name
            guard fm.fileExists(atPath: from) else { continue }
            do {
                try fm.createDirectory(atPath: stagedDir, withIntermediateDirectories: true)
                try fm.copyItem(atPath: from, toPath: stagedDir + "/" + Self.stagedName(name))
                AttachmentQuarantine.ensure(stagedDir + "/" + Self.stagedName(name))
            } catch {
                failed += 1
                storeLogger.error("note \(noteId, privacy: .public): attachment copy repair failed: \(error)")
            }
        }
        if failed == 0 { try? fm.removeItem(atPath: batchPath(batchID) + "/" + Self.copySourceName) }
        return failed
    }

    // MARK: - Single files (AttachmentStore)

    /// Stages `data`, then renames it into `Attachments/<noteId>/` under the first free name of
    /// `filename`, `name 2.ext`, `name 3.ext`, … (never replacing a file). No row: nothing
    /// references the file until the caller's text commits it, and a crash before the rename
    /// leaves only a rowless batch that recovery removes. Returns the name it got.
    public func place(_ data: Data, filename: String, noteId: String, source: URL? = nil) throws -> String {
        try database.pool.write { db in
            try place(data, filename: filename, noteId: noteId, source: source, in: db)
        }
    }

    /// AttachmentStore already owns the writer through its note-protection check.
    func place(_ data: Data, filename: String, noteId: String, source: URL? = nil, in db: Database) throws -> String {
        try NotePrivacy.requireNoPendingTransition(noteId, in: db)
        let staged = try stage([ImportedAttachment(filename: filename, data: data, source: source)], noteId: noteId)
        defer { discard(staged) }
        let dir = directory(for: noteId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stagedPath = staged.entries[0].path
        for candidate in Self.uniqueCandidates(filename) {
            guard Self.stagedName(candidate).utf8.count <= 255 else { break }
            if renamex_np(stagedPath, dir.path + "/" + candidate, UInt32(RENAME_EXCL)) == 0 {
                AttachmentQuarantine.ensure(dir.path + "/" + candidate)
                return candidate
            }
            guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dir.path]) }
        }
        throw FileError.invalidFilename(filename)
    }

    /// `name.ext`, `name 2.ext`, `name 3.ext`, … (Bear's collision names).
    static func uniqueCandidates(_ filename: String) -> some Sequence<String> {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return sequence(first: 1) { $0 + 1 }.lazy.map { n in
            n == 1 ? filename : ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
    }

    // MARK: - Internals

    private func rowExists(_ batchID: String) -> Bool {
        (try? database.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM staging_batch WHERE id = ?)", arguments: [batchID])
        }) ?? true
    }

    private func stagedEntries(batchID: String, noteId: String) -> [Staged.Entry] {
        let dir = batchPath(batchID) + "/" + noteId
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map {
            Staged.Entry(filename: Self.decodeStagedName($0), path: dir + "/" + $0)
        }
    }

    /// The number of files that could not be renamed (all of them if the directory is missing).
    private func moveIntoPlace(_ entries: [Staged.Entry], noteId: String) -> Int {
        guard !entries.isEmpty else { return 0 }
        let dir = directory(for: noteId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            storeLogger.error("note \(noteId, privacy: .public): attachment directory not created: \(error)")
            return entries.count
        }
        var failed = 0
        for entry in entries {
            let target = dir.path + "/" + entry.filename
            guard rename(entry.path, target) == 0 else {
                failed += 1
                storeLogger.error("note \(noteId, privacy: .public): attachment not moved into place (errno \(errno)), left in staging")
                continue
            }
            // Staged files have their record already; one staged by an older build gets one now.
            AttachmentQuarantine.ensure(target)
        }
        return failed
    }

    private func removeStale(noteId: String, keeping filenames: [String]) {
        let fm = FileManager.default
        let dir = directory(for: noteId)
        guard let existing = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let keep = Set(filenames.map(Self.fileSystemKey))
        for name in existing where !keep.contains(Self.fileSystemKey(name)) {
            do {
                try fm.removeItem(at: dir.appendingPathComponent(name))
            } catch {
                storeLogger.error("note \(noteId, privacy: .public): stale attachment not removed: \(error)")
            }
        }
    }

    /// Deletes the batch directory, then the row (the commit marker goes last).
    private func finish(batchID: String, hasDirectory: Bool) {
        if hasDirectory { try? FileManager.default.removeItem(atPath: batchPath(batchID)) }
        do {
            try database.pool.write { db in
                try db.execute(sql: "DELETE FROM staging_batch WHERE id = ?", arguments: [batchID])
            }
        } catch {
            storeLogger.error("staging batch \(batchID, privacy: .public): row not deleted: \(error)")
        }
    }

    /// `%` → `%25`; names are already single path components without NUL.
    static func stagedName(_ filename: String) -> String {
        filename.replacingOccurrences(of: "%", with: "%25")
    }

    public static func decodeStagedName(_ staged: String) -> String {
        staged.replacingOccurrences(of: "%25", with: "%")
    }

    /// How a case- and normalization-insensitive file system compares names.
    public static func fileSystemKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func validate(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.unicodeScalars.contains("\u{0}"),
              filename.utf8.count <= 255
        else { throw FileError.invalidFilename(filename) }
    }

    private static func writeSynced(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }
}
