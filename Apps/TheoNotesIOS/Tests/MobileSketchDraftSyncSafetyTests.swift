// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Synchronization
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchDraftSyncSafetyTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("draft-sync-safety-" + UUID().uuidString)))
    }
    private func cleanup(_ library: MobileLibrary) { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
    private func deletion() -> SyncEntity {
        SyncEntity(mutation: SyncMutation(mutationId: "remote-vault-delete", entityType: .keyBundle,
            entityId: "account-note-key", parentRevision: 0, tombstone: true), revision: 1, sequence: 1, receivedAt: 1)
    }
    private func snapshot(_ noteID: String) -> MobileSketchDraftStore.Draft {
        .init(generation: 0, originalNoteID: noteID, drawingData: Data("protected pending sketch".utf8), canvasSize: CGSize(width: 768, height: 1024))
    }
    private func pointer(_ library: MobileLibrary, id: UUID) -> URL {
        let identity = MobileCardPublication.libraryID(for: library.paths)
        let namespace = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return library.paths.root.appendingPathComponent("SketchDrafts").appendingPathComponent(namespace)
            .appendingPathComponent("Drafts").appendingPathComponent(id.uuidString).appendingPathComponent("current")
    }
    @Test(arguments: [false, true])
    func realKeyBundleDeletionWaitsWithDurableInboxIncludingExclusiveSync(exclusive: Bool) async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# No locked note rows\nKeep source")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let draft = snapshot(note.id), drafts = library.sketchDraftStore
        #expect(try await drafts.checkpoint(draft, protection: .sealed(access)))
        let key = SymmetricKey(size: .bits256), entity = deletion()
        try SyncQueue(database: library.database).configure(accountID: "account") // Existing synced baseline; uploads intentionally disabled.
        let inbox = SyncInbox(database: library.database), coordinator = MobileSyncCommitCoordinator(library: library)
        let transport = DraftKeyBundleTransport(entity)
        let engine = SyncEngine(database: library.database, paths: library.paths, accountID: "account", vaultKey: key,
            transport: transport, blobs: DraftNoBlobs(), coordinator: coordinator)
        let materializer = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account", vaultKey: key,
            blobs: DraftNoBlobs(), coordinator: coordinator)
        if exclusive {
            await #expect(throws: CancellationError.self) {
                _ = try await library.synchronize(using: engine, notePassword: "fixture password", exclusive: true)
            }
        } else {
            try inbox.persist(draftPullResult([entity]), requestedAfter: 0)
            await #expect(throws: CancellationError.self) { _ = try await materializer.apply(entity) }
        }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try library.store.note(id: note.id) == note)
        #expect(try inbox.pending().contains { $0.mutation.mutationId == entity.mutation.mutationId })
        let recoveredAccess = try NotePrivacy(store: library.store).unlock(password: "fixture password")
        #expect(try await drafts.load(draft.id, access: recoveredAccess) == draft)
        // The exact persisted remote version can apply after explicit discard, not a new download.
        try await drafts.discardAll()
        if exclusive {
            _ = try await library.synchronize(using: engine, notePassword: "fixture password", exclusive: true)
        } else { #expect(try await materializer.apply(entity) == .applied) }
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        #expect(try inbox.pending().isEmpty)
        await engine.shutdown()
    }
    @Test(arguments: [false, true])
    func orphanOrCorruptDraftDefersBeforeActualKeyBundleWriter(corruptPointer: Bool) async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Plain note")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let draft = snapshot(note.id)
        #expect(try await library.sketchDraftStore.checkpoint(draft, protection: .sealed(access)))
        let index = pointer(library, id: draft.id)
        if corruptPointer { try Data("bad pointer".utf8).write(to: index) }
        else { try FileManager.default.removeItem(at: index) }
        try SyncQueue(database: library.database).configure(accountID: "account")
        let inbox = SyncInbox(database: library.database), entity = deletion()
        try inbox.persist(draftPullResult([entity]), requestedAfter: 0)
        let applier = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account",
            vaultKey: SymmetricKey(size: .bits256), blobs: DraftNoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
        await #expect(throws: CancellationError.self) { _ = try await applier.apply(entity) }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope && library.privateAccess === access)
        #expect(try inbox.pending().count == 1)
        if corruptPointer { #expect(try Data(contentsOf: index) == Data("bad pointer".utf8)) }
        else { #expect(try await library.sketchDraftStore.load(draft.id, access: access)?.drawingData == draft.drawingData) }
    }
    @Test func firstIncomingKeyBundleAppliesWithoutVaultDespitePlainMissingOriginalDraft() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        #expect(try !NotePrivacy(store: library.store).hasPassword)
        let draft = snapshot(UUID().uuidString)
        #expect(try await library.sketchDraftStore.checkpoint(draft, protection: .plain))
        let (incomingEnvelope, _) = try CryptoEnvelope.create(password: "remote fixture password")
        let envelopeBytes = try JSONEncoder().encode(incomingEnvelope)
        // The real wire payload uses URL-safe base64, not JSONEncoder's default Data encoding.
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "envelope": SyncWire.base64(envelopeBytes)])
        let transportKey = SymmetricKey(size: .bits256)
        let ciphertext = try NoteCipher.seal(payload, vaultKey: transportKey,
            context: SyncWire.cipherContext(accountID: "account", type: .keyBundle, entityID: "account-note-key"))
        let entity = SyncEntity(mutation: SyncMutation(mutationId: "first-remote-vault", entityType: .keyBundle,
            entityId: "account-note-key", parentRevision: 0, tombstone: false, ciphertext: SyncWire.base64(ciphertext)),
            revision: 1, sequence: 1, receivedAt: 1)
        try SyncQueue(database: library.database).configure(accountID: "account")
        let inbox = SyncInbox(database: library.database)
        try inbox.persist(draftPullResult([entity]), requestedAfter: 0)
        let applier = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account", vaultKey: transportKey,
            blobs: DraftNoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
        #expect(try await applier.apply(entity) == .applied)
        #expect(try NotePrivacy(store: library.store).envelope() == incomingEnvelope)
        #expect(try inbox.pending().isEmpty)
        #expect(try await library.sketchDraftStore.load(draft.id) == draft)
    }

    @Test func realVaultDeletionAlsoWaitsForPlainResidualWhoseOriginalNoteIsMissing() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Source later removed")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let envelope = try NotePrivacy(store: library.store).envelope(), draft = snapshot(note.id)
        #expect(try await library.sketchDraftStore.checkpoint(draft, protection: .plain))
        try library.store.deletePermanently([note.id])
        try SyncQueue(database: library.database).configure(accountID: "account")
        let inbox = SyncInbox(database: library.database), entity = deletion()
        try inbox.persist(draftPullResult([entity]), requestedAfter: 0)
        let applier = SyncMaterializer(database: library.database, paths: library.paths, accountID: "account", vaultKey: SymmetricKey(size: .bits256),
            blobs: DraftNoBlobs(), coordinator: MobileSyncCommitCoordinator(library: library))
        await #expect(throws: CancellationError.self) { _ = try await applier.apply(entity) }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try inbox.pending().count == 1)
        #expect(try await library.sketchDraftStore.load(draft.id)?.drawingData == draft.drawingData)
    }

    @Test func unknownScopePreservesProtectedDraftButVaultScopeAndRealErrorsRemainSafe() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Plain note")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), drafts = library.sketchDraftStore
        #expect(try await drafts.checkpoint(snapshot(note.id), protection: .sealed(access)))
        let coordinator = MobileSyncCommitCoordinator(library: library), called = Mutex(false)
        #expect(try await coordinator.commit { called.withLock { $0 = true }; return .applied } == .applied)
        #expect(called.withLock { $0 })
        called.withLock { $0 = false }
        await #expect(throws: CancellationError.self) {
            try await coordinator.commit(scope: .globalPrivacy) { called.withLock { $0 = true }; return .applied }
        }
        #expect(!called.withLock { $0 })
        #expect(try await coordinator.commit(scope: .unrelated) { .unchanged } == .unchanged)
        try await drafts.discardAll()
        await #expect(throws: CocoaError.self) {
            try await coordinator.commit(scope: .globalPrivacy) { throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(try await drafts.checkpoint(snapshot(note.id), protection: .sealed(access)), "Failure path must release the draft admission fence")
    }
}

private struct DraftNoBlobs: SyncBlobTransport {
    func ensureUploaded(_ hashes: [String]) async throws {}
    func download(hash: String) async throws -> URL { throw URLError(.fileDoesNotExist) }
}
private actor DraftKeyBundleTransport: SyncTransport {
    let entity: SyncEntity
    init(_ entity: SyncEntity) { self.entity = entity }
    func pull(after cursor: Int64) async throws -> SyncPullResult {
        try draftPullResult(cursor < 1 ? [entity] : [])
    }
    func acknowledge(_ cursor: Int64) async throws {}
    func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult {
        guard mutations.isEmpty else { throw CocoaError(.featureUnsupported) }
        return try JSONDecoder().decode(SyncPushResult.self, from: Data("{\"results\":[]}".utf8))
    }
}

// Exercise the same public wire decoding boundary as an HTTP transport. Core's
// response memberwise initializers intentionally are not part of its public API.
private func draftPullResult(_ changes: [SyncEntity]) throws -> SyncPullResult {
    struct Wire: Encodable {
        let changes: [SyncEntity]
        let cursor: Int64
        let hasMore: Bool
    }
    return try JSONDecoder().decode(SyncPullResult.self,
        from: JSONEncoder().encode(Wire(changes: changes, cursor: 1, hasMore: false)))
}
