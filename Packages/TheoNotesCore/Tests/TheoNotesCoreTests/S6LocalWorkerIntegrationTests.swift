// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing
@testable import TheoNotesCore

// Opt-in host integration, not a Mac/iOS application or production transport test.
// This protocol intercepts every request and permits only the two synthetic hosts.
private final class S6LoopbackProtocol: URLProtocol, @unchecked Sendable {
    private let work = Mutex<Task<Void, Never>?>(nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let task = Task {
            do {
                guard let target = request.url, target.scheme == "https",
                      ["sync.s6.invalid", "s6local.r2.cloudflarestorage.com"].contains(target.host ?? ""),
                      let portText = ProcessInfo.processInfo.environment["THEO_S6_PORT"],
                      let port = Int(portText), (1024...65535).contains(port)
                else { throw URLError(.unsupportedURL) }
                var forwarded = request
                forwarded.url = URL(string: "http://127.0.0.1:\(port)/bridge")!
                forwarded.setValue(target.absoluteString, forHTTPHeaderField: "X-S6-Target")
                if forwarded.httpBody == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var body = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                        if count == 0 { break }
                        body.append(buffer, count: count)
                        guard body.count <= 8 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
                    }
                    forwarded.httpBodyStream = nil; forwarded.httpBody = body
                }
                // No custom protocol or proxy on this loopback-only session.
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [:]
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                let (bytes, result) = try await session.data(for: forwarded)
                let response = try #require(result as? HTTPURLResponse)
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { fields, item in
                    fields[String(describing: item.key)] = String(describing: item.value)
                }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: target, statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: bytes)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        work.withLock { $0 = task }
    }
    override func stopLoading() { work.withLock { $0?.cancel(); $0 = nil } }
}

private actor S6Credentials: SyncCredentialStore {
    var value: SyncCredentials
    init(_ value: SyncCredentials) { self.value = value }
    func load() -> SyncCredentials? { value }
    func save(_ value: SyncCredentials) { self.value = value }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["THEO_S6_PORT"] != nil))
struct S6LocalWorkerIntegrationTests {
    private let rateLimitDeadline = ContinuousClock().now.advanced(by: .seconds(600))

    /// Exercise the unchanged Worker limiter; retry only 429, never a lost-response 503.
    /// Four retries per operation and one ten-minute suite-instance deadline bound failures.
    private func honoringRateLimit<Value>(_ operation: () async throws -> Value) async throws -> Value {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch let error as SyncHTTPError {
                guard case .server(status: 429, code: _, retryAfter: let retryAfter) = error else { throw error }
                let seconds = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 1
                let delay = Duration.seconds(max(1, seconds))
                guard retries < 4, ContinuousClock().now.advanced(by: delay) < rateLimitDeadline else { throw error }
                retries += 1
                print("S6 fixture honoring HTTP 429 Retry-After: \(max(1, seconds))s (retry \(retries)/4)")
                try await Task.sleep(for: delay)
            }
        }
    }

    private func control(_ path: String, body: Data? = nil) async throws -> Data {
        let text = try #require(ProcessInfo.processInfo.environment["THEO_S6_PORT"])
        let port = try #require(Int(text))
        try #require((1024...65535).contains(port))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__s6/\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        return bytes
    }

    private func sketchAttachmentConflict(libraries: [SyncMaterializerTests.Library], engines: [SyncEngine],
                                          transports: [HTTPSyncTransport], blobs: [SyncBlobTransfer],
                                          key: SymmetricKey, firstDeviceWins: Bool) async throws {
        let baseline = try SketchSyncPNGFixture.baseline()
        let (leftBytes, rightBytes) = try SketchSyncPNGFixture.conflictEdits(baseline: baseline)
        // Each ordering has a separate authored note/attachment identity in the same fixture account.
        let note = try libraries[0].store.create(text: "# Protocol sketch\n" + AttachmentMarkdown.link(for: "sketch.png"))
        _ = try AttachmentStore(paths: libraries[0].paths, database: libraries[0].db)
            .add(data: baseline, filename: "sketch.png", to: note.id)
        for _ in 0..<3 { for engine in engines { _ = try await honoringRateLimit { try await engine.synchronize() } } }
        for library in libraries {
            let file = library.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("sketch.png")
            #expect(try Data(contentsOf: file) == baseline)
            #expect(try SketchSyncPNGFixture.archive(in: Data(contentsOf: file)) == SketchSyncPNGFixture.archive(in: baseline))
        }
        let attachmentID = try #require(try await libraries[0].db.pool.read {
            try String.fetchOne($0, sql: "SELECT id FROM attachment WHERE noteId=? AND filename='sketch.png' AND deletedAt IS NULL", arguments: [note.id])
        })
        try SketchSyncPNGFixture.replace(leftBytes, noteID: note.id, paths: libraries[0].paths, database: libraries[0].db)
        try SketchSyncPNGFixture.replace(rightBytes, noteID: note.id, paths: libraries[1].paths, database: libraries[1].db)
        let winner = firstDeviceWins ? 0 : 1, loser = firstDeviceWins ? 1 : 0
        // Freeze the stale immutable attachment mutation BEFORE either device reconnects.
        _ = try await SyncAttachmentPreparer(database: libraries[loser].db, paths: libraries[loser].paths,
            accountID: "account", vaultKey: key).preparePending()
        let queued = try #require(try libraries[loser].queue.prepareNext(vaultKey: key))
        #expect(queued.entityType == .attachment && queued.entityId == attachmentID)
        _ = try await honoringRateLimit { try await engines[winner].synchronize() }
        // Real encrypted blob upload/promotion and real authenticated Worker CAS rejection.
        try await honoringRateLimit { try await blobs[loser].ensureUploaded(queued.blobRefs) }
        let pushed = try await honoringRateLimit { try await transports[loser].push([queued]) }
        let result = try #require(pushed.results.first)
        #expect(result.status == .conflict && result.current?.mutation.entityId == attachmentID)
        for _ in 0..<6 { for engine in engines { _ = try await honoringRateLimit { try await engine.synchronize() } } }
        for library in libraries {
            let scopedNoteIDs = try await library.db.pool.read { db in
                Set(try String.fetchAll(db, sql: "SELECT noteId FROM sync_conflict WHERE originalNoteId=?", arguments: [note.id])).union([note.id])
            }
            let versions = try SketchSyncPNGFixture.reachable(store: library.store, paths: library.paths, database: library.db)
                .filter { scopedNoteIDs.contains($0.noteID) }
            #expect(Set(versions.map(\.bytes)) == Set([leftBytes, rightBytes]))
            #expect(Set(versions.map(\.noteID)).count == 2)
            let expectedArchives = try Set([SketchSyncPNGFixture.archive(in: leftBytes), SketchSyncPNGFixture.archive(in: rightBytes)])
            #expect(try Set(versions.map { try SketchSyncPNGFixture.archive(in: $0.bytes) }) == expectedArchives)
            #expect(try library.inbox.pending().isEmpty)
            #expect(try library.queue.pendingMutations().isEmpty)
        }
        let stats = try JSONDecoder().decode([String: Int].self, from: await control("stats"))
        #expect((stats["conflicts"] ?? 0) >= 1)
        #expect((stats["verifiedBlobs"] ?? 0) >= 3)
        #expect((stats["blobPuts"] ?? 0) >= 3 && (stats["blobGets"] ?? 0) >= 3)
    }

    @Test func offlineConflictAttachmentBytesAndLostReceiptThroughCurrentWorker() async throws {
        let signing = [Curve25519.Signing.PrivateKey(), Curve25519.Signing.PrivateKey()]
        let setup = try JSONSerialization.data(withJSONObject: ["signingKeys": signing.map { SyncWire.base64($0.publicKey.rawRepresentation) }])
        let credentials = try JSONDecoder().decode([SyncCredentials].self, from: await control("setup", body: setup))
        try #require(credentials.count == 2)
        let key = SymmetricKey(size: .bits256)
        let left = try SyncMaterializerTests.Library(key: key), right = try SyncMaterializerTests.Library(key: key)
        defer { left.cleanup(); right.cleanup() }
        let libraries = [left, right]
        var engines: [SyncEngine] = [], transports: [HTTPSyncTransport] = [], blobs: [SyncBlobTransfer] = []
        for index in 0..<2 {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [S6LoopbackProtocol.self]
            let transport = try HTTPSyncTransport(endpoint: URL(string: "https://sync.s6.invalid")!, signingKey: signing[index],
                credentials: S6Credentials(credentials[index]), session: URLSession(configuration: config))
            let blob = SyncBlobTransfer(database: libraries[index].db, paths: libraries[index].paths,
                transport: transport, session: URLSession(configuration: config))
            transports.append(transport); blobs.append(blob)
            engines.append(SyncEngine(database: libraries[index].db, paths: libraries[index].paths, accountID: "account",
                vaultKey: key, transport: transport, blobs: blob))
        }
        do {
            // Verify singleton behavior through the real Worker route without provisioning anything.
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [S6LoopbackProtocol.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            var register = URLRequest(url: URL(string: "https://sync.s6.invalid/v1/auth/begin")!)
            register.httpMethod = "POST"
            register.httpBody = try JSONSerialization.data(withJSONObject: ["kind": "register", "provisioningToken": "s6-local-fixture-only",
                "device": ["deviceId": "s6-other", "signingKey": SyncWire.base64(signing[0].publicKey.rawRepresentation),
                    "transferKey": SyncWire.base64(signing[1].publicKey.rawRepresentation), "encryptedName": "YWJj"]])
            let (rejection, response) = try await session.data(for: register)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
            #expect(String(decoding: rejection, as: UTF8.self).contains("provisioning_closed"))

            let note = try left.store.create(text: "Original\n" + AttachmentMarkdown.link(for: "fixture.bin"))
            let bytes = Data((0..<131_089).map { UInt8($0 % 251) })
            _ = try AttachmentStore(paths: left.paths, database: left.db).add(data: bytes, filename: "fixture.bin", to: note.id)
            for _ in 0..<3 { _ = try await honoringRateLimit { try await engines[0].synchronize() }; _ = try await honoringRateLimit { try await engines[1].synchronize() } }
            let imported = try #require(try right.store.note(id: note.id))
            let destination = right.paths.attachments.appendingPathComponent(note.id + "/fixture.bin")
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(try SyncAttachmentPreparer.hashFile(destination).hash == SyncWire.hash(bytes))

            // Both edits happen with no sync calls between them, modelling an offline interval.
            let leftNote = try #require(try left.store.note(id: note.id))
            _ = try left.store.updateText(id: note.id, text: "Left offline edit\n" + AttachmentMarkdown.link(for: "fixture.bin"), expectedRevision: leftNote.revision)
            _ = try right.store.updateText(id: note.id, text: "Right offline edit\n" + AttachmentMarkdown.link(for: "fixture.bin"), expectedRevision: imported.revision)
            for _ in 0..<4 { _ = try await honoringRateLimit { try await engines[0].synchronize() }; _ = try await honoringRateLimit { try await engines[1].synchronize() } }
            let leftNotes = try await left.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
            let rightNotes = try await right.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
            #expect(leftNotes.count == 2)
            #expect(leftNotes.map(\.id) == rightNotes.map(\.id))
            #expect(leftNotes.map(\.text) == rightNotes.map(\.text))
            #expect(leftNotes.contains { $0.text.hasPrefix("Left offline edit") })
            #expect(leftNotes.contains { $0.text.hasPrefix("Right offline edit") })
            for library in libraries {
                let attachments = try await library.db.pool.read {
                    try Row.fetchAll($0, sql: "SELECT noteId,filename FROM attachment WHERE deletedAt IS NULL")
                        .map { ($0["noteId"] as String, $0["filename"] as String) }
                }
                #expect(attachments.count == 2)
                for (noteID, filename) in attachments {
                    #expect(try Data(contentsOf: library.paths.attachments.appendingPathComponent(noteID + "/" + filename)) == bytes)
                }
            }

            // Reuse this one-shot Worker account and its two real protocol clients.
            for firstDeviceWins in [false, true] {
                try await sketchAttachmentConflict(libraries: libraries, engines: engines,
                    transports: transports, blobs: blobs, key: key, firstDeviceWins: firstDeviceWins)
            }

            _ = try left.store.create(text: "Receipt loss fixture")
            _ = try await control("lose-next-push", body: Data("{}".utf8))
            await #expect(throws: SyncHTTPError.server(status: 503, code: "s6_lost_response", retryAfter: nil)) { _ = try await honoringRateLimit { try await engines[0].synchronize() } }
            let pending = try left.queue.pendingMutations()
            #expect(!pending.isEmpty)
            let retried = try await honoringRateLimit { try await engines[0].synchronize() }
            #expect(retried.pendingUploads == 0)
            _ = try await honoringRateLimit { try await engines[1].synchronize() }
            #expect(try await right.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note WHERE text='Receipt loss fixture'") } == 1)
            for engine in engines {
                let summary = try await honoringRateLimit { try await engine.synchronize() }
                #expect(summary.pendingUploads == 0 && summary.pendingDownloads == 0 && summary.unavailableAttachments == 0)
            }
            let stats = try JSONDecoder().decode([String: Int].self, from: await control("stats"))
            #expect((stats["workerRequests"] ?? 0) > 0)
            #expect((stats["verifiedBlobs"] ?? 0) >= 1)
            #expect((stats["blobPuts"] ?? 0) >= 1 && (stats["blobGets"] ?? 0) >= 1)
            #expect(stats["lostPushResponses"] == 1)
            print("S6 local integration evidence: \(stats.sorted { $0.key < $1.key })")
        } catch {
            for engine in engines { await engine.shutdown() }
            for blob in blobs { await blob.shutdown() }
            for transport in transports { await transport.shutdown() }
            throw error
        }
        for engine in engines { await engine.shutdown() }
        for blob in blobs { await blob.shutdown() }
        for transport in transports { await transport.shutdown() }
    }
}
