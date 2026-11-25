// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// IOS-TOOLBAR: the formatting bar's Formatting menu, Attach and Camera buttons are the one place for these actions
/// (IOS-CLUTTER-R1..R3); Note Actions no longer repeats them. Runs only against the disposable --ui-testing library.
@MainActor final class FormattingBarUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func fixture(_ text: String = "Toolbar fixture") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        app.buttons["new-note"].tap()
        let editor = noteText(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        return app
    }

    private func tapBar(_ identifier: String, _ app: XCUIApplication) {
        let button = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 60), "\(identifier) must be in the formatting bar")
        button.tap()
    }

    /// A Note Actions entry with this label, never the bar's own button of the same name.
    private func noteMenuEntry(_ label: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH %@)", label, "toolbar-")).firstMatch
    }

    /// Tap outside the open menu (the nav bar's middle opens the title menu, so never there) until `gone` is off screen.
    private func closeMenu(_ app: XCUIApplication, until gone: XCUIElement) {
        for (dx, dy) in [(0.03, 0.45), (0.97, 0.45), (0.5, 0.012)] {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            if gone.waitForNonExistence(timeout: 4) { return }
        }
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attachEntry(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        tapBar("toolbar-attach", app)
        let entry = app.buttons[identifier].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "\(identifier) must be in the Attach menu")
        return entry
    }

    private func cancelPicker(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 60), "the native picker must actually be presented")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 60))
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 60))
    }

    func testFormattingMenuHoldsStylesAndAppliesAHeading() {
        let app = fixture("Toolbar heading")
        // IOS-TOOLBAR-R2: the one menu is the only place for Bold, Italic and headings.
        XCTAssertFalse(app.buttons["Headings"].exists)
        tapBar("toolbar-format", app)
        XCTAssertTrue(app.buttons["Bold"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Italic"].firstMatch.exists)
        // IOS-TOOLBAR-R4: the six levels sit in one "Heading" submenu.
        XCTAssertFalse(app.buttons["Heading 2"].exists)
        // IOS-TOOLBAR-R9: six top-level rows, every one on screen without scrolling (375-point phones too).
        for entry in ["Bold", "Italic", "Heading", "More Styles", "Paragraph", "Insert"] {
            let row = app.buttons[entry].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30) && row.isHittable, "\(entry) must be on screen in the open menu")
        }
        XCTAssertFalse(app.buttons["Sort To-Dos"].exists, "Sort To-Dos sits in Paragraph")
        let heading = app.buttons["Heading"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        heading.tap()
        let level2 = app.buttons["Heading 2"].firstMatch
        XCTAssertTrue(level2.waitForExistence(timeout: 30))
        level2.tap()
        // The editor's accessibility value exposes the heading line's marker; level 2 is exactly "##".
        let value = NSPredicate(format: "value BEGINSWITH %@ AND NOT (value BEGINSWITH %@)", "##", "###")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: value, object: noteText(app))], timeout: 30), .completed,
                       "Actual editor value: \(String(reflecting: noteText(app).value))")
    }

    /// IOS-TOOLBAR-R3: all eight cells are on screen and none is cut by the window edge (375-point phones too).
    func testBarFitsTheWidthWithoutScrolling() {
        let app = fixture("Toolbar width")
        let window = app.windows.firstMatch.frame
        for id in ["toolbar-format", "toolbar-attach", "toolbar-camera", "toolbar-To Do", "toolbar-Bullet List", "toolbar-Link", "toolbar-Code Block", "toolbar-dismiss-keyboard"] {
            let cell = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 30), "\(id) must be in the bar")
            XCTAssertGreaterThanOrEqual(cell.frame.minX, window.minX, "\(id) starts inside the window")
            XCTAssertLessThanOrEqual(cell.frame.maxX, window.maxX, "\(id) ends inside the window")
            XCTAssertGreaterThanOrEqual(cell.frame.width, 44, "\(id) keeps a 44-point target")
        }
    }

    /// The editor refuses the date command without a style; 1.0.0 builds 1 to 3 sent none, so the entry did nothing.
    func testFormattingMenuInsertsTheDate() {
        let app = fixture("Toolbar date ")
        tapBar("toolbar-format", app)
        let insert = app.buttons["Insert"].firstMatch
        XCTAssertTrue(insert.waitForExistence(timeout: 30)); insert.tap()
        // IOS-TOOLBAR-R9: Date is the first entry of Insert.
        let entry = app.buttons["Date"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        XCTAssertTrue(entry.isHittable, "Date must be on screen without scrolling")
        entry.tap()
        let year = String(Calendar.current.component(.year, from: Date()))
        let value = NSPredicate(format: "value CONTAINS %@", year)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: value, object: noteText(app))], timeout: 30), .completed,
                       "Actual editor value: \(String(reflecting: noteText(app).value))")
    }

    func testAttachPhotoLibraryOpensThePhotoPicker() {
        let app = fixture()
        let entry = attachEntry("toolbar-attach-photos", app)
        XCTAssertTrue(entry.isEnabled)
        entry.tap()
        cancelPicker(app)
    }

    func testAttachInsertFileOpensTheFilePicker() {
        let app = fixture()
        let entry = attachEntry("toolbar-attach-file", app)
        XCTAssertTrue(entry.isEnabled)
        entry.tap()
        cancelPicker(app)
    }

    func testAttachNewSketchOpensTheSketchEditor() {
        let app = fixture()
        let entry = attachEntry("toolbar-attach-sketch", app)
        XCTAssertTrue(entry.isEnabled)
        entry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["mobile.sketch.canvas"].waitForExistence(timeout: 60))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 60))
    }

    /// IOS-CLUTTER-R1..R3, R9: Note Actions holds none of the bar's actions, and the bar's own controls still work.
    func testNoteActionsLeaveBarActionsToTheBar() {
        let app = fixture()
        let dismiss = app.buttons["toolbar-dismiss-keyboard"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 30))
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 30), "the bar's Dismiss Keyboard closes the keyboard")
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Find in Note"].firstMatch.waitForExistence(timeout: 30))
        for label in ["Photo Library", "Take Photo", "Scan Document", "New Sketch", "Insert File", "Dismiss Keyboard", "Recovered Sketches"] {
            XCTAssertFalse(noteMenuEntry(label, app).exists, "\(label) must not be in Note Actions")
        }
        closeMenu(app, until: app.buttons["Find in Note"].firstMatch)
        XCTAssertTrue(app.buttons["Find in Note"].firstMatch.waitForNonExistence(timeout: 30))
        let entry = attachEntry("toolbar-attach-scan", app)
        XCTAssertTrue(app.buttons["toolbar-attach-photos"].exists && app.buttons["toolbar-attach-file"].exists
                      && app.buttons["toolbar-attach-sketch"].exists)
        // The iOS 27.0 simulator reports a document camera and a camera source, so the bar's one rule (unchanged since
        // 8dc07333) leaves both enabled there (measured on iPhone SE, iPhone 17, iPad A16); a device without one disables them.
        XCTAssertTrue(entry.exists)
        closeMenu(app, until: app.buttons["toolbar-attach-photos"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["toolbar-camera"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Code Block"].firstMatch.exists, "IOS-CLUTTER-R13: the bar's code button names what it makes")
    }

    /// Design r3 (iPad): WebKit's previous/next field arrows are gone from the on-screen keyboard's shortcut bar; undo, redo and
    /// paste stay, and typing still reaches the note. The screen is held for a host screenshot (marker file, as in MoveToICloudUITests).
    func testShortcutBarHasNoFieldArrowsOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the shortcut bar above the keys is the iPad's")
        let app = fixture("Shortcut bar")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "this test needs the on-screen keyboard")
        // The system's shortcut bar: undo, redo and paste on the left ("LeftButtonBar"), WebKit's arrows were on the right.
        XCTAssertTrue(app.buttons["assistantUndo"].firstMatch.waitForExistence(timeout: 15), "undo stays in the shortcut bar")
        XCTAssertTrue(app.buttons["assistantRedo"].exists && app.buttons["assistantPaste:forEvent:"].exists, "redo and paste stay")
        let right = app.otherElements["RightButtonBar"].firstMatch
        XCTAssertTrue(right.exists, "the shortcut bar is up")
        XCTAssertEqual(right.buttons.count, 0, "no previous/next field arrows: \(right.buttons.allElementsBoundByIndex.map(\.label))")
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            let folder = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/TheoNotesMoveShots", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("shortcut-bar").path, contents: Data())
            Thread.sleep(forTimeInterval: 10)
        }
        noteText(app).typeText(" typed after")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Shortcut bar typed after"), object: noteText(app))
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed, "typing still reaches the note")
    }

    /// IOS-CLUTTER-R15: Copy Table uses one label form; IOS-CLUTTER-R11: no tag switch inside Export.
    func testNoteActionsCopyTableAndExportEntries() {
        let app = fixture()
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        app.buttons["More"].firstMatch.tap()
        let copyTable = app.buttons["Copy Table"].firstMatch
        XCTAssertTrue(copyTable.waitForExistence(timeout: 30))
        // Design r3: Title Case, like the Mac's Note ▸ Make Read-Only.
        XCTAssertTrue(app.buttons["Make Read-Only"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Make Read-only"].exists)
        shot("More submenu", app)
        copyTable.tap()
        for label in ["Copy Table as Markdown", "Copy Table as HTML", "Copy Table as CSV"] {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 30), "\(label) must be in Copy Table")
        }
        closeMenu(app, until: app.buttons["Copy Table as CSV"].firstMatch)
        app.descendants(matching: .any)["Note Actions"].firstMatch.tap()
        let export = app.buttons["Export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        export.tap()
        XCTAssertTrue(app.buttons["Print"].firstMatch.waitForExistence(timeout: 30))
        shot("Note Actions Export menu", app)
        XCTAssertFalse(app.descendants(matching: .any)["Keep Tags in Rendered Exports"].exists)
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep Tags")).firstMatch.exists)
        closeMenu(app, until: app.buttons["Print"].firstMatch)
    }
}
