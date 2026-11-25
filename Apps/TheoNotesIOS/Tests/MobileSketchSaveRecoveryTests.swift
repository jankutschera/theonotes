// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import SwiftUI
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchSaveRecoveryTests {
    @Test(arguments: [false, true]) func failedOrUncertainSaveKeepsDurableDraftAndBlocksBlindRetry(uncertain: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        let bytes = PKDrawing().dataRepresentation()
        host.checkpoint(MobileSketchCheckpoint(drawingData: bytes, canvasSize: CGSize(width: 64, height: 64)))
        #expect(try await host.waitForCheckpoint())
        if uncertain { try await host.prepareForWrite() }
        host.recordSaveFailure()
        #expect(host.keepsDraftOnCancel)
        try await host.cancelByUser()
        let durable = try #require(try await store.load(host.id))
        #expect(durable.drawingData == bytes)
        #expect(durable.state == (uncertain ? .insertionUnconfirmed : .editing))
        #expect(try await store.discover().count == 1)
        await #expect(throws: (any Error).self) { try await host.prepareForWrite() }
        #expect(try await store.load(host.id) != nil)
    }

    @Test(arguments: [false, true]) func explicitNormalDiscardDeletesOnlyTheUnattemptedDraft(protected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: root); try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
        let notes = NoteStore(db: db, notifier: nil, paths: paths)
        let access = try NotePrivacy(store: notes).setPassword("fixture-password"); defer { access.revoke() }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { true }, protection: { protected ? .sealed(access) : .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(MobileSketchCheckpoint(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64)))
        #expect(try await host.waitForCheckpoint())
        #expect(!host.keepsDraftOnCancel)
        try await host.cancelByUser()
        #expect(try await store.load(host.id, access: access) == nil)
        #expect(try await store.discover().isEmpty)
    }

    @Test func editorLocalFailurePreserveHookMakesLaterCancelNonDestructive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(MobileSketchCheckpoint(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64)))
        #expect(try await host.waitForCheckpoint())
        #expect(!host.keepsDraftOnCancel) // Local canvas validation never invoked onDone.
        try await host.prepareToKeepAfterSaveFailure()
        #expect(host.keepsDraftOnCancel)
        try await host.cancelByUser()
        #expect(try await store.load(host.id) != nil)
    }

    @Test func staleSavePreservesDraftWithoutAuthorizingOldOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture")
        var current = true
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { current }, protection: { .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(MobileSketchCheckpoint(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64)))
        #expect(try await host.waitForCheckpoint())
        current = false; host.recordSaveFailure()
        try await host.cancelByUser()
        #expect(host.keepsDraftOnCancel)
        #expect(try await store.load(host.id) != nil)
        do { try await host.prepareForWrite(); Issue.record("Stale origin must not authorize a write") }
        catch MobileSketchDraftHost.Failure.stale { }
        catch { Issue.record("Expected stale refusal") }
    }

    @Test func protectedUncertainSaveClosesOnlyWithSealedRecoveryStillReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = AppPaths(root: root); try paths.createDirectories()
        let db = try AppDatabase(path: paths.database)
        defer { try? db.pool.close(); try? FileManager.default.removeItem(at: root) }
        let notes = NoteStore(db: db, notifier: nil, paths: paths)
        let access = try NotePrivacy(store: notes).setPassword("fixture-password"); defer { access.revoke() }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture")
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { true }, protection: { .sealed(access) })
        #expect(try await host.reserveFresh())
        let bytes = PKDrawing().dataRepresentation()
        host.checkpoint(MobileSketchCheckpoint(drawingData: bytes, canvasSize: CGSize(width: 64, height: 64)))
        #expect(try await host.waitForCheckpoint())
        try await host.prepareForWrite(); host.recordSaveFailure()
        try await host.cancelByUser()
        await #expect(throws: (any Error).self) { _ = try await store.load(host.id) }
        let recovered = try #require(try await store.load(host.id, access: access))
        #expect(recovered.drawingData == bytes && recovered.state == .insertionUnconfirmed)
        #expect(try await store.discover().count == 1)
        #expect(try notes.allNotes().isEmpty) // Close never inserts a duplicate note.
    }

    @Test func failedCheckpointCannotCloseAndPretendDrawingWasKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "fixture", beforeCheckpoint: { throw CocoaError(.fileWriteOutOfSpace) })
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: "11111111-1111-4111-8111-111111111111", boundary: { true }, protection: { .plain })
        #expect(try await host.reserveFresh())
        host.checkpoint(MobileSketchCheckpoint(drawingData: PKDrawing().dataRepresentation(), canvasSize: CGSize(width: 64, height: 64)))
        host.recordSaveFailure()
        await #expect(throws: (any Error).self) { try await host.cancelByUser() }
        #expect(try await store.discover().isEmpty)
    }

    @Test func inactiveKeepsCanvasBackgroundAndAppLockSuspendAndReofferRecovery() {
        #expect(!MobileSketchLifecyclePolicy.shouldSuspend(phase: .inactive, appLocked: false))
        #expect(!MobileSketchLifecyclePolicy.shouldSuspend(phase: .active, appLocked: false))
        #expect(MobileSketchLifecyclePolicy.shouldSuspend(phase: .background, appLocked: false))
        #expect(MobileSketchLifecyclePolicy.shouldSuspend(phase: .active, appLocked: true))
        #expect(MobileSketchLifecyclePolicy.deferredAfterProgrammaticSuspend(wasDeferred: true, hadPrompt: false)) // explicit Not Now
        #expect(!MobileSketchLifecyclePolicy.deferredAfterProgrammaticSuspend(wasDeferred: false, hadPrompt: true))
        #expect(!MobileSketchLifecyclePolicy.deferredAfterProgrammaticSuspend(wasDeferred: true, hadPrompt: true))
    }
}
