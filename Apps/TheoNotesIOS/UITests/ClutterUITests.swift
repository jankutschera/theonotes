// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest

/// IOS-CLUTTER (1.1): each action has one visible place. Every test checks that the removed copy is gone and that
/// the place that remains still works. Runs only against the disposable --ui-testing library.
@MainActor final class ClutterUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func noteText(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Note text")).firstMatch
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        XCTAssertTrue(app.buttons["new-note"].waitForExistence(timeout: 60))
        return app
    }

    private func createNote(_ text: String, _ app: XCUIApplication) {
        app.buttons["new-note"].tap()
        let editor = noteText(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        editor.tap(); editor.typeText(text)
        let first = String(text.split(separator: "\n")[0])
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", first), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 30), .completed)
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
    }

    /// The note list with its rows: on iPhone go back from the editor; on iPad it is already on screen.
    private func showList(_ app: XCUIApplication) {
        let select = app.buttons["select-notes"].firstMatch
        if select.exists && select.isHittable { return }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 30))
    }

    private func showSidebar(_ app: XCUIApplication) {
        let options = app.buttons["Library Options"].firstMatch
        for _ in 0..<5 where !(options.exists && options.isHittable) {
            let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show Sidebar", "Toggle sidebar"])).firstMatch
            if toggle.exists && toggle.isHittable { toggle.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            _ = options.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(options.isHittable, "the sidebar must be on screen")
    }

    /// Tap outside the open menu (the nav bar's middle opens the title menu, so never there) until `gone` is off screen.
    private func closeMenu(_ app: XCUIApplication, until gone: XCUIElement) {
        for (dx, dy) in [(0.03, 0.45), (0.97, 0.45), (0.5, 0.012)] {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
            if gone.waitForNonExistence(timeout: 4) { return }
        }
    }

    /// Visible controls with this label; hidden key commands have no frame and never count.
    private func visible(_ label: String, _ app: XCUIApplication) -> Bool {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.contains { $0.isHittable }
    }

    private func row(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func selectionMenu(for title: String, _ app: XCUIApplication) {
        app.buttons["select-notes"].firstMatch.tap()
        let target = row(title, app)
        XCTAssertTrue(target.waitForExistence(timeout: 30)); target.tap()
        let menu = app.buttons.matching(NSPredicate(format: "label == %@", "1 Selected")).firstMatch
        // On iPad the first tap can go to keyboard focus handover only; tap once more if nothing was selected.
        if !menu.waitForExistence(timeout: 5) { target.tap() }
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()
        XCTAssertTrue(app.buttons["Select All"].firstMatch.waitForExistence(timeout: 30))
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// IOS-CLUTTER-R8: Quick Open and From Template are in Note Actions exactly when the list's bottom bar is not on screen
    /// or is covered by the on-screen keyboard.
    func testQuickOpenAndTemplateFollowTheListColumn() throws {
        let app = launch()
        try XCTSkipIf(app.windows.firstMatch.frame.width < 700, "Only the regular-width layout has a hideable list column.")
        createNote("Column fixture", app)
        let quickOpen = app.buttons["note-quick-open"].firstMatch, template = app.buttons["note-from-template"].firstMatch
        let actions = app.descendants(matching: .any)["Note Actions"].firstMatch
        func openActions(expecting present: Bool, _ message: String) {
            actions.tap()
            XCTAssertTrue(app.buttons["Copy Link to Note"].firstMatch.waitForExistence(timeout: 30), message)
            XCTAssertEqual(quickOpen.exists && template.exists, present, message)
            closeMenu(app, until: app.buttons["Copy Link to Note"].firstMatch)
            XCTAssertTrue(app.buttons["Copy Link to Note"].firstMatch.waitForNonExistence(timeout: 30))
        }
        openActions(expecting: false, "list column visible: the list's bar holds them")
        // The docked on-screen keyboard covers the list's bar: Note Actions holds them, and they work (round 3).
        noteText(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "this step needs the on-screen keyboard")
        openActions(expecting: true, "on-screen keyboard over the list's bar: Note Actions holds them")
        actions.tap(); XCTAssertTrue(quickOpen.waitForExistence(timeout: 30)); quickOpen.tap()
        XCTAssertTrue(app.staticTexts["Quick Open"].firstMatch.waitForExistence(timeout: 30), "Quick Open opens from Note Actions")
        app.buttons["Done"].firstMatch.tap()
        noteText(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        actions.tap(); XCTAssertTrue(template.waitForExistence(timeout: 30)); template.tap()
        XCTAssertTrue(app.staticTexts["New from Template"].firstMatch.waitForExistence(timeout: 30), "From Template opens from Note Actions")
        app.buttons["Cancel"].firstMatch.tap()
        // The keyboard's own hide key: the editor keeps the keyboard focus with no on-screen keyboard, as with a hardware
        // keyboard; the bar is free, so they are there once, in the bar.
        noteText(app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        let hide = app.buttons["Hide keyboard"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "the iPad keyboard's hide key")
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 30))
        openActions(expecting: false, "no on-screen keyboard: only the list's bar holds them")
        XCTAssertTrue(app.buttons["list-quick-open"].firstMatch.isHittable && app.buttons["list-from-template"].firstMatch.isHittable,
                      "the list's bar holds both")
        app.buttons["toolbar-dismiss-keyboard"].firstMatch.tap()
        app.typeKey("1", modifierFlags: .control)
        XCTAssertTrue(app.buttons["select-notes"].firstMatch.waitForNonExistence(timeout: 30), "Editor Only hides the list")
        openActions(expecting: true, "Editor Only: Note Actions holds them (⌃1)")
        app.typeKey("3", modifierFlags: .control)
        XCTAssertTrue(app.buttons["select-notes"].firstMatch.waitForExistence(timeout: 30))
        openActions(expecting: false, "list column back: not in Note Actions")
        // No hand-collapse step: on a full-screen iPad (iOS 27, both orientations) the system offers only Show/Hide
        // Sidebar, which never hides the list column; Editor Only is reachable by ⌃1 alone (evidence 2026-11-16, T2).
    }

    /// Select mode: a tap on the blank trailing part of a row still toggles it.
    func testSelectionRowTogglesFromItsTrailingBlank() {
        let app = launch()
        createNote("Blank tap fixture\nBody", app)
        showList(app)
        app.buttons["select-notes"].firstMatch.tap()
        let target = row("Blank tap fixture", app)
        XCTAssertTrue(target.waitForExistence(timeout: 30))
        let frame = target.frame
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.maxX - 12, dy: frame.midY)).tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "1 Selected")).firstMatch.waitForExistence(timeout: 30),
                      "a tap at the row's trailing edge selects it")
    }

    /// IOS-CLUTTER-R4, R10: search lives in the search field (and ⌘F); List Options and the row menu hold no copy.
    func testSearchLivesInTheSearchField() {
        let app = launch()
        createNote("Searchable fixture\nBody", app)
        showList(app)
        app.buttons["List Options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Sort Notes"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(visible("Search Notes", app))
        XCTAssertFalse(visible("Find", app))
        closeMenu(app, until: app.buttons["Sort Notes"].firstMatch)
        let target = row("Searchable fixture", app)
        XCTAssertTrue(target.waitForExistence(timeout: 30))
        target.press(forDuration: 1.5)
        let copyLink = app.buttons["Copy Link to Note"].firstMatch
        if !copyLink.waitForExistence(timeout: 15) { target.press(forDuration: 2.5) }
        XCTAssertTrue(copyLink.waitForExistence(timeout: 30), "the row's context menu must open")
        XCTAssertFalse(visible("Search Notes", app))
        closeMenu(app, until: app.buttons["Copy Link to Note"].firstMatch)
        XCTAssertTrue(app.buttons["Copy Link to Note"].firstMatch.waitForNonExistence(timeout: 30))
        // ⌘F is registered once and focuses the field while the list has the keyboard.
        app.typeKey("f", modifierFlags: .command)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 30), .completed, "⌘F must focus the search field")
        field.typeText("zzzz-no-match")
        XCTAssertTrue(app.staticTexts["No matching notes"].firstMatch.waitForExistence(timeout: 30))
        shot("Search field", app)
    }

    /// IOS-CLUTTER-R5, R6: the selection menu offers Pin or Unpin, Archive or Restore; section keys use the Mac numbers.
    func testSelectionMenuMatchesSelectionAndScope() {
        let app = launch()
        createNote("Selection fixture\nBody", app)
        showList(app)
        selectionMenu(for: "Selection fixture", app)
        XCTAssertTrue(app.buttons["selection-pin"].exists)
        XCTAssertFalse(app.buttons["selection-unpin"].exists)
        XCTAssertTrue(app.buttons["selection-archive"].exists)
        XCTAssertFalse(app.buttons["selection-restore"].exists)
        shot("Selection menu in Notes", app)
        app.buttons["selection-pin"].tap()
        selectionMenu(for: "Selection fixture", app)
        XCTAssertTrue(app.buttons["selection-unpin"].exists, "a pinned selection offers Unpin")
        XCTAssertFalse(app.buttons["selection-pin"].exists)
        app.buttons["selection-archive"].tap()
        XCTAssertTrue(row("Selection fixture", app).waitForNonExistence(timeout: 30))
        app.typeKey("9", modifierFlags: [.command, .option])
        XCTAssertTrue(app.navigationBars["Archive"].waitForExistence(timeout: 30), "⌥⌘9 opens Archive")
        selectionMenu(for: "Selection fixture", app)
        XCTAssertTrue(app.buttons["selection-restore"].exists)
        XCTAssertEqual(app.buttons["selection-restore"].label, "Unarchive", "IOS-DESIGN-R14: Archive's way back reads Unarchive")
        XCTAssertFalse(app.buttons["selection-archive"].exists, "no Archive inside Archive")
        shot("Selection menu in Archive", app)
        app.buttons["selection-trash"].tap()
        app.typeKey("0", modifierFlags: [.command, .option])
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 30), "⌥⌘0 opens Trash")
        selectionMenu(for: "Selection fixture", app)
        XCTAssertTrue(app.buttons["selection-restore"].exists)
        XCTAssertFalse(app.buttons["selection-archive"].exists)
        XCTAssertFalse(app.buttons["selection-pin"].exists || app.buttons["selection-unpin"].exists, "IOS-DESIGN-R14: no Pin in the Trash")
        XCTAssertTrue(app.buttons["Delete…"].firstMatch.exists, "IOS-DESIGN-R2: one-line Delete…")
        shot("Selection menu in Trash", app)
        app.buttons["selection-restore"].tap()
        app.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 30), "⌥⌘1 opens Notes")
        XCTAssertTrue(row("Selection fixture", app).waitForExistence(timeout: 30))
    }

    /// IOS-CLUTTER-R6, R7, R16: no Navigate submenu, no second "All Notes"; Library Options keeps its entries.
    func testSidebarHoldsEachEntryOnce() {
        let app = launch()
        createNote("Workspace fixture\n#clutterspace ", app)
        showSidebar(app)
        app.buttons["Library Options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Recovered Sketches"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Import Notes"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Navigate"].exists)
        closeMenu(app, until: app.buttons["Import Notes"].firstMatch)
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "clutterspace")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 30), app.debugDescription)
        tag.press(forDuration: 1.2)
        let use = app.buttons["Use as Workspace"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 30)); use.tap()
        showSidebar(app)
        // Small phones keep the sidebar scrolled to the tag; the Workspace section sits at the top.
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertTrue(app.staticTexts["Workspace"].firstMatch.waitForExistence(timeout: 30), "the Workspace section shows")
        XCTAssertFalse(app.buttons["All Notes"].exists, "leaving a workspace is in the Workspaces menu only")
        shot("Sidebar in a workspace", app)
        app.buttons["Workspaces"].firstMatch.tap()
        let all = app.buttons["All Notes"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 30)); all.tap()
        showSidebar(app)
        XCTAssertTrue(app.staticTexts["Workspace"].firstMatch.waitForNonExistence(timeout: 30))
    }

    /// IOS-CLUTTER-R11, R12: one export tag switch in Settings, the wiki link switch in the export menu, the renamed to-do switch.
    func testSettingsHoldTheExportAndToDoSwitchesOnce() {
        let app = launch()
        createNote("Export fixture\nBody", app)
        showList(app)
        app.buttons["List Options"].firstMatch.tap()
        let export = app.buttons["Export Listed Notes"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 30)); export.tap()
        XCTAssertTrue(app.descendants(matching: .any)["Note Links in HTML"].firstMatch.waitForExistence(timeout: 30))
        // Design r3: the same format order as Note Actions ▸ Export.
        let order = ["Markdown", "TextBundle", "HTML", "PDF", "Rich Text (RTF)", "Plain Text"]
        let tops = order.map { app.buttons[$0].firstMatch.frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "export order: \(zip(order, tops).map { "\($0) \($1)" })")
        shot("Export Listed Notes menu", app)
        closeMenu(app, until: app.descendants(matching: .any)["Note Links in HTML"].firstMatch)
        showSidebar(app)
        app.buttons["Library Options"].firstMatch.tap()
        app.buttons["Settings"].firstMatch.tap()
        let general = app.buttons["General"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 30)); general.tap()
        let todos = app.switches["Checked To-Dos at Bottom"].firstMatch
        XCTAssertTrue(todos.waitForExistence(timeout: 30))
        XCTAssertFalse(app.switches["Move Checked To Dos to Bottom"].exists)
        let before = todos.value as? String
        if todos.switches.firstMatch.exists { todos.switches.firstMatch.tap() } else { todos.tap() }
        XCTAssertNotEqual(todos.value as? String, before, "the renamed switch still works")
        let tags = app.switches["Keep Tags in Exports"].firstMatch
        for _ in 0..<5 where !tags.isHittable { app.swipeUp() }
        XCTAssertTrue(tags.exists)
        XCTAssertFalse(app.switches["Keep Tags During Export"].exists)
        XCTAssertFalse(app.switches["Use Relative Wiki Links"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "and to Copy As")).firstMatch.exists, "IOS11-EXPORT-R2: the footer names Copy As")
        shot("Settings General", app)
    }
}
