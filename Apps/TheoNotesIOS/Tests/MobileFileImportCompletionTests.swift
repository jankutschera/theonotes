// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite @MainActor struct MobileFileImportCompletionTests {
    @Test func libraryOperationRejectsFilesAndReleasesOnlyTheirOperation() throws {
        let gate = MobileMediaOperationGate()
        let id = try #require(gate.begin())
        #expect(MobileFileImportCompletion.claim(gate: gate, operationID: id,
                    importingNotes: false, libraryOperationBusy: true) == .busy)
        #expect(gate.currentID == nil)
        let next = try #require(gate.begin())
        #expect(MobileFileImportCompletion.claim(gate: gate, operationID: id,
                    importingNotes: false, libraryOperationBusy: true) == .stale)
        #expect(gate.currentID == next)
    }

    @Test func availableCompletionClaimsOnceAndDoesNotBlockInsertion() throws {
        let gate = MobileMediaOperationGate()
        let id = try #require(gate.begin())
        #expect(MobileFileImportCompletion.claim(gate: gate, operationID: id,
                    importingNotes: false, libraryOperationBusy: false) == .ready)
        #expect(gate.currentID == nil)
        #expect(MobileFileImportCompletion.claim(gate: gate, operationID: id,
                    importingNotes: false, libraryOperationBusy: false) == .stale)
    }

    @Test func notesImportCannotConsumeAnAttachmentOperationWhenLibraryIsBusy() throws {
        let gate = MobileMediaOperationGate()
        let id = try #require(gate.begin())
        #expect(MobileFileImportCompletion.claim(gate: gate, operationID: nil,
                    importingNotes: true, libraryOperationBusy: true) == .busy)
        #expect(gate.currentID == id)
    }
}
