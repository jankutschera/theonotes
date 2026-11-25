// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest
import UIKit

/// The iPad sidebar must react to real taps (store 1.0.0: "in the left bar I cannot tap anything").
/// Every row is tapped with a real XCUITest tap; the selection must move and the list title must change.
/// Runs only against the disposable --ui-testing library.
@MainActor final class SidebarTapsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Only disposable simulator libraries are used.")
        #endif
    }

    private func launch(landscape: Bool, withNote: Bool, extra: [String] = []) -> XCUIApplication {
        // An iPhone in landscape has too little height for the whole sidebar; the iPad is the landscape case.
        XCUIDevice.shared.orientation = landscape && UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        if withNote {
            app.buttons["new-note"].tap()
            let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 60))
            editor.tap(); editor.typeText("# Tapped fixture\nA note with a tag #sidebar-tag")
            app.buttons["Dismiss Keyboard"].firstMatch.tap()
        }
        return app
    }

    private func revealSidebar(_ app: XCUIApplication) {
        // iPhone: note, then list, then sidebar (two steps back); iPad portrait: the sidebar button.
        for _ in 0..<3 {
            if app.descendants(matching: .any)["scope-Notes"].firstMatch.waitForExistence(timeout: 3) { return }
            let show = app.buttons["Show Sidebar"].firstMatch
            if show.exists { show.tap(); continue }
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
        }
    }

    private func report(_ app: XCUIApplication, _ name: String, _ text: String) {
        let a = XCTAttachment(string: text); a.name = name + "-result"; a.lifetime = .keepAlways; add(a)
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    private func tapRows(_ rows: [(id: String, title: String)], label: String, landscape: Bool, withNote: Bool, extra: [String] = []) {
        let app = launch(landscape: landscape, withNote: withNote, extra: extra)
        var lines = [String]()
        for row in rows {
            revealSidebar(app)
            let element = app.descendants(matching: .any)[row.id].firstMatch
            guard element.waitForExistence(timeout: 20) else { lines.append("\(row.id): missing"); XCTFail("\(row.id) missing"); continue }
            let hittable = element.isHittable
            element.tap()
            let titled = app.navigationBars[row.title].waitForExistence(timeout: 5)
            lines.append("\(row.id): hittable=\(hittable) titleChanged=\(titled)")
            XCTAssertTrue(titled, "tapping \(row.id) must show the list titled \(row.title)")
            report(app, "\(label)-\(row.id)", lines.last!)
        }
        report(app, "\(label)-summary", lines.joined(separator: "\n"))
    }

    private let rows: [(id: String, title: String)] = [
        ("scope-Inbox", "Inbox"), ("scope-Ideas", "Ideas"), ("scope-Logs", "Logs"), ("scope-References", "References"),
        ("scope-Pinned", "Pinned"), ("scope-Untagged", "Untagged"), ("scope-To Do", "To Do"), ("scope-Today", "Today"),
        ("scope-Archive", "Archive"), ("scope-Trash", "Trash"), ("scope-Notes", "Notes"),
    ]

    func testEmptyLibraryLandscape() { tapRows(rows, label: "empty-landscape", landscape: true, withNote: false) }
    func testEmptyLibraryPortrait() { tapRows(rows, label: "empty-portrait", landscape: false, withNote: false) }
    func testOneNoteLandscape() { tapRows(rows, label: "note-landscape", landscape: true, withNote: true) }
    /// The note list obeys real taps too: a row opens its note, also right after the sidebar was used.
    func testNoteListRowTapOpensTheNote() {
        let app = launch(landscape: true, withNote: true)
        for (id, title) in [("scope-Trash", "Trash"), ("scope-Notes", "Notes")] {
            revealSidebar(app)
            let row = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "\(id) must show \(title)")
        }
        let note = app.staticTexts["Tapped fixture"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "tapping the note row opens the editor")
        report(app, "note-row-tap", "opened")
    }

    /// The keyboard handover keeps working next to the taps: with the editor holding the keyboard, a tap on
    /// the sidebar still selects the row (and takes the keyboard from the editor).
    func testSidebarTapWorksWhileTheEditorHoldsTheKeyboard() {
        let app = launch(landscape: true, withNote: false)
        app.buttons["new-note"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText("keyboard in the editor")
        // A row near the top: the on-screen keyboard of a simulator without a hardware keyboard covers the bottom ones.
        let ideas = app.descendants(matching: .any)["scope-Ideas"].firstMatch
        if !ideas.waitForExistence(timeout: 5) { revealSidebar(app) }
        XCTAssertTrue(ideas.waitForExistence(timeout: 20)); ideas.tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 10), "a sidebar tap works while the editor holds the keyboard")
        report(app, "tap-after-editing", "ideas shown")
    }
}
