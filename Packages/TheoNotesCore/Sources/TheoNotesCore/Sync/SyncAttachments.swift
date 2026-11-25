// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Darwin
import Foundation
import GRDB

public struct SyncAttachmentPayload: Codable, Equatable, Sendable {
    public var version = 1
    public let id: String
    public let noteId: String
    public let filename: String
    public let isLocked: Bool
    public let blobHash: String
    public let cipherBytes: Int64
    /// For a protected attachment these describe the inner ciphertext, never its plaintext.
    public let fileBytes: Int64
    public let fileHash: String
    public let uti: String?
    public let width: Int?
    public let height: Int?
    public let ocrText: String?
    public let createdAt: Int64
    public let updatedAt: Int64

    public func validate() throws {
        guard version == 1 else { throw SyncProtocolError.unsupportedVersion }
        try SyncWire.validateID(id); try SyncWire.validateID(noteId)
        try AttachmentFiles.validate(filename)
        guard !filename.hasPrefix("."), cipherBytes > 0, cipherBytes <= SyncWire.maximumBlobBytes,
              fileBytes >= 0, fileBytes < cipherBytes,
              blobHash.count == 64, fileHash.count == 64,
              (blobHash + fileHash).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !isLocked || (filename == id + ".bch" && uti == nil && width == nil && height == nil && ocrText == nil)
        else { throw SyncProtocolError.invalidPayload }
    }
}

/// Streams file encryption away from the SQLite writer. The final transaction verifies both
/// the semantic generation and open-file identity before publishing a reusable encrypted blob.
/// A crash before that transaction leaves an unreferenced ciphertext file, never a queued
/// mutation pointing at absent bytes. Password-protected attachments remain inner ciphertext.
public actor SyncAttachmentPreparer {
    private let database: AppDatabase
    private let paths: AppPaths
    private let accountID: String
    private let vaultKey: SymmetricKey
    private var scanAfter: String?

    public init(database: AppDatabase, paths: AppPaths, accountID: String, vaultKey: SymmetricKey) {
        self.database = database; self.paths = paths; self.accountID = accountID; self.vaultKey = vaultKey
    }

    @discardableResult public func preparePending(limit: Int = 100) throws -> Int {
        func candidates(after: String?) throws -> [String] { try database.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT d.localId FROM sync_dirty d WHERE d.entityType='attachment' AND d.tombstone=0
                  AND NOT EXISTS(SELECT 1 FROM sync_outbox o WHERE o.entityType='attachment' AND o.localId=d.localId)
                  AND (? IS NULL OR d.localId>?)
                ORDER BY d.localId LIMIT ?
                """, arguments: [after, after, max(1, min(limit, 1000))])
        } }
        var ids = try candidates(after: scanAfter)
        if ids.isEmpty, scanAfter != nil { scanAfter = nil; ids = try candidates(after: nil) }
        var ready = 0
        for id in ids {
            try Task.checkCancellation()
            scanAfter = id
            do { if try prepare(id: id) { ready += 1 } }
            catch SyncQueueError.snapshotUnavailable { continue }
        }
        return ready
    }

    /// Internal entry point also permits deterministic concurrent-edit tests.
    func prepare(id: String, beforeCommit: @Sendable () throws -> Void = {},
                 verifyCached: @Sendable (String, AppPaths, String, Int64) throws -> (url: URL, relative: String) = {
                     try SyncBlobLocation.verified($0, paths: $1, hash: $2, size: $3)
                 }) throws -> Bool {
        let snapshot = try database.pool.read { try Snapshot.read(id: id, accountID: accountID, in: $0) }
        guard let snapshot else { return false }
        let input = try OpenAttachment(paths: paths, noteId: snapshot.noteId, filename: snapshot.filename)
        defer { try? input.handle.close() }
        let fingerprint = try input.fingerprint()
        let cached = try database.pool.read { db -> (String, String, Int64, Data)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.generation,c.fingerprint,c.encryptedDescriptor,b.localPath,c.blobHash,b.byteSize FROM sync_attachment_cache c
                JOIN sync_blob_state b ON b.hash=c.blobHash WHERE c.attachmentId=?
                """, arguments: [id]), row["generation"] as Int64 == snapshot.generation,
                  row["fingerprint"] as String == fingerprint, let path: String = row["localPath"]
            else { return nil }
            let encrypted: Data = row["encryptedDescriptor"]
            let context = try SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: id)
            do {
                let plain = try NoteCipher.open(encrypted, vaultKey: vaultKey, context: context + ":cache")
                let descriptor = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain)
                try descriptor.validate()
                let expected = SyncAttachmentPayload(id: id, noteId: snapshot.noteId, filename: snapshot.filename,
                    isLocked: snapshot.isLocked, blobHash: row["blobHash"], cipherBytes: row["byteSize"],
                    fileBytes: descriptor.fileBytes, fileHash: descriptor.fileHash,
                    uti: snapshot.isLocked ? nil : snapshot.uti, width: snapshot.isLocked ? nil : snapshot.width,
                    height: snapshot.isLocked ? nil : snapshot.height, ocrText: snapshot.isLocked ? nil : snapshot.ocrText,
                    createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt)
                // Dirty generations restart after acceptance; the full descriptor must still match.
                guard plain == (try SyncPayloadCodec.encoder().encode(expected)) else { return nil }
                return (path, row["blobHash"], row["byteSize"], encrypted)
            } catch is CryptoError { return nil }
            catch is DecodingError { return nil }
            catch is SyncProtocolError { return nil }
        }
        var resolved: (url: URL, relative: String)?
        if let cached {
            do { resolved = try verifyCached(cached.0, paths, cached.1, cached.2) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        if let cached, let resolved {
            try beforeCommit()
            try database.pool.write { db in
                guard try Snapshot.read(id: id, accountID: accountID, in: db) == snapshot,
                      try input.fingerprint() == fingerprint,
                      try Data.fetchOne(db, sql: "SELECT encryptedDescriptor FROM sync_attachment_cache WHERE attachmentId=? AND generation=? AND fingerprint=?",
                        arguments: [id, snapshot.generation, fingerprint]) == cached.3 else { throw SyncQueueError.snapshotUnavailable }
                let current = try OpenAttachment(paths: paths, noteId: snapshot.noteId, filename: snapshot.filename)
                defer { try? current.handle.close() }
                guard try current.fingerprint() == fingerprint else { throw SyncQueueError.snapshotUnavailable }
                try db.execute(sql: "UPDATE sync_blob_state SET localPath=? WHERE hash=? AND localPath=?",
                               arguments: [resolved.relative, cached.1, cached.0])
            }
            return true
        }

        let directory = paths.root.appendingPathComponent("SyncBlobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(UUIDv7.make() + ".bch")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: output) } }
        let context = try SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: id)
        var sourceHash = SHA256(), sourceBytes: Int64 = 0
        try ChunkedCipher.encrypt(output: output, keyEncryptionKey: vaultKey, context: context) {
            try Task.checkCancellation()
            let data = try input.handle.read(upToCount: ChunkedCipher.chunkSize) ?? Data()
            sourceBytes += Int64(data.count)
            guard sourceBytes < SyncWire.maximumBlobBytes - 100_000 else { throw SyncProtocolError.invalidPayload }
            sourceHash.update(data: data)
            return data
        }
        guard try input.fingerprint() == fingerprint else { throw SyncQueueError.snapshotUnavailable }
        let cipher = try Self.hashFile(output)
        let descriptor = SyncAttachmentPayload(id: id, noteId: snapshot.noteId, filename: snapshot.filename,
            isLocked: snapshot.isLocked, blobHash: cipher.hash, cipherBytes: cipher.size,
            fileBytes: sourceBytes, fileHash: sourceHash.finalize().map { String(format: "%02x", $0) }.joined(),
            uti: snapshot.isLocked ? nil : snapshot.uti, width: snapshot.isLocked ? nil : snapshot.width,
            height: snapshot.isLocked ? nil : snapshot.height, ocrText: snapshot.isLocked ? nil : snapshot.ocrText,
            createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt)
        try descriptor.validate()
        let encrypted = try NoteCipher.seal(SyncPayloadCodec.encoder().encode(descriptor), vaultKey: vaultKey, context: context + ":cache")
        try beforeCommit()
        try database.pool.write { db in
            guard try Snapshot.read(id: id, accountID: accountID, in: db) == snapshot,
                  try input.fingerprint() == fingerprint else { throw SyncQueueError.snapshotUnavailable }
            // Reopen from the directory to detect replacement/rename while the old fd remained valid.
            let current = try OpenAttachment(paths: paths, noteId: snapshot.noteId, filename: snapshot.filename)
            defer { try? current.handle.close() }
            guard try current.fingerprint() == fingerprint else { throw SyncQueueError.snapshotUnavailable }
            try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)",
                           arguments: [cipher.hash, "SyncBlobs/" + output.lastPathComponent, cipher.size])
            try db.execute(sql: """
                INSERT INTO sync_attachment_cache(attachmentId,generation,fingerprint,encryptedDescriptor,blobHash) VALUES(?,?,?,?,?)
                ON CONFLICT(attachmentId) DO UPDATE SET generation=excluded.generation,fingerprint=excluded.fingerprint,
                  encryptedDescriptor=excluded.encryptedDescriptor,blobHash=excluded.blobHash
                """, arguments: [id, snapshot.generation, fingerprint, encrypted, cipher.hash])
            // A file can arrive or change without another text edit. Refresh its parent's
            // version pins so a later privacy transition can still recover these bytes.
            try SyncMaterializer.markNote(snapshot.noteId, deleted: false, in: db)
        }
        keep = true
        return true
    }

    nonisolated static func capture(_ dirty: SyncDirty, accountID: String, vaultKey: SymmetricKey, in db: Database) throws -> SyncContent {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM attachment WHERE id=?)", arguments: [dirty.localID]) == true else { return SyncContent(payload: nil) }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_attachment_cache WHERE attachmentId=? AND generation=?",
            arguments: [dirty.localID, dirty.generation]) else { throw SyncQueueError.snapshotUnavailable }
        let context = try SyncWire.cipherContext(accountID: accountID, type: .attachment, entityID: dirty.localID)
        let (plain, descriptor) = try decodeCached(row["encryptedDescriptor"], vaultKey: vaultKey, context: context)
        guard descriptor.id == dirty.localID, descriptor.blobHash == row["blobHash"] as String else { throw SyncQueueError.snapshotUnavailable }
        return SyncContent(payload: plain, blobRefs: [descriptor.blobHash])
    }

    nonisolated static func decodeCached(_ encrypted: Data, vaultKey: SymmetricKey, context: String) throws -> (Data, SyncAttachmentPayload) {
        do {
            let plain = try NoteCipher.open(encrypted, vaultKey: vaultKey, context: context + ":cache")
            let descriptor = try SyncPayloadCodec.decode(SyncAttachmentPayload.self, from: plain)
            try descriptor.validate()
            return (plain, descriptor)
        } catch is CryptoError { throw SyncQueueError.snapshotUnavailable }
        catch is DecodingError { throw SyncQueueError.snapshotUnavailable }
        catch is SyncProtocolError { throw SyncQueueError.snapshotUnavailable }
    }

    nonisolated static func hashFile(_ url: URL) throws -> (hash: String, size: Int64) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), size: Int64 = 0
        while let chunk = try file.read(upToCount: ChunkedCipher.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk); size += Int64(chunk.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    private struct Snapshot: Equatable {
        let id: String, noteId: String, filename: String
        let generation: Int64, createdAt: Int64, updatedAt: Int64
        let isLocked: Bool
        let uti: String?, width: Int?, height: Int?, ocrText: String?

        static func read(id: String, accountID: String, in db: Database) throws -> Self? {
            guard try String.fetchOne(db, sql: "SELECT accountId FROM sync_control WHERE enabled=1") == accountID else { throw SyncQueueError.notEnabled }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT a.*,n.isLocked,d.generation FROM attachment a JOIN note n ON n.id=a.noteId
                JOIN sync_dirty d ON d.entityType='attachment' AND d.localId=a.id
                WHERE a.id=? AND d.tombstone=0
                """, arguments: [id]) else { return nil }
            let noteId: String = row["noteId"]
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM privacy_transition WHERE noteId=?) OR EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?)",
                arguments: [noteId, noteId]) == false else { throw SyncQueueError.snapshotUnavailable }
            return Self(id: id, noteId: noteId, filename: row["filename"], generation: row["generation"],
                createdAt: SyncNotePayload.milliseconds(row["createdAt"] as Date), updatedAt: SyncNotePayload.milliseconds(row["updatedAt"] as Date),
                isLocked: row["isLocked"], uti: row["uti"], width: row["width"], height: row["height"], ocrText: row["ocrText"])
        }
    }

    /// Presence only: reuse the preparer's path validation and no-follow regular-file open.
    /// Do not fingerprint, read, encrypt, or modify the source while summarizing the queue.
    nonisolated static func hasSource(paths: AppPaths, noteId: String, filename: String) -> Bool {
        guard let input = try? OpenAttachment(paths: paths, noteId: noteId, filename: filename) else { return false }
        try? input.handle.close()
        return true
    }

    private struct OpenAttachment {
        let handle: FileHandle
        init(paths: AppPaths, noteId: String, filename: String) throws {
            try SyncWire.validateID(noteId); try AttachmentFiles.validate(filename)
            let root = open(paths.attachments.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw SyncQueueError.snapshotUnavailable }; defer { close(root) }
            let directory = openat(root, noteId, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw SyncQueueError.snapshotUnavailable }; defer { close(directory) }
            let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw SyncQueueError.snapshotUnavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); throw SyncQueueError.snapshotUnavailable }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        func fingerprint() throws -> String {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw SyncQueueError.snapshotUnavailable }
            return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
    }
}

/// Durable cache pointers are library-relative. Legacy sandbox prefixes are never opened:
/// only a recognized cache directory and filename can be rebound to this library.
enum SyncBlobLocation {
    static func relative(_ stored: String) throws -> String {
        guard !stored.contains("\\"), !stored.contains("\0") else { throw SyncProtocolError.invalidPayload }
        let components = stored.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else { throw SyncProtocolError.invalidPayload }
        let parts: [String]
        if stored.hasPrefix("/") {
            guard components.count >= 3 else { throw SyncProtocolError.invalidPayload }
            parts = components.suffix(2).map(String.init)
        } else { parts = components.map(String.init) }
        guard parts.count == 2 else { throw SyncProtocolError.invalidPayload }
        let name = parts[1]
        switch parts[0] {
        case "SyncBlobs":
            guard name.hasSuffix(".bch"), UUID(uuidString: String(name.dropLast(4))) != nil else { throw SyncProtocolError.invalidPayload }
        case "SyncDownloads":
            try SyncWire.validateHash(name)
        default: throw SyncProtocolError.invalidPayload
        }
        return parts.joined(separator: "/")
    }

    /// Cheap read-only presence check for summaries. Integrity remains the uploader's job.
    static func isPresent(_ stored: String, paths: AppPaths, hash: String, size: Int64) -> Bool {
        guard (try? SyncWire.validateHash(hash)) != nil,
              let relative = try? relative(stored) else { return false }
        let pieces = relative.split(separator: "/").map(String.init)
        if pieces[0] == "SyncDownloads", pieces[1] != hash { return false }
        let base = paths.root.resolvingSymlinksInPath()
        let root = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return false }; defer { close(root) }
        let directory = openat(root, pieces[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return false }; defer { close(directory) }
        let fd = openat(directory, pieces[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_size == size
    }

    /// Stage transport-owned bytes before the materializer enters its coordinated DB commit.
    static func pinDownloaded(_ source: URL, paths: AppPaths, hash: String, size: Int64) throws -> URL {
        try SyncWire.validateHash(hash)
        let base = paths.root.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("SyncDownloads", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw SyncProtocolError.invalidPayload }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent(hash)
        if !FileManager.default.fileExists(atPath: local.path) {
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            let measured = try SyncAttachmentPreparer.hashFile(temporary)
            guard measured.hash == hash, measured.size == size else { throw SyncProtocolError.invalidPayload }
            do { try FileManager.default.moveItem(at: temporary, to: local) }
            catch { guard FileManager.default.fileExists(atPath: local.path) else { throw error } }
        }
        return try verified("SyncDownloads/" + hash, paths: paths, hash: hash, size: size).url
    }

    static func verified(_ stored: String, paths: AppPaths, hash: String, size: Int64) throws -> (url: URL, relative: String) {
        let relative = try relative(stored)
        let pieces = relative.split(separator: "/").map(String.init)
        if pieces[0] == "SyncDownloads", pieces[1] != hash { throw SyncProtocolError.invalidPayload }
        let base = paths.root.resolvingSymlinksInPath()
        let root = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw SyncQueueError.snapshotUnavailable }; defer { close(root) }
        let directory = openat(root, pieces[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SyncQueueError.snapshotUnavailable }; defer { close(directory) }
        let fd = openat(directory, pieces[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw SyncQueueError.snapshotUnavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == size else {
            throw SyncProtocolError.invalidPayload
        }
        var checksum = SHA256(), count: Int64 = 0
        while let bytes = try file.read(upToCount: ChunkedCipher.chunkSize), !bytes.isEmpty {
            try Task.checkCancellation()
            count += Int64(bytes.count); checksum.update(data: bytes)
        }
        let actual = checksum.finalize().map { String(format: "%02x", $0) }.joined()
        var after = stat()
        guard count == size, actual == hash, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw SyncProtocolError.invalidPayload }
        return (base.appendingPathComponent(relative), relative)
    }
}
