// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest
import UIKit

/// Opt in only on a disposable iPad simulator. The focused count test proves OS/registry creation;
/// the original side-by-side AX tests additionally gate same-note edit propagation on a device.
@MainActor final class MobileMultiwindowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func editors(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text"))
    }
    private func wait(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 30) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
                       timeout: timeout) == .completed
    }

    func testOpenInNewWindowCreatesSecondSceneAndSharesSameNoteEdits() throws {
        try openSecondWindow(fromNoteActions: false)
    }
    func testNoteActionsOpensSecondWindowAndSharesSameNoteEdits() throws {
        try openSecondWindow(fromNoteActions: true)
    }
    func testNoteActionsCreatesSecondConnectedAndRegisteredScene() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THEONOTES_MULTIWINDOW_UI"] == "1",
                          "Requires the dedicated disposable iPad simulator.")
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Multiple note windows require iPad.")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library", "--multiwindow-ui-testing"]
        app.launch()
        let create = app.buttons["new-note"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 60)); create.tap()
        XCTAssertTrue(editors(in: app).firstMatch.waitForExistence(timeout: 60))
        let counts = app.descendants(matching: .any).matching(identifier: "multiwindow-scene-counts")
        func hasCounts(_ expected: String) -> Bool {
            counts.allElementsBoundByIndex.contains { ($0.value as? String) == expected }
        }
        XCTAssertTrue(wait { hasCounts("connected=1;registered=1") },
                      "The fixture must begin with exactly one actual OS scene and one registered editor.")
        let actions = app.descendants(matching: .any)["Note Actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
        let open = app.buttons["open-note-window-menu-action"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(wait { hasCounts("connected=2;registered=2") },
                      "Opening the note must create a second connected OS scene and register its own editor.")
        // Leave the app running for the coordinator's separate simulator screenshot.
    }
    private func openSecondWindow(fromNoteActions: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THEONOTES_MULTIWINDOW_UI"] == "1",
                          "Requires an explicitly configured disposable iPad multitasking simulator; run separately from compact UI tests.")
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Multiple note windows require iPad.")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        defer { app.terminate() }
        let create = app.buttons["new-note"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 60))
        create.tap()
        let source = editors(in: app).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 60))
        let fixture = "Window fixture " + UUID().uuidString
        source.tap(); source.typeText("# " + fixture + "\nSame-note window fixture.")
        XCTAssertTrue(wait { (source.value as? String ?? "").contains(fixture) })
        let dismiss = app.buttons["Dismiss Keyboard"].firstMatch
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }

        let open: XCUIElement
        if fromNoteActions {
            let actions = app.descendants(matching: .any)["Note Actions"].firstMatch
            XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
            open = app.buttons["open-note-window-menu-action"]
        } else {
            // The selected list row has an app-owned context menu, independent of iPad OS chrome.
            let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "The wide library list must be visible in this configured fixture.")
            let row = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: \.isHittable))
            row.press(forDuration: 1)
            open = app.buttons["Open in New Window"].firstMatch
        }
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The app must expose the action when the OS supports multiple scenes.")
        open.tap()
        let noteWindows = app.windows.containing(NSPredicate(format: "label == %@", "Note text"))
        XCTAssertTrue(wait { noteWindows.count >= 2 },
                      "System activation must expose two actual note windows. A single visible editor is not evidence of multiwindow success.")
        let first = noteWindows.element(boundBy: 0).descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        let second = noteWindows.element(boundBy: 1).descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(wait { (first.value as? String ?? "").contains(fixture) &&
                             (second.value as? String ?? "").contains(fixture) })
        let editable = [first, second].first(where: \.isHittable)
        let writer = try XCTUnwrap(editable)
        writer.tap(); writer.typeText(" shared-window-edit")
        XCTAssertTrue(wait { (first.value as? String ?? "").contains("shared-window-edit") &&
                             (second.value as? String ?? "").contains("shared-window-edit") },
                      "An edit must reach both actual same-note windows without a stale page or lost text.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Two actual same-note windows after edit propagation"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
