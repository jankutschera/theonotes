// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

@testable import TheoNotesCore
import Testing
@testable import BaerchenIOS

@Suite @MainActor
struct MobileSyncStatusTests {
    @Test func missingAttachmentsNeverClaimUploadsWaitingOrFullySynced() {
        var summary = SyncRunSummary()
        summary.unavailableAttachments = 9
        #expect(MobileSyncController.statusText(for: summary) == "9 attachments are unavailable on this device")
        summary.unavailableAttachments = 1
        #expect(MobileSyncController.statusText(for: summary) == "1 attachment is unavailable on this device")
        summary.unavailableAttachments = 0
        #expect(MobileSyncController.statusText(for: summary) == "All notes are up to date")
    }

    @Test func unavailableFilesRemainVisibleAlongsideTransferAndPasswordStatus() {
        var summary = SyncRunSummary()
        summary.pendingUploads = 2
        summary.pendingDownloads = 3
        summary.unavailableAttachments = 9
        #expect(MobileSyncController.statusText(for: summary)
            == "2 uploads and 3 downloads waiting. 9 attachments are unavailable on this device")
        summary.waitingForUnlock = 4
        #expect(MobileSyncController.statusText(for: summary)
            == "4 encrypted changes need your note password. 9 attachments are unavailable on this device")
        summary.unavailableAttachments = 0
        #expect(MobileSyncController.statusText(for: summary) == "4 encrypted changes need your note password")
    }
    @Test func deferredRemoteChangesRemainVisibleAlongsidePasswordStatus() {
        var summary = SyncRunSummary()
        summary.deferredConflicts = 2
        #expect(MobileSyncController.statusText(for: summary) == "2 edits waiting to merge")
        summary.waitingForUnlock = 1
        #expect(MobileSyncController.statusText(for: summary)
            == "1 encrypted change needs your note password. 2 edits waiting to merge")
        summary.waitingForUnlock = 0
        summary.deferredConflicts = 1
        #expect(MobileSyncController.statusText(for: summary) == "1 edit waiting to merge")
    }

}
