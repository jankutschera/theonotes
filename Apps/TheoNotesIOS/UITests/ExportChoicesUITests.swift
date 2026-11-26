// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// 1.1 A9, A10, A14 on iPhone and iPad: real taps on the menus a person uses, against the disposable --ui-testing library.
/// Exports go through the real Files save sheet into "On My iPhone/iPad"; the written files are read by the evidence run.
@MainActor final class ExportChoicesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-library"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        return app
    }

    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func createNote(_ text: String, _ app: XCUIApplication) {
        app.buttons["new-note"].tap()
        let editor = noteText(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        let first = String(text.split(separator: "\n")[0])
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", first), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed)
    }

    private func showList(_ app: XCUIApplication) {
        if app.buttons["Hide keyboard"].firstMatch.exists { app.buttons["Hide keyboard"].firstMatch.tap() }
        let key = app.buttons["toolbar-dismiss-keyboard"].firstMatch
        if key.exists && key.isHittable { key.tap() }
        let select = app.buttons["select-notes"].firstMatch
        if select.exists && select.isHittable { return }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 30))
    }

    private func newNote(_ app: XCUIApplication) {
        showList(app)
        app.buttons["new-note"].tap()
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 60))
    }

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

    /// Opens Note Actions and taps a menu entry by label, scrolling the menu when the entry is below the fold.
    private func openActions(_ app: XCUIApplication, entry: String) {
        let actions = app.descendants(matching: .any)["Note Actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 30)); actions.tap()
        let item = app.buttons[entry].firstMatch
        // On a 375-point phone the entries below the fold only exist once the menu is scrolled.
        if !item.waitForExistence(timeout: 10) { scrollMenu(app, until: item) }
        XCTAssertTrue(item.waitForExistence(timeout: 20), "\(entry) must be in Note Actions")
        scrollMenu(app, until: item)
        XCTAssertTrue(item.isHittable, "\(entry) must be reachable in Note Actions (visible or by scrolling)")
        item.tap()
    }

    /// Scrolls an open menu the way a finger does: a drag that starts on one of its visible entries.
    private func scrollMenu(_ app: XCUIApplication, until item: XCUIElement) {
        let anchors = ["Note Info", "Copy Link to Note", "Pin", "Find in Note", "Plain Text", "PDF", "Markdown"]
        for _ in 0..<8 where !(item.exists && item.isHittable) {
            guard let anchor = anchors.lazy.map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) else { break }
            anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        }
    }

    private func choose(_ label: String, _ app: XCUIApplication) {
        let item = app.buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 30), "\(label) must be in the menu")
        scrollMenu(app, until: item)
        XCTAssertTrue(item.isHittable, "\(label) must be visible or reachable by scrolling")
        item.tap()
    }

    /// A real PNG attachment through the bar's Attach menu and a drawn stroke.
    private func insertSketch(_ app: XCUIApplication) {
        let editor = noteText(app)
        editor.tap()
        let menu = app.descendants(matching: .any)["toolbar-attach"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        let sketch = app.buttons["toolbar-attach-sketch"].firstMatch
        XCTAssertTrue(sketch.waitForExistence(timeout: 20)); sketch.tap()
        let finger = app.switches["Draw with Finger"].firstMatch
        XCTAssertTrue(finger.waitForExistence(timeout: 30))
        if finger.value as? String != "1" { finger.tap() }
        let canvas = app.descendants(matching: .any)["mobile.sketch.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(forDuration: 0.2, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 30))
    }

    /// In a Files sheet: go to "On My iPhone/iPad", through Browse when the sheet opened somewhere else.
    private func goToLocalFiles(_ app: XCUIApplication) throws {
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["On My iPad", "On My iPhone"]))
        let browse = app.buttons.matching(identifier: "Browse")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            local.allElementsBoundByIndex.contains { $0.isHittable } || browse.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed, "the Files sheet loaded")
        if !local.allElementsBoundByIndex.contains(where: { $0.isHittable }) {
            try XCTUnwrap(browse.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
            XCTAssertTrue(local.firstMatch.waitForExistence(timeout: 15))
        }
        try XCTUnwrap(local.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
    }

    private func saveToLocalFiles(_ app: XCUIApplication, expectingName: String) throws {
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        try goToLocalFiles(app)
        // The iOS 27 save sheet shows no name field; the run script checks the written file by its name afterwards.
        app.buttons["Save"].firstMatch.tap()
        // A file of the same name from an earlier run makes Files ask; a person taps Replace (the default handler tapped Stop).
        let replace = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Replace Existing Item"].buttons["Replace"]
        if replace.waitForExistence(timeout: 5) { replace.tap() }
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForNonExistence(timeout: 30))
    }

    private func row(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// The oldest row with this title (the list is newest first, and pasted copies start with the same line).
    private func openRow(_ title: String, _ app: XCUIApplication) {
        showList(app)
        XCTAssertTrue(row(title, app).waitForExistence(timeout: 30))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(noteText(app).waitForExistence(timeout: 30))
    }

    /// Pastes into a new note with the edit menu's Paste, as a finger does, and returns the note's text.
    private func pasteIntoNewNote(_ app: XCUIApplication) -> String {
        newNote(app)
        let editor = noteText(app)
        editor.tap()
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        editor.tap()
        if !paste.waitForExistence(timeout: 5) { editor.tap() }
        if !paste.waitForExistence(timeout: 5) { editor.press(forDuration: 1.0) }
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "the edit menu offers Paste")
        paste.tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != nil AND value != ''"), object: editor)], timeout: 15)
        return editor.value as? String ?? ""
    }

    /// Pastes into the list's search field with the edit menu's Paste and returns the raw text, then clears the field.
    /// (The editor's accessibility value leaves out Markdown markers it styles, so it cannot tell Markdown from Plain Text.)
    private func pasteIntoSearch(_ app: XCUIApplication) -> String {
        showList(app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        field.tap()
        if !paste.waitForExistence(timeout: 5) { field.press(forDuration: 1.0) }
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "the edit menu offers Paste")
        paste.tap()
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != 'Search notes'"), object: field)], timeout: 15)
        let value = field.value as? String ?? ""
        let clear = field.buttons["Clear text"].firstMatch
        if clear.exists { clear.tap() }
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        return value
    }

    /// A Form switch flips only from its control, not its label: tap the control's end of the row.
    private func turnOn(_ toggle: XCUIElement) {
        if toggle.value as? String != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, "1", "\(toggle.label) is on")
    }

    private func toggle(_ label: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    // MARK: Menus

    /// A9 + A10: the choices at the end of Export, Copy As beside it with the one Keep Tags switch.
    func testExportAndCopyAsMenus() {
        let app = launch()
        createNote("Menu fixture\nBody #tag", app)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()

        openActions(app, entry: "Export")
        XCTAssertTrue(app.buttons["Print"].firstMatch.waitForExistence(timeout: 30))
        // Design r3: one order of formats in every export menu, Print after them.
        let order = ["Markdown", "TextBundle", "HTML", "PDF", "Rich Text (RTF)", "Plain Text", "Print"]
        let tops = order.map { app.buttons[$0].firstMatch.frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "export order: \(zip(order, tops).map { "\($0) \($1)" })")
        let include = toggle("Include Attachments", app), embed = toggle("Images Inside File", app)
        XCTAssertTrue(include.waitForExistence(timeout: 10) && embed.exists, "the two choices end the Export menu")
        XCTAssertTrue(embed.isEnabled, "images inside the file is available while attachments are included")
        XCTAssertFalse(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep Tags")).firstMatch.exists, "IOS-CLUTTER-R11")
        shot("Export menu", app)
        include.tap()
        XCTAssertTrue(app.buttons["Print"].firstMatch.waitForNonExistence(timeout: 15))

        openActions(app, entry: "Export")
        XCTAssertTrue(toggle("Images Inside File", app).waitForExistence(timeout: 10))
        XCTAssertFalse(toggle("Images Inside File", app).isEnabled, "greyed while attachments are left out")
        XCTAssertTrue(app.buttons["TextBundle"].firstMatch.exists, "the TextBundle entry stops promising attachments")
        shot("Export menu, attachments off", app)
        toggle("Include Attachments", app).tap()

        openActions(app, entry: "Copy As")
        for label in ["Markdown", "Plain Text", "HTML", "Rich Text"] {
            XCTAssertTrue(app.buttons[label].firstMatch.waitForExistence(timeout: 20), "\(label) must be in Copy As")
        }
        XCTAssertFalse(toggle("Keep Tags", app).exists, "IOS-CLUTTER-R11: Keep Tags is in Settings only")
        XCTAssertFalse(app.buttons["Copy as HTML"].exists || app.buttons["Copy as Rich Text"].exists, "one place per action: the old copies left Export")
        shot("Copy As menu", app)
        closeMenu(app, until: app.buttons["Rich Text"].firstMatch)
    }

    // MARK: Copy As

    func testCopyAsPlainTextMarkdownAndTheShortcutPaste() {
        let app = launch()
        createNote("Copy fixture\nBold **word** and #travel", app)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()

        openActions(app, entry: "Copy As"); choose("Plain Text", app)
        let plain = pasteIntoSearch(app)
        XCTAssertTrue(plain.contains("Bold word") && !plain.contains("**"), "Plain Text drops the markup: \(plain)")

        openRow("Copy fixture", app)
        openActions(app, entry: "Copy As"); choose("Markdown", app)
        let markdown = pasteIntoSearch(app)
        XCTAssertTrue(markdown.contains("Bold **word** and #travel"), "Markdown copies the text as written: \(markdown)")

        openRow("Copy fixture", app)
        app.typeKey("c", modifierFlags: [.command, .shift])
        let rich = pasteIntoSearch(app)
        XCTAssertTrue(rich.contains("Bold word") && !rich.contains("**"), "⇧⌘C copies as Rich Text (plain text beside it): \(rich)")
    }

    func testCopyAsOfASelectionCopiesTheSelectionOnly() {
        let app = launch()
        createNote("Select fixture\nsecond line\nhere", app)
        // Select the word with a double tap: four ⇧← presses sometimes arrived as three under load ("ere"),
        // although the same presses select "here" on screen when all arrive (round 2 probe).
        let word = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "here")).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 30))
        word.doubleTap()
        openActions(app, entry: "Copy As"); choose("Markdown", app)
        let pasted = pasteIntoNewNote(app)
        XCTAssertEqual(pasted.trimmingCharacters(in: .whitespacesAndNewlines), "here", "only the selected text is copied")
    }

    // MARK: Export with the choices (written files are read by the evidence run)

    func testExportMarkdownWithAttachmentsOffAndWithImagesEmbedded() throws {
        let app = launch()
        createNote("Export attach off\nbody", app)
        insertSketch(app)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        openActions(app, entry: "Export"); toggle("Include Attachments", app).tap()
        openActions(app, entry: "Export"); choose("Markdown", app)
        try saveToLocalFiles(app, expectingName: "Export attach off")
        XCTAssertTrue(app.buttons["Note Actions"].firstMatch.waitForExistence(timeout: 30) || app.descendants(matching: .any)["Note Actions"].firstMatch.exists)

        openActions(app, entry: "Export"); toggle("Include Attachments", app).tap()
        showList(app)
        createNote("Export images inside\nbody", app)
        insertSketch(app)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        openActions(app, entry: "Export"); toggle("Images Inside File", app).tap()
        openActions(app, entry: "Export"); choose("Markdown", app)
        try saveToLocalFiles(app, expectingName: "Export images inside")
        openActions(app, entry: "Export"); toggle("Images Inside File", app).tap()
    }

    // MARK: Import options

    /// A14: export a note to Files with real taps, then import that file again with the options off and on.
    func testImportOptionsStepOffAndOn() throws {
        var app = launch()
        let first = "Import fixture heading"
        createNote(first + "\nPlain line with #3rd and #work", app)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        openActions(app, entry: "Export"); choose("Markdown", app)
        try saveToLocalFiles(app, expectingName: first)

        for (index, optionsOn) in [false, true].enumerated() {
            app.terminate()
            app = launch()
            showList(app)
            if !app.buttons["Library Options"].firstMatch.exists || !app.buttons["Library Options"].firstMatch.isHittable {
                let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Toggle sidebar"])).firstMatch
                if toggle.exists && toggle.isHittable { toggle.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            }
            app.buttons["Library Options"].firstMatch.tap()
            app.buttons["Import Notes"].firstMatch.tap()
            try goToLocalFiles(app)
            let files = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", first))
            XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 15))
            try XCTUnwrap(files.allElementsBoundByIndex.first { $0.isHittable }, "the exported file is in Files").tap()
            // iPad's picker selects the file and waits for Open; the phone's opens it at once.
            let open = app.buttons["Open"].firstMatch
            if open.exists {
                let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: open)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, "Open is enabled once the file is selected")
                open.tap()
            }

            let sheetTitle = app.navigationBars["Import Notes"].firstMatch
            XCTAssertTrue(sheetTitle.waitForExistence(timeout: 30), "the options step opens before anything is imported: " + app.debugDescription)
            let firstLine = app.switches["Use First Line as Title"].firstMatch, keep = app.switches["Keep Number Tags as Text"].firstMatch
            XCTAssertTrue(firstLine.exists && keep.exists)
            if optionsOn { turnOn(firstLine); turnOn(keep) }
            shot("Import options sheet, options " + (optionsOn ? "on" : "off") + " (\(index))", app)
            app.buttons["Import"].firstMatch.tap()
            XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 30))

            // The sidebar's tag list shows what became a tag (the editor's value leaves out the escape it styles).
            let tag = { (name: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch }
            XCTAssertTrue(app.staticTexts["Tags"].firstMatch.waitForExistence(timeout: 30), "the import made tags")
            // On the 375-point phone the tag list starts at the bottom edge and "work" sits below the fold: scroll like a finger.
            let work = tag("work")
            var swipes = 0
            while !work.waitForExistence(timeout: 5) && swipes < 4 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(work.exists, "#work is a tag either way")
            for _ in 0..<swipes { app.swipeDown() }
            XCTAssertEqual(tag("3rd").exists, !optionsOn, optionsOn ? "#3rd stays text" : "#3rd is a tag with the options off")
            let notes = app.descendants(matching: .any)["scope-Notes"].firstMatch
            if notes.waitForExistence(timeout: 5) { notes.tap() }
            let target = row(first, app)
            XCTAssertTrue(target.waitForExistence(timeout: 30)); target.tap()
            let editor = noteText(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 30))
            let text = editor.value as? String ?? ""
            if optionsOn {
                XCTAssertTrue(text.hasPrefix("# " + first), "the first line became the title: \(text)")
            } else {
                XCTAssertTrue(text.hasPrefix(first) && !text.hasPrefix("#"), "unchanged with both options off: \(text)")
            }
        }
    }
}
