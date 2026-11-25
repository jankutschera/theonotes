// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

@MainActor
final class SyncPauseUITests: XCTestCase {
    func testPauseRemainsEnabledAboveDisabledInitialSyncNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--ui-testing", "--reset-library", "--sync-pause-fixture"]
        app.launch()

        let pause = app.buttons["Pause and Use App"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 60))
        XCTAssertTrue(pause.isEnabled, "The escape must not inherit disabled navigation.")
        XCTAssertTrue(pause.isHittable)
        let create = app.buttons["new-note"].firstMatch
        XCTAssertTrue(create.exists)
        XCTAssertFalse(create.isEnabled, "The initial merge must preserve the editing guard.")

        pause.tap()
        let editingRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [editingRestored], timeout: 30), .completed)
        XCTAssertFalse(pause.exists)
        create.tap()

        let editor = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap()
        editor.typeText("Editable after pausing sync")
        let textArrived = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Editable after pausing sync"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [textArrived], timeout: 15), .completed)
    }
}
