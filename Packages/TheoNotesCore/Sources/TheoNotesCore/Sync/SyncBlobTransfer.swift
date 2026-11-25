// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Synchronization

public protocol SyncBlobTransport: Sendable {
    func ensureUploaded(_ hashes: [String]) async throws
    func download(hash: String) async throws -> URL
}

/// The database owns multipart progress; no successful part is forgotten on process restart.
/// Only ciphertext is staged or sent. Download size and SHA-256 are checked before publication.
public actor SyncBlobTransfer: SyncBlobTransport {
    private let database: AppDatabase
    private let paths: AppPaths
    private let transport: HTTPSyncTransport
    private let session: URLSession
    private let files: (any SyncBlobFileTransfer)?
    private var uploading: [String: Task<Void, any Error>] = [:]
    private var downloading: [String: Task<URL, any Error>] = [:]
    private var closed = false

    public init(database: AppDatabase, paths: AppPaths, transport: HTTPSyncTransport,
                session: URLSession = URLSession(configuration: .ephemeral), files: (any SyncBlobFileTransfer)? = nil) {
        self.database = database; self.paths = paths; self.transport = transport; self.session = session; self.files = files
    }
    public func shutdown() async {
        closed = true
        let uploads = Array(uploading.values), downloads = Array(downloading.values)
        uploads.forEach { $0.cancel() }; downloads.forEach { $0.cancel() }
        session.invalidateAndCancel()
        for task in uploads { _ = try? await task.value }
        for task in downloads { _ = try? await task.value }
    }
    public func ensureUploaded(_ hashes: [String]) async throws {
        guard !closed else { throw CancellationError() }
        for hash in Set(hashes).sorted() {
            try SyncWire.validateHash(hash); try Task.checkCancellation()
            if let task = uploading[hash] { try await awaitTransfer(task); continue }
            let task = Task { try await self.upload(hash: hash) }
            uploading[hash] = task
            do { try await awaitTransfer(task); uploading.removeValue(forKey: hash) }
            catch { uploading.removeValue(forKey: hash); throw error }
        }
    }
    public func download(hash: String) async throws -> URL {
        guard !closed else { throw CancellationError() }
        try SyncWire.validateHash(hash)
        if let task = downloading[hash] { return try await awaitTransfer(task) }
        let task = Task { try await self.fetchBlob(hash: hash) }
        downloading[hash] = task
        do { let value = try await awaitTransfer(task); downloading.removeValue(forKey: hash); return value }
        catch { downloading.removeValue(forKey: hash); throw error }
    }

    private func awaitTransfer<Value: Sendable>(_ task: Task<Value, any Error>) async throws -> Value {
        try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }

    private struct Blob: Sendable {
        let data: Data?, path: String?, size: Int64, uploaded: Bool, multipartId: String?, parts: String?
    }
    private struct Part: Codable, Sendable { let partNumber: Int; let etag: String }
    private struct Prepare: Decodable, Sendable {
        let hash: String, ready: Bool
        let mode: String?, url: URL?, headers: [String: String]?, expiresAt: Int64?
        let uploadId: String?, partSize: Int64?, partCount: Int?
    }
    private struct Signed: Decodable, Sendable {
        let url: URL, headers: [String: String], expiresAt: Int64
        let size: Int64?, hash: String?, partNumber: Int?
    }
    private struct Ready: Decodable, Sendable { let hash: String; let ready: Bool }

    private func upload(hash: String, allowRestart: Bool = true) async throws {
        guard let blob = try await database.pool.read({ db -> Blob? in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_blob_state WHERE hash=?", arguments: [hash]) else { return nil }
            return Blob(data: row["data"], path: row["localPath"], size: row["byteSize"], uploaded: row["uploaded"], multipartId: row["multipartId"], parts: row["completedParts"])
        }) else { throw SyncQueueError.snapshotUnavailable }
        if blob.uploaded { return }
        guard blob.size > 0, blob.size <= SyncWire.maximumBlobBytes else { throw SyncProtocolError.invalidPayload }
        let file: URL
        if let path = blob.path {
            let resolved = try SyncBlobLocation.verified(path, paths: paths, hash: hash, size: blob.size)
            file = resolved.url
            if path != resolved.relative {
                try await database.pool.write { db in
                    try db.execute(sql: "UPDATE sync_blob_state SET localPath=? WHERE hash=? AND localPath=?",
                                   arguments: [resolved.relative, hash, path])
                }
            }
        }
        else if let data = blob.data {
            let directory = try cacheDirectory("SyncBlobs")
            file = directory.appendingPathComponent(hash + ".bnc")
            try data.write(to: file, options: .atomic)
        } else { throw SyncQueueError.snapshotUnavailable }
        let actual = try SyncAttachmentPreparer.hashFile(file)
        guard actual.hash == hash, actual.size == blob.size else { throw SyncProtocolError.invalidPayload }
        struct Request: Encodable { let hash: String; let size: Int64 }
        let prepared: Prepare = try await transport.operation(path: "/v1/blobs/prepare", method: "POST", body: JSONEncoder().encode(Request(hash: hash, size: blob.size)))
        guard prepared.hash == hash else { throw SyncHTTPError.invalidResponse }
        if !prepared.ready {
            if prepared.mode == "single" {
                guard let url = prepared.url, let headers = prepared.headers, let expiry = prepared.expiresAt else { throw SyncHTTPError.invalidResponse }
                _ = try await put(file: file, size: blob.size, id: hash, signed: Signed(url: url, headers: headers, expiresAt: expiry, size: nil, hash: nil, partNumber: nil))
                try await commit(hash: hash, parts: nil)
            } else if prepared.mode == "multipart" {
                let directory = try cacheDirectory("SyncBlobs")
                guard let uploadID = prepared.uploadId, !uploadID.isEmpty,
                      let partSize = prepared.partSize, partSize == 8 * 1024 * 1024,
                      let count = prepared.partCount, count == Int((blob.size + partSize - 1) / partSize)
                else { throw SyncHTTPError.invalidResponse }
                var parts: [Part] = []
                if blob.multipartId == uploadID, let stored = blob.parts {
                    parts = try JSONDecoder().decode([Part].self, from: Data(stored.utf8))
                    guard parts.count <= count, parts.enumerated().allSatisfy({ $0.element.partNumber == $0.offset + 1 }) else { throw SyncHTTPError.invalidResponse }
                }
                try await persist(hash: hash, uploadID: uploadID, parts: parts)
                let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
                if parts.count < count {
                    for number in (parts.count + 1)...count {
                        try Task.checkCancellation()
                        let offset = Int64(number - 1) * partSize, size = min(partSize, blob.size - offset)
                        try reader.seek(toOffset: UInt64(offset))
                        guard let bytes = try reader.read(upToCount: Int(size)), bytes.count == size else { throw SyncQueueError.snapshotUnavailable }
                        let partFile = directory.appendingPathComponent("part-" + UUIDv7.make())
                        try bytes.write(to: partFile, options: .atomic)
                        defer { try? FileManager.default.removeItem(at: partFile) }
                        struct Request: Encodable { let hash: String; let partNumber: Int }
                        let signed: Signed = try await transport.operation(path: "/v1/blobs/part", method: "POST", body: JSONEncoder().encode(Request(hash: hash, partNumber: number)))
                        guard signed.partNumber == number else { throw SyncHTTPError.invalidResponse }
                        let etag: String
                        do { etag = try await put(file: partFile, size: size, id: hash + ":" + uploadID + ":" + String(number), signed: signed) }
                        catch SyncHTTPError.server(status: 404, code: "blob_upload_failed", retryAfter: _) where allowRestart {
                            try await restart(hash: hash, uploadID: uploadID)
                            try await upload(hash: hash, allowRestart: false)
                            return
                        }
                        parts.append(Part(partNumber: number, etag: etag))
                        try await persist(hash: hash, uploadID: uploadID, parts: parts)
                    }
                }
                do { try await commit(hash: hash, parts: parts) }
                catch SyncHTTPError.server(status: 409, code: "multipart_incomplete", retryAfter: _) where allowRestart {
                    try await restart(hash: hash, uploadID: uploadID)
                    try await upload(hash: hash, allowRestart: false)
                    return
                }
            } else { throw SyncHTTPError.invalidResponse }
        }
        try await database.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET uploaded=1,multipartId=NULL,completedParts=NULL WHERE hash=?", arguments: [hash]) }
    }
    private func persist(hash: String, uploadID: String, parts: [Part]) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(parts), as: UTF8.self)
        try await database.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET multipartId=?,completedParts=? WHERE hash=?", arguments: [uploadID, encoded, hash]) }
    }
    private func commit(hash: String, parts: [Part]?) async throws {
        struct Request: Encodable { let hash: String; let parts: [Part]? }
        let result: Ready = try await transport.operation(path: "/v1/blobs/commit", method: "POST", body: JSONEncoder().encode(Request(hash: hash, parts: parts)))
        guard result.hash == hash, result.ready else { throw SyncHTTPError.invalidResponse }
    }
    private func restart(hash: String, uploadID: String) async throws {
        struct Request: Encodable { let hash: String; let uploadId: String }
        let result: Ready = try await transport.operation(path: "/v1/blobs/restart", method: "POST", body: JSONEncoder().encode(Request(hash: hash, uploadId: uploadID)))
        guard result.hash == hash else { throw SyncHTTPError.invalidResponse }
    }
    private func put(file: URL, size: Int64, id: String, signed: Signed) async throws -> String {
        try Self.validate(signed)
        guard signed.headers["Content-Type"] == "application/octet-stream", signed.headers["Content-Length"] == String(size), signed.headers.count == 2 else { throw SyncHTTPError.invalidResponse }
        var request = URLRequest(url: signed.url); request.httpMethod = "PUT"; request.timeoutInterval = 180
        for (name, value) in signed.headers { request.setValue(value, forHTTPHeaderField: name) }
        let response: HTTPURLResponse
        if let files { response = try await files.upload(request: request, file: file, id: id) }
        else {
            let (_, result) = try await session.upload(for: request, fromFile: file, delegate: BlobTransferDelegate(maximum: 65_536))
            guard let http = result as? HTTPURLResponse else { throw SyncHTTPError.invalidResponse }; response = http
        }
        guard (200..<300).contains(response.statusCode) else { throw SyncHTTPError.server(status: response.statusCode, code: "blob_upload_failed", retryAfter: nil) }
        guard let etag = response.value(forHTTPHeaderField: "ETag"), etag.utf8.count <= 1024, !etag.isEmpty else { throw SyncHTTPError.invalidResponse }
        return etag
    }
    private func fetchBlob(hash: String) async throws -> URL {
        let directory = try cacheDirectory("SyncDownloads"), destination = directory.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: destination.path) {
            if try SyncAttachmentPreparer.hashFile(destination).hash == hash { return destination }
            try FileManager.default.removeItem(at: destination)
        }
        struct Request: Encodable { let hash: String }
        let signed: Signed = try await transport.operation(path: "/v1/blobs/download", method: "POST", body: JSONEncoder().encode(Request(hash: hash)))
        try Self.validate(signed)
        guard signed.hash == hash, let size = signed.size, size > 0, size <= SyncWire.maximumBlobBytes, signed.headers.isEmpty else { throw SyncHTTPError.invalidResponse }
        var request = URLRequest(url: signed.url); request.timeoutInterval = 180
        let temporary: URL, response: URLResponse
        if let files { (temporary, response) = try await files.download(request: request, maximum: size, id: hash) }
        else { (temporary, response) = try await session.download(for: request, delegate: BlobTransferDelegate(maximum: size)) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else { throw SyncHTTPError.invalidResponse }
        guard response.statusCode == 200 else { throw SyncHTTPError.server(status: response.statusCode, code: "blob_download_failed", retryAfter: nil) }
        let actual = try SyncAttachmentPreparer.hashFile(temporary)
        guard actual.size == size, actual.hash == hash else { throw SyncProtocolError.invalidPayload }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    private static func validate(_ signed: Signed) throws {
        guard signed.url.scheme == "https", let host = signed.url.host,
              host.hasSuffix(".r2.cloudflarestorage.com"), signed.url.user == nil, signed.url.password == nil,
              signed.url.fragment == nil, signed.url.port == nil,
              signed.expiresAt > Int64(Date.now.timeIntervalSince1970 * 1000)
        else { throw SyncHTTPError.invalidResponse }
    }
    private func cacheDirectory(_ name: String) throws -> URL {
        var directory = paths.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }
}

private final class BlobTransferDelegate: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, Sendable {
    let maximum: Int64
    let received = Mutex<Int64>(0)
    init(maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if received.withLock({ $0 += Int64(data.count); return $0 > maximum }) { dataTask.cancel() }
    }
}
