// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct NextUpTimelineTests {
    @Test func futureEntriesChangeAtTheirPublishedDatesAndExpiredTextIsNotCarriedForward() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .empty), .init(date: now.addingTimeInterval(60), state: .candidate,
                noteId: "a", kind: "reminder", title: "Due", line: "Call")])
        #expect(snapshot.nextUpEntry(at: now)?.state == .empty)
        #expect(snapshot.nextUpEntry(at: now.addingTimeInterval(60))?.title == "Due")
        #expect(snapshot.nextUpEntry(at: now.addingTimeInterval(86401)) == nil)
    }
    @Test func emptyLockedMissingAndExpiredNextUpOnlyOpenTheApp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let empty = WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .empty)])
        for value in [empty, WidgetSnapshot.locked(libraryID: "library", now: now)] {
            let url = WidgetRoutes.nextUp(snapshot: value, at: now)
            #expect(url == WidgetRoutes.openApp())
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == nil)
        }
        #expect(WidgetRoutes.nextUp(snapshot: nil, at: now) == WidgetRoutes.openApp())
        let candidate = WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .candidate, noteId: "a", kind: "todo", title: "Note")])
        #expect(WidgetRoutes.nextUp(snapshot: candidate, at: now) == WidgetRoutes.note("a", libraryID: "library"))
        #expect(WidgetRoutes.nextUp(snapshot: candidate, at: now.addingTimeInterval(86401)) == WidgetRoutes.openApp())
    }

}
