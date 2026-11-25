// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesWatch

@Suite @MainActor struct WatchPresentationTests {
    @Test func waitingAndExpiredRequestsNeverClaimApplication() {
        let now = Date()
        let waiting = WatchPresentedOperation(id: UUID(), kind: .create, state: .waitingForLibrary,
            expiresAt: now.addingTimeInterval(60), deliveryDeadline: ContinuousClock.now.advanced(by: .seconds(60)))
        #expect(waiting.effectiveState(now: now) == .waitingForLibrary)
        #expect(waiting.effectiveState(now: now.addingTimeInterval(60)) == .expired)
        let elapsed = WatchPresentedOperation(id: UUID(), kind: .append, state: .queued,
            expiresAt: now.addingTimeInterval(60), deliveryDeadline: ContinuousClock.now.advanced(by: .seconds(-1)))
        #expect(elapsed.effectiveState(now: now.addingTimeInterval(-10)) == .expired)
        #expect(WatchOperationState.waitingForStorage.title == "Waiting for local save")
    }
    @Test func queuedNeverClaimsAppliedAndRefusalHasSafeUserText() {
        #expect(WatchOperationState.queued.title == "Queued")
        #expect(WatchOperationState.applied.title == "Applied on iPhone")
        #expect(WatchOperationState.appliedArchived.title == "Saved on iPhone (archived)")
        #expect(WatchOperationState.appliedTrashed.title == "Saved on iPhone (in Trash)")
        #expect(WatchOperationState.refused(.staleTarget).title == "Refused")
        #expect(WatchRefusalReason.staleTarget.message.contains("Refresh"))
        let privacy = WatchRefusalReason.privacy.message
        #expect(privacy.contains("paused to protect your notes"))
        #expect(!privacy.contains("App Lock") && !privacy.contains("Private fixture"))
    }
    @Test func homeShowsOneNoticeLine() {
        let presentation = WatchLibraryPresentation()
        #expect(presentation.homeNotice?.hasPrefix("iPhone unavailable") == true)
        presentation.isReachable = true
        #expect(presentation.homeNotice?.contains("App Lock") == true)
        presentation.notice = .unavailable
        #expect(presentation.homeNotice == WatchUserNotice.unavailable.message)
        presentation.notice = nil; presentation.isAuthorized = true
        #expect(presentation.homeNotice == nil)
    }
    @Test func captureRejectsEmptyNulAndOversizedTextWithoutChangingSource() {
        #expect(!WatchCaptureText.isValid(" \n"))
        #expect(!WatchCaptureText.isValid("a\0b"))
        #expect(!WatchCaptureText.isValid(String(repeating: "x", count: 16_385)))
        #expect(WatchCaptureText.isValid("  Exact dictated text 🐻\n"))
    }
    @Test func epochMismatchExplainsPriorApplicationForEachAction() {
        for kind in [WatchPresentedOperation.Kind.create, .append, .task] {
            let message = WatchRefusalReason.epochMismatch.message(for: kind)
            #expect(message.contains("may already have been applied before the restore"))
            #expect(message.contains(kind == .task ? "Check the task" : "Check iPhone"))
        }
    }
    @Test func unauthorizedProjectionNeverDisplaysStaleNotes() {
        let presentation = WatchLibraryPresentation()
        presentation.notes = [.init(id: UUID(), revision: 1, title: "Private", text: "Source", tasks: [])]
        #expect(presentation.visibleNotes.isEmpty)
        presentation.isAuthorized = true
        #expect(presentation.visibleNotes.isEmpty)
        presentation.isReachable = true
        #expect(presentation.visibleNotes.isEmpty)
        presentation.authorizationDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        #expect(presentation.visibleNotes.count == 1)
        presentation.isReachable = false
        #expect(presentation.visibleNotes.isEmpty)
        presentation.isReachable = true
        presentation.isAuthorized = false
        #expect(presentation.visibleNotes.isEmpty)
    }
    @Test func taskTargetKeepsExactSourceIdentity() {
        let id = UUID(), digest = String(repeating: "a", count: 64)
        let target = WatchTaskTarget(noteID: id, revision: 9, utf16Offset: 12, sourceSHA256: digest, expectedMarker: "[X]")
        let task = WatchPresentedTask(title: "Exact task", isChecked: true, target: target)
        #expect(task.id == 12 && task.target.noteID == id && task.target.revision == 9)
        #expect(task.target.sourceSHA256 == digest && task.target.expectedMarker == "[X]")
    }
}
