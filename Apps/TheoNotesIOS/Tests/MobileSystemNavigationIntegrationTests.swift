// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileSystemNavigationIntegrationTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func cleanup(_ library: MobileLibrary) {
        try? library.close(); try? FileManager.default.removeItem(at: library.paths.root)
    }

    @Test(arguments: [false, true])
    func heldSwitchDisconnectsImmediatelyAndOnlyReplaysOnCompletedDestination(abort: Bool) async throws {
        let old = try library(), next = try library()
        defer { cleanup(old); cleanup(next) }
        let router = MobileCaptureRouter()
        let navigation = MobileSpotlightNavigation()
        let connection = MobileLibraryRuntimeConnection(captureRouter: router, connectServices: { navigation.connect($0) })
        #expect(connection.connect(old))
        #expect(connection.prepareToDrain(old, ready: true))
        router.enqueue(.newNote) // Already bound to the outgoing library before the switch.
        #expect(connection.beginSwitch())
        #expect(!connection.beginSwitch()) // Other scenes cannot claim another overlapping switch.
        var release: CheckedContinuation<Void, Never>?
        let switching = Task {
            await withCheckedContinuation { release = $0 }
            let destination = abort ? old : next
            connection.finishSwitch(destination)
            #expect(connection.prepareToDrain(destination, ready: true))
            try await connection.drainCaptures(destination, ready: true)
        }
        defer { release?.resume(); switching.cancel() }
        for _ in 0..<200 where release == nil { try await Task.sleep(for: .milliseconds(5)) }
        let resume = try #require(release)
        release = nil
        #expect(!connection.connect(old)) // A late phase callback must not resurrect the old binding.
        #expect(!connection.prepareToDrain(old, ready: true))
        #expect(MobileQuickActions.receive(type: MobileQuickActions.Action.newNote.rawValue, router: router))
        try await router.drain()
        #expect(router.pendingCount == 2)
        #expect(try old.store.allNotes().isEmpty)
        #expect(try next.store.allNotes().isEmpty)
        resume.resume()
        try await switching.value
        #expect(!connection.isSwitching && router.pendingCount == 0)
        #expect(try old.store.allNotes().count == (abort ? 2 : 0))
        #expect(try next.store.allNotes().count == (abort ? 0 : 1))
    }

    @Test(arguments: [false, true])
    func latestWidgetOrSpotlightNavigationWinsAcrossReadinessBoundary(widgetLast: Bool) async throws {
        let library = try library(); defer { cleanup(library) }
        let widget = try library.store.create(text: "# Widget destination")
        let spotlight = try library.store.create(text: "# Spotlight destination")
        library.selectedID = nil
        let navigation = MobileSpotlightNavigation()
        navigation.connect(library)
        let receiveWidget = {
            navigation.receiveWidget(noteID: widget.id, libraryID: MobileCardPublication.libraryID(for: library.paths))
        }
        let receiveSpotlight = { navigation.receive(MobileSpotlight.identifier(noteID: spotlight.id, paths: library.paths)) }
        if widgetLast { receiveSpotlight(); receiveWidget() }
        else { receiveWidget(); receiveSpotlight() }
        try navigation.drain(ready: false)
        #expect(library.selectedID == nil)
        try navigation.drain(ready: true)
        #expect(library.selectedID == (widgetLast ? widget.id : spotlight.id))
        library.selectedID = nil
        try navigation.drain(ready: true)
        #expect(library.selectedID == nil) // The selected delivery was consumed once.
    }

    @Test func sharedNavigationRetainsLibraryAndPrivacyChecksDuringSwitchAndAuthentication() async throws {
        let old = try library(), next = try library()
        defer { cleanup(old); cleanup(next) }
        let oldNote = try old.store.create(text: "# Old library note")
        let note = try next.store.create(text: "# Current note")
        let navigation = MobileSpotlightNavigation()
        navigation.connect(old)
        navigation.receiveWidget(noteID: oldNote.id, libraryID: MobileCardPublication.libraryID(for: old.paths))
        navigation.connect(nil)
        try navigation.drain(ready: true)
        navigation.connect(next)
        try navigation.drain(ready: true)
        #expect(next.selectedID == nil)
        try await next.setAppLock(true, authenticate: {})
        next.lockApplication()
        navigation.receiveWidget(noteID: note.id, libraryID: MobileCardPublication.libraryID(for: next.paths))
        try navigation.drain(ready: true)
        #expect(next.selectedID == nil)
        try await next.setAppLock(true, authenticate: {})
        try navigation.drain(ready: true)
        #expect(next.selectedID == note.id) // Widget access remains allowed after authentication.
        next.selectedID = nil
        navigation.receive(MobileSpotlight.identifier(noteID: note.id, paths: next.paths))
        try navigation.drain(ready: true)
        #expect(next.selectedID == nil) // Enabled App Lock still rejects stale Spotlight results.
        try await next.unlockNotes(password: "fixture-password", createPassword: true)
        try next.lockNote(note.id)
        navigation.receiveWidget(noteID: note.id, libraryID: MobileCardPublication.libraryID(for: next.paths))
        try navigation.drain(ready: true)
        #expect(next.selectedID == nil)
        let trash = try next.store.create(text: "# Trashed destination")
        try next.store.trash([trash.id])
        navigation.receiveWidget(noteID: trash.id, libraryID: MobileCardPublication.libraryID(for: next.paths))
        try navigation.drain(ready: true)
        #expect(next.selectedID == nil)
    }
}
