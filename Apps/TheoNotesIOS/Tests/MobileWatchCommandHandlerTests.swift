// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileWatchCommandHandlerTests {
    @Test(arguments: [NoteLocation.archive, .trash]) func replayAcknowledgesSavedLocation(location: NoteLocation) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let command = WatchWireCommand(id: UUID(), libraryID: try library.store.watchLibraryID(), epoch: try library.store.watchEpoch(), action: .create(text: "Saved"))
        let first = try await MobileWatchCommandHandler.handle(command, library: library)
        guard case .applied(let id, let revision) = first.result else { Issue.record("Expected applied"); return }
        if location == .archive { try library.store.archive([id]) } else { try library.store.trash([id]) }
        let replay = try await MobileWatchCommandHandler.handle(command, library: library)
        let expected: WatchWireResult = location == .archive ? .appliedArchived(noteID: id, revision: revision) : .appliedTrashed(noteID: id, revision: revision)
        #expect(replay.result == expected && replay.matches(command))
    }
    @Test func duplicateCreateReturnsSameCommittedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let command = WatchWireCommand(id: UUID(), libraryID: try library.store.watchLibraryID(), epoch: try library.store.watchEpoch(), action: .create(text: "Watch fixture"))
        let first = try await MobileWatchCommandHandler.handle(command, library: library)
        let second = try await MobileWatchCommandHandler.handle(command, library: library)
        #expect(first == second)
        guard case .applied(let id, _) = first.result else { Issue.record("Expected applied"); return }
        #expect(try library.store.note(id: id)?.text == "Watch fixture")
        #expect(try library.store.captureSource(noteId: id) == .voice)
    }
    @Test func wrongLibraryNeverMutates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let command = WatchWireCommand(id: UUID(), libraryID: String(repeating: "a", count: 64), epoch: try library.store.watchEpoch(), action: .create(text: "Must not appear"))
        await #expect(throws: WatchWireError.self) { try await MobileWatchCommandHandler.handle(command, library: library) }
    }
}
