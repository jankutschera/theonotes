// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchDraftTransitionTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sketch-transition-" + UUID().uuidString)))
    }
    private func cleanup(_ library: MobileLibrary) {
        try? library.close(); try? FileManager.default.removeItem(at: library.paths.root)
    }
    private func draft(noteID: String, id: UUID = UUID(), generation: Int = 0) -> MobileSketchDraftStore.Draft {
        .init(id: id, generation: generation, originalNoteID: noteID,
              drawingData: Data("synthetic local draft archive".utf8), canvasSize: CGSize(width: 768, height: 1024))
    }
    private func pointer(_ library: MobileLibrary, id: UUID) -> URL {
        let identity = MobileCardPublication.libraryID(for: library.paths)
        let namespace = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return library.paths.root.appendingPathComponent("SketchDrafts").appendingPathComponent(namespace)
            .appendingPathComponent("Drafts").appendingPathComponent(id.uuidString).appendingPathComponent("current")
    }
    @Test func protectedDraftBlocksPasswordRemovalWithoutRevokingVaultThenDiscardAllowsIt() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Keep exact source\n👩‍💻 e\u{301}\r\n")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), before = try NotePrivacy(store: library.store).envelope()
        let value = draft(noteID: note.id), store = library.sketchDraftStore, sync = library.sync
        #expect(!sync.paused)
        #expect(try await store.checkpoint(value, protection: .sealed(access)))
        await #expect(throws: MobileSketchDraftError.self) { try await library.deleteNotesPassword() }
        #expect(try NotePrivacy(store: library.store).envelope() == before)
        #expect(try library.store.note(id: note.id) == note)
        #expect(library.privateAccess === access && library.hasNotePassword && !sync.paused && !library.libraryOperationBusy)
        _ = try access.journalKey()
        #expect(try await store.load(value.id, access: access) == value)
        // Failure path released the actual Library admission fence.
        #expect(try await store.checkpoint(draft(noteID: note.id, id: value.id, generation: 1), protection: .sealed(access)))
        try await store.discardAll()
        try await library.deleteNotesPassword()
        #expect(!library.hasNotePassword && library.privateAccess == nil)
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        #expect(try library.store.note(id: note.id) == note)
        #expect(throws: NotePrivacyError.accessRevoked) { _ = try access.journalKey() }
    }
    @Test(arguments: [false, true])
    func replaceAllWithAnyDraftPreservesLibraryAndVaultUntilExplicitDiscard(protected: Bool) async throws {
        let target = try makeLibrary(), source = try makeLibrary()
        defer { cleanup(target); cleanup(source) }
        let original = try target.store.create(text: "# Original library\nKeep exactly")
        target.selectedID = original.id
        try await target.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(target.privateAccess), envelope = try NotePrivacy(store: target.store).envelope()
        let replacement = try source.store.create(text: "# Replacement library")
        let backup = try await source.makeBackup()
        let value = draft(noteID: original.id), store = target.sketchDraftStore
        #expect(try await store.checkpoint(value, protection: protected ? .sealed(access) : .plain))
        await #expect(throws: MobileSketchDraftError.self) {
            _ = try await target.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: "fixture password")
        }
        #expect(try target.store.note(id: original.id) == original)
        #expect(try target.store.note(id: replacement.id) == nil)
        #expect(try NotePrivacy(store: target.store).envelope() == envelope)
        #expect(target.privateAccess === access && target.hasNotePassword && target.selectedID == original.id && !target.libraryOperationBusy)
        _ = try access.journalKey()
        #expect(try await store.load(value.id, access: protected ? access : nil) == value)
        try await store.discardAll()
        _ = try await target.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: "fixture password")
        #expect(try target.store.note(id: original.id) == nil)
        #expect(try target.store.note(id: replacement.id)?.text == replacement.text)
        #expect(try NotePrivacy(store: target.store).envelope() == nil)
        #expect(throws: NotePrivacyError.accessRevoked) { _ = try access.journalKey() }
    }
    @Test func realLibrarySuspendedActionBlocksNewPeerCheckpointAndReleasesAfterFailure() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Stable")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let peer = MobileSketchDraftStore(root: library.paths.root, libraryID: MobileCardPublication.libraryID(for: library.paths))
        let held = HeldDraftTransition(), value = draft(noteID: note.id)
        let action = Task<Void, any Error> {
            try await library.withSuspendedSketchWrites {
                #expect(try await !library.sketchDraftStore.hasProtectedDrafts())
                await held.hold() // The same real admission fence remains held across sync pause's await.
                throw CocoaError(.userCancelled)
            }
        }
        try await wait(held)
        await #expect(throws: MobileSketchDraftStore.Failure.self) { try await peer.checkpoint(value, protection: .sealed(access)) }
        #expect(try await library.sketchDraftStore.discover().isEmpty)
        await held.release()
        await #expect(throws: CocoaError.self) { _ = try await action.value }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope && library.privateAccess === access)
        #expect(try await peer.checkpoint(value, protection: .sealed(access)))
        #expect(try await peer.load(value.id, access: access) == value)
    }
    @Test func checkpointQueuedBeforeActualPasswordDeletionCannotLandAfterAdmissionResumes() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Stable")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), held = HeldDraftTransition()
        let peer = MobileSketchDraftStore(root: library.paths.root, libraryID: MobileCardPublication.libraryID(for: library.paths), beforeCheckpoint: { await held.hold() })
        let value = draft(noteID: note.id)
        let pending = Task { try await peer.checkpoint(value, protection: .sealed(access)) }
        try await wait(held)
        try await library.deleteNotesPassword()
        #expect(!library.hasNotePassword && library.privateAccess == nil)
        await held.release()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(try await library.sketchDraftStore.discover().isEmpty)
        #expect(try library.store.note(id: note.id) == note)
        // Successful transition also releases the fence for a fresh, authorized ordinary draft.
        #expect(try await library.sketchDraftStore.checkpoint(draft(noteID: note.id), protection: .plain))
    }
    @Test func corruptPointerBlocksBothDestructiveTransitionsWithoutChangingVaultOrNote() async throws {
        let library = try makeLibrary(), source = try makeLibrary()
        defer { cleanup(library); cleanup(source) }
        let note = try library.store.create(text: "# Preserve corrupted-draft recovery")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let value = draft(noteID: note.id), store = library.sketchDraftStore
        #expect(try await store.checkpoint(value, protection: .sealed(access)))
        let index = pointer(library, id: value.id), corrupted = Data("corrupt pointer must remain".utf8)
        try corrupted.write(to: index)
        _ = try source.store.create(text: "# Replacement")
        let backup = try await source.makeBackup()
        await #expect(throws: (any Error).self) { try await library.deleteNotesPassword() }
        await #expect(throws: (any Error).self) {
            _ = try await library.restoreBackup(backup, mode: .replaceAll, backupPassword: nil, currentPassword: "fixture password")
        }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try library.store.note(id: note.id) == note)
        #expect(library.privateAccess === access && library.hasNotePassword && !library.libraryOperationBusy)
        _ = try access.journalKey()
        #expect(try Data(contentsOf: index) == corrupted)
        #expect(try await store.checkpoint(draft(noteID: note.id), protection: .plain), "Both error paths must release writer admission")
    }
    @Test(arguments: [false, true])
    func semanticPlainResidualOfLockedOrMissingNoteBlocksPasswordRemoval(missing: Bool) async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Semantic private residual")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), envelope = try NotePrivacy(store: library.store).envelope()
        let value = draft(noteID: note.id)
        #expect(try await library.sketchDraftStore.checkpoint(value, protection: .plain))
        if missing { try library.store.deletePermanently([note.id]) }
        else { try access.lock(noteId: note.id) } // Core fixture deliberately skips the host's best-effort upgrade.
        #expect(try await library.sketchDraftStore.discover().first?.isProtected == false)
        await #expect(throws: MobileSketchDraftError.self) { try await library.deleteNotesPassword() }
        #expect(try NotePrivacy(store: library.store).envelope() == envelope)
        #expect(try await library.sketchDraftStore.load(value.id)?.drawingData == value.drawingData)
    }
    @Test func currentPlainDraftDoesNotUnnecessarilyKeepNotesPassword() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Ordinary current note")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let value = draft(noteID: note.id)
        #expect(try await library.sketchDraftStore.checkpoint(value, protection: .plain))
        try await library.deleteNotesPassword()
        #expect(try NotePrivacy(store: library.store).envelope() == nil)
        #expect(try await library.sketchDraftStore.load(value.id) == value)
    }
    @Test func actualLocalLockFencesQueuedPlainDecisionAndFailedUpgradeDoesNotBlockLock() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Lock now")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess), store = library.sketchDraftStore, value = draft(noteID: note.id)
        #expect(try await store.checkpoint(value, protection: .plain))
        let beforeLock = store.captureAdmission(for: note.id)
        try library.lockNote(note.id)
        access.revoke() // Synchronous, before the scheduled best-effort Task can obtain its key.
        #expect(try library.store.note(id: note.id)?.isLocked == true)
        await #expect(throws: (any Error).self) { _ = try await store.upgradePlainDrafts(noteID: note.id, access: access) }
        #expect(try await store.load(value.id)?.drawingData == value.drawingData)
        let peer = MobileSketchDraftStore(root: library.paths.root, libraryID: MobileCardPublication.libraryID(for: library.paths))
        await #expect(throws: CancellationError.self) { try await peer.checkpoint(draft(noteID: note.id, id: value.id, generation: 10), protection: .plain, admission: beforeLock) }
        #expect(try library.store.note(id: note.id)?.isLocked == true)
    }

    @Test func actualUnlockAllowsFreshOrdinaryDraftAfterProtectionFence() async throws {
        let library = try makeLibrary(); defer { cleanup(library) }
        let note = try library.store.create(text: "# Lock then unlock")
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        try library.lockNote(note.id)
        let queuedUpgradeAdmission = library.sketchDraftStore.captureAdmission(for: note.id)
        let access = try #require(library.privateAccess)
        try library.removeNoteLock(note.id)
        #expect(try library.store.note(id: note.id)?.isLocked == false)
        let store = library.sketchDraftStore, value = draft(noteID: note.id)
        let admission = store.captureAdmission(for: note.id)
        #expect(try await store.checkpoint(value, protection: .plain, admission: admission))
        // Deterministically execute an upgrade queued by the old lock AFTER fresh
        // post-unlock plaintext exists. It must not seal that unrelated new draft.
        await #expect(throws: CancellationError.self) {
            try await store.upgradePlainDrafts(noteID: note.id, access: access, admission: queuedUpgradeAdmission)
        }
        #expect(try await store.load(value.id) == value)
        #expect(try await store.discover().allSatisfy { !$0.isProtected })
    }

    private func wait(_ held: HeldDraftTransition) async throws {
        for _ in 0..<500 { if await held.started { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CancellationError()
    }
}

private actor HeldDraftTransition {
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
