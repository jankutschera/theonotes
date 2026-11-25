// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import TheoNotesCore

@Suite struct NoteHistoryTests {
    private func history(_ ids: [String], capacity: Int = NoteHistory.defaultCapacity) -> NoteHistory {
        var history = NoteHistory(capacity: capacity)
        ids.forEach { history.visit($0) }
        return history
    }

    @Test func testEmptyHistoryCannotNavigate() {
        var h = NoteHistory()
        #expect(h.current == nil)
        #expect(!h.canGoBack && !h.canGoForward)
        #expect(h.goBack() == nil)
        #expect(h.goForward() == nil)
    }

    @Test func testBackAndForwardWalkTheVisits() {
        var h = history(["a", "b", "c"])
        #expect(h.current == "c")
        #expect(h.canGoBack && !h.canGoForward)
        #expect(h.goBack() == "b")
        #expect(h.goBack() == "a")
        #expect(!h.canGoBack)
        #expect(h.goBack() == nil)
        #expect(h.current == "a")
        #expect(h.goForward() == "b")
        #expect(h.goForward() == "c")
        #expect(h.goForward() == nil)
        #expect(h.current == "c")
    }

    @Test func testVisitAfterGoingBackDropsTheForwardEntries() {
        var h = history(["a", "b", "c"])
        _ = h.goBack()
        h.visit("d")
        #expect(h.entries == ["a", "b", "d"])
        #expect(!h.canGoForward)
        #expect(h.goBack() == "b")
    }

    @Test func testVisitingTheCurrentNoteAgainIsNoVisit() {
        var h = history(["a", "b"])
        h.visit("b")
        #expect(h.entries == ["a", "b"])
        _ = h.goBack()
        h.visit("a") // e.g. the selection echoing the navigation
        #expect(h.entries == ["a", "b"])
        #expect(h.canGoForward)
    }

    @Test func testANoteVisitedAgainLaterIsANewEntry() {
        let h = history(["a", "b", "a"])
        #expect(h.entries == ["a", "b", "a"])
    }

    @Test func testHistoryIsCappedAtOneHundredDroppingTheOldest() {
        var h = history((0..<150).map { "n\($0)" })
        #expect(NoteHistory.defaultCapacity == 100)
        #expect(h.entries.count == 100)
        #expect(h.entries.first == "n50")
        #expect(h.current == "n149")
        var steps = 0
        while h.goBack() != nil { steps += 1 }
        #expect(steps == 99)
        #expect(h.current == "n50")
    }

    @Test func testCapAppliesAfterGoingBackToo() {
        var h = history(["a", "b", "c"], capacity: 3)
        _ = h.goBack()
        h.visit("d")
        h.visit("e")
        #expect(h.entries == ["b", "d", "e"])
        #expect(h.current == "e")
    }

    @Test func testUnavailableNotesAreSkipped() {
        var h = history(["a", "gone", "b", "gone2", "c"])
        let available: (String) -> Bool = { !$0.hasPrefix("gone") }
        #expect(h.goBack(where: available) == "b")
        #expect(h.goBack(where: available) == "a")
        #expect(h.goForward(where: available) == "b")
        #expect(h.goForward(where: available) == "c")
        // Nothing available behind: stays put.
        var only = history(["gone", "c"])
        #expect(only.goBack(where: available) == nil)
        #expect(only.current == "c")
    }
}
