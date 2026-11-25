// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import Synchronization
@testable import BaerchenIOS

private final class PendingCiphertextProtocol: URLProtocol, @unchecked Sendable {
    static let stopped = Mutex(false)
    static let started = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.withLock { $0 = true } }
    override func stopLoading() { Self.stopped.withLock { $0 = true } }
}

private enum ReplayEvent: Sendable, Equatable { case taskLookupEntered, replayFinished, replayFailed }

private actor StalledTaskLookup {
    private var released = false
    private var continuation: CheckedContinuation<[URLSessionTask], Never>?

    func tasks() async -> [URLSessionTask] {
        if released { return [] }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: [])
    }
}

@Suite(.serialized) struct MobileBlobFilesTests {
    @Test(arguments: [true, false])
    func completedReplayDoesNotWaitForSystemTaskEnumeration(upload: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = "replay-account:replay-device", id = "completed-blob"
        let key = SyncWire.hash(Data((identity + (upload ? ":put:" : ":get:") + id).utf8))
        let bytes = Data("durable encrypted fixture".utf8)
        let journal: [String: Any] = [key: ["id": key, "maximum": 65536, "upload": upload,
            "status": 200, "headers": ["ETag": "durable-ack"], "error": false, "received": 0]]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("journal.json"))
        if !upload { try bytes.write(to: root.appendingPathComponent(key + ".cipher")) }
        let lookup = StalledTaskLookup()
        let (events, delivery) = AsyncStream<ReplayEvent>.makeStream()
        let executor = try MobileBlobFiles(directory: root, identity: identity, configuration: .ephemeral,
            taskLookup: { _ in
                delivery.yield(.taskLookupEntered)
                return await lookup.tasks()
            })
        defer { executor.cancel(); delivery.finish() }
        let replay = Task {
            do {
                let request = URLRequest(url: URL(string: "https://unreachable.invalid/blob")!)
                if upload {
                    // Missing source also proves no replacement upload was staged.
                    let response = try await executor.upload(request: request, file: root.appendingPathComponent("absent"), id: id)
                    #expect(response.statusCode == 200)
                    #expect(response.value(forHTTPHeaderField: "ETag") == "durable-ack")
                } else {
                    let (file, response) = try await executor.download(request: request, maximum: Int64(bytes.count), id: id)
                    #expect(response.statusCode == 200)
                    #expect(try Data(contentsOf: file) == bytes)
                    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(key + ".cipher").path))
                }
                delivery.yield(.replayFinished)
            } catch {
                delivery.yield(.replayFailed)
                throw error
            }
        }
        var iterator = events.makeAsyncIterator()
        let first = await iterator.next()
        // Deterministic ordering, no timeout: the old implementation enters the gate
        // first and fails this assertion. Release it even on failure so cleanup completes.
        #expect(first == .replayFinished)
        await lookup.release()
        try await replay.value
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [String: Any]
        #expect(remaining?.isEmpty == true)
    }

    @Test func cancellingWaiterKeepsSystemTaskAndDurableCiphertext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingCiphertextProtocol.self]
        PendingCiphertextProtocol.started.withLock { $0 = false }
        PendingCiphertextProtocol.stopped.withLock { $0 = false }
        let executor = try MobileBlobFiles(directory: root, identity: "account:device", configuration: configuration)
        defer { executor.cancel() }
        let source = root.appendingPathComponent("source")
        try Data("encrypted fixture".utf8).write(to: source)
        let waiter = Task { try await executor.upload(request: URLRequest(url: URL(string: "https://ciphertext.invalid/blob")!), file: source, id: "hash") }
        for _ in 0..<100 {
            if PendingCiphertextProtocol.started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(PendingCiphertextProtocol.started.withLock { $0 })
        waiter.cancel()
        do { _ = try await waiter.value; Issue.record("Waiter should detach through cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation result: \(error)") }
        #expect(!PendingCiphertextProtocol.stopped.withLock { $0 })
        let key = SyncWire.hash(Data("account:device:put:hash".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(key + ".cipher").path))
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [String: Any]
        #expect(records?[key] != nil)
    }

    @Test func completedUploadSurvivesExecutorRecreationWithoutResending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "blob:multipart:2", identity = "test-account:test-device"
        let key = SyncWire.hash(Data((identity + ":put:" + id).utf8))
        let journal: [String: Any] = [key: ["id": key, "maximum": 65536, "upload": true,
            "status": 200, "headers": ["ETag": "acknowledged-part"], "error": false, "received": 0]]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("journal.json"))
        let executor = try MobileBlobFiles(directory: root, identity: identity, configuration: .ephemeral)
        defer { executor.cancel() }
        // The source intentionally does not exist: only a durable server acknowledgment may bypass it.
        let response = try await executor.upload(request: URLRequest(url: URL(string: "https://unreachable.invalid/blob")!),
            file: root.appendingPathComponent("absent"), id: id)
        #expect(response.value(forHTTPHeaderField: "ETag") == "acknowledged-part")
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("journal.json"))) as? [String: Any]
        #expect(remaining?.isEmpty == true)
    }

    @Test func completedDownloadIsRetainedUntilOwnershipPassesToCore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = "test-account:test-device", bytes = Data("ciphertext fixture".utf8)
        let id = SyncWire.hash(bytes), key = SyncWire.hash(Data((identity + ":get:" + id).utf8))
        let journal: [String: Any] = [key: ["id": key, "maximum": bytes.count, "upload": false,
            "status": 200, "headers": [:], "error": false, "received": 0]]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent("journal.json"))
        try bytes.write(to: root.appendingPathComponent(key + ".cipher"))
        let executor = try MobileBlobFiles(directory: root, identity: identity, configuration: .ephemeral)
        defer { executor.cancel() }
        let (file, response) = try await executor.download(request: URLRequest(url: URL(string: "https://unreachable.invalid/blob")!), maximum: Int64(bytes.count), id: id)
        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(key + ".cipher").path))
    }
}
