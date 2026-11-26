// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// (1.1): a finger's tap on a wiki link's text opens the linked note; a tap beside it
/// places the caret and brings up the keyboard. Runs only against the disposable --ui-testing library.
@MainActor final class LinkTapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func createNote(_ text: String, _ app: XCUIApplication) {
        app.buttons["new-note"].firstMatch.tap()
        let editor = noteText(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        let first = String(text.split(separator: "\n")[0])
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", first), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
    }

    private func has(_ editor: XCUIElement, _ value: String) -> XCTestExpectation {
        XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: editor)
    }

    /// A run of the note's text as the web view exposes it to accessibility. The text view's own
    /// value ends where a link's run starts, so a note with a link is checked through its runs.
    private func text(_ label: String, _ app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
    }

    func testTapOnWikiLinkOpensNoteAndTapBesideEdits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        let target = "Tap target\nThe linked note."
        let source = "Tap source\nGo to [[Tap target]] now"
        createNote(target, app)
        if !app.buttons["new-note"].firstMatch.isHittable { app.navigationBars.buttons.firstMatch.tap() }
        createNote(source, app)
        let editor = noteText(app)

        let link = text("Tap target", app)
        record(app, "Source note before the link tap")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the link text must be reachable inside the web view")
        link.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [has(editor, target)], timeout: 15), .completed, "the tap must open the linked note")
        record(app, "Linked note after the tap")

        // Back to the source through the note list (Go Back is checked on its own below).
        let select = app.buttons["select-notes"].firstMatch
        if !(select.exists && select.isHittable) { app.navigationBars.buttons.firstMatch.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tap source")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Tap source\n"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 15), .completed, "Go Back must return to the source note")

        let beside = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "Go to")).firstMatch
        XCTAssertTrue(beside.waitForExistence(timeout: 10), "the text beside the link must be reachable")
        beside.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "a tap beside the link must bring up the keyboard")
        editor.typeText("Z")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@", "Tap source\n", "Z"),
            object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 10), .completed, "typing must land in the source note")
        XCTAssertTrue(link.exists, "the source note with its link is still the one shown")
        record(app, "Typed beside the link")
        app.terminate()
    }

    /// Go Back after a note switch without any link: tells a Go Back fault apart from the link tap.
    func testGoBackReturnsToThePreviousNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        createNote("Back first\nOne.", app)
        if !app.buttons["new-note"].firstMatch.isHittable { app.navigationBars.buttons.firstMatch.tap() }
        createNote("Back second\nTwo.", app)
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Go Back"].firstMatch.tap()
        let editor = noteText(app)
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Back first\nOne."), object: editor)
        let result = XCTWaiter.wait(for: [back], timeout: 15)
        record(app, "After Go Back")
        XCTAssertEqual(result, .completed, "Go Back must show the previous note")
        app.terminate()
    }

    private func record(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " AX"; tree.lifetime = .keepAlways; add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
