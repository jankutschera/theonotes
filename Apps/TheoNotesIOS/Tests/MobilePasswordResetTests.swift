// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

@MainActor @Suite struct MobilePasswordResetTests {
    @Test func resetRevokesCachedAccessAndKeepsPlainSource() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mobile-password-reset-\(UUID())"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# Kept\nExact e\u{301}\r\n")
        try await library.unlockNotes(password: "old password", createPassword: true)
        let old = try #require(library.privateAccess)
        try await library.deleteNotesPassword()
        #expect(!library.hasNotePassword && library.privateAccess == nil && !library.biometryEnabled)
        #expect(throws: NotePrivacyError.accessRevoked) { try old.journalKey() }
        #expect(try library.store.note(id: note.id) == note)
        #expect(try !library.settings.value(.mobileBiometry))
    }

    @Test func refusedOperationsExplainSavingAndDoNotPauseSync() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mobile-busy-\(UUID())"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let sync = library.sync
        #expect(!sync.paused)
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.busy }
        let expected = "The open note is still saving. Try again."
        do { _ = try await library.importNotes([]); Issue.record("Import should wait") }
        catch { #expect(error.localizedDescription == expected) }
        do { _ = try await library.restoreBackup(paths.root.appendingPathComponent("absent"), mode: .merge, backupPassword: nil, currentPassword: nil); Issue.record("Restore should wait") }
        catch { #expect(error.localizedDescription == expected) }
        do { try await library.deleteNotesPassword(); Issue.record("Password removal should wait") }
        catch { #expect(error.localizedDescription == expected) }
        #expect(!sync.paused)
        #expect(library.hasNotePassword)
    }

    @Test func unavailableEditorDoesNotBlockSyncCommit() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mobile-unavailable-\(UUID())"))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        library.drainEditorForLibraryOperation = { throw MobileEditorDrainError.unavailable }
        let result = try await MobileSyncCommitCoordinator(library: library).commit(scope: .unknown) { .applied }
        #expect(result == .applied)
    }
}
