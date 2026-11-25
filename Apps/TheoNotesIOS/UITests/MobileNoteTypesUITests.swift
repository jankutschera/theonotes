// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

@MainActor final class MobileNoteTypesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
    }

    func testTypeFromNoteInfo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        let create = app.buttons["new-note"]
        XCTAssertTrue(create.waitForExistence(timeout: 60))
        create.tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText("# Sort fixture\nA thought to file.")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["Note Info"].firstMatch.tap()
        let type = app.descendants(matching: .any)["note-type-menu"].firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "Note type menu")
        type.tap()
        app.buttons["Idea"].firstMatch.tap()
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "#idea"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 20), .completed)
        showSidebar(app)
        let ideas = app.descendants(matching: .any)["scope-Ideas"].firstMatch
        XCTAssertTrue(ideas.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "Note types sidebar")
        ideas.tap()
        XCTAssertTrue(app.staticTexts["Sort fixture"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testSortInboxAndUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        let create = app.buttons["new-note"]
        XCTAssertTrue(create.waitForExistence(timeout: 60)); create.tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText("# Inbox fixture\nSort this note.")
        app.buttons["Dismiss Keyboard"].firstMatch.tap()
        showSidebar(app)
        let inbox = app.descendants(matching: .any)["scope-Inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), app.debugDescription)
        inbox.tap()
        let sort = app.buttons["sort-inbox"]
        XCTAssertTrue(sort.waitForExistence(timeout: 15), app.debugDescription)
        sort.tap()
        XCTAssertTrue(app.staticTexts["Sort Inbox"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Inbox fixture"].waitForExistence(timeout: 15), app.debugDescription)
        capture(app, "Sort Inbox")
        let idea = app.buttons["Idea"].firstMatch
        XCTAssertTrue(idea.waitForExistence(timeout: 10), app.debugDescription)
        idea.tap()
        XCTAssertTrue(app.staticTexts["Inbox sorted"].waitForExistence(timeout: 15), app.debugDescription)
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10), app.debugDescription)
        undo.tap()
        XCTAssertTrue(app.staticTexts["Inbox fixture"].waitForExistence(timeout: 15), app.debugDescription)
        let archiveRest = app.buttons["Archive the Rest…"].firstMatch
        if !archiveRest.isHittable { app.swipeUp() }
        XCTAssertTrue(archiveRest.waitForExistence(timeout: 10), app.debugDescription)
        archiveRest.tap()
        XCTAssertTrue(app.staticTexts["Archive 1 note?"].waitForExistence(timeout: 10), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        XCTAssertFalse(app.staticTexts["Archive 1 note?"].exists)
        XCTAssertTrue(app.staticTexts["Inbox fixture"].waitForExistence(timeout: 10))
    }

    func testSidebarAtAccessibilityTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        showSidebar(app)
        let inbox = app.descendants(matching: .any)["scope-Inbox"].firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(inbox.isHittable)
        capture(app, "Sidebar large text")
        let references = app.descendants(matching: .any)["scope-References"].firstMatch
        if !references.isHittable { app.swipeUp() }
        XCTAssertTrue(references.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(references.isHittable)
        capture(app, "Sidebar large text continued")
    }

    private func showSidebar(_ app: XCUIApplication) {
        for _ in 0..<3 {
            if app.descendants(matching: .any)["scope-Inbox"].firstMatch.isHittable { return }
            let back = app.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable { back.tap(); continue }
            let sidebar = app.buttons["Show Sidebar"].firstMatch
            if sidebar.exists && sidebar.isHittable { sidebar.tap(); continue }
            break
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
