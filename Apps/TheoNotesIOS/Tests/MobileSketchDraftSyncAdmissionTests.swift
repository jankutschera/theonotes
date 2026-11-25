// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import PencilKit
import Synchronization
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchDraftSyncAdmissionTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func cleanup(_ value: MobileLibrary) { try? value.close(); try? FileManager.default.removeItem(at: value.paths.root) }
    private var snapshot: MobileSketchCheckpoint {
        .init(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64))
    }

    @Test func reservedFreshHostCanCheckpointAndPrepareAfterUnknownSync() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Open drawing origin")
        let drafts = library.sketchDraftStore
        let host = MobileSketchDraftHost(store: drafts, owner: UUID(), originalNoteID: note.id,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let called = Mutex(false)
        #expect(try await MobileSyncCommitCoordinator(library: library).commit(scope: .unknown) {
            called.withLock { $0 = true }; return .applied
        } == .applied)
        #expect(called.withLock { $0 })
        let checkpoint = snapshot
        host.checkpoint(checkpoint)
        #expect(try await host.waitForCheckpoint())
        try await host.prepareForWrite()
        let saved = try #require(try await drafts.load(host.id))
        #expect(saved.drawingData == checkpoint.drawingData && saved.state == .insertionUnconfirmed)
        try await host.discard()
    }

    @Test func protectedDraftDoesNotBlockUnknownButStillBlocksActualVaultScope() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Ordinary origin")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let draft = MobileSketchDraftStore.Draft(generation: 0, originalNoteID: note.id,
            drawingData: snapshot.drawingData, canvasSize: snapshot.canvasSize)
        #expect(try await library.sketchDraftStore.checkpoint(draft, protection: .sealed(access)))
        let coordinator = MobileSyncCommitCoordinator(library: library), called = Mutex(false)
        #expect(try await coordinator.commit { called.withLock { $0 = true }; return .applied } == .applied)
        #expect(called.withLock { $0 })
        called.withLock { $0 = false }
        await #expect(throws: CancellationError.self) {
            try await coordinator.commit(scope: .globalPrivacy) { called.withLock { $0 = true }; return .applied }
        }
        #expect(!called.withLock { $0 })
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try await library.sketchDraftStore.load(draft.id, access: access) == draft)
    }

    @Test func firstKeyBundleWithLiveOrdinaryClaimStillAllowsCheckpointAndPrepare() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Ordinary live draft")
        let drafts = library.sketchDraftStore
        let host = MobileSketchDraftHost(store: drafts, owner: UUID(), originalNoteID: note.id,
            boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let (envelope, _) = try CryptoEnvelope.create(password: "remote fixture password")
        let wire = try JSONSerialization.data(withJSONObject: ["version": 1,
            "envelope": SyncWire.base64(JSONEncoder().encode(envelope))])
        let key = SymmetricKey(size: .bits256)
        let cipher = try NoteCipher.seal(wire, vaultKey: key,
            context: SyncWire.cipherContext(accountID: "account", type: .keyBundle, entityID: "account-note-key"))
        let entity = SyncEntity(mutation: SyncMutation(mutationId: "first-vault-live-sketch", entityType: .keyBundle,
            entityId: "account-note-key", parentRevision: 0, ciphertext: SyncWire.base64(cipher)), revision: 1, sequence: 1, receivedAt: 1)
        try SyncQueue(database: library.database).configure(accountID: "account")
        let applier = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account",
            vaultKey: key, blobs: AdmissionNoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
        #expect(try await applier.apply(entity) == .applied)
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        host.checkpoint(snapshot); #expect(try await host.waitForCheckpoint())
        try await host.prepareForWrite()
        #expect(try await drafts.load(host.id)?.state == .insertionUnconfirmed)
        try await host.discard()
    }

    @Test func claimRenewalRejectsOldQueuedTokenAndWrongProtectedAccess() async throws {
        let library = try library(), other = try self.library()
        defer { cleanup(library); cleanup(other) }
        let note = try library.store.create(text: "# Authenticated draft")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        try await other.unlockNotes(password: "different fixture password", createPassword: true)
        let access = try #require(library.privateAccess), wrongAccess = try #require(other.privateAccess)
        let store = library.sketchDraftStore, id = UUID(), owner = UUID()
        #expect(try await store.reserveFresh(id, owner: owner))
        let checkpoint = snapshot
        let draft = MobileSketchDraftStore.Draft(id: id, generation: 1, originalNoteID: note.id,
            drawingData: checkpoint.drawingData, canvasSize: checkpoint.canvasSize)
        let old = store.captureAdmission(for: note.id)
        #expect(try await store.checkpoint(draft, protection: .sealed(access), admission: old))
        let suspension = try await store.suspendWrites(); await store.resumeWrites(suspension)
        await #expect(throws: CancellationError.self) {
            try await store.renewClaim(id, owner: owner, protection: .sealed(access), admission: old)
        }
        let fresh = store.captureAdmission(for: note.id)
        await #expect(throws: (any Error).self) {
            try await store.renewClaim(id, owner: owner, protection: .sealed(wrongAccess), admission: fresh)
        }
        #expect(try await !store.renewClaim(id, owner: UUID(), protection: .sealed(access), admission: fresh))
        #expect(try await store.load(id, access: access) == draft)
        #expect(try await store.renewClaim(id, owner: owner, protection: .sealed(access), admission: fresh))
        let next = MobileSketchDraftStore.Draft(id: id, generation: 2, originalNoteID: note.id,
            drawingData: checkpoint.drawingData, canvasSize: checkpoint.canvasSize)
        #expect(try await store.checkpoint(next, protection: .sealed(access), admission: fresh))
        #expect(try await store.load(id, access: access) == next)
        try await store.delete(id)
    }

    @Test func actualExternalReferenceTombstoneDoesNotInvalidateLiveSketchClaim() async throws {
        let library = try library(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Live sketch")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess)
        let drafts = library.sketchDraftStore
        let host = MobileSketchDraftHost(store: drafts, owner: UUID(), originalNoteID: note.id,
            boundary: { true }, protection: { .sealed(access) })
        #expect(try await host.reserveFresh())
        host.checkpoint(snapshot); #expect(try await host.waitForCheckpoint())
        try SyncQueue(database: library.database).configure(accountID: "account")
        let entity = SyncEntity(mutation: SyncMutation(mutationId: "remote-external-delete", entityType: .externalRef,
            entityId: UUID().uuidString, parentRevision: 0, tombstone: true), revision: 1, sequence: 1, receivedAt: 1)
        struct Pull: Encodable { let changes: [SyncEntity]; let cursor: Int64; let hasMore: Bool }
        let pull = try JSONDecoder().decode(SyncPullResult.self,
            from: JSONEncoder().encode(Pull(changes: [entity], cursor: 1, hasMore: false)))
        let inbox = SyncInbox(database: library.database)
        try inbox.persist(pull, requestedAfter: 0)
        let applier = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account",
            vaultKey: SymmetricKey(size: .bits256), blobs: AdmissionNoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
        _ = try await applier.apply(entity)
        #expect(try inbox.pending().isEmpty)
        host.checkpoint(snapshot); #expect(try await host.waitForCheckpoint())
        try await host.prepareForWrite()
        #expect(try await drafts.load(host.id, access: access)?.state == .insertionUnconfirmed)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        try await host.discard()
    }
}

private struct AdmissionNoBlobs: SyncBlobTransport {
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL { throw URLError(.fileDoesNotExist) }
}
