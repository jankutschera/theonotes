// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// REL-R79: a fresh install lists the twelve getting started notes under their tag, a relaunch does not
/// add more, and Settings ▸ Restore Getting Started Notes says "Nothing to restore" when nothing is missing. Runs only against
/// the disposable --ui-testing library (`--reset-library` is the "erased app data" of a fresh install).
@MainActor final class GettingStartedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false; executionTimeAllowance = 300
        // An earlier class may leave the iPad in landscape (SidebarTapsUITests); the counts below assume nothing.
        XCUIDevice.shared.orientation = .portrait
    }

    /// The note list: the rightmost collection view. On a landscape iPad the sidebar is on screen as well and is the first one.
    private func noteList(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.allElementsBoundByIndex.filter(\.exists).max(by: { $0.frame.minX < $1.frame.minX }) ?? app.collectionViews.firstMatch
    }

    private func openSidebar(_ app: XCUIApplication) {
        // A relaunch may restore the note list or an open note: go back until the sidebar shows.
        for attempt in 0..<3 where !app.buttons["Library Options"].waitForExistence(timeout: attempt == 0 ? 60 : 10) {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            back.tap()
        }
        XCTAssertTrue(app.buttons["Library Options"].waitForExistence(timeout: 10), "the sidebar shows")
    }

    /// Library Options, Settings, then the restore row at the end of the Settings list (scrolled to, as a finger would).
    private func restoreRow(_ app: XCUIApplication) -> XCUIElement {
        openSidebar(app)
        app.buttons["Library Options"].tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        let restore = app.descendants(matching: .any)["settings-restore-getting-started"].firstMatch
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        for _ in 0..<5 where !(restore.exists && restore.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(restore.waitForExistence(timeout: 10), "Settings has the Restore Getting Started Notes row")
        return restore
    }

    private func showTag(_ app: XCUIApplication) {
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "getting started")).firstMatch
        // The tags sit below the fixed places; the sidebar list is lazy, so scroll to them as a finger would.
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 60))
        for _ in 0..<6 where !(tag.exists && tag.isHittable) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(tag.waitForExistence(timeout: 10), "the sidebar lists the tag")
        tag.tap()
    }

    /// The distinct note rows of the list, scrolled from the top to the bottom (the list is lazy).
    private func rowLabels(_ app: XCUIApplication) -> Set<String> {
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 60))
        let list = noteList(app)
        var seen = Set<String>()
        var idle = 0
        while idle < 2 {
            let before = seen.count
            for cell in list.cells.allElementsBoundByIndex where cell.exists { seen.insert(cell.staticTexts.firstMatch.label) }
            idle = seen.count == before ? idle + 1 : 0
            list.swipeUp()
        }
        return seen.filter { !$0.isEmpty }
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // The row is a button inside the cell, labelled "<title>, <preview>"; the cell itself has no label.
        app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
    }

    /// Scrolls the list back to the top until the row can be hit, lets the scroll settle (a tap during a fling only stops it), then taps.
    private func tapRow(_ app: XCUIApplication, _ title: String) {
        let target = row(app, title)
        // All the way to the top: a row that is only just hittable can sit half under the bar, where a tap does not reach it.
        let list = noteList(app)
        for _ in 0..<4 { list.swipeDown() }
        for _ in 0..<4 where !(target.exists && target.isHittable) { list.swipeDown() }
        Thread.sleep(forTimeInterval: 1.5)
        target.tap()
    }

    /// Waits until the editor shows a note whose text starts with `prefix` (on iPad the editor of the previous note is already there).
    private func editorShows(_ app: XCUIApplication, _ prefix: String) -> Bool {
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Note text", prefix)).firstMatch
        return editor.waitForExistence(timeout: 60)
    }

    private func backToList(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 30))
        back.tap()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// A fresh install: the twelve notes under their tag, the Welcome note opens with its text, a tap on one of its scenario links opens
    /// that guide (LINK-TAP-R1, STARTER-R16), and a relaunch adds nothing.
    func testFreshInstallOpensTheTourAndARelaunchAddsNothing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-getting-started"]
        app.launch()
        openSidebar(app)
        showTag(app)
        let first = rowLabels(app)
        XCTAssertEqual(first.count, 12, "a fresh install shows the twelve notes: \(first.sorted())")
        XCTAssertTrue(first.contains { $0.hasPrefix("Welcome to Theo Notes") })
        attach(app, "starters-1-note-list")

        // Open Welcome by a real tap, then another tour note.
        tapRow(app, "Welcome to Theo Notes")
        XCTAssertTrue(editorShows(app, "# Welcome to Theo Notes"), "Welcome opens with its own text")
        attach(app, "starters-2-welcome-open")
        // Welcome is the entry: a finger taps the link of a scenario, as the note tells iPhone and iPad readers to do.
        let link = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Tags and links")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "Welcome shows the Tags and links link")
        link.tap()
        let second = editorShows(app, "# Tags and links")
        if !second { attach(app, "starters-second-note-not-open") }
        XCTAssertTrue(second, "a second tour note opens")
        backToList(app)

        // Relaunch on the same library: still twelve.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--seed-getting-started"]
        app.launch()
        openSidebar(app)
        showTag(app)
        XCTAssertEqual(rowLabels(app), first, "a relaunch adds nothing")
    }

    /// Settings ▸ Restore Getting Started Notes brings back a note moved to the Trash by touch and hold, and with nothing missing it says so.
    func testSettingsRestoresATrashedStarter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-getting-started"]
        app.launch()
        openSidebar(app)
        showTag(app)

        // Move one note to the Trash with the row's swipe action; the tag then lists eleven.
        let find = row(app, "Find anything")
        for _ in 0..<6 where !(find.exists && find.isHittable) { noteList(app).swipeDown() }
        Thread.sleep(forTimeInterval: 1.5)
        find.swipeLeft()
        // The row's own Trash action, not the sidebar's Trash place (also a button named Trash, off screen).
        let trash = app.collectionViews.buttons.matching(identifier: "trash")
        XCTAssertTrue(trash.firstMatch.waitForExistence(timeout: 15), "the row's swipe action offers Trash")
        guard let action = trash.allElementsBoundByIndex.first(where: { $0.isHittable }) else { return XCTFail("no visible Trash action") }
        action.tap()
        XCTAssertTrue(find.waitForNonExistence(timeout: 30), "the trashed note is gone from the tag")

        // Settings, Restore Getting Started Notes: the Trash note comes back and the tag shows twelve again.
        let restore = restoreRow(app)
        attach(app, "starters-3-settings-row")
        restore.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 60))
        XCTAssertEqual(rowLabels(app).count, 12, "the restored note is back")

        // Nothing is missing now: the row says so and changes nothing.
        restoreRow(app).tap()
        XCTAssertTrue(app.alerts["Nothing to restore"].waitForExistence(timeout: 15), "the notice for nothing to restore")
    }
}
