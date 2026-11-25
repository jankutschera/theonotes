// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Task 14 fix round 2: after a `submit` that throws (the live gateway throws `outcomeNotStored` when the store refused a result), the
/// publisher marks its rows `unknown` so that the restart path resolves them. A failure to mark them must reach the caller: a cycle that
/// carries on as if all were well would leave rows `sending` with no one to resolve them until the next launch.
final class SubmitFailingGateway: CloudKitGateway, @unchecked Sendable {
    let inner: FakeCloudKitDevice
    let error: Error
    private let onSubmit: @Sendable () -> Void
    init(inner: FakeCloudKitDevice, error: Error, onSubmit: @escaping @Sendable () -> Void = {}) { self.inner = inner; self.error = error; self.onSubmit = onSubmit }

    var events: AsyncStream<CloudGatewayEvent> { inner.events }
    func prepare() async throws -> CloudAccountState { try await inner.prepare() }
    func accountState() async -> CloudAccountState { await inner.accountState() }
    func submit(_ saves: [CloudSave]) async throws { onSubmit(); throw error }
    func fetchChanges(into sink: any CloudChangeSink) async throws { try await inner.fetchChanges(into: sink) }
    func fetch(_ names: [String], keys: [String]?) async throws -> [String: CloudRecord] { try await inner.fetch(names, keys: keys) }
    func delete(_ names: [String]) async throws { try await inner.delete(names) }
    func deleteZone() async throws { try await inner.deleteZone() }
    func deleteZone(expecting userHash: String) async throws { try await inner.deleteZone(expecting: userHash) }
}

@Suite struct CloudPublisherSubmitFailureTests {
    private func publisher(_ device: PublisherDevice, gateway: any CloudKitGateway) -> CloudPublisher {
        CloudPublisher(database: device.db, paths: device.paths, store: device.store, gateway: gateway, accountID: device.accountID, vaultKey: device.key,
                       blobs: device.blobs, intake: device.sink, keyReadiness: PublisherDevice.gate(device.keysReady), crash: .never)
    }

    @Test func aFailedSubmitMarksTheRowsUnknownAndRethrowsTheOriginalError() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let device = world.devices[0]
        let note = try device.noteStore.create(text: "# Unknown\nbody\n")
        let failing = SubmitFailingGateway(inner: device.gateway, error: CloudSyncError.failed(code: "outcomeNotStored"))
        await #expect(throws: CloudSyncError.failed(code: "outcomeNotStored")) { _ = try await publisher(device, gateway: failing).publishCycle() }
        let rows = try device.store.allInflight()
        #expect(!rows.isEmpty && rows.allSatisfy { $0.state == .unknown }, "rows must be unknown after a failed submit: \(rows.map(\.state))")
        _ = note
    }

    @Test func aFailureToMarkTheRowsUnknownIsNotSwallowed() async throws {
        let world = try await PublisherWorld.make(1); defer { world.cleanup() }
        let device = world.devices[0]
        _ = try device.noteStore.create(text: "# Unmarked\nbody\n")
        // The library's database goes away while the submit fails: the rows cannot be marked.
        let db = device.db
        let failing = SubmitFailingGateway(inner: device.gateway, error: CloudSyncError.failed(code: "outcomeNotStored")) { try? db.pool.close() }
        do {
            _ = try await publisher(device, gateway: failing).publishCycle()
            Issue.record("the cycle must fail")
        } catch {
            if case CloudPublisherError.unknownNotRecorded(let attempts, let cause) = error {
                #expect(!attempts.isEmpty)
                #expect(cause.contains("outcomeNotStored"))
            } else {
                Issue.record("expected unknownNotRecorded, got \(error)")
            }
        }
    }
}
