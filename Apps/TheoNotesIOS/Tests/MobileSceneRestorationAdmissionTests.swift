// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneRestorationAdmissionTests {
    @Test(arguments: ["missing", "deleted", "foreign"])
    func staleRestorationIsNeutralButExplicitRequestStillReportsUnavailable(reason: String) throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let current = try library.store.create(text: "Other window must not flash")
        library.selectedID = current.id
        let target = try library.store.create(text: "Restored target")
        let address: MobileNoteSceneAddress
        if reason == "foreign" {
            address = try MobileNoteSceneAddress(libraryID: String(repeating: "f", count: 64), noteID: target.id)
        } else {
            address = try MobileNoteSceneAddress(libraryID: MobileCardPublication.libraryID(for: paths),
                noteID: reason == "missing" ? UUID().uuidString : target.id)
            if reason == "deleted" { try library.store.trash([target.id]); try library.store.deletePermanently([target.id]) }
        }
        let navigation = MobileSceneActivationAdmission.initialNavigation(address: address, library: library)
        #expect(navigation.selectedID == nil && navigation.id == address.windowID)
        guard case .discardRestoration? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active, origin: .restoration) else {
            Issue.record("A missing restored target should leave a neutral window without a global alert"); return
        }
        guard case .unavailable? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active, origin: .external) else {
            Issue.record("An explicit unavailable request must retain its informative refusal"); return
        }
        #expect(library.errorMessage == nil && library.selectedID == current.id)
        #expect(MobileSceneActivationAdmission.initialNavigation(address: nil, library: library).selectedID == current.id)
    }

    @Test func validProtectedRestorationStillWaitsAndRechecksAccess() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "restoration fixture", createPassword: true)
        let note = try library.store.create(text: "# Restored private content")
        try library.lockNote(note.id); try library.lockVault()
        let address = try MobileNoteSceneActivation.address(noteID: note.id, library: library)
        if case .some = MobileSceneActivationAdmission.resolve(address, library: library, phase: .background, origin: .restoration) {
            Issue.record("Background restoration must remain pending without access")
        }
        guard case .waitingForUnlock? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active, origin: .restoration) else {
            Issue.record("Do not discard a protected restoration while access is unavailable"); return
        }
        try await library.unlockNotes(password: "restoration fixture")
        guard case .note(let found)? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active, origin: .restoration) else {
            Issue.record("Recheck protected restoration after successful unlock"); return
        }
        #expect(found.id == note.id && library.selectedID == nil && library.errorMessage == nil)
    }
}
