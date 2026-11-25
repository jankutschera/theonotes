// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSketchRecoveryCapacityTests {
    @Test func managerExcludesCurrentAndRefusesAnotherLiveEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "capacity-fixture")
        let current = UUID(), other = UUID(), otherOwner = UUID()
        let bytes = PKDrawing().dataRepresentation()
        for id in [current, other] {
            try await store.checkpoint(.init(id: id, generation: 1, originalNoteID: nil, drawingData: bytes,
                canvasSize: .init(width: 64, height: 64)), protection: .plain)
        }
        let model = MobileSketchRecoveryCapacityModel(store: store, currentDraftID: current, allowed: { true })
        try await model.refresh()
        #expect(model.items.map(\.id) == [other])
        await #expect(throws: (any Error).self) { try await model.discardSavedDraft(current) }
        #expect(try await store.claim(other, owner: otherOwner))
        await #expect(throws: (any Error).self) { try await model.discardSavedDraft(other) }
        #expect(try await store.load(other)?.drawingData == bytes)
        await store.release(other, owner: otherOwner)
        try await model.discardSavedDraft(other)
        #expect(try await store.load(other) == nil)
        #expect(try await store.load(current)?.drawingData == bytes)
        #expect(model.items.isEmpty)
    }

    @Test func staleLibraryCannotDeleteSavedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "capacity-fixture")
        let id = UUID(), bytes = PKDrawing().dataRepresentation()
        try await store.checkpoint(.init(id: id, generation: 1, originalNoteID: nil, drawingData: bytes,
            canvasSize: .init(width: 64, height: 64)), protection: .plain)
        var allowed = true
        let model = MobileSketchRecoveryCapacityModel(store: store, currentDraftID: UUID(), allowed: { allowed })
        try await model.refresh(); allowed = false
        await #expect(throws: (any Error).self) { try await model.discardSavedDraft(id) }
        #expect(try await store.load(id)?.drawingData == bytes)
    }
    @Test func explicitlyDiscardingAnotherDraftAllowsFreshCurrentCheckpointAtCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSketchDraftStore(root: root, libraryID: "capacity-fixture")
        let bytes = PKDrawing().dataRepresentation()
        var saved: [UUID] = []
        for _ in 0..<64 {
            let id = UUID(); saved.append(id)
            try await store.checkpoint(.init(id: id, generation: 1, originalNoteID: nil,
                drawingData: bytes, canvasSize: .init(width: 64, height: 64)), protection: .plain)
        }
        let current = UUID()
        let draft = MobileSketchDraftStore.Draft(id: current, generation: 1, originalNoteID: nil,
            drawingData: bytes, canvasSize: .init(width: 64, height: 64))
        await #expect(throws: (any Error).self) { try await store.checkpoint(draft, protection: .plain) }
        let model = MobileSketchRecoveryCapacityModel(store: store, currentDraftID: current, allowed: { true })
        try await model.refresh()
        #expect(model.items.count == 64)
        try await model.discardSavedDraft(saved[0])
        #expect(try await store.checkpoint(draft, protection: .plain))
        #expect(try await store.load(current)?.drawingData == bytes)
        #expect(try await store.discover().count == 64)
    }

}
