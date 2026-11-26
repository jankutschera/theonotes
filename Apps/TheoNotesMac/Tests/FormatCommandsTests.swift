// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// The Format menu: Bear's shortcuts (the shared table in Fixtures/bridge), the commands the
/// editor implements, checkmarks/enabling from `formatState`, and routing to the editor.
@MainActor
@Suite struct FormatCommandsTests {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/bridge")

    private struct Shortcut: Decodable, Hashable {
        let shortcut: String
        let command: String
        let args: [String: CommandArgument]?
    }

    private static func shortcutTable() throws -> [Shortcut] {
        try JSONDecoder().decode([Shortcut].self, from: Data(contentsOf: fixtureDir.appendingPathComponent("format-shortcuts.json")))
    }

    // MARK: - The table

    @Test func menuShortcutsAreTheSharedBearTable() throws {
        let menu = (FormatMenu.items + FindMenu.items).compactMap { item in
            item.shortcutDisplay.map { Shortcut(shortcut: $0, command: item.command.rawValue, args: item.args) }
        }
        #expect(Set(menu) == Set(try Self.shortcutTable()))
        #expect(menu.count == Set(menu.map(\.shortcut)).count, "duplicate shortcuts")
        // ⇧⌘0 is Dismiss Workspace; insert hours moved to ⌃⇧⌘0 (spec §4.2).
        #expect(!menu.contains { $0.shortcut == "⇧⌘0" })
        #expect(menu.contains(Shortcut(shortcut: "⌃⇧⌘0", command: "insertDate", args: ["style": .string("hours")])))
    }

    @Test func everyMenuItemRunsACommandOfTheProtocolFixtures() throws {
        let names = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: Self.fixtureDir.appendingPathComponent("command-names.json"))
        )
        for item in FormatMenu.items {
            #expect(names.contains(item.command.rawValue), "\(item.title): \(item.command)")
        }
        #expect(Set(FormatMenu.items.map(\.title)).count == FormatMenu.items.count)
    }

    // MARK: - The menu bar

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private func modifierFlags(_ item: NSMenuItem) -> NSEvent.ModifierFlags {
        item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
    }

    /// AppKit writes ⇧ + letter as the uppercase key equivalent without the shift flag.
    private func normalized(_ key: String, _ flags: NSEvent.ModifierFlags) -> (String, NSEvent.ModifierFlags) {
        guard key.count == 1, key != key.lowercased() else { return (key, flags) }
        return (key.lowercased(), flags.union(.shift))
    }

    @Test func formatMenuIsInTheMenuBarWithTheShortcutsAndNoConflicts() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let format = try #require(mainMenu.items.first { $0.title == "Format" }?.submenu)
        let formatItems = allItems(format)
        for item in FormatMenu.items {
            let menuItem = try #require(formatItems.first { $0.title == item.menuTitle }, "\(item.menuTitle) missing")
            guard let shortcut = item.shortcut else {
                #expect(menuItem.keyEquivalent.isEmpty, "\(item.title)")
                continue
            }
            let (key, flags) = normalized(menuItem.keyEquivalent, modifierFlags(menuItem))
            // SwiftUI translates the apostrophe through the current keyboard layout (⌘' becomes
            // "´" on a German layout), so Toggle Fold only has to have some key equivalent.
            let character = String(shortcut.key.character).lowercased()
            if character == "'" {
                #expect(!menuItem.keyEquivalent.isEmpty, "\(item.title) has no key equivalent")
            } else {
                #expect(key == character, "\(item.title): \(menuItem.keyEquivalent.debugDescription)")
            }
            #expect(flags == item.modifierFlags, "\(item.title): \(flags)")
        }
        #expect(format.items.contains { $0.title == "Heading" && $0.submenu != nil })
        #expect(format.items.contains { $0.title == "Insert Date" && $0.submenu != nil })

        // No other menu item takes one of Bear's Format shortcuts.
        let formatKeys = Set(FormatMenu.items.compactMap(\.shortcutDisplay))
        for menuItem in mainMenu.items.filter({ $0.title != "Format" }).flatMap({ $0.submenu.map(allItems) ?? [] })
        where !menuItem.keyEquivalent.isEmpty {
            let (key, flags) = normalized(menuItem.keyEquivalent, modifierFlags(menuItem))
            let display = FormatMenuItem("", .bold, KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: eventModifiers(flags))).shortcutDisplay
            #expect(!formatKeys.contains(display ?? ""), "\(menuItem.title) also uses \(display ?? "")")
        }
    }

    private func eventModifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    // MARK: - Enabling and checkmarks

    private func item(_ title: String) throws -> FormatMenuItem {
        try #require(FormatMenu.items.first { $0.title == title })
    }

    @Test func checkmarksFollowTheFormatState() throws {
        let format = FormatState(active: [.bold, .heading, .highlight, .todo], headingLevel: 2, inTodo: true, inCode: false, canIndent: false)
        #expect(try item("Bold").isChecked(in: format) == true)
        #expect(try item("Italic").isChecked(in: format) == false)
        #expect(try item("Heading 2").isChecked(in: format) == true)
        #expect(try item("Heading 1").isChecked(in: format) == false)
        #expect(try item("Highlight").isChecked(in: format) == true)
        #expect(try item("Todo").isChecked(in: format) == true)
        // Commands without a state have no checkmark.
        #expect(try item("Red").isChecked(in: format) == nil)
        #expect(try item("Toggle Todo").isChecked(in: format) == nil)
        #expect(try item("Long Date").isChecked(in: format) == nil)
        #expect(try item("Move Line Up").isChecked(in: format) == nil)
    }

    @Test func itemsAreDisabledWithoutAnEditableFocusedEditorAndForStylesInCode() throws {
        for item in FormatMenu.items {
            #expect(!item.isEnabled(in: .unavailable), "\(item.title)")
            #expect(item.isEnabled(in: EditorMenuState(enabled: true, format: .plain, features: .all)), "\(item.title)")
        }
        let span = EditorMenuState(enabled: true, format: FormatState(active: [.inlineCode], headingLevel: nil, inTodo: false, inCode: true, canIndent: false))
        #expect(try !item("Bold").isEnabled(in: span))
        #expect(try !item("Link").isEnabled(in: span))
        #expect(try !item("Wiki Link").isEnabled(in: span))
        #expect(try !item("Footnote").isEnabled(in: span))
        #expect(try item("Open Link").isEnabled(in: span))
        #expect(try item("Inline Code").isEnabled(in: span))
        #expect(try !item("Create Table").isEnabled(in: EditorMenuState(enabled: true, format: span.format, features: .all))) // toggles the span off
        #expect(try item("Heading 1").isEnabled(in: span))
        let block = EditorMenuState(enabled: true, format: FormatState(active: [.codeBlock], headingLevel: nil, inTodo: false, inCode: true, canIndent: false))
        #expect(try !item("Inline Code").isEnabled(in: block))
        #expect(try !item("Heading 1").isEnabled(in: block))
        #expect(try !item("List").isEnabled(in: block))
        #expect(try item("Code Block").isEnabled(in: block)) // removes the fences
        #expect(try item("Move Line Up").isEnabled(in: block))
    }

    // MARK: - Key events

    private func key(_ characters: String, _ ignoring: String? = nil, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func keyEventsFindTheirMenuItem() throws {
        #expect(FormatMenu.item(for: key("b", nil, 11, .command))?.title == "Bold")
        #expect(FormatMenu.item(for: key("U", nil, 32, [.command, .shift]))?.title == "Strikethrough")
        #expect(FormatMenu.item(for: key("ç", "c", 8, [.command, .option]))?.title == "Inline Code")
        #expect(FormatMenu.item(for: key("\u{3}", "c", 8, [.command, .control]))?.title == "Code Block")
        #expect(FormatMenu.item(for: key(".", nil, 47, .command))?.title == "Toggle Todo")
        // ⇧7 types "&" (US) or "/" (German): the unmodified key decides.
        #expect(FormatMenu.item(for: key("&", nil, 26, [.command, .shift]))?.title == "Long Date with Time")
        #expect(FormatMenu.item(for: key("0", ")", 29, [.command, .shift, .control]))?.title == "Time")
        #expect(FormatMenu.item(for: key("2", nil, 19, .command))?.args == ["level": .int(2)])
        #expect(FormatMenu.item(for: key("d", nil, 2, .command))?.title == "Wiki Link")
        #expect(FormatMenu.item(for: key("E", nil, 14, [.command, .shift]))?.title == "Footnote")
        #expect(FormatMenu.item(for: key("K", nil, 40, [.command, .shift]))?.title == "Open Link")
        #expect(FormatMenu.item(for: key("˚", "k", 40, [.command, .shift, .option]))?.args == ["window": .string("new")])
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        #expect(FormatMenu.item(for: key(up, nil, 126, [.command, .option, .numericPad, .function]))?.title == "Move Line Up")

        #expect(FormatMenu.item(for: key("z", nil, 6, .command)) == nil)
        #expect(FormatMenu.item(for: key("a", nil, 0, .command)) == nil) // ⌘A stays with the editor
        #expect(FormatMenu.item(for: key(")", nil, 29, [.command, .shift])) == nil) // ⇧⌘0: Dismiss Workspace
        #expect(FormatMenu.item(for: key("b", nil, 11, [])) == nil)
        #expect(FormatMenu.item(for: key("b", nil, 11, .control)) == nil)
    }

    // MARK: - Routing

    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesFormatTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState
        let noteId: String

        init(readOnly: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesFormat-\(UUID().uuidString)")
            environment = try AppEnvironment(paths: AppPaths(root: root))
            noteId = try environment.store.create(text: "hello").id
            // Trashed notes open read-only (spec §4.9).
            if readOnly { try environment.store.trash([noteId]) }
            editor = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
            state = MainWindowState(environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor)
            try editor.open(noteId: noteId)
            _ = editor.handle(.ready(version: EditorBridge.version))
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var commands: [HostToEditorMessage] {
            page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
        }
    }

    private func event(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        key(characters, nil, keyCode, flags)
    }

    @Test func formatShortcutsInTheEditorRunTheMenuCommand() throws {
        let env = try Env()
        #expect(env.state.handleFormatShortcut(event("b", 11, .command)))
        #expect(env.state.handleFormatShortcut(event("&", 26, [.command, .shift])))
        #expect(!env.state.handleFormatShortcut(event("z", 6, .command)))
        #expect(env.commands == [
            .applyCommand(name: .bold),
            .applyCommand(name: .insertDate, args: ["style": .string("longTime")]),
        ])
    }

    @Test func aDisabledCommandSwallowsItsShortcutWithoutRunning() throws {
        let env = try Env()
        _ = env.editor.handle(.formatState(
            noteId: env.noteId,
            state: FormatState(active: [.codeBlock], headingLevel: nil, inTodo: false, inCode: true, canIndent: false)
        ))
        #expect(env.state.handleFormatShortcut(event("b", 11, .command)))
        #expect(env.commands.isEmpty)
        #expect(env.state.handleFormatShortcut(event("c", 8, [.command, .control]))) // Code Block works in code
        #expect(env.commands == [.applyCommand(name: .codeBlock)])
    }

    @Test func readOnlyNotesGetNoCommands() throws {
        let env = try Env(readOnly: true)
        #expect(env.state.handleFormatShortcut(event("b", 11, .command)))
        env.state.perform(try item("Bold"))
        #expect(env.commands.isEmpty)
        #expect(!env.editor.status.isEditable)
    }

    /// R36: opening a link is not an edit, so Open Link (⇧⌘K / ⌥⇧⌘K) runs in read-only notes too.
    @Test func openLinkRunsInReadOnlyNotes() throws {
        let env = try Env(readOnly: true)
        let focused = env.state.menuState(editorFocused: true)
        #expect(try item("Open Link").isEnabled(in: focused))
        #expect(try item("Open Link in New Window").isEnabled(in: focused))
        #expect(try !item("Bold").isEnabled(in: focused))
        #expect(try !item("Open Link").isEnabled(in: env.state.menuState(editorFocused: false)))
        #expect(env.state.handleFormatShortcut(key("K", nil, 40, [.command, .shift])))
        env.state.perform(try item("Open Link in New Window"))
        #expect(env.commands == [.applyCommand(name: .openLink), .applyCommand(name: .openLink, args: ["window": .string("new")])])
    }

    /// Bridge v3: the table and fold commands are in the Format menu with Bear's shortcuts; the
    /// fold and copy commands run in read-only notes (folding is not an edit), the table edits do not.
    @Test func tableAndFoldCommandsAreInTheMenuAndFoldsRunInReadOnlyNotes() throws {
        let shortcuts = Dictionary(uniqueKeysWithValues: FormatMenu.items.compactMap { item in
            item.shortcutDisplay.map { ($0, item.command) }
        })
        #expect(shortcuts["⌥⌘T"] == .createTable)
        #expect(shortcuts["⌃⌘↓"] == .tableAddRow)
        #expect(shortcuts["⌃⌘→"] == .tableAddColumn)
        #expect(shortcuts["⌃⌘⌫"] == .tableDeleteRow)
        #expect(shortcuts["⌃⇧⌘⌫"] == .tableDeleteColumn)
        #expect(shortcuts["⌘'"] == .toggleFold)

        let readOnly = try Env(readOnly: true)
        var focused = readOnly.state.menuState(editorFocused: true)
        focused.features = .all
        #expect(try item("Toggle Fold").isEnabled(in: focused))
        var unfocused = readOnly.state.menuState(editorFocused: false)
        unfocused.features = .all
        #expect(try !item("Toggle Fold").isEnabled(in: unfocused))
        for title in ["Create Table", "Add Row", "Add Column", "Delete Row", "Delete Column"] {
            #expect(try !item(title).isEnabled(in: focused), "\(title) edits")
            #expect(try item(title).isEnabled(in: EditorMenuState(enabled: true, format: .plain, features: .all)), "\(title)")
        }
        #expect(readOnly.state.handleFormatShortcut(key("'", nil, 39, .command), features: .all))
        #expect(readOnly.state.handleFormatShortcut(key("t", nil, 17, [.command, .option]), features: .all)) // swallowed, disabled
        #expect(readOnly.commands == [.applyCommand(name: .toggleFold)])

        let editable = try Env()
        #expect(editable.state.handleFormatShortcut(key("t", nil, 17, [.command, .option]), features: .all))
        #expect(editable.commands == [.applyCommand(name: .createTable)])
    }

    /// M6 Task 5: the editor implements tables, so the Table items are enabled with the build's own
    /// features and their shortcuts run.
    @Test func tablesAreImplementedAndTheirShortcutsRun() throws {
        let titles = ["Create Table", "Add Row", "Add Column", "Delete Row", "Delete Column"]
        let state = EditorMenuState(enabled: true, format: .plain, canOpenLink: true)
        #expect(state.features == .implemented)
        #expect(EditorFeatures.implemented.contains(.tables))
        for title in titles {
            #expect(try item(title).isEnabled(in: state), "\(title)")
        }
        let env = try Env()
        #expect(env.state.handleFormatShortcut(key("t", nil, 17, [.command, .option])))
        #expect(env.commands == [.applyCommand(name: .createTable)])
        // Table edits stay off inside code.
        let code = EditorMenuState(enabled: true, format: FormatState(active: [.codeBlock], headingLevel: nil, inTodo: false, inCode: true, canIndent: false))
        for title in titles {
            #expect(try !item(title).isEnabled(in: code), "\(title) in code")
        }
    }

    /// M6 Task 6: the Table submenu also moves rows and columns and copies the table; the move items
    /// edit (off in read-only notes and in code), the copy items run in read-only notes too.
    @Test func tableSubmenuHasMoveAndCopyItems() throws {
        let moves: [(String, EditorCommandName, [String: CommandArgument])] = [
            ("Move Row Up", .tableMoveRow, ["direction": .string("up")]),
            ("Move Row Down", .tableMoveRow, ["direction": .string("down")]),
            ("Move Column Left", .tableMoveColumn, ["direction": .string("left")]),
            ("Move Column Right", .tableMoveColumn, ["direction": .string("right")]),
        ]
        let copies: [(String, String)] = [
            ("Copy Table as CSV", "csv"), ("Copy Table as HTML", "html"), ("Copy Table as Markdown", "markdown"),
        ]
        let editable = EditorMenuState(enabled: true, format: .plain, canOpenLink: true)
        let readOnly = EditorMenuState(enabled: false, format: .plain, canOpenLink: true)
        let unfocused = EditorMenuState(enabled: false, format: .plain)
        let code = EditorMenuState(
            enabled: true,
            format: FormatState(active: [.codeBlock], headingLevel: nil, inTodo: false, inCode: true, canIndent: false))
        for (title, command, args) in moves {
            let menuItem = try item(title)
            #expect(menuItem.command == command && menuItem.args == args && menuItem.shortcut == nil, "\(title)")
            #expect(menuItem.isEnabled(in: editable), "\(title)")
            #expect(!menuItem.isEnabled(in: readOnly), "\(title) edits")
            #expect(!menuItem.isEnabled(in: code), "\(title) in code")
        }
        for (title, format) in copies {
            let menuItem = try item(title)
            #expect(menuItem.command == .copyTable && menuItem.args == ["format": .string(format)] && menuItem.shortcut == nil, "\(title)")
            #expect(menuItem.isEnabled(in: editable) && menuItem.isEnabled(in: readOnly), "\(title)")
            #expect(!menuItem.isEnabled(in: unfocused), "\(title) needs the editor's focus")
        }
        // They sit in the Table submenu, after Bear's five.
        let table = FormatMenu.entries.compactMap { entry -> [String]? in
            if case .submenu("Table", let items) = entry { items.map(\.title) } else { nil }
        }.first
        #expect(table == [
            "Create Table", "Add Row", "Add Column", "Delete Row", "Delete Column",
            "Move Row Up", "Move Row Down", "Move Column Left", "Move Column Right",
            "Copy Table as CSV", "Copy Table as HTML", "Copy Table as Markdown",
        ])
        // Running one sends the command with its arguments.
        let env = try Env()
        env.state.perform(try item("Move Column Left"))
        env.state.perform(try item("Copy Table as HTML"))
        #expect(env.commands == [
            .applyCommand(name: .tableMoveColumn, args: ["direction": .string("left")]),
            .applyCommand(name: .copyTable, args: ["format": .string("html")]),
        ])
    }

    /// A feature the editor does not implement keeps its items disabled and its shortcut unswallowed.
    @Test func itemsOfAnUnimplementedFeatureAreDisabledAndTheirShortcutsAreNotSwallowed() throws {
        let off = EditorMenuState(enabled: true, format: .plain, canOpenLink: true, features: .folding)
        for title in ["Create Table", "Add Row", "Add Column", "Delete Row", "Delete Column"] {
            #expect(try !item(title).isEnabled(in: off), "\(title)")
        }
        #expect(try item("Toggle Fold").isEnabled(in: off))
        let env = try Env()
        #expect(!env.state.handleFormatShortcut(key("t", nil, 17, [.command, .option]), features: .folding))
        #expect(env.commands.isEmpty)
        // A real command stays swallowed and runs.
        #expect(env.state.handleFormatShortcut(event("b", 11, .command)))
        #expect(env.commands == [.applyCommand(name: .bold)])
    }

    /// M7 Task 11: the heading badge's Fold All / Unfold All have menu-bar items (keyboard-only use),
    /// enabled in editable and read-only notes like Toggle Fold.
    @Test func foldAllAndUnfoldAllAreFormatMenuItems() throws {
        let state = EditorMenuState(enabled: true, format: .plain, canOpenLink: true)
        #expect(try item("Fold All Headings").command == .foldAll)
        #expect(try item("Unfold All Headings").command == .unfoldAll)
        #expect(try item("Fold All Headings").isEnabled(in: state))
        #expect(try item("Unfold All Headings").isEnabled(in: state))
    }

    /// M7 final review I4: the heading badge's Copy Link to Here has a Format menu item for the heading
    /// at the caret, so a keyboard-only user can reach it. It is a host action (the badge menu's), not an editor
    /// command, so it sits beside `FormatMenu.items` in `FormatMenu.entries`, right after Unfold All Headings.
    @Test func copyLinkToHereIsAFormatMenuItemForTheHeadingAtTheCaret() throws {
        let titles = FormatMenu.entries.compactMap { entry -> String? in
            switch entry {
            case .item(let item): item.title
            case .copyLinkToHere: FormatMenu.copyLinkToHereTitle
            default: nil
            }
        }
        let fold = try #require(titles.firstIndex(of: "Unfold All Headings"))
        #expect(titles[fold + 1] == "Copy Link to Here")
        #expect(FormatMenu.copyLinkToHereTitle == "Copy Link to Here", "the badge menu's wording")

        let heading = FormatState(active: [.heading], headingLevel: 2, inTodo: false, inCode: false, canIndent: false)
        #expect(EditorMenuState(enabled: true, format: heading, canOpenLink: true).canCopyHeadingLink)
        #expect(EditorMenuState(enabled: false, format: heading, canOpenLink: true).canCopyHeadingLink, "read-only notes too")
        #expect(!EditorMenuState(enabled: true, format: .plain, canOpenLink: true).canCopyHeadingLink, "the caret is not in a heading")
        #expect(!EditorMenuState(enabled: true, format: heading, canOpenLink: false).canCopyHeadingLink, "no focused editor")
        #expect(!EditorMenuState.unavailable.canCopyHeadingLink)
    }

    @Test func copyLinkToHereIsInTheMenuBarWithoutAShortcut() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let format = try #require(mainMenu.items.first { $0.title == "Format" }?.submenu)
        let copy = try #require(allItems(format).first { $0.title == "Copy Link to Here" }, "Format > Copy Link to Here is missing")
        #expect(copy.keyEquivalent.isEmpty)
        let titles = format.items.map(\.title)
        let fold = try #require(titles.firstIndex(of: "Unfold All Headings"))
        #expect(titles[fold + 1] == "Copy Link to Here")
    }

    /// The menu action runs the same code as the badge menu's item: it copies the caret heading's link.
    @Test func theFormatTargetCopiesTheCaretHeadingLink() throws {
        let env = try Env()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TheoNotesFormatTest-\(UUID().uuidString)"))
        env.editor.pasteboard = pasteboard
        let id = try env.environment.store.create(text: "# Plan\n\nintro").id
        try env.editor.open(noteId: id)
        _ = env.editor.handle(.selectionChanged(noteId: id, anchor: 3, head: 3))
        env.state.copyHeadingLink()
        #expect(pasteboard.string(forType: .string) == "[[Plan/Plan]]")
    }

    /// M6 Task 7: the editor implements folding, so Toggle Fold (⌘') is enabled with the build's
    /// own features and its shortcut runs, in editable and read-only notes alike.
    @Test func foldingIsImplementedAndToggleFoldRuns() throws {
        #expect(EditorFeatures.implemented.contains(.folding))
        #expect(try item("Toggle Fold").isEnabled(in: EditorMenuState(enabled: true, format: .plain, canOpenLink: true)))
        let env = try Env()
        #expect(env.state.handleFormatShortcut(key("'", nil, 39, .command)))
        #expect(env.commands == [.applyCommand(name: .toggleFold)])
        let readOnly = try Env(readOnly: true)
        #expect(readOnly.state.handleFormatShortcut(key("ä", "ä", 39, .command)))
        #expect(readOnly.commands == [.applyCommand(name: .toggleFold)])
    }

    /// ⌘' is the physical key (kVK_ANSI_Quote, 39), so a layout that types another
    /// character there (German "ä") triggers Toggle Fold too, and the typed "'" elsewhere does not.
    @Test func toggleFoldMatchesThePhysicalQuoteKey() {
        #expect(FormatMenu.item(for: key("'", nil, 39, .command))?.title == "Toggle Fold")
        #expect(FormatMenu.item(for: key("ä", "ä", 39, .command))?.title == "Toggle Fold")
        #expect(FormatMenu.item(for: key("é", "é", 39, .command))?.title == "Toggle Fold")
        #expect(FormatMenu.item(for: key("'", nil, 24, .command)) == nil)
        #expect(FormatMenu.item(for: key("ä", "ä", 39, [.command, .shift])) == nil)
        #expect(FormatMenu.item(for: key("ä", "ä", 39, [])) == nil)
    }

    /// ⌃⌘⌫ and ⌃⇧⌘⌫ (the delete key types U+007F).
    @Test func deleteKeyShortcutsFindTheirTableItems() {
        #expect(FormatMenu.item(for: key("\u{7F}", nil, 51, [.command, .control]))?.title == "Delete Row")
        #expect(FormatMenu.item(for: key("\u{7F}", nil, 51, [.command, .control, .shift]))?.title == "Delete Column")
        #expect(FormatMenu.item(for: key("\u{7F}", nil, 51, .command)) == nil)
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        #expect(FormatMenu.item(for: key(down, nil, 125, [.command, .control, .numericPad, .function]))?.title == "Add Row")
        #expect(FormatMenu.item(for: key(right, nil, 124, [.command, .control, .numericPad, .function]))?.title == "Add Column")
        #expect(FormatMenu.item(for: key("t", nil, 17, [.command, .option]))?.title == "Create Table")
    }

    /// The system Show/Hide Toolbar (⌥⌘T) and Customize Toolbar are replaced, so ⌥⌘T has
    /// one owner, Format ▸ Table ▸ Create Table. A window with a toolbar is what makes AppKit
    /// and SwiftUI offer them.
    @Test func theAppRemovesTheSystemToolbarCommands() throws {
        // The test host has no SwiftUI window with a toolbar, so SwiftUI never offers Hide Toolbar
        // there and a live-menu check cannot fail by itself (a real toolbar window in the test
        // also upsets the focus tests). This pins the replacement in the source.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Commands/TheoNotesCommands.swift"),
            encoding: .utf8)
        let lines = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.contains("CommandGroup(replacing: .toolbar) {}"))
    }

    /// Whatever the host menu offers, ⌥⌘T belongs to Create Table alone.
    @Test func optionCommandTHasOneOwnerInTheMenuBar() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let optionCommandT = NSEvent.ModifierFlags([.command, .option])
        var owners: [String] = []
        for menuItem in mainMenu.items.flatMap({ $0.submenu.map(allItems) ?? [] }) {
            #expect(menuItem.action != #selector(NSWindow.toggleToolbarShown(_:)), "\(menuItem.title)")
            #expect(menuItem.action != #selector(NSWindow.runToolbarCustomizationPalette(_:)), "\(menuItem.title)")
            if menuItem.keyEquivalent.lowercased() == "t", modifierFlags(menuItem) == optionCommandT { owners.append(menuItem.title) }
        }
        #expect(owners == ["Create Table"], "\(owners)")
    }

    /// M6 Task 14 (cross-plan X38): Edit ▸ Typewriter Mode is ⌃⌘T and nothing else in the menu
    /// bar takes it; View ▸ Zoom's keys (⌘+ ⌘= ⌘- ⌘0) are not its keys.
    @Test func typewriterModeIsInTheEditMenuWithCtrlCmdT() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let edit = try #require(mainMenu.items.first { $0.title == "Edit" }?.submenu)
        let item = try #require(edit.items.first { $0.title == "Typewriter Mode" }, "\(edit.items.map(\.title))")
        let (key, flags) = normalized(item.keyEquivalent, modifierFlags(item))
        #expect(key == "t")
        #expect(flags == [.command, .control])

        let controlCommandT = NSEvent.ModifierFlags([.command, .control])
        var owners: [String] = []
        for menuItem in mainMenu.items.flatMap({ $0.submenu.map(allItems) ?? [] }) {
            let (itemKey, itemFlags) = normalized(menuItem.keyEquivalent, modifierFlags(menuItem))
            if itemKey == "t", itemFlags == controlCommandT { owners.append(menuItem.title) }
        }
        #expect(owners == ["Typewriter Mode"], "\(owners)")
        // Zoom keys stay free of it.
        #expect(!["+", "=", "-", "0"].contains(key))
        // Format's own table does not use ⌃⌘T either.
        #expect(!FormatMenu.items.contains { $0.shortcut?.key == "t" && $0.modifierFlags == controlCommandT })
    }

    /// Final review I5: Bear's Format ▸ Code ▸ Math / Math Block (inventory rows 101–102) are menu
    /// items next to Code Block, without a shortcut, off in code like Inline Code's
    /// styles, and send `insertMath {display}`.
    @Test func mathAndMathBlockAreFormatMenuItemsThatInsertMath() throws {
        let math = try item("Math")
        let block = try item("Math Block")
        #expect(math.command == .insertMath && math.args == ["display": .bool(false)])
        #expect(block.command == .insertMath && block.args == ["display": .bool(true)])
        #expect(math.shortcut == nil && block.shortcut == nil)
        let titles = FormatMenu.entries.compactMap { entry -> String? in
            if case .item(let item) = entry { return item.title }
            return nil
        }
        let code = try #require(titles.firstIndex(of: "Code Block"))
        #expect(Array(titles[code...].prefix(3)) == ["Code Block", "Math", "Math Block"])
        let span = EditorMenuState(enabled: true, format: FormatState(active: [.inlineCode], headingLevel: nil, inTodo: false, inCode: true, canIndent: false))
        #expect(!math.isEnabled(in: span) && !block.isEnabled(in: span))
        #expect(math.isEnabled(in: EditorMenuState(enabled: true, format: .plain)))
        #expect(!math.isEnabled(in: .unavailable))

        let env = try Env()
        env.state.perform(math)
        env.state.perform(block)
        #expect(env.commands == [
            .applyCommand(name: .insertMath, args: ["display": .bool(false)]),
            .applyCommand(name: .insertMath, args: ["display": .bool(true)]),
        ])
    }

    @Test func foldAndCopyCommandsRunInReadOnlyNotes() {
        let readOnlyCommands: [EditorCommandName] = [.copyTable, .toggleFold, .foldAll, .unfoldAll, .openLink]
        for command in EditorCommandName.allCases {
            #expect(command.runsInReadOnly == (readOnlyCommands.contains(command) || command.isFind), "\(command)")
        }
    }

    @Test func theMenuStateComesFromTheFocusedEditor() throws {
        let env = try Env()
        #expect(env.editor.status.isEditable)
        // Not focused (no window): everything off, no checkmarks shown.
        #expect(env.state.editorMenuState == EditorMenuState(enabled: false, format: .plain, canFind: true))
        let format = FormatState(active: [.italic], headingLevel: nil, inTodo: false, inCode: false, canIndent: true)
        _ = env.editor.handle(.formatState(noteId: env.noteId, state: format))
        #expect(env.state.editorMenuState.format == format)
        env.state.perform(try item("Heading 3"))
        #expect(env.commands == [.applyCommand(name: .heading, args: ["level": .int(3)])])
    }

    /// Format ▸ File… (⇧⌘V, Bear's "Format → File") opens the host's panel and inserts the
    /// chosen files; it never reaches the editor as a command.
    @Test func insertFileOpensThePanelAndInsertsTheFiles() async throws {
        let env = try Env()
        let source = env.root.appendingPathComponent("Scan 1.pdf")
        try Data([1, 2]).write(to: source)
        var panels = 0
        env.editor.attachments.chooseFiles = {
            panels += 1
            return [source]
        }
        #expect(env.state.handleFormatShortcut(event("V", 9, [.command, .shift])))
        #expect(panels == 1)
        await env.editor.attachments.pendingWork?.value
        #expect(env.commands == [.applyCommand(name: .insertText, args: [
            "text": .string(#"[Scan 1.pdf](Scan%201.pdf)<!-- {"preview":"true","embed":"true"} -->"#),
        ])])
        let stored = env.root.appendingPathComponent("Attachments/\(env.noteId)/Scan 1.pdf")
        #expect(try Data(contentsOf: stored) == Data([1, 2]))

        // Off in code and in read-only notes.
        _ = env.editor.handle(.formatState(
            noteId: env.noteId, state: FormatState(active: [], headingLevel: nil, inTodo: false, inCode: true, canIndent: false)))
        #expect(env.state.handleFormatShortcut(event("V", 9, [.command, .shift])))
        #expect(panels == 1)
        let readOnly = try Env(readOnly: true)
        readOnly.editor.attachments.chooseFiles = { panels += 1; return [source] }
        readOnly.state.perform(try item("File…"))
        #expect(panels == 1)
    }

    // MARK: - Edit ▸ Paste From ▸ Code

    @Test func pasteAsCodeSendsThePasteboardTextToAnEditableNote() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TheoNotesTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("let a = 1\nlet b = 2", forType: .string)
        let env = try Env()
        env.editor.pasteAsCode(pasteboard)
        #expect(env.commands == [.applyCommand(name: .pasteCode, args: ["text": .string("let a = 1\nlet b = 2")])])
        // Nothing to paste: no command.
        pasteboard.clearContents()
        env.editor.pasteAsCode(pasteboard)
        #expect(env.commands.count == 1)
        // Read-only notes get none.
        pasteboard.setString("x", forType: .string)
        let readOnly = try Env(readOnly: true)
        readOnly.editor.pasteAsCode(pasteboard)
        #expect(readOnly.commands.isEmpty)
    }

    @Test func pasteFromCodeFollowsThePasteboardGroupInTheEditMenu() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        let edit = try #require(mainMenu.items.first { $0.title == "Edit" }?.submenu)
        let titles = edit.items.map(\.title)
        let index = try #require(titles.firstIndex(of: "Paste From"), "\(titles)")
        // Exactly after the system pasteboard group (Cut … Select All).
        #expect(titles[index - 1] == "Select All", "\(titles)")
        let pasteFrom = try #require(edit.items[index].submenu)
        #expect(pasteFrom.items.map(\.title) == ["Code"])
        #expect(pasteFrom.items[0].keyEquivalent.isEmpty)
    }
}
