// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileExplicitWindowRequestTests {
    private let libraryID = String(repeating: "a", count: 64)

    @Test func markerIsOneShotBoundedAndCannotBeReusedForAnotherTargetOrRestoration() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let address = try MobileNoteSceneAddress(libraryID: libraryID, noteID: UUID().uuidString)
        let changed = try MobileNoteSceneAddress(windowID: address.windowID, libraryID: libraryID, noteID: UUID().uuidString)
        var requests = MobileExplicitWindowRequests()
        requests.mark(address, now: now)
        let consumed1 = requests.consume(changed, now: now)
        #expect(!consumed1)
        let consumed2 = requests.consume(address, now: now)
        #expect(consumed2)
        let consumed3 = requests.consume(address, now: now)
        #expect(!consumed3)
        requests.mark(address, now: now)
        let consumed4 = requests.consume(address, now: now.addingTimeInterval(MobileExplicitWindowRequests.lifetime))
        #expect(!consumed4)
        requests.mark(address, now: now)
        let consumed5 = requests.consume(address, now: now.addingTimeInterval(-1))
        #expect(!consumed5)
        var restarted = MobileExplicitWindowRequests()
        let restored = try JSONDecoder().decode(MobileNoteSceneAddress.self, from: JSONEncoder().encode(address))
        let consumed6 = restarted.consume(restored, now: now)
        #expect(!consumed6)
        var values: [MobileNoteSceneAddress] = []
        for index in 0...MobileExplicitWindowRequests.capacity {
            let next = try MobileNoteSceneAddress(libraryID: libraryID, noteID: UUID().uuidString)
            values.append(next); requests.mark(next, now: now.addingTimeInterval(Double(index)))
        }
        #expect(requests.count == MobileExplicitWindowRequests.capacity)
        let consumed7 = requests.consume(values[0], now: now.addingTimeInterval(65))
        #expect(!consumed7)
        let consumed8 = requests.consume(values.last!, now: now.addingTimeInterval(65))
        #expect(consumed8)
    }

    @Test func vanishedExplicitTargetReportsUnavailableButIdenticalRestorationIsSilent() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: "Disposable target")
        let request = try MobileNoteSceneActivation.requestedAddress(noteID: note.id, library: library)
        try library.store.trash([note.id]); _ = try library.store.emptyTrash(ids: [note.id])
        let explicit = MobileNoteSceneActivation.consumeExplicitRequest(request)
        #expect(explicit)
        // These are the exact two origins consumed by the production SceneRoot.
        if case .unavailable? = MobileSceneActivationAdmission.resolve(request, library: library, phase: .active, origin: .external) { }
        else { Issue.record("A newly requested window must show the unavailable notice") }
        let consumedAgain = MobileNoteSceneActivation.consumeExplicitRequest(request)
        #expect(!consumedAgain)
        let restored = try JSONDecoder().decode(MobileNoteSceneAddress.self, from: JSONEncoder().encode(request))
        if case .discardRestoration? = MobileSceneActivationAdmission.resolve(restored, library: library, phase: .active, origin: .restoration) { }
        else { Issue.record("A later restored missing address must remain silent") }
        #expect(library.selectedID == nil)
        try await library.closeAfterStopping()
        try FileManager.default.removeItem(at: paths.root)
    }
}
