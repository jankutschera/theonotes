// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesCore

private final class BlobMockProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    static let handler = Mutex<Handler?>(nil)
    static let pause = Mutex<(@Sendable (URLRequest) -> Bool)?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.pause.withLock({ $0 })?(request) == true { return }
        do {
            guard let handler = Self.handler.withLock({ $0 }), let url = request.url else { throw SyncHTTPError.invalidResponse }
            let (status, headers, data) = try handler(request)
            var fields = headers; fields["Content-Length"] = String(data.count)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func json(_ object: [String: Any], status: Int = 200) throws -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: object))
    }
}
private actor BlobTestCredentials: SyncCredentialStore {
    let value = SyncCredentials(accountId: "account", deviceId: "device", accessToken: "test", refreshToken: "test",
        accessExpiresAt: Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000),
        refreshExpiresAt: Int64(Date.now.addingTimeInterval(7200).timeIntervalSince1970 * 1000))
    func load() -> SyncCredentials? { value }
    func save(_ value: SyncCredentials) {}
}

@Suite(.serialized) struct SyncBlobTransferTests {
    private struct Library: Sendable {
        let paths: AppPaths, db: AppDatabase
        let metadata: HTTPSyncTransport, blobs: SyncBlobTransfer
        init(paths suppliedPaths: AppPaths? = nil, files: (any SyncBlobFileTransfer)? = nil) throws {
            paths = suppliedPaths ?? AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sync-blob-test-\(UUID())"))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BlobMockProtocol.self]
            metadata = try HTTPSyncTransport(endpoint: URL(string: "https://sync.example")!, signingKey: Curve25519.Signing.PrivateKey(),
                credentials: BlobTestCredentials(), session: URLSession(configuration: configuration))
            blobs = SyncBlobTransfer(database: db, paths: paths, transport: metadata, session: URLSession(configuration: configuration), files: files)
        }
        func add(_ bytes: Data) throws -> String {
            let hash = SyncWire.hash(bytes)
            try db.pool.write { try $0.execute(sql: "INSERT INTO sync_blob_state(hash,data,byteSize) VALUES(?,?,?)", arguments: [hash, bytes, bytes.count]) }
            return hash
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
    }
    private static let expiry = Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)


    private actor FileExecutor: SyncBlobFileTransfer {
        var captured: (String, Data)?
        func upload(request: URLRequest, file: URL, id: String) throws -> HTTPURLResponse {
            captured = (id, try Data(contentsOf: file))
            return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "test-part"])!
        }
        func download(request: URLRequest, maximum: Int64, id: String) throws -> (URL, HTTPURLResponse) {
            throw URLError(.unsupportedURL)
        }
    }
    @Test(arguments: ["relative", "absolute", "relocated"])
    func preparedCiphertextSurvivesLibraryRelocation(mode: String) async throws {
        let files = FileExecutor(), original = try Library(files: files)
        let bytes = Data("pending prepared encrypted bytes".utf8), hash = SyncWire.hash(bytes)
        let directory = original.paths.root.appendingPathComponent("SyncBlobs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = UUID().uuidString + ".bch", relative = "SyncBlobs/" + filename
        let source = directory.appendingPathComponent(filename)
        try bytes.write(to: source)
        try await original.db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)",
                           arguments: [hash, mode == "relative" ? relative : source.path, bytes.count])
        }
        await original.blobs.shutdown(); await original.metadata.shutdown()
        try original.db.pool.close()
        let currentPaths: AppPaths
        if mode == "relocated" {
            currentPaths = AppPaths(root: original.paths.root.deletingLastPathComponent().appendingPathComponent("relocated-" + UUID().uuidString))
            try FileManager.default.moveItem(at: original.paths.root, to: currentPaths.root)
            #expect(!FileManager.default.fileExists(atPath: original.paths.root.path))
        } else { currentPaths = original.paths }
        let library = try Library(paths: currentPaths, files: files)
        defer { library.cleanup(); original.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.path == "/v1/blobs/prepare" {
                return try BlobMockProtocol.json(["hash": hash, "ready": false, "mode": "single",
                    "url": "https://test.r2.cloudflarestorage.com/blob", "headers": ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count)], "expiresAt": Self.expiry])
            }
            return try BlobMockProtocol.json(["hash": hash, "ready": true])
        } }
        try await library.blobs.ensureUploaded([hash])
        #expect(await files.captured?.1 == bytes)
        let state = try await library.db.pool.read { db in
            (try String.fetchOne(db, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [hash]),
             try Int.fetchOne(db, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]))
        }
        #expect(state.0 == relative)
        #expect(state.1 == 1)
        #expect(try Data(contentsOf: currentPaths.root.appendingPathComponent(relative)) == bytes)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test(arguments: ["escape", "file-symlink", "directory-symlink", "tampered", "wrong-size"])
    func invalidPreparedLocationCannotUploadOrRepairPointer(mode: String) async throws {
        let files = FileExecutor(), library = try Library(files: files)
        defer { library.cleanup() }
        let bytes = Data("valid encrypted bytes".utf8), hash = SyncWire.hash(bytes)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let filename = UUID().uuidString + ".bch", directory = library.paths.root.appendingPathComponent("SyncBlobs")
        if mode == "directory-symlink" { try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside) }
        else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = directory.appendingPathComponent(filename)
        if mode == "file-symlink" {
            let target = outside.appendingPathComponent(filename)
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        } else { try (mode == "tampered" ? Data("wrong encrypted bytes".utf8) : bytes).write(to: file) }
        let stored = mode == "escape" ? "../SyncBlobs/" + filename : "SyncBlobs/" + filename
        try await library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO sync_blob_state(hash,localPath,byteSize) VALUES(?,?,?)",
                           arguments: [hash, stored, bytes.count + (mode == "wrong-size" ? 1 : 0)])
        }
        await #expect(throws: Error.self) { try await library.blobs.ensureUploaded([hash]) }
        #expect(await files.captured == nil)
        let state = try await library.db.pool.read { db in
            (try String.fetchOne(db, sql: "SELECT localPath FROM sync_blob_state WHERE hash=?", arguments: [hash]),
             try Int.fetchOne(db, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]))
        }
        #expect(state.0 == stored)
        #expect(state.1 == 0)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func injectedFileExecutorReceivesVerifiedCiphertextAndStableIdentity() async throws {
        let files = FileExecutor(), library = try Library(files: files)
        defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        let bytes = Data("encrypted blob fixture".utf8), hash = try library.add(bytes)
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.path == "/v1/blobs/prepare" {
                return try BlobMockProtocol.json(["hash": hash, "ready": false, "mode": "single",
                    "url": "https://test.r2.cloudflarestorage.com/blob", "headers": ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count)], "expiresAt": Self.expiry])
            }
            return try BlobMockProtocol.json(["hash": hash, "ready": true])
        } }
        try await library.blobs.ensureUploaded([hash])
        let captured = await files.captured
        #expect(captured?.0 == hash)
        #expect(captured?.1 == bytes)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func cancellingAWaitingDownloadStopsItsNetworkTaskAndAllowsRetry() async throws {
        let library = try Library()
        defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil }; BlobMockProtocol.pause.withLock { $0 = nil } }
        let bytes = Data("retry after background expiration".utf8), hash = SyncWire.hash(bytes)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        BlobMockProtocol.pause.withLock { $0 = { request in
            guard request.url?.host == "test.r2.cloudflarestorage.com" else { return false }
            continuation.yield(); return true
        } }
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.path == "/v1/blobs/download" {
                return try BlobMockProtocol.json(["hash": hash, "size": bytes.count,
                    "url": "https://test.r2.cloudflarestorage.com/bucket/objects/test", "expiresAt": Self.expiry, "headers": [:]])
            }
            return (200, [:], bytes)
        } }
        let task = Task { try await library.blobs.download(hash: hash) }
        var events = stream.makeAsyncIterator()
        await events.next()
        task.cancel()
        await #expect(throws: Error.self) { try await task.value }
        BlobMockProtocol.pause.withLock { $0 = nil }
        continuation.finish()
        let downloaded = try await library.blobs.download(hash: hash)
        #expect(try Data(contentsOf: downloaded) == bytes)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func lostCommitResponseRetriesWithoutReuploadingVerifiedCiphertext() async throws {
        let library = try Library(); defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        let bytes = Data("opaque cipher bytes".utf8), hash = try library.add(bytes)
        let puts = Mutex(0), committed = Mutex(false)
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.host == "test.r2.cloudflarestorage.com" {
                #expect(request.httpMethod == "PUT")
                #expect(request.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
                puts.withLock { $0 += 1 }; return (200, ["ETag": "\"opaque\""], Data())
            }
            switch request.url?.path {
            case "/v1/blobs/prepare":
                if committed.withLock({ $0 }) { return try BlobMockProtocol.json(["hash": hash, "ready": true]) }
                return try BlobMockProtocol.json(["hash": hash, "ready": false, "mode": "single",
                    "url": "https://test.r2.cloudflarestorage.com/bucket/uploads/test", "expiresAt": Self.expiry,
                    "headers": ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count)]])
            case "/v1/blobs/commit":
                committed.withLock { $0 = true }; return try BlobMockProtocol.json(["error": "response_lost"], status: 500)
            default: throw SyncHTTPError.invalidResponse
            }
        } }
        await #expect(throws: SyncHTTPError.server(status: 500, code: "response_lost", retryAfter: nil)) { try await library.blobs.ensureUploaded([hash]) }
        #expect(try await library.db.pool.read { try Bool.fetchOne($0, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]) } == false)
        try await library.blobs.ensureUploaded([hash])
        #expect(puts.withLock { $0 } == 1)
        #expect(try await library.db.pool.read { try Bool.fetchOne($0, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]) } == true)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func verifiedDownloadIsReusableAndWrongBytesNeverReachCache() async throws {
        let library = try Library(); defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        let bytes = Data("encrypted download".utf8), hash = SyncWire.hash(bytes)
        let corrupt = Mutex(true), gets = Mutex(0)
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.path == "/v1/blobs/download" {
                return try BlobMockProtocol.json(["hash": hash, "size": bytes.count,
                    "url": "https://test.r2.cloudflarestorage.com/bucket/objects/test", "expiresAt": Self.expiry, "headers": [:]])
            }
            gets.withLock { $0 += 1 }
            return (200, [:], corrupt.withLock({ $0 }) ? Data(repeating: 0, count: bytes.count) : bytes)
        } }
        await #expect(throws: SyncProtocolError.invalidPayload) { try await library.blobs.download(hash: hash) }
        #expect(!FileManager.default.fileExists(atPath: library.paths.root.appendingPathComponent("SyncDownloads/" + hash).path))
        corrupt.withLock { $0 = false }
        let file = try await library.blobs.download(hash: hash)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try await library.blobs.download(hash: hash) == file)
        #expect(gets.withLock { $0 } == 2)
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func refusesInsecureBlobDestinationBeforeSendingBytes() async throws {
        let library = try Library(); defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        let bytes = Data("cipher".utf8), hash = try library.add(bytes)
        BlobMockProtocol.handler.withLock { $0 = { request in
            #expect(request.url?.path == "/v1/blobs/prepare")
            return try BlobMockProtocol.json(["hash": hash, "ready": false, "mode": "single",
                "url": "http://untrusted.example/upload", "expiresAt": Self.expiry,
                "headers": ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count)]])
        } }
        await #expect(throws: SyncHTTPError.invalidResponse) { try await library.blobs.ensureUploaded([hash]) }
        await library.blobs.shutdown(); await library.metadata.shutdown()
    }

    @Test func freshClientResumesMultipartAfterLastDurablyAcknowledgedPart() async throws {
        let library = try Library(); defer { library.cleanup(); BlobMockProtocol.handler.withLock { $0 = nil } }
        let size = 64 * 1024 * 1024 + 1, partSize = 8 * 1024 * 1024
        let hash = try library.add(Data(repeating: 19, count: size))
        let requested = Mutex<[Int]>([]), failOnce = Mutex(true)
        BlobMockProtocol.handler.withLock { $0 = { request in
            if request.url?.host == "test.r2.cloudflarestorage.com" {
                let number = Int(request.url!.lastPathComponent)!
                requested.withLock { $0.append(number) }
                if number == 2, failOnce.withLock({ value in let old = value; value = false; return old }) {
                    return (503, [:], Data())
                }
                return (200, ["ETag": "\"part-\(number)\""], Data())
            }
            switch request.url?.path {
            case "/v1/blobs/prepare":
                return try BlobMockProtocol.json(["hash": hash, "ready": false, "mode": "multipart", "uploadId": "stable-upload", "partSize": partSize, "partCount": 9])
            case "/v1/blobs/part":
                // Requests are sequential; the first client fails on 2, the new client starts at 2.
                let previous = requested.withLock { $0 }
                let number = previous.isEmpty ? 1 : (previous.last == 2 && previous.count == 2 ? 2 : previous.last! + 1)
                return try BlobMockProtocol.json(["partNumber": number, "url": "https://test.r2.cloudflarestorage.com/bucket/part/\(number)",
                    "expiresAt": Self.expiry, "headers": ["Content-Type": "application/octet-stream", "Content-Length": String(number == 9 ? 1 : partSize)]])
            case "/v1/blobs/commit": return try BlobMockProtocol.json(["hash": hash, "ready": true])
            default: throw SyncHTTPError.invalidResponse
            }
        } }
        await #expect(throws: SyncHTTPError.server(status: 503, code: "blob_upload_failed", retryAfter: nil)) { try await library.blobs.ensureUploaded([hash]) }
        let progress = try await library.db.pool.read { try String.fetchOne($0, sql: "SELECT completedParts FROM sync_blob_state WHERE hash=?", arguments: [hash]) }
        #expect(try #require(progress).contains("part-1"))
        await library.blobs.shutdown()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BlobMockProtocol.self]
        let resumed = SyncBlobTransfer(database: library.db, paths: library.paths, transport: library.metadata, session: URLSession(configuration: config))
        try await resumed.ensureUploaded([hash])
        #expect(requested.withLock { $0 } == [1,2,2,3,4,5,6,7,8,9])
        #expect(try await library.db.pool.read { try Bool.fetchOne($0, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]) } == true)
        await resumed.shutdown(); await library.metadata.shutdown()
    }
}
