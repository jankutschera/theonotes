// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneLibraryIntegrationTests {
    private func fixture() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func remove(_ library: MobileLibrary) {
        try? library.close(); try? FileManager.default.removeItem(at: library.paths.root)
    }
    @Test func placeholderWindowKeepsSharedActivityUntilLastWindowStops() async throws {
        let library = try fixture(); defer { remove(library) }
        let first = UUID(), loading = UUID()
        try library.registerScene(id: first, activity: .active)
        try library.registerScene(id: loading, activity: .active) // No editor constructed yet.
        #expect(!library.updateSceneActivity(id: first, activity: .background).becameInactive)
        #expect(library.hasActiveSceneWindows && library.isActive)
        // Delay editor construction/attachment across another event-loop turn. The
        // synchronous window reservation must remain the shared activity authority.
        await Task.yield()
        let navigation = MobileSceneNavigation(id: loading)
        let editor = MobileEditor(library: library)
        try library.registerScene(id: loading, editor: editor, navigation: navigation, observation: nil, activity: .active)
        #expect(library.hasActiveSceneWindows && library.isActive)
        #expect(library.updateSceneActivity(id: loading, activity: .background).becameInactive)
        #expect(!library.hasActiveSceneWindows && !library.isActive)
        try await library.detachScene(id: first); try await library.detachScene(id: loading)
        try await library.closeAfterStopping()
    }
    @Test func legacyNavigationAndCallbacksDeliverToOneChosenSceneAndScopedCreationStaysLocal() async throws {
        let library = try fixture(); defer { remove(library) }
        let first = MobileSceneNavigation(), last = MobileSceneNavigation()
        let a = MobileEditor(library: library), b = MobileEditor(library: library)
        try library.registerScene(id: first.id, editor: a, navigation: first, observation: nil, activity: .active)
        try library.registerScene(id: last.id, editor: b, navigation: last, observation: nil, activity: .active)
        let note = try library.store.create(text: "# External target")
        try library.reveal(note.id)
        #expect(first.selectedID == nil && last.selectedID == note.id)
        library.pendingCallbackNavigation = MobileCallbackNavigation(noteID: note.id, header: "Heading", find: nil, edit: false)
        #expect(first.pendingCallbackNavigation == nil && last.pendingCallbackNavigation?.noteID == note.id)
        #expect(library.pendingCallbackNavigation == nil)
        last.pendingCallbackNavigation = nil
        library.query = "later search"
        #expect(last.pendingCallbackNavigation == nil, "Consumed callbacks must not replay on a later delivery")
        first.scope = .tag("Work")
        let created = try library.createNote(in: first)
        #expect(first.selectedID == created && last.selectedID == note.id)
        #expect(try library.store.note(id: created)?.text.contains("#Work") == true)
        #expect(library.selectedID == note.id)
        library.prepareLegacyNavigationContext(for: first.id)
        let external = try library.createNote()
        #expect(first.selectedID == external && last.selectedID == note.id)
        #expect(try library.store.note(id: external)?.text.contains("#Work") == true)
        try await library.detachScene(id: first.id); try await library.detachScene(id: last.id)
        try await library.closeAfterStopping()
    }
    @Test func strictSceneDrainBlocksNewSessionsAndSwitchClaimBeforeAnyAwait() async throws {
        let library = try fixture(); defer { remove(library) }
        let navigation = MobileSceneNavigation(), editor = MobileEditor(library: library)
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        let note = try library.store.create(text: "# Kept")
        try await library.withDrainedEditor {
            #expect(throws: MobileEditorDrainError.busy) { _ = try library.session(for: note.id) }
        }
        let before = library.sceneAdmissionGeneration
        try library.claimSceneLibrarySwitch()
        #expect(throws: MobileEditorDrainError.busy) { _ = try library.createNote(in: navigation) }
        #expect(throws: MobileEditorDrainError.busy) { try library.registerScene(id: UUID(), activity: .active) }
        library.cancelSceneLibrarySwitch()
        #expect(library.sceneAdmissionGeneration > before)
        #expect(!library.sceneOperationPending)
        #expect(try library.store.note(id: note.id)?.text == note.text)
        try await library.detachScene(id: navigation.id)
        try await library.closeAfterStopping()
    }
    @Test func sharedPrivacyAdmissionStaysClosedAfterDrainUntilActualKeyRevocation() async throws {
        let library = try fixture(); defer { remove(library) }
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess)
        let first = MobileSceneNavigation(), second = MobileSceneNavigation()
        let a = MobileEditor(library: library), b = MobileEditor(library: library)
        try library.registerScene(id: first.id, editor: a, navigation: first, observation: nil, activity: .active)
        try library.registerScene(id: second.id, editor: b, navigation: second, observation: nil, activity: .active)
        let note = try library.store.create(text: "# Kept")
        let token = try #require(library.beginScenePrivacyClose())
        try await library.prepareScenePrivacyClose()
        #expect(a.isClosedForPrivacy && b.isClosedForPrivacy && library.privateAccess === access)
        let replacement = MobileEditor(library: library)
        #expect(throws: MobileEditorDrainError.busy) { try library.replaceClosedSceneEditor(id: second.id, editor: replacement) }
        #expect(throws: MobileEditorDrainError.busy) { _ = try library.session(for: note.id) }
        #expect(library.beginScenePrivacyClose() == nil)
        library.finishScenePrivacyClose(UUID())
        library.finishScenePrivacyClose(token) // Even the owner cannot release a live vault early.
        #expect(library.sceneOperationPending)
        try library.lockVault()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        #expect(library.sceneOperationPending, "Key revocation must precede admission release")
        library.finishScenePrivacyClose(token)
        #expect(!library.sceneOperationPending)
        try library.replaceClosedSceneEditor(id: second.id, editor: replacement)
        _ = try library.session(for: note.id)
        try await library.detachScene(id: first.id); try await library.detachScene(id: second.id)
        try await library.closeAfterStopping()
    }

    @Test func modalRoutingOwnerCannotMigrateToAnotherWindowAfterDetach() async throws {
        let library = try fixture(); defer { remove(library) }
        let first = MobileSceneNavigation(), second = MobileSceneNavigation()
        let a = MobileEditor(library: library), b = MobileEditor(library: library)
        try library.registerScene(id: first.id, editor: a, navigation: first, observation: nil, activity: .active)
        try library.registerScene(id: second.id, editor: b, navigation: second, observation: nil, activity: .active)
        library.markSceneFrontmost(id: first.id)
        let token = try #require(library.beginSceneRoutingLease(sceneID: first.id, deliveryID: UUID()))
        library.markSceneFrontmost(id: second.id)
        let note = try library.store.create(text: "# Voice owner target")
        try library.reveal(note.id)
        #expect(first.selectedID == note.id && second.selectedID == nil)
        try await library.detachScene(id: first.id)
        #expect(throws: MobileEditorDrainError.busy) { _ = try library.createNote() }
        library.selectedID = note.id // Simulate a late navigation callback, not a new write.
        library.releaseSceneRoutingLease(token)
        #expect(second.selectedID == nil, "A closed modal owner's late navigation is dropped")
        try await library.detachScene(id: second.id)
        try await library.closeAfterStopping()
    }

    @Test func sceneActivationRemainsPendingUntilLocalSceneBecomesActive() async throws {
        let library = try fixture(); defer { remove(library) }
        let note = try library.store.create(text: "# Local activation target")
        let address = try MobileNoteSceneActivation.address(noteID: note.id, library: library)
        if case .some = MobileSceneActivationAdmission.resolve(address, library: library, phase: .background) {
            Issue.record("Background scenes must retain, not resolve, their pending activity")
        }
        if case .some = MobileSceneActivationAdmission.resolve(address, library: library, phase: .inactive) {
            Issue.record("Inactive scenes must retain, not resolve, their pending activity")
        }
        guard case .note(let resolved)? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active) else {
            Issue.record("The active local scene should resolve its pending address"); return
        }
        #expect(resolved.id == note.id && library.selectedID == nil)
        try await library.setAppLock(true, authenticate: {})
        library.lockApplication()
        guard case .waitingForUnlock? = MobileSceneActivationAdmission.resolve(address, library: library, phase: .active) else {
            Issue.record("Local activation is not authorization to bypass App Lock"); return
        }
        try await library.closeAfterStopping()
    }

}
