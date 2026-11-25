// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

@Suite struct SyncEngineTests {
    actor Server: SyncTransport {
        var entities: [String: SyncEntity] = [:]
        var receipts: [String: SyncEntity] = [:]
        var history: [SyncEntity] = []
        var loseResponse = false
        var missingBlobOnce = false
        func loseNextResponse() { loseResponse = true }
        func reportMissingBlobOnce() { missingBlobOnce = true }
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            if missingBlobOnce {
                missingBlobOnce = false
                return .init(results: mutations.map { .init(mutationId: $0.mutationId, status: .missingBlob, entity: nil, current: nil) })
            }
            var results: [SyncMutationResult] = []
            for mutation in mutations {
                let key = mutation.entityType.rawValue + ":" + mutation.entityId
                if let prior = receipts[mutation.mutationId] {
                    guard prior.mutation == mutation else { throw SyncQueueError.invalidReceipt }
                    results.append(.init(mutationId: mutation.mutationId, status: .accepted, entity: prior, current: nil))
                } else if let current = entities[key], current.revision != mutation.parentRevision {
                    results.append(.init(mutationId: mutation.mutationId, status: .conflict, entity: nil, current: current))
                } else {
                    let entity = SyncEntity(mutation: mutation, revision: mutation.parentRevision + 1,
                                            sequence: Int64(history.count + 1), receivedAt: Int64(history.count + 1))
                    entities[key] = entity; receipts[mutation.mutationId] = entity; history.append(entity)
                    results.append(.init(mutationId: mutation.mutationId, status: .accepted, entity: entity, current: nil))
                }
            }
            if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
            return .init(results: results)
        }
        func pull(after cursor: Int64) async throws -> SyncPullResult {
            let changes = Array(history.filter { $0.sequence > cursor }.prefix(2))
            let last = changes.last?.sequence ?? cursor
            return .init(changes: changes, cursor: last, hasMore: last < history.count)
        }
        func acknowledge(_ cursor: Int64) async throws {
            guard cursor <= history.count else { throw SyncInboxError.invalidPage }
        }
        func count() -> Int { history.count }
    }

    func engine(_ library: SyncMaterializerTests.Library, _ server: Server) -> SyncEngine {
        SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
                   transport: server, blobs: SyncPayloadReaderTests.Blobs())
    }

    @Test func unavailableAttachmentStopsFastContinuationWithoutDroppingItsQueuedWork() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Legacy import\n" + AttachmentMarkdown.link(for: "missing.txt"))
        let dirtyBefore = try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty WHERE entityType='attachment'") }
        let server = Server(), sync = engine(library, server)
        let first = try await sync.synchronize()
        #expect(first.uploaded > 0)
        #expect(first.pendingUploads == 0 && first.unavailableAttachments == 1)
        #expect(!first.shouldContinueSoon)
        #expect(try library.queue.pendingCount() == 1)

        let published = await server.count()
        for _ in 0..<2 {
            let exhausted = try await sync.synchronize()
            #expect(exhausted.pendingUploads == 0 && exhausted.unavailableAttachments == 1)
            #expect(try library.queue.pendingCount() == 1)
            #expect(try await library.db.pool.read { try String.fetchAll($0, sql: "SELECT json_array(entityType,localId,generation,tombstone) FROM sync_dirty WHERE entityType='attachment'") } == dirtyBefore)
            #expect(exhausted.uploaded == 0 && exhausted.downloaded == 0 && exhausted.applied == 0)
            #expect(!exhausted.shouldContinueSoon)
            #expect(await server.count() == published)
        }

        // A later ordinary poll still discovers a file arriving without a database edit.
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("recovered bytes".utf8).write(to: directory.appendingPathComponent("missing.txt"))
        let recovered = try await sync.synchronize()
        #expect(recovered.uploaded > 0)
        #expect(recovered.pendingUploads == 0 && recovered.pendingDownloads == 0 && recovered.unavailableAttachments == 0)
        #expect(!recovered.shouldContinueSoon)
        await sync.shutdown()
    }

    actor CountingCoordinator: SyncCommitCoordinator {
        var count = 0
        func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
            count += 1
            return try change()
        }
    }
    @Test func receivedChangesUseHostCommitBoundaryOnlyWhenApplyingLocalContent() async throws {
        let key = SymmetricKey(size: .bits256)
        let source = try SyncMaterializerTests.Library(key: key), target = try SyncMaterializerTests.Library(key: key)
        defer { source.cleanup(); target.cleanup() }
        let server = Server(), sender = engine(source, server), coordinator = CountingCoordinator()
        let receiver = SyncEngine(database: target.db, paths: target.paths, accountID: "account", vaultKey: key,
            transport: server, blobs: SyncPayloadReaderTests.Blobs(), coordinator: coordinator)
        let note = try source.store.create(text: "Remote text")
        _ = try await sender.synchronize()
        #expect(await coordinator.count == 0)
        _ = try await receiver.synchronize()
        #expect(try target.store.note(id: note.id)?.text == "Remote text")
        let commits = await coordinator.count
        #expect(commits > 0)
        _ = try await receiver.synchronize()
        #expect(await coordinator.count == commits)
        await sender.shutdown(); await receiver.shutdown()
    }

    actor UploadCancellationTransport: SyncTransport {
        let server: Server
        var batches = 0
        var acknowledged: Int64 = 0
        init(server: Server) { self.server = server }
        func pull(after cursor: Int64) async throws -> SyncPullResult { try await server.pull(after: cursor) }
        func acknowledge(_ cursor: Int64) async throws {
            try await server.acknowledge(cursor)
            acknowledged = cursor
        }
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
            _ = try await server.push(mutations)
            batches += 1
            throw CancellationError()
        }
    }

    @Test func cancellationAfterFirstUploadBatchStillPersistsAndAcknowledgesRemoteChanges() async throws {
        let key = SymmetricKey(size: .bits256)
        let source = try SyncMaterializerTests.Library(key: key), target = try SyncMaterializerTests.Library(key: key)
        defer { source.cleanup(); target.cleanup() }
        let server = Server(), sender = engine(source, server)
        let remote = try source.store.create(text: "Remote before the backlog")
        _ = try await sender.synchronize()
        for index in 0..<300 { _ = try target.store.create(text: "Offline note \(index)") }
        for _ in 0..<300 { _ = try #require(try target.queue.prepareNext(vaultKey: key)) }
        let transport = UploadCancellationTransport(server: server)
        let receiver = SyncEngine(database: target.db, paths: target.paths, accountID: "account", vaultKey: key,
                                  transport: transport, blobs: SyncPayloadReaderTests.Blobs())
        await #expect(throws: CancellationError.self) { try await receiver.synchronize() }
        #expect(await transport.batches == 1)
        #expect(try SyncInbox(database: target.db).cursor() > 0)
        #expect(await transport.acknowledged > 0)
        #expect(try target.store.note(id: remote.id)?.text == "Remote before the backlog")
        #expect(try await target.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") } == 300)
        await sender.shutdown(); await receiver.shutdown()
    }

    actor FailingCoordinator: SyncCommitCoordinator {
        let cancellation: Bool
        init(cancellation: Bool) { self.cancellation = cancellation }
        func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
            if cancellation { throw CancellationError() }
            throw SyncApplyError.changedDuringDownload
        }
    }

    @Test(arguments: [false, true])
    func earlyMaterializationFailureDefersUntilAfterUploadsUnlessCancelled(cancellation: Bool) async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let remote = try library.entity(library.payload("Remote"))
        let server = Server()
        _ = try await server.push([remote.mutation])
        _ = try library.store.create(text: "Local upload must proceed")
        let sync = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
            transport: server, blobs: SyncPayloadReaderTests.Blobs(), coordinator: FailingCoordinator(cancellation: cancellation))
        if cancellation {
            await #expect(throws: CancellationError.self) { try await sync.synchronize() }
        } else {
            await #expect(throws: SyncApplyError.changedDuringDownload) { try await sync.synchronize() }
        }
        #expect(await server.count() == (cancellation ? 1 : 2))
        #expect(try library.inbox.pending().contains { $0 == remote })
        #expect(try library.store.note(id: "note") == nil)
        await sync.shutdown()
    }

    @Test func earlyNewNoteMaterializationUsesOnlyLatestReceivedRevision() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let first = try library.entity(library.payload("Old text"))
        let latest = try library.entity(library.payload("Current text"), revision: 2, sequence: 2)
        let server = Server()
        _ = try await server.push([first.mutation, latest.mutation])
        _ = try library.store.create(text: "Upload backlog")
        let coordinator = CountingCoordinator(), transport = UploadCancellationTransport(server: server)
        let sync = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
            transport: transport, blobs: SyncPayloadReaderTests.Blobs(), coordinator: coordinator)
        await #expect(throws: CancellationError.self) { try await sync.synchronize() }
        #expect(try library.store.note(id: "note")?.text == "Current text")
        #expect(await coordinator.count == 1)
        await sync.shutdown()
    }

    @Test func pendingKeyEnvelopePrecedesEarlyNewNotesDuringFirstSyncVaultConversion() async throws {
        let library = try SyncMaterializerTests.Library(enabled: false)
        defer { library.cleanup() }
        let local = try library.store.create(text: "Local protected note")
        let access = try NotePrivacy(store: library.store).setPassword("local password")
        defer { access.revoke() }
        try access.lock(noteId: local.id)
        let (envelope, key) = try CryptoEnvelope.create(password: "account password")
        let envelopeEntity = try library.entity(SyncLockEnvelopePayload(envelope: JSONEncoder().encode(envelope)),
            type: .keyBundle, id: "account-note-key")
        var remote = library.payload("Remote protected note", id: "remote-note")
        remote.isLocked = true; remote.text = ""
        remote.encryptedPayload = try NoteCipher.seal(JSONEncoder().encode(
            LockedNotePayload(text: "Remote protected note", attachments: [:])), vaultKey: key, context: remote.id)
        let remoteEntity = try library.entity(remote, id: remote.id, sequence: 2)
        let server = Server(), sync = engine(library, server)
        _ = try await server.push([envelopeEntity.mutation, remoteEntity.mutation])
        let summary = try await sync.synchronize(noteAccess: access, remoteNotePassword: "account password")
        #expect(summary.passwordRefreshRequired && summary.uploaded == 0 && summary.pendingDownloads == 1)
        #expect(try library.store.note(id: remote.id) == nil)
        let refreshed = try NotePrivacy(store: library.store).unlock(password: "account password")
        defer { refreshed.revoke() }
        #expect(try refreshed.note(id: local.id)?.text == "Local protected note")
        #expect(await server.count() == 2)
        await sync.shutdown()
    }

    actor CancellationTransport: SyncTransport {
        var block = true
        var started = false
        var waiter: CheckedContinuation<Void, Never>?
        func waitForPull() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func pull(after cursor: Int64) async throws -> SyncPullResult {
            if block {
                block = false; started = true; waiter?.resume(); waiter = nil
                try await Task.sleep(for: .seconds(60))
            }
            return .init(changes: [], cursor: cursor, hasMore: false)
        }
        func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult { .init(results: []) }
        func acknowledge(_ cursor: Int64) async throws {}
    }
    @Test func backgroundExpirationCancelsCurrentCycleWithoutClosingNextForegroundSync() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let transport = CancellationTransport()
        let engine = SyncEngine(database: library.db, paths: library.paths, accountID: "account", vaultKey: library.key,
            transport: transport, blobs: SyncPayloadReaderTests.Blobs())
        let run = Task { try await engine.synchronize() }
        await transport.waitForPull()
        await engine.cancelCurrentRun()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(try await engine.synchronize().pendingDownloads == 0)
        await engine.shutdown()
    }

    @Test func expiredRemoteBlobClearsTheUploadedFlagAndRetriesTheSameMutation() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        _ = try library.store.create(text: "# Large note\n" + String(repeating: "body ", count: 70_000))
        let pending = try #require(try library.queue.prepareNext(vaultKey: library.key))
        let hash = try #require(pending.payloadRef)
        try await library.db.pool.write { try $0.execute(sql: "UPDATE sync_blob_state SET uploaded=1 WHERE hash=?", arguments: [hash]) }
        let server = Server(), sync = engine(library, server)
        await server.reportMissingBlobOnce()
        await #expect(throws: SyncProtocolError.invalidPayload) { try await sync.synchronize() }
        #expect(try await library.db.pool.read { try Bool.fetchOne($0, sql: "SELECT uploaded FROM sync_blob_state WHERE hash=?", arguments: [hash]) } == false)
        #expect(try library.queue.pendingMutations() == [pending])
        #expect(try await sync.synchronize().pendingUploads == 0)
        #expect(await server.count() == 1)
        await sync.shutdown()
    }

    @Test func twoOfflineLibrariesConvergeAndPreserveBothConflictingEdits() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = try SyncMaterializerTests.Library(key: key), b = try SyncMaterializerTests.Library(key: key)
        defer { a.cleanup(); b.cleanup() }
        let server = Server()
        let left = engine(a, server), right = engine(b, server)
        let original = try a.store.create(text: "Original")
        #expect(try await left.synchronize().pendingUploads == 0)
        #expect(try await right.synchronize().pendingDownloads == 0)
        let imported = try #require(try b.store.note(id: original.id))
        _ = try a.store.updateText(id: original.id, text: "Edited on iPhone", expectedRevision: original.revision)
        _ = try b.store.updateText(id: original.id, text: "Edited on iPad", expectedRevision: imported.revision)
        _ = try await left.synchronize()
        let conflict = try await right.synchronize()
        #expect(conflict.pendingUploads == 0 && conflict.pendingDownloads == 0)
        #expect(conflict.deferredConflicts == 0)
        _ = try await left.synchronize()
        let leftNotes = try await a.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
        let rightNotes = try await b.db.pool.read { try Note.fetchAll($0).sorted { $0.id < $1.id } }
        #expect(leftNotes.map(\.id) == rightNotes.map(\.id))
        #expect(leftNotes.map(\.text) == rightNotes.map(\.text))
        #expect(Set(leftNotes.map(\.text)) == ["Edited on iPhone", "Edited on iPad"])
        await left.shutdown(); await right.shutdown()
    }

    @Test func lostAcceptanceResponseReplaysSameMutationAfterRestartAndOldReceiptStaysIdempotent() async throws {
        let library = try SyncMaterializerTests.Library(); defer { library.cleanup() }
        let server = Server(), first = engine(library, server)
        let note = try library.store.create(text: "Saved offline")
        await server.loseNextResponse()
        await #expect(throws: URLError.self) { try await first.synchronize() }
        let pending = try #require(try library.queue.pendingMutations().first)
        #expect(await server.count() == 1)
        await first.shutdown()
        let resumed = engine(library, server)
        let recovered = try await resumed.synchronize()
        #expect(recovered.pendingUploads == 0 && recovered.pendingDownloads == 0)
        #expect(try await library.db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note") } == 1)
        #expect(await server.count() == 1)
        _ = try library.store.updateText(id: note.id, text: "Newer edit", expectedRevision: note.revision)
        _ = try await resumed.synchronize()
        let prior = try #require(try await server.push([pending]).results.first?.entity)
        try library.queue.accept(prior)
        let revision = try await library.db.pool.read { try Int64.fetchOne($0, sql: "SELECT serverRevision FROM sync_entity_state WHERE entityType='note' AND localId=?", arguments: [note.id]) }
        #expect(revision == 2)
        #expect(try library.store.note(id: note.id)?.text == "Newer edit")
        await resumed.shutdown()
    }
}
