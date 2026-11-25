// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

@MainActor final class MobileHardwareReturnUITests: XCTestCase {
    // The simulator's typeKey(Return) does not reach even an explicitly focused WebView.
    // Return itself remains a physical-keyboard device check.
    func testHardwareTypingAfterCreatingNoteWithoutTappingEditor() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        let create = app.buttons["new-note"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 60))
        create.tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        app.typeKey("a", modifierFlags: [])
        app.typeKey("b", modifierFlags: [])
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "ab"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed, app.debugDescription)
    }

    func testHardwareTypingAfterClosingSketchWithoutRetappingEditor() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText("a")
        let menu = app.descendants(matching: .any)["toolbar-attach"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        let sketch = app.buttons["toolbar-attach-sketch"].firstMatch
        XCTAssertTrue(sketch.waitForExistence(timeout: 20)); sketch.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20)); cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 20), .completed)
        app.typeKey("b", modifierFlags: [])
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "ab"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed, app.debugDescription)
    }
}
