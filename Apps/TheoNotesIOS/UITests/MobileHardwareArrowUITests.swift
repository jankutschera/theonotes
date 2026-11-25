// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

@MainActor final class MobileHardwareArrowUITests: XCTestCase {
    func testHardwareArrowsMoveTheCaretInsteadOfTheSidebar() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        let create = app.buttons["new-note"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 60)); create.tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        for key in ["a", "b", "c"] { app.typeKey(key, modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: [])
        app.typeKey("x", modifierFlags: [])
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS[c] %@", "abxc"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed, app.debugDescription)
    }
}
