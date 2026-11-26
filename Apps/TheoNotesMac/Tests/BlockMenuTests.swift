// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// The native menus of the rich blocks; M6 Task 9: the heading menu.
@MainActor
@Suite struct BlockMenuTests {
    let root: URL
    let environment: AppEnvironment
    let page = FakeEditorPage()
    let controller: EditorBridgeController
    let pasteboard: NSPasteboard
    let rect = CaretRect(x: 4, y: 8, width: 24, height: 16)

    static let text = "# Plan\n\nintro\n\n## Tasks\n\nmore\n\n### Deep dive"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesMacTests-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        controller = EditorBridgeController(
            environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
        )
        pasteboard = NSPasteboard(name: NSPasteboard.Name("TheoNotesTest-\(UUID().uuidString)"))
        controller.pasteboard = pasteboard
        controller.blockMenus.features = .all
    }

    /// Opens a note with `text`, ready, and collects the menus the controller pops up.
    private func show(_ text: String = text, trashed: Bool = false, archived: Bool = false) throws -> (id: String, popped: PoppedMenus) {
        let id = try environment.store.create(text: text).id
        if trashed { try environment.store.trash([id]) }
        if archived { try environment.store.archive([id]) }
        try controller.open(noteId: id)
        _ = controller.handle(.ready(version: EditorBridge.version))
        let popped = PoppedMenus()
        controller.blockMenus.popUp = { menu, at in popped.shown.append((menu, at)) }
        return (id, popped)
    }

    final class PoppedMenus {
        var shown: [(menu: NSMenu, rect: CaretRect)] = []
    }

    private func request(_ id: String, line: Int, level: Int, folded: Bool = false, menuId: String = "m1") -> HeadingMenuRequest {
        HeadingMenuRequest(noteId: id, menuId: menuId, line: line, level: level, folded: folded, rect: rect)
    }

    private func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
        try #require(menu.items.first { $0.title == title }, "no item \(title)")
    }

    /// The nth menu popped up so far (the last for a negative index).
    private func poppedMenu(_ popped: PoppedMenus, _ index: Int = 0) throws -> NSMenu {
        let all = popped.shown
        let shown = index < 0 ? all.last : (all.indices.contains(index) ? all[index] : nil)
        return try #require(shown).menu
    }

    private func levelsMenu(_ menu: NSMenu) throws -> NSMenu {
        let submenu = try item(menu, "Heading").submenu
        return try #require(submenu)
    }

    private func choose(_ item: NSMenuItem) throws {
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    @Test func calloutMenuChecksTypeAndTargetsTheMappedCallout() throws {
        let (id, popped) = try show("> [!TIP]\n> Body")
        _ = controller.handle(.calloutMenu(CalloutMenuRequest(noteId: id, menuId: "callout-1", calloutType: .tip, rect: rect)))
        let menu = try poppedMenu(popped)
        #expect(titles(menu) == ["Note", "Tip", "Important", "Warning", "Caution"])
        #expect(try item(menu, "Tip").state == .on)
        try choose(item(menu, "Warning"))
        #expect(page.delivered.last == .applyCommand(name: .setCalloutType, args: ["type": .string("warning"), "menuId": .string("callout-1")]))
    }

    // MARK: -

    @Test func headingMenuHasFoldCopyLinkAndLevels() throws {
        let (id, popped) = try show()
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        let shown = try #require(popped.shown.first)
        #expect(shown.rect == rect)
        let menu = shown.menu
        #expect(titles(menu) == ["Fold", "Fold All Headings", "Unfold All Headings", "Copy Link to Here", "Heading"])
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })

        let levels = try levelsMenu(menu)
        #expect(levels.items.map(\.title) == ["Heading 1", "Heading 2", "Heading 3", "Heading 4", "Heading 5", "Heading 6"])
        #expect(levels.items.map(\.state) == [.off, .on, .off, .off, .off, .off])

        // The fold items run the folding commands; a folded heading offers Unfold.
        try choose(item(menu, "Fold"))
        try choose(item(menu, "Fold All Headings"))
        try choose(item(menu, "Unfold All Headings"))
        #expect(page.delivered.suffix(3) == [
            .applyCommand(name: .toggleFold, args: ["menuId": .string("m1")]),
            .applyCommand(name: .foldAll),
            .applyCommand(name: .unfoldAll),
        ])
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2, folded: true)))
        #expect(try titles(poppedMenu(popped, -1)).first == "Unfold")
    }

    /// M6 Task 7: the shipped editor folds, so the heading menu enables the fold items by default.
    @Test func foldItemsAreEnabledByDefault() throws {
        #expect(BlockMenus().features.contains(.folding))
        controller.blockMenus.features = .implemented
        let (id, popped) = try show()
        _ = controller.handle(.headingMenu(request(id, line: 1, level: 1)))
        let menu = try poppedMenu(popped)
        for title in ["Fold", "Fold All Headings", "Unfold All Headings"] {
            #expect(try item(menu, title).isEnabled, "\(title)")
        }
    }

    /// Fix round 1 (M11): a heading with an empty section has nothing to fold, so Fold is disabled;
    /// a folded heading still offers Unfold, and Fold All / Unfold All stay enabled.
    @Test func foldIsDisabledForAHeadingWithAnEmptySection() throws {
        let (id, popped) = try show("# Plan\n\nintro\n\n## Empty\n\n  \n## Tasks\nmore\n### Deep dive\n")
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        #expect(try !item(poppedMenu(popped, -1), "Fold").isEnabled)
        #expect(try item(poppedMenu(popped, -1), "Fold All Headings").isEnabled)
        _ = controller.handle(.headingMenu(request(id, line: 10, level: 3)))
        #expect(try !item(poppedMenu(popped, -1), "Fold").isEnabled)
        _ = controller.handle(.headingMenu(request(id, line: 8, level: 2)))
        #expect(try item(poppedMenu(popped, -1), "Fold").isEnabled)
        _ = controller.handle(.headingMenu(request(id, line: 1, level: 1)))
        #expect(try item(poppedMenu(popped, -1), "Fold").isEnabled)
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2, folded: true)))
        #expect(try item(poppedMenu(popped, -1), "Unfold").isEnabled)
    }

    @Test func foldItemsStayDisabledUntilTheEditorImplementsFolding() throws {
        controller.blockMenus.features = []
        let (id, popped) = try show()
        _ = controller.handle(.headingMenu(request(id, line: 1, level: 1)))
        let menu = try poppedMenu(popped)
        for title in ["Fold", "Fold All Headings", "Unfold All Headings"] {
            #expect(try !item(menu, title).isEnabled, "\(title)")
        }
        #expect(try item(menu, "Copy Link to Here").isEnabled)
        #expect(try item(menu, "Heading").submenu?.items.allSatisfy { $0.isEnabled } == true)

        // Once the feature is on, the same menu runs the commands.
        controller.blockMenus.features = .implemented.union(.folding)
        _ = controller.handle(.headingMenu(request(id, line: 1, level: 1)))
        #expect(try item(poppedMenu(popped, -1), "Fold").isEnabled)
    }

    @Test func copyLinkToHereWritesTheWikiLink() throws {
        let (id, popped) = try show()
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        try choose(item(poppedMenu(popped), "Copy Link to Here"))
        #expect(pasteboard.string(forType: .string) == "[[Plan/Tasks]]")
        #expect(pasteboard.data(forType: .html) == nil && pasteboard.data(forType: .rtf) == nil)

        // The title's slash is escaped; a heading keeps its own.
        let (slashed, slashedPopped) = try show("# A/B\n\n## C/D")
        _ = controller.handle(.headingMenu(request(slashed, line: 3, level: 2)))
        try choose(item(poppedMenu(slashedPopped), "Copy Link to Here"))
        #expect(pasteboard.string(forType: .string) == #"[[A\/B/C/D]]"#)

        // A heading a link cannot spell offers no link, and the pasteboard is left alone.
        let (odd, oddPopped) = try show("# Odd\n\n## a | b")
        _ = controller.handle(.headingMenu(request(odd, line: 3, level: 2)))
        let copy = try item(poppedMenu(oddPopped), "Copy Link to Here")
        #expect(!copy.isEnabled)
        #expect(copy.toolTip == "This heading can't be linked: the note title or heading contains [ ] or |, or the title repeats a space")
        #expect(pasteboard.string(forType: .string) == #"[[A\/B/C/D]]"#)
    }

    // MARK: - Format ▸ Copy Link to Here (keyboard path, M7 final review I4)

    private func placeCaret(_ id: String, in text: String, at needle: String, offset: Int = 0) {
        let caret = (text as NSString).range(of: needle).location + offset
        _ = controller.handle(.selectionChanged(noteId: id, anchor: caret, head: caret))
    }

    @Test func theFormatMenuCopiesTheLinkOfTheHeadingAtTheCaret() throws {
        let (id, _) = try show()
        pasteboard.clearContents()
        placeCaret(id, in: Self.text, at: "## Tasks", offset: 4)
        #expect(controller.copyHeadingLinkAtCaret())
        #expect(pasteboard.string(forType: .string) == "[[Plan/Tasks]]")
        #expect(pasteboard.data(forType: .html) == nil && pasteboard.data(forType: .rtf) == nil)

        // The first line and the last line of the note are headings too.
        placeCaret(id, in: Self.text, at: "# Plan")
        #expect(controller.copyHeadingLinkAtCaret())
        #expect(pasteboard.string(forType: .string) == "[[Plan/Plan]]")
        placeCaret(id, in: Self.text, at: "### Deep dive", offset: 13)
        #expect(controller.copyHeadingLinkAtCaret())
        #expect(pasteboard.string(forType: .string) == "[[Plan/Deep dive]]")
    }

    @Test func theFormatMenuCopiesNothingOffAHeadingOrWhenNoLinkCanReachIt() throws {
        let (id, _) = try show()
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        placeCaret(id, in: Self.text, at: "intro", offset: 2)
        #expect(!controller.copyHeadingLinkAtCaret(), "the caret is in body text")
        #expect(pasteboard.string(forType: .string) == "old")

        // A heading a link cannot spell, a repeated heading, and a note in the Trash: the same rules as the badge menu.
        let odd = "# Odd\n\n## a | b\n\n## Again\n\n## Again"
        let (oddId, _) = try show(odd)
        placeCaret(oddId, in: odd, at: "## a | b", offset: 3)
        #expect(!controller.copyHeadingLinkAtCaret())
        placeCaret(oddId, in: odd, at: "## Again\n\n## Again", offset: 14)
        #expect(!controller.copyHeadingLinkAtCaret(), "an earlier heading has the same text")
        let (trashedId, _) = try show(trashed: true)
        placeCaret(trashedId, in: Self.text, at: "## Tasks")
        #expect(!controller.copyHeadingLinkAtCaret())
        #expect(pasteboard.string(forType: .string) == "old")
    }

    @Test func caretLineCountsLinesFromOneInUTF16Offsets() {
        let text = "a\n😀b\n\nc"
        #expect(BlockMenus.line(ofUTF16Offset: 0, in: text) == 1)
        #expect(BlockMenus.line(ofUTF16Offset: 2, in: text) == 2)
        #expect(BlockMenus.line(ofUTF16Offset: 5, in: text) == 2, "after the emoji's two UTF-16 units and b")
        #expect(BlockMenus.line(ofUTF16Offset: 7, in: text) == 4)
        #expect(BlockMenus.line(ofUTF16Offset: 999, in: text) == 4, "past the end clamps")
        #expect(BlockMenus.line(ofUTF16Offset: -3, in: text) == 1)
    }

    @Test func levelItemsSendHeadingWithTheMenuId() throws {
        let (id, popped) = try show()
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2, menuId: "menu-x-7")))
        let levels = try levelsMenu(poppedMenu(popped))
        try choose(levels.items[3])
        #expect(page.delivered.last == .applyCommand(name: .heading, args: ["level": .int(4), "menuId": .string("menu-x-7")]))
        try choose(levels.items[0])
        #expect(page.delivered.last == .applyCommand(name: .heading, args: ["level": .int(1), "menuId": .string("menu-x-7")]))
    }

    @Test func aStaleOrMismatchedLineShowsNoMenu() throws {
        let (id, popped) = try show()
        let other = try environment.store.create(text: "# Other").id
        for stale in [
            request(other, line: 1, level: 1), // not the shown note
            request("missing", line: 1, level: 1),
            request(id, line: 99, level: 2), // past the text
            request(id, line: 0, level: 1),
            request(id, line: 3, level: 1), // "intro" is no heading
            request(id, line: 5, level: 3), // a level 2 heading
            request(id, line: 1, level: 2),
        ] {
            _ = controller.handle(.headingMenu(stale))
        }
        #expect(popped.shown.isEmpty)

        // The text the menu is checked against is the live session text, not the page's view.
        _ = controller.handle(.headingMenu(request(id, line: 9, level: 3)))
        #expect(popped.shown.count == 1)
        let session = try environment.session(for: id)
        _ = session.apply(
            txId: "t1", baseRevision: session.revision,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "x\n"), .retain(Self.text.utf16.count)]),
            origin: nil
        )
        _ = controller.handle(.headingMenu(request(id, line: 9, level: 3)))
        #expect(popped.shown.count == 1)
        _ = controller.handle(.headingMenu(request(id, line: 10, level: 3)))
        #expect(popped.shown.count == 2)
    }

    @Test func aRepeatedHeadingCannotBeLinkedAndSaysWhy() throws {
        // R16 resolves `[[Plan/Notes]]` to the first heading with that key, so a link from the
        // second would open the first.
        let (id, popped) = try show("# Plan\n\n## Notes\n\n##  notes \n\n## Other")
        _ = controller.handle(.headingMenu(request(id, line: 3, level: 2)))
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        _ = controller.handle(.headingMenu(request(id, line: 7, level: 2)))
        let first = try item(poppedMenu(popped, 0), "Copy Link to Here")
        let second = try item(poppedMenu(popped, 1), "Copy Link to Here")
        let other = try item(poppedMenu(popped, 2), "Copy Link to Here")
        #expect(first.isEnabled && first.toolTip == nil)
        #expect(!second.isEnabled)
        #expect(second.toolTip == "This heading can't be linked: its text appears earlier in the note")
        #expect(other.isEnabled)
        pasteboard.clearContents()
        try choose(second)
        #expect(pasteboard.string(forType: .string) == nil)
        try choose(first)
        #expect(pasteboard.string(forType: .string) == "[[Plan/Notes]]")
    }

    @Test func aTrashedNoteCannotBeLinkedAndSaysWhy() throws {
        // R16 does not resolve links to notes in the Trash.
        let (id, popped) = try show(trashed: true)
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        let menu = try poppedMenu(popped)
        let copy = try item(menu, "Copy Link to Here")
        #expect(!copy.isEnabled)
        #expect(copy.toolTip == "This heading can't be linked: the note is in the Trash")
        // Folding is not an edit.
        #expect(try item(menu, "Fold").isEnabled)
        #expect(try !item(menu, "Heading").isEnabled)
    }

    @Test func aNoteWithoutATitleCannotBeLinkedAndSaysWhy() throws {
        // `[[/Heading]]` would point into whichever note it is pasted in.
        let (id, popped) = try show("\n## Section")
        _ = controller.handle(.headingMenu(request(id, line: 2, level: 2)))
        let copy = try item(poppedMenu(popped), "Copy Link to Here")
        #expect(!copy.isEnabled)
        #expect(copy.toolTip?.hasSuffix("the note has no title") == true)
    }

    @Test func readOnlyNoteKeepsFoldAndCopyEnabled() throws {
        let (id, popped) = try show(archived: true)
        #expect(!controller.status.isEditable)
        _ = controller.handle(.headingMenu(request(id, line: 5, level: 2)))
        let menu = try poppedMenu(popped)
        for title in ["Fold", "Fold All Headings", "Unfold All Headings", "Copy Link to Here"] {
            #expect(try item(menu, title).isEnabled, "\(title)")
        }
        let levels = try levelsMenu(menu)
        #expect(levels.items.allSatisfy { !$0.isEnabled })
        #expect(levels.items[1].state == .on)
        #expect(try !item(menu, "Heading").isEnabled)

        // Folding runs in a read-only note, the editor's own refusal aside.
        try choose(item(menu, "Fold"))
        #expect(page.delivered.last == .applyCommand(name: .toggleFold, args: ["menuId": .string("m1")]))
        try choose(item(menu, "Copy Link to Here"))
        #expect(pasteboard.string(forType: .string) == "[[Plan/Tasks]]")
        // A level change would be refused by the host as well.
        let before = page.delivered.count
        try choose(levels.items[3])
        #expect(page.delivered.count == before)
    }

    // MARK: - Callout menu (M6 Task 10)

    @Test func calloutMenuChecksTheCurrentTypeAndSendsSetCalloutType() throws {
        let (id, popped) = try show("> [!WARNING] Careful\n> body")
        _ = controller.handle(.calloutMenu(CalloutMenuRequest(noteId: id, menuId: "menu-c-1", calloutType: .warning, rect: rect)))
        let shown = try #require(popped.shown.first)
        #expect(shown.rect == rect)
        let menu = shown.menu
        #expect(titles(menu) == ["Note", "Tip", "Important", "Warning", "Caution"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Warning"])
        #expect(menu.items.allSatisfy { $0.isEnabled })
        try choose(item(menu, "Tip"))
        #expect(page.delivered.last == .applyCommand(name: .setCalloutType, args: ["type": .string("tip"), "menuId": .string("menu-c-1")]))

        // Another note's request is ignored.
        _ = controller.handle(.calloutMenu(CalloutMenuRequest(noteId: "other", menuId: "m2", calloutType: .note, rect: rect)))
        #expect(popped.shown.count == 1)
    }

    @Test func calloutMenuIsDisabledInReadOnlyNotes() throws {
        let (id, popped) = try show("> [!NOTE]\n> body", archived: true)
        _ = controller.handle(.calloutMenu(CalloutMenuRequest(noteId: id, menuId: "m1", calloutType: .note, rect: rect)))
        let menu = try poppedMenu(popped)
        #expect(menu.items.allSatisfy { !$0.isEnabled })
        let before = page.delivered.count
        try choose(item(menu, "Caution"))
        #expect(page.delivered.count == before)
    }

    // MARK: - Table menu (M6 Task 6)

    static let tableText = "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"

    private func tableRequest(
        _ id: String, row: Int = 2, column: Int = 1, rows: Int = 3, columns: Int = 3, menuId: String = "menu-t-1"
    ) -> TableMenuRequest {
        TableMenuRequest(noteId: id, menuId: menuId, row: row, column: column, rows: rows, columns: columns, rect: rect)
    }

    private func copyMenu(_ menu: NSMenu) throws -> NSMenu {
        try #require(item(menu, "Copy Table As").submenu)
    }

    @Test func tableMenuItemsSendTheirCommandWithTheMenuId() throws {
        let (id, popped) = try show(Self.tableText)
        // A middle cell: every move is possible.
        _ = controller.handle(.tableMenu(tableRequest(id, rows: 4)))
        let shown = try #require(popped.shown.first)
        #expect(shown.rect == rect)
        let menu = shown.menu
        #expect(titles(menu) == [
            "Add Row", "Add Column", "Delete Row", "Delete Column",
            "Move Row Up", "Move Row Down", "Move Column Left", "Move Column Right", "Copy Table As",
        ])
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })
        let copy = try copyMenu(menu)
        #expect(copy.items.map(\.title) == ["CSV", "HTML", "Markdown"])
        #expect(copy.items.allSatisfy { $0.isEnabled })

        let menuId = CommandArgument.string("menu-t-1")
        let expected: [(String, EditorCommandName, [String: CommandArgument])] = [
            ("Add Row", .tableAddRow, ["menuId": menuId]),
            ("Add Column", .tableAddColumn, ["menuId": menuId]),
            ("Delete Row", .tableDeleteRow, ["menuId": menuId]),
            ("Delete Column", .tableDeleteColumn, ["menuId": menuId]),
            ("Move Row Up", .tableMoveRow, ["direction": .string("up"), "menuId": menuId]),
            ("Move Row Down", .tableMoveRow, ["direction": .string("down"), "menuId": menuId]),
            ("Move Column Left", .tableMoveColumn, ["direction": .string("left"), "menuId": menuId]),
            ("Move Column Right", .tableMoveColumn, ["direction": .string("right"), "menuId": menuId]),
        ]
        for (title, command, args) in expected {
            try choose(item(menu, title))
            #expect(page.delivered.last == .applyCommand(name: command, args: args), "\(title)")
        }
        for (title, format) in [("CSV", "csv"), ("HTML", "html"), ("Markdown", "markdown")] {
            try choose(item(copy, title))
            #expect(
                page.delivered.last == .applyCommand(name: .copyTable, args: ["format": .string(format), "menuId": menuId]), "\(title)")
        }
    }

    /// The header never moves and nothing moves into it; a column at either edge cannot
    /// move outwards. Those items are disabled instead of doing nothing.
    @Test func moveItemsAreDisabledAtTheEdges() throws {
        let (id, popped) = try show(Self.tableText)
        let moves = ["Move Row Up", "Move Row Down", "Move Column Left", "Move Column Right"]
        func enabled(_ request: TableMenuRequest) throws -> [Bool] {
            _ = controller.handle(.tableMenu(request))
            let menu = try poppedMenu(popped, -1)
            return try moves.map { try item(menu, $0).isEnabled }
        }
        #expect(try enabled(tableRequest(id, row: 0, column: 0)) == [false, false, false, true])
        #expect(try enabled(tableRequest(id, row: 1, column: 1)) == [false, true, true, true])
        #expect(try enabled(tableRequest(id, row: 2, column: 2)) == [true, false, true, false])
        // A one-cell table has nowhere to move; the other items stay on.
        #expect(try enabled(tableRequest(id, row: 0, column: 0, rows: 1, columns: 1)) == [false, false, false, false])
        #expect(try item(poppedMenu(popped, -1), "Add Row").isEnabled)
    }

    @Test func editingItemsAreDisabledInReadOnlyNotes() throws {
        let (id, popped) = try show(Self.tableText, archived: true)
        #expect(!controller.status.isEditable)
        _ = controller.handle(.tableMenu(tableRequest(id)))
        let menu = try poppedMenu(popped)
        for title in [
            "Add Row", "Add Column", "Delete Row", "Delete Column", "Move Row Up", "Move Row Down", "Move Column Left",
            "Move Column Right",
        ] {
            #expect(try !item(menu, title).isEnabled, "\(title)")
        }
        // Copying is not an edit: the submenu and its items work, and the command is delivered.
        #expect(try item(menu, "Copy Table As").isEnabled)
        let copy = try copyMenu(menu)
        #expect(copy.items.allSatisfy { $0.isEnabled })
        try choose(item(copy, "CSV"))
        #expect(page.delivered.last == .applyCommand(name: .copyTable, args: ["format": .string("csv"), "menuId": .string("menu-t-1")]))
        // A disabled editing item runs nothing.
        let before = page.delivered.count
        try choose(item(menu, "Add Row"))
        #expect(page.delivered.count == before)
    }

    @Test func tableMenuItemsStayDisabledUntilTheEditorImplementsTables() throws {
        controller.blockMenus.features = [.folding]
        let (id, popped) = try show(Self.tableText)
        _ = controller.handle(.tableMenu(tableRequest(id)))
        let menu = try poppedMenu(popped)
        #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        #expect(try copyMenu(menu).items.allSatisfy { !$0.isEnabled })
    }

    @Test func aTableMenuOfAnotherNoteIsIgnored() throws {
        let (_, popped) = try show(Self.tableText)
        let other = try environment.store.create(text: Self.tableText).id
        _ = controller.handle(.tableMenu(tableRequest(other)))
        _ = controller.handle(.tableMenu(tableRequest("missing")))
        #expect(popped.shown.isEmpty)
    }

    @Test func copyTextWithHTMLWritesBothPasteboardTypes() throws {
        _ = try show()
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        let html = "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>"
        #expect(controller.handle(.copyText(text: html, html: html)) == nil)
        // A plain paste gets the HTML source, a rich paste the table.
        #expect(pasteboard.string(forType: .string) == html)
        #expect(pasteboard.string(forType: .html) == html)
        #expect(Set(pasteboard.types ?? []).isSuperset(of: [.string, .html]))

        // A plain copy afterwards leaves no stale HTML behind.
        #expect(controller.handle(.copyText(text: "A,B", html: nil)) == nil)
        #expect(pasteboard.string(forType: .string) == "A,B")
        #expect(pasteboard.data(forType: .html) == nil)

        // The raw postMessage body (what the page sends).
        let (reply, error) = controller.handle(body: ["type": "copyText", "text": "<b>x</b>", "html": "<b>x</b>"])
        #expect(reply == nil && error == nil)
        #expect(pasteboard.string(forType: .html) == "<b>x</b>")
    }
}
