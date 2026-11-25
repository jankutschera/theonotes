// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import CryptoKit
import Foundation
import GRDB
import Synchronization

/// Optimistic source ticket verified under the SAME writer that adds the new attachment.
/// The original remains untouched for Undo. Both plaintext and protected callers use plaintext hashes.
public struct AttachmentSourceGuard: Sendable {
    public enum Failure: Error, Equatable { case changed }
    public let filename: String
    public let plaintextSHA256: String
    public let maximumBytes: Int
    public let expectedNoteRevision: Int
    public init(filename: String, plaintextSHA256: String, maximumBytes: Int, expectedNoteRevision: Int) {
        self.filename = filename; self.plaintextSHA256 = plaintextSHA256
        self.maximumBytes = maximumBytes; self.expectedNoteRevision = expectedNoteRevision
    }
    func validate(note: Note) throws {
        guard note.revision == expectedNoteRevision, !note.isReadOnly, note.deletedAt == nil, note.location == .notes,
              maximumBytes >= 0, maximumBytes <= 64 * 1024 * 1024 else { throw Failure.changed }
        try AttachmentFiles.validate(filename)
    }
    func validate(bytes: Data) throws {
        guard bytes.count <= maximumBytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == plaintextSHA256
        else { throw Failure.changed }
    }
    /// No-follow bounded read; an in-place write or replacement during the read invalidates the ticket.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes <= 64 * 1024 * 1024 else { throw Failure.changed }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.changed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { throw Failure.changed }
        var result = Data()
        while let bytes = try handle.read(upToCount: min(64 * 1024, maximumBytes - result.count + 1)), !bytes.isEmpty {
            try Task.checkCancellation()
            guard bytes.count <= maximumBytes - result.count else { throw Failure.changed }
            result.append(bytes)
        }
        var after = stat(), current = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &current) == 0,
              result.count == before.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              current.st_dev == after.st_dev, current.st_ino == after.st_ino else { throw Failure.changed }
        return result
    }
}

/// The files of a note's attachments for the editor (spec §4.4): adding (drop, paste, ⇧⌘V),
/// renaming, deleting and resolving them. Writes follow the staging rule (`AttachmentFiles`).
///
/// Every file written gets a quarantine record (`AttachmentQuarantine`): copied from the source
/// file of `add(fileAt:)`, fresh for bytes.
///
/// Nothing here edits note text: the editor inserts or rewrites the link, and files no committed
/// text references any more are removed by `NoteStore.removeUnreferencedAttachments`.
public struct AttachmentStore: Sendable {
    /// Longest filename (UTF-8 bytes) `add` gives a file, leaving room for ` 99`.
    static let maxNameBytes = 200

    private let files: AttachmentFiles
    private let database: AppDatabase

    public init(paths: AppPaths, database: AppDatabase) {
        files = AttachmentFiles(paths: paths, database: database)
        self.database = database
    }

    /// Writes `data` into `Attachments/<noteId>/` under a cleaned-up, unique version of
    /// `filename` (Bear's collision names: `photo 2.jpg`). Returns the name it got.
    public func add(data: Data, filename: String, to noteId: String) throws -> String {
        try mutate([noteId]) { try files.place(data, filename: Self.usableName(filename), noteId: noteId, in: $0) }
    }

    /// One durable staging batch; a transaction failure leaves none of the new files installed.
    public func addBatch(_ inputs: [ImportedAttachment], to noteId: String, validatingSource source: AttachmentSourceGuard? = nil) throws -> [String] {
        guard !inputs.isEmpty else { return [] }
        var staged: AttachmentFiles.Staged?
        let names: [String]
        do {
            names = try mutate([noteId]) { db in
                if let source {
                    try source.validate(note: NoteStore.require(noteId, in: db))
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE noteId=? AND filenameKey=? AND deletedAt IS NULL)",
                        arguments: [noteId, AttachmentFiles.fileSystemKey(source.filename)]) == true,
                          let sourceURL = try url(for: source.filename, noteId: noteId, in: db) else { throw AttachmentSourceGuard.Failure.changed }
                    try source.validate(bytes: AttachmentSourceGuard.read(sourceURL, maximumBytes: source.maximumBytes))
                }
                let directory = files.directory(for: noteId)
                let present = FileManager.default.fileExists(atPath: directory.path)
                    ? try FileManager.default.contentsOfDirectory(atPath: directory.path) : []
                var reserved = Set(present.map(AttachmentFiles.fileSystemKey))
                reserved.formUnion(try String.fetchAll(db, sql: "SELECT filenameKey FROM attachment WHERE noteId=?", arguments: [noteId]))
                let imported = inputs.map { input -> ImportedAttachment in
                    let name = AttachmentFiles.uniqueCandidates(Self.usableName(input.filename)).first {
                        !reserved.contains(AttachmentFiles.fileSystemKey($0))
                    }!
                    reserved.insert(AttachmentFiles.fileSystemKey(name))
                    return ImportedAttachment(filename: name, data: input.data, source: input.source)
                }
                let batch = try files.stage(imported, noteId: noteId)
                staged = batch
                try AttachmentFiles.record(batch, in: db)
                return imported.map(\.filename)
            }
        } catch {
            if let staged { files.discard(staged) }
            throw error
        }
        if let staged {
            files.install(staged)
            // install deliberately retains failed batches for recovery. Do not claim that
            // callers can insert links until this specific committed batch is installed.
            try database.pool.read { db in
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE id=?)", arguments: [staged.batchID]) == true {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: files.directory(for: noteId).path])
                }
            }
        }
        return names
    }

    /// Copies the file at `url` in (the original stays where it is), with the original's
    /// quarantine record.
    public func add(fileAt url: URL, to noteId: String) throws -> String {
        try mutate([noteId]) { db in
            try files.place(Data(contentsOf: url, options: .mappedIfSafe), filename: Self.usableName(url.lastPathComponent),
                            noteId: noteId, source: url, in: db)
        }
    }

    /// Copies `filename` of note `source` into `noteId` under a unique name, with the source's
    /// quarantine record (a link copied from one note and pasted into another: Bear copies the
    /// file). Returns the name it got.
    public func copy(_ filename: String, from source: String, to noteId: String) throws -> String {
        try mutate([source, noteId]) { db in
            guard let url = fileURL(for: filename, noteId: source) else { throw AttachmentFiles.FileError.invalidFilename(filename) }
            return try files.place(Data(contentsOf: url, options: .mappedIfSafe), filename: filename, noteId: noteId, source: url, in: db)
        }
    }

    /// Gives the file a second, unique name derived from `newName` (a hard link, so it costs no
    /// space). The old name stays until no committed text references it, so undoing the link
    /// rewrite keeps working. Returns the new name.
    public func rename(_ filename: String, to newName: String, in noteId: String) throws -> String {
        try mutate([noteId]) { try renameFile(filename, to: newName, in: noteId, db: $0) }
    }

    private func renameFile(_ filename: String, to newName: String, in noteId: String, db: Database) throws -> String {
        guard let source = fileURL(for: filename, noteId: noteId) else { throw AttachmentFiles.FileError.invalidFilename(filename) }
        let dir = files.directory(for: noteId).path
        for candidate in AttachmentFiles.uniqueCandidates(Self.usableName(newName)) {
            if link(source.path, dir + "/" + candidate) == 0 { return candidate }
            guard errno == EEXIST else { break }
        }
        // No hard links on this volume: a copy through staging.
        return try files.place(Data(contentsOf: source, options: .mappedIfSafe), filename: Self.usableName(newName),
                               noteId: noteId, source: source, in: db)
    }

    /// Removes the file now. (The editor's Delete removes the link only; the file follows with
    /// the cleanup once the note is committed and closed.)
    public func delete(_ filename: String, from noteId: String) throws {
        try mutate([noteId]) { _ in
            guard let url = fileURL(for: filename, noteId: noteId) else { throw AttachmentFiles.FileError.invalidFilename(filename) }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The regular file `filename` of the note, or nil: invalid names (`..`, `/`, NUL), a note
    /// id that is not a single path component, symlinks (also to files of other notes) and
    /// anything that is not a regular file.
    public func url(for filename: String, noteId: String) -> URL? {
        try? database.pool.read { try url(for: filename, noteId: noteId, in: $0) }
    }

    /// For callers already reading a library snapshot. Keeps the privacy check in the same
    /// transaction without recursively entering the database pool.
    public func url(for filename: String, noteId: String, in db: Database) throws -> URL? {
        guard try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [noteId]) == false else { return nil }
        return fileURL(for: filename, noteId: noteId)
    }

    private struct PendingRecovery: Error {}

    private func mutate<T>(_ noteIds: [String], body: (Database) throws -> T) throws -> T {
        var attemptedRecovery = false
        while true {
            do {
                return try database.pool.write { db in
                    for id in noteIds {
                        try NotePrivacy.requireNoPendingTransition(id, in: db)
                        if try Bool.fetchOne(db, sql: "SELECT isLocked FROM note WHERE id = ?", arguments: [id]) == true {
                            throw StoreError.noteLocked(id: id)
                        }
                        for batchID in try String.fetchAll(db, sql: "SELECT id FROM staging_batch WHERE noteId=?", arguments: [id]) {
                            let directory = files.staging.appendingPathComponent(batchID)
                            if FileManager.default.fileExists(atPath: directory.path) {
                                guard let lock = try BatchLock.acquire(directory.appendingPathComponent(".lock").path) else {
                                    throw AttachmentFiles.FileError.batchLocked
                                }
                                lock.release()
                            }
                            guard !attemptedRecovery else {
                                throw CocoaError(.fileWriteUnknown, userInfo: [
                                    NSFilePathErrorKey: files.directory(for: id).path,
                                    NSLocalizedDescriptionKey: "The note's pending attachments could not be recovered.",
                                ])
                            }
                            throw PendingRecovery()
                        }
                    }
                    return try body(db)
                }
            } catch is PendingRecovery {
                // Recovery enters the pool itself; leave the writer before running it.
                _ = try files.recover()
                attemptedRecovery = true
            }
        }
    }

    private func fileURL(for filename: String, noteId: String) -> URL? {
        guard (try? AttachmentFiles.validate(filename)) != nil, (try? AttachmentFiles.validate(noteId)) != nil,
              !noteId.hasPrefix(".") else { return nil }
        let dir = files.directory(for: noteId)
        guard let directoryValues = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]),
              directoryValues.isSymbolicLink != true else { return nil }
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let resolvedDir = dir.resolvingSymlinksInPath().path
        guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == resolvedDir else { return nil }
        return url
    }

    /// A single path component without `/`, `:`, control characters or leading dots, at most
    /// `maxNameBytes` long (the extension kept); "file" when nothing is left.
    public static func usableName(_ filename: String) -> String {
        var name = String(String.UnicodeScalarView(filename.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" ? "-" : scalar
        }.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        name = String(name.drop(while: { $0 == "." || $0 == " " })).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "file" }
        guard name.utf8.count > maxNameBytes else { return name }
        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxNameBytes { base.removeLast() }
        return base.isEmpty ? String(name.prefix(32)) : base + suffix
    }
}

/// Notes whose attachment files must stay even when the committed text stops referencing them:
/// those open in an editor session in this process (unsaved edits or the editor's undo history
/// may link them again). Thread-safe; the app updates it as sessions open and close.
public final class AttachmentRetention: Sendable {
    private let retained = Mutex<[String: Int]>([:])

    /// Files of copied or cut attachment links (ruling R30): kept while the pasteboard still holds
    /// that copy (`token`, its change count; nil until it settled after the copy) and at most 24 h.
    private struct Held: Sendable {
        var noteId: String
        var key: String
        var token: Int?
        var until: Date
    }
    private let held = Mutex<[Held]>([])
    private let currentToken = Mutex<(@Sendable () -> Int)?>(nil)
    public static let maxHold: TimeInterval = 24 * 60 * 60

    public init() {}

    /// What tells whether the pasteboard changed (the app: `NSPasteboard.general.changeCount`).
    public func setPasteboardToken(_ provider: @escaping @Sendable () -> Int) {
        currentToken.withLock { $0 = provider }
    }

    /// Keeps `names` of `noteId` for a paste. The pasteboard token is taken by `settleHeldFiles`,
    /// once the copy has reached the pasteboard.
    public func holdFiles(_ names: [String], of noteId: String, now: Date = .now) {
        let keys = names.map(AttachmentFiles.fileSystemKey)
        held.withLock { entries in
            entries.removeAll { $0.noteId == noteId && keys.contains($0.key) }
            entries += keys.map { Held(noteId: noteId, key: $0, token: nil, until: now.addingTimeInterval(Self.maxHold)) }
        }
    }

    /// Gives held files without a token the pasteboard's current one.
    public func settleHeldFiles() {
        guard let token = currentToken.withLock({ $0 })?() else { return }
        held.withLock { entries in
            for i in entries.indices where entries[i].token == nil { entries[i].token = token }
        }
    }

    /// Whether a copied link still holds the file; drops entries whose pasteboard changed or
    /// whose 24 h are over.
    public func holds(_ name: String, of noteId: String, now: Date = .now) -> Bool {
        let token = currentToken.withLock({ $0 })?()
        let key = AttachmentFiles.fileSystemKey(name)
        return held.withLock { entries in
            entries.removeAll { $0.until <= now || ($0.token != nil && token != nil && $0.token != token) }
            return entries.contains { $0.noteId == noteId && $0.key == key }
        }
    }

    public func retain(_ noteId: String) {
        retained.withLock { $0[noteId, default: 0] += 1 }
    }

    public func release(_ noteId: String) {
        retained.withLock { counts in
            guard let count = counts[noteId] else { return }
            counts[noteId] = count > 1 ? count - 1 : nil
        }
    }

    public func contains(_ noteId: String) -> Bool {
        retained.withLock { $0[noteId] != nil }
    }
}
