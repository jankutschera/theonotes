// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchDraftHostTests {
    private let noteID = "11111111-1111-4111-8111-111111111111"
    private let privateNoteID = "22222222-2222-4222-8222-222222222222"
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sketch-host-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var snapshot: MobileSketchCheckpoint {
        MobileSketchCheckpoint(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64))
    }
    @Test func hostCapturesAdmissionBeforeQueuedProtectionDecisionAndUsesFreshTokenOnRetry() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileSketchDraftStore(root: directory, libraryID: "test-library")
        var decisions = 0
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: noteID, boundary: { true }, protection: { decisions += 1; return .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(snapshot) // Token captured synchronously, before queued Task executes.
        let transition = store.beginProtectionTransition(noteID: noteID)
        store.completeProtectionTransition(transition, isProtected: false)
        // Current state permits plain again, so only the captured OLD epoch prevents publication.
        await #expect(throws: CancellationError.self) { _ = try await host.waitForCheckpoint() }
        #expect(try await store.discover().isEmpty && decisions == 1)
        host.checkpoint(snapshot)
        #expect(try await host.waitForCheckpoint())
        #expect(try await store.discover().count == 1)
        try await host.discard()
    }
    @Test func uncertainMarkerUsesAdmissionCapturedBeforeProtectionCallback() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileSketchDraftStore(root: directory, libraryID: "test-library")
        var changeEpoch = false
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: noteID, boundary: { true }, protection: {
            if changeEpoch {
                let transition = store.beginProtectionTransition(noteID: noteID)
                store.completeProtectionTransition(transition, isProtected: false)
            }
            return .plain
        })
        #expect(try await host.reserveFresh())
        host.checkpoint(snapshot); #expect(try await host.waitForCheckpoint())
        changeEpoch = true
        await #expect(throws: CancellationError.self) { try await host.prepareForWrite() }
        #expect(try await store.load(host.id)?.state == .editing)
        try await host.discard()
    }
    @Test func plainResidualOfLockedOrUnknownVaultNoteRequiresHiddenProtectedRecovery() {
        var note = Note(id: noteID, text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now)
        #expect(!MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: true, readOriginal: { note }))
        note.isLocked = true
        #expect(MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: true, readOriginal: { note }))
        #expect(MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: true, readOriginal: { nil }))
        #expect(!MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: false, readOriginal: { nil }))
        #expect(MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: false, hasVault: false, readOriginal: { throw CocoaError(.fileReadUnknown) }))
        note.isLocked = false
        #expect(MobileSketchDraftRestorePolicy.requiresProtection(storedProtected: true, hasVault: false, readOriginal: { note }))
    }
    @Test func protectionLookupFailureOrMissingNoteNeverAuthorizesPlaintext() {
        let missing = MobileSketchDraftProtectionPolicy.resolve(requiresProtection: false, access: nil, readNote: { nil })
        #expect(missing == nil)
        let failed = MobileSketchDraftProtectionPolicy.resolve(requiresProtection: false, access: nil, readNote: { throw CocoaError(.fileReadUnknown) })
        #expect(failed == nil)
        let plain = Note(id: privateNoteID, text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now)
        guard case .plain? = MobileSketchDraftProtectionPolicy.resolve(requiresProtection: false, access: nil, readNote: { plain }) else {
            Issue.record("A verified ordinary note should allow its ordinary draft"); return
        }
        #expect(MobileSketchDraftProtectionPolicy.resolve(requiresProtection: true, access: nil, readNote: { plain }) == nil)
        var locked = plain; locked.isLocked = true
        #expect(MobileSketchDraftProtectionPolicy.resolve(requiresProtection: false, access: nil, readNote: { locked }) == nil)
    }
    @Test func checkpointCannotCrossLibraryBoundaryAndProtectedDraftNeverFallsBackToPlain() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileSketchDraftStore(root: directory, libraryID: "test-library")
        var current = true
        let stale = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: noteID, boundary: { current }, protection: { .plain })
        #expect(try await stale.reserveFresh())
        stale.checkpoint(snapshot)
        current = false // same path can now represent a replaced library/generation
        await #expect(throws: (any Error).self) { _ = try await stale.waitForCheckpoint() }
        #expect(try await store.discover().isEmpty)
        stale.suspend()
        let protected = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: privateNoteID, boundary: { true }, protection: { nil })
        #expect(try await protected.reserveFresh())
        protected.checkpoint(snapshot)
        await #expect(throws: MobileSketchDraftHost.Failure.self) { _ = try await protected.waitForCheckpoint() }
        #expect(try await store.discover().isEmpty)
        protected.suspend()
    }
    @Test func writerAttemptPersistsUncertaintyBeforeWriterAndAutosaveCannotClearIt() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileSketchDraftStore(root: directory, libraryID: "test-library")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: noteID, boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(snapshot)
        try await host.prepareForWrite()
        #expect(try await store.load(host.id)?.state == .insertionUnconfirmed)
        host.checkpoint(snapshot)
        #expect(try await host.waitForCheckpoint())
        #expect(try await store.load(host.id)?.state == .insertionUnconfirmed)
        await #expect(throws: MobileSketchDraftHost.Failure.self) { try await host.prepareForWrite() }
        try await host.discard()
        #expect(try await store.discover().isEmpty)
    }
    @Test func freshTargetUsesCurrentUnicodeOffsetsAndPreservesMetadataOutsideReplacement() throws {
        let text = "# ö🙂\n\n![Drawing](my%20drawing.png)<!-- {\"width\":\"320\"} -->\n"
        let target = try #require(MobileSketchDraftRestorePolicy.freshTarget(filename: "my drawing.png", text: text, noteID: noteID))
        #expect(target.source == "![Drawing](my%20drawing.png)")
        #expect((text as NSString).substring(with: NSRange(location: target.from, length: target.to - target.from)) == target.source)
        #expect(MobileSketchDraftRestorePolicy.freshTarget(filename: "my drawing.png", text: text + text, noteID: noteID) == nil)
    }
    @Test func changedOriginalOrPlainTargetCannotReceiveProtectedRecovery() {
        let originalHash = String(repeating: "a", count: 64), changedHash = String(repeating: "b", count: 64)
        let draft = MobileSketchDraftStore.Draft(generation: 1, originalNoteID: noteID, sourceFilename: "drawing.png", sourceSHA256: originalHash, drawingData: snapshot.drawingData, canvasSize: snapshot.canvasSize)
        var note = Note(id: noteID, text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now)
        #expect(!MobileSketchDraftRestorePolicy.canUseOriginal(draft, note: note, canRead: true, currentHash: originalHash, protected: true))
        note.isLocked = true
        #expect(!MobileSketchDraftRestorePolicy.canUseOriginal(draft, note: note, canRead: true, currentHash: changedHash, protected: true))
        #expect(!MobileSketchDraftRestorePolicy.canUseOriginal(draft, note: nil, canRead: true, currentHash: originalHash, protected: true))
        #expect(MobileSketchDraftRestorePolicy.canUseOriginal(draft, note: note, canRead: true, currentHash: originalHash, protected: true))
    }
    @Test func passwordResetDetectsPlainResidualAfterNoteLocksAndAfterOriginalDisappears() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MobileLibrary(paths: AppPaths(root: directory))
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let note = try library.store.create(text: "# Original")
        let draft = MobileSketchDraftStore.Draft(generation: 1, originalNoteID: note.id,
            drawingData: snapshot.drawingData, canvasSize: snapshot.canvasSize)
        #expect(try await library.sketchDraftStore.checkpoint(draft, protection: .plain))
        #expect(!(try await library.hasKeyDependentSketchDrafts()))
        // Models the permitted no-key sync-lock residual: bytes stay file-protected, and
        // metadata now requires vault recovery even though the pointer remains plain.
        try library.privateAccess?.lock(noteId: note.id)
        #expect(!(try await library.sketchDraftStore.hasProtectedDrafts()))
        #expect(try await library.hasKeyDependentSketchDrafts())
        try library.store.trash([note.id]); _ = try library.store.emptyTrash(ids: [note.id])
        #expect(try await library.hasKeyDependentSketchDrafts())
        try await library.closeAfterStopping()
    }
    @Test func protectedNewTargetRequiresUnlockAndIsLockedBeforeAnyAttachmentInsertion() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MobileLibrary(paths: AppPaths(root: directory))
        #expect(throws: MobileSketchDraftHost.Failure.self) { try MobileSketchDraftRestorePolicy.createNewTarget(library: library, protected: true) }
        #expect(try library.store.allNotes().isEmpty)
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        let id = try MobileSketchDraftRestorePolicy.createNewTarget(library: library, protected: true)
        let note = try #require(try library.store.note(id: id))
        #expect(note.isLocked && note.text.isEmpty && note.encryptedPayload != nil)
        #expect(try library.privateAccess?.note(id: id)?.text.isEmpty == true)
        try await library.closeAfterStopping()
    }
}
