// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import TheoNotesCore
@testable import TheoNotes

struct MacSyncStatusTextTests {
    private func text(uploads: Int = 0, downloads: Int = 0, unavailable: Int = 0, locked: Int = 0) -> String {
        MacSyncController.statusText(
            waitingForUnlock: locked, pendingUploads: uploads, pendingDownloads: downloads, unavailableAttachments: unavailable)
    }

    @Test func unavailableAttachmentsAreNotReportedAsWaitingUploads() {
        #expect(text(unavailable: 9) == "9 attachments are unavailable on this Mac")
    }

    @Test func unavailableAttachmentsAreShownNextToRealTransfers() {
        #expect(text(uploads: 2, downloads: 1, unavailable: 9)
            == "2 uploads and 1 downloads waiting · 9 attachments are unavailable on this Mac")
        #expect(text(unavailable: 3, locked: 4)
            == "4 encrypted changes need your note password · 3 attachments are unavailable on this Mac")
    }

    @Test func nothingPendingIsUpToDate() {
        #expect(text() == "All notes are up to date")
    }
    @Test func deferredRemoteChangesRemainVisibleAlongsidePasswordStatus() {
        var summary = SyncRunSummary()
        summary.deferredConflicts = 2
        #expect(MacSyncController.statusText(for: summary) == "2 edits waiting to merge")
        summary.waitingForUnlock = 1
        #expect(MacSyncController.statusText(for: summary)
            == "1 encrypted change needs your note password · 2 edits waiting to merge")
        summary.waitingForUnlock = 0
        summary.deferredConflicts = 1
        #expect(MacSyncController.statusText(for: summary) == "1 edit waiting to merge")
    }

}
