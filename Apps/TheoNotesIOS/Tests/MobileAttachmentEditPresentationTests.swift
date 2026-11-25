// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileAttachmentEditPresentationTests {
    @Test func filterRemovalPreservesAuthoritativeDraftAndModalLease() throws {
        let note = Note(id: "draft", text: "# Sketch", title: "Sketch", titleKey: "sketch", createdAt: .now, modifiedAt: .now)
        var filteredResults = [note]
        let gate = MobileMediaOperationGate(), id = try #require(gate.begin())
        let lease = MobileAttachmentEditLease(gate: gate, id: id)
        #expect(lease.present())
        filteredResults.removeAll() // Search/tag membership changes, stored selected note does not.
        let access = MobileAttachmentDraftAccessState(note: note, canRead: true)
        if !access.permitsDraft(expectedLocked: false) { lease.cancel() }
        #expect(filteredResults.isEmpty && lease.canContinue && lease.isPresented && gate.begin() == nil)
    }
    @Test(arguments: ["lock", "delete", "trash", "readOnly", "access"])
    func authoritativePrivacyOrDeletionInvalidatesDraftButKeepsNativeDismissalLease(change: String) throws {
        var note = Note(id: "draft", text: "# Sketch", title: "Sketch", titleKey: "sketch", createdAt: .now, modifiedAt: .now)
        if change == "lock" { note.isLocked = true }
        if change == "trash" { note.location = .trash }
        if change == "readOnly" { note.isReadOnly = true }
        let gate = MobileMediaOperationGate(), id = try #require(gate.begin())
        let lease = MobileAttachmentEditLease(gate: gate, id: id)
        #expect(lease.present())
        let access = MobileAttachmentDraftAccessState(note: change == "delete" ? nil : note, canRead: change != "access")
        if !access.permitsDraft(expectedLocked: false) { lease.cancel() }
        #expect(!lease.canContinue && lease.isPresented && gate.begin() == nil)
        #expect(lease.didDismiss())
        #expect(gate.begin() != nil)
    }
    @Test func initialReadOnlyImageStillPermitsExistingPreviewFallback() {
        var note = Note(id: "preview", text: "", title: "", titleKey: "", createdAt: .now, modifiedAt: .now)
        note.isReadOnly = true
        let state = MobileAttachmentDraftAccessState(note: note, canRead: true)
        #expect(state.permitsDraft(expectedLocked: false, requiresEditable: false))
        #expect(!state.permitsDraft(expectedLocked: false))
    }
    @Test func menuHandoffReservationBlocksOtherActionsBeforePresentation() throws {
        let gate = MobileMediaOperationGate(), id = try #require(gate.begin())
        let lease = MobileAttachmentEditLease(gate: gate, id: id)
        #expect(gate.begin() == nil && !lease.isPresented && lease.canContinue)
        #expect(lease.present()) // called only by native attachment-actions onDismiss
        #expect(!lease.present())
        #expect(lease.isPresented && gate.begin() == nil)
        #expect(lease.didDismiss())
        #expect(gate.begin() != nil)
    }
    @Test func cancelDuringLoadOrSaveRetainsModalLeaseUntilNativeDismissal() throws {
        let gate = MobileMediaOperationGate(), id = try #require(gate.begin())
        let lease = MobileAttachmentEditLease(gate: gate, id: id)
        #expect(lease.present())
        lease.cancel()
        #expect(!lease.canContinue && lease.isPresented && gate.begin() == nil)
        #expect(lease.didDismiss())
        let newer = try #require(gate.begin())
        lease.cancel()
        #expect(!lease.didDismiss() && gate.isCurrent(newer))
    }
    @Test func cancelledPendingMenuCannotPresentAfterReactivationOrClearNewerOwner() throws {
        let gate = MobileMediaOperationGate(), id = try #require(gate.begin())
        let lease = MobileAttachmentEditLease(gate: gate, id: id)
        lease.cancel()
        let newer = try #require(gate.begin())
        #expect(!lease.present() && !lease.didDismiss())
        lease.cancel()
        #expect(gate.isCurrent(newer))
    }
}
