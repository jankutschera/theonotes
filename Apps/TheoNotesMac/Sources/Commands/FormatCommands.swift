// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

extension EditorCommandName {
    /// Edit ▸ Find ▸ Find… / Find and Replace… / Find Next / Find Previous: they also run in
    /// read-only notes (the editor refuses replacing there).
    var isFind: Bool { self == .find || self == .findAndReplace || self == .findNext || self == .findPrevious }

    /// Commands that also run in read-only notes: the Find commands, Open Link (⇧⌘K / ⌥⇧⌘K:
    /// opening a link is not an edit, R36), and the ones that only fold or copy (Copy Table As,
    /// ⌘' Toggle Fold, Fold All, Unfold All).
    var runsInReadOnly: Bool {
        switch self {
        case .find, .findAndReplace, .findNext, .findPrevious, .openLink, .copyTable, .toggleFold, .foldAll, .unfoldAll: true
        default: false
        }
    }
}

/// Editor features whose commands the shipped editor really implements. Bridge v3 declared the
/// table and fold commands as stubs; a menu item of a stub stays disabled and its shortcut is not
/// swallowed. The owning task flips its flag in `implemented` (Task 5 `.tables`, Task 7 `.folding`; both
/// are on now, the mechanism stays for the next stub).
struct EditorFeatures: OptionSet, Equatable, Sendable {
    let rawValue: Int
    static let tables = EditorFeatures(rawValue: 1)
    static let folding = EditorFeatures(rawValue: 2)
    static let all: EditorFeatures = [.tables, .folding]
    /// What the editor in this build implements.
    static let implemented: EditorFeatures = [.tables, .folding]
}

extension EditorCommandName {
    /// The feature this command belongs to, nil for the commands that always work.
    var requiredFeature: EditorFeatures? {
        switch self {
        case .createTable, .tableAddRow, .tableAddColumn, .tableDeleteRow, .tableDeleteColumn, .tableMoveRow,
             .tableMoveColumn, .copyTable: .tables
        case .toggleFold, .foldAll, .unfoldAll: .folding
        default: nil
        }
    }
}

/// Edit ▸ Find (R18): ⌘F / ⌥⌘F / ⌘G / ⇧⌘G belong to the native menu like the Format shortcuts and
/// run in the shown note's editor through `applyCommand`, also while the note list has keyboard
/// focus. Find… / Find and Replace… open the editor's find panel; Find Next / Previous select its
/// match while it is open, else they step through the note-list search highlight (R32).
enum FindMenu {
    static let items: [FormatMenuItem] = [
        FormatMenuItem("Find…", .find, KeyboardShortcut("f", modifiers: .command)),
        FormatMenuItem("Find and Replace…", .findAndReplace, KeyboardShortcut("f", modifiers: [.command, .option])),
        FormatMenuItem("Find Next", .findNext, KeyboardShortcut("g", modifiers: .command)),
        FormatMenuItem("Find Previous", .findPrevious, KeyboardShortcut("g", modifiers: [.command, .shift])),
    ]
}

/// One Format menu command: a registry command of the editor (`applyCommand`) with Bear's shortcut
/// (inventory §2.17.1; `Fixtures/bridge/format-shortcuts.json` is the shared table).
struct FormatMenuItem: Identifiable, Equatable {
    let title: String
    let command: EditorCommandName
    var args: [String: CommandArgument]?
    var shortcut: KeyboardShortcut?
    /// Matches the physical key instead of the typed character (a layout that types something
    /// else there still triggers it): ⌘' is kVK_ANSI_Quote (M6-R5).
    var keyCode: UInt16?

    var id: String { title }

    /// What the menu shows: the Copy Table items sit in a "Copy Table As" submenu and read CSV, HTML, Markdown.
    var menuTitle: String {
        guard command == .copyTable, case .string(let format) = args?["format"] else { return title }
        return format == "csv" ? "CSV" : format == "html" ? "HTML" : "Markdown"
    }

    init(
        _ title: String, _ command: EditorCommandName, args: [String: CommandArgument]? = nil, _ shortcut: KeyboardShortcut? = nil,
        keyCode: UInt16? = nil
    ) {
        self.title = title
        self.command = command
        self.args = args
        self.shortcut = shortcut
        self.keyCode = keyCode
    }

    /// Whether the editor implements this item's command (see `EditorFeatures`).
    func isAvailable(with features: EditorFeatures) -> Bool {
        command.requiredFeature.map(features.contains) ?? true
    }

    /// Off in code (spec: inline styles never touch text inside code spans and blocks).
    private static let offInCode: Set<EditorCommandName> = [
        .bold, .italic, .underline, .strike, .highlight, .link, .wikiLink, .footnote, .horizontalRule, .insertFile, .insertMath,
        .createTable, .tableAddRow, .tableAddColumn, .tableDeleteRow, .tableDeleteColumn, .tableMoveRow, .tableMoveColumn,
    ]
    /// Line formats are off inside a code block.
    private static let lineFormats: Set<EditorCommandName> = [.heading, .bulletList, .orderedList, .todo, .toggleTodo, .quote, .callout]
    /// Items that show a checkmark when the selection has the style.
    private static let toggles: Set<EditorCommandName> = [
        .bold, .italic, .underline, .strike, .inlineCode, .link, .bulletList, .orderedList, .todo, .quote, .codeBlock,
    ]

    func isEnabled(in state: EditorMenuState) -> Bool {
        if !isAvailable(with: state.features) { return false }
        if command.isFind { return state.canFind }
        if command.runsInReadOnly { return state.enabled || state.canOpenLink }
        guard state.enabled else { return false }
        let format = state.format
        if Self.offInCode.contains(command) { return !format.inCode }
        if command == .inlineCode { return !format.inCode || format.active.contains(.inlineCode) }
        if Self.lineFormats.contains(command) { return !format.active.contains(.codeBlock) }
        return true
    }

    /// The checkmark, or nil for an item without one (a plain command).
    func isChecked(in format: FormatState) -> Bool? {
        switch command {
        case .heading:
            guard case .int(let level) = args?["level"] else { return nil }
            return format.headingLevel == level
        case .highlight:
            // The colors are commands; "Highlight" itself shows whether the selection is highlighted.
            return args == nil ? format.active.contains(.highlight) : nil
        default:
            return Self.toggles.contains(command) ? format.active.contains(command) : nil
        }
    }

    /// `⌥⌘C`, `⌃⇧⌘0`, `⌥⌘↑`: Apple's modifier order, then the key.
    var shortcutDisplay: String? {
        guard let shortcut else { return nil }
        let m = shortcut.modifiers
        var out = ""
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option) { out += "⌥" }
        if m.contains(.shift) { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        switch shortcut.key {
        case .leftArrow: out += "←"
        case .rightArrow: out += "→"
        case .upArrow: out += "↑"
        case .downArrow: out += "↓"
        case .delete: out += "⌫"
        default: out += String(shortcut.key.character).uppercased()
        }
        return out
    }

    /// The AppKit modifier flags of the shortcut.
    var modifierFlags: NSEvent.ModifierFlags {
        guard let m = shortcut?.modifiers else { return [] }
        var flags: NSEvent.ModifierFlags = []
        if m.contains(.command) { flags.insert(.command) }
        if m.contains(.shift) { flags.insert(.shift) }
        if m.contains(.option) { flags.insert(.option) }
        if m.contains(.control) { flags.insert(.control) }
        return flags
    }
}

/// What the Format menu needs of the focused window's editor.
struct EditorMenuState: Equatable {
    /// An editable note is shown and the editor has keyboard focus.
    var enabled: Bool
    var format: FormatState
    /// A note is shown (Find Next / Previous target it from the note list too, read-only included).
    var canFind = false
    /// A note is shown, read-only included, and the editor has keyboard focus (Open Link, R36;
    /// folding and Copy Table As).
    var canOpenLink = false
    /// The editor features this build implements; items of the others stay disabled.
    var features: EditorFeatures = .implemented

    /// Format > Copy Link to Here: the caret is in a heading of the note shown (read-only included). Whether
    /// a link can reach it is checked when the item runs, not on every state change.
    var canCopyHeadingLink: Bool { canOpenLink && format.headingLevel != nil }

    static let unavailable = EditorMenuState(enabled: false, format: .plain)
}

/// The Format menu, top to bottom.
enum FormatMenu {
    enum Entry {
        case item(FormatMenuItem)
        case submenu(String, [FormatMenuItem])
        case divider
        /// Copy Link to Here (the heading badge menu's item, M7-R22): a host action, not an editor command.
        case copyLinkToHere
    }

    static let copyLinkToHereTitle = "Copy Link to Here"
    /// The submenu of Format ▸ Table and of the cell menu that holds the three Copy Table forms.
    static let copyTableTitle = "Copy Table As"

    private static func key(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }

    static let highlightColors: [(title: String, color: String)] = [
        ("Green", "green"), ("Red", "red"), ("Blue", "blue"), ("Yellow", "yellow"), ("Purple", "purple"),
    ]

    static let entries: [Entry] = [
        .item(FormatMenuItem("Bold", .bold, key("b"))),
        .item(FormatMenuItem("Italic", .italic, key("i"))),
        .item(FormatMenuItem("Underline", .underline, key("u"))),
        .item(FormatMenuItem("Strikethrough", .strike, key("u", [.command, .shift]))),
        .item(FormatMenuItem("Highlight", .highlight, key("m", [.command, .shift]))),
        .submenu("Highlight Color", highlightColors.map {
            FormatMenuItem($0.title, .highlight, args: ["color": .string($0.color)])
        }),
        .item(FormatMenuItem("Inline Code", .inlineCode, key("c", [.command, .option]))),
        .item(FormatMenuItem("Link", .link, key("k"))),
        .item(FormatMenuItem("Open Link", .openLink, key("k", [.command, .shift]))),
        .item(FormatMenuItem("Open Link in New Window", .openLink, args: ["window": .string("new")], key("k", [.command, .shift, .option]))),
        .item(FormatMenuItem("Wiki Link", .wikiLink, key("d"))),
        .item(FormatMenuItem("Footnote", .footnote, key("e", [.command, .shift]))),
        .divider,
        .submenu("Heading", (1...6).map { level in
            FormatMenuItem("Heading \(level)", .heading, args: ["level": .int(level)], key(KeyEquivalent(Character("\(level)"))))
        }),
        .divider,
        .item(FormatMenuItem("List", .bulletList, key("l"))),
        .item(FormatMenuItem("Ordered List", .orderedList, key("l", [.command, .shift]))),
        .item(FormatMenuItem("Todo", .todo, key("t"))),
        .item(FormatMenuItem("Toggle Todo", .toggleTodo, key("."))),
        .item(FormatMenuItem("Move Checked Todos to Bottom", .moveCheckedToBottom)),
        .item(FormatMenuItem("Quote", .quote, key("t", [.command, .shift]))),
        // No shortcut; the type is chosen from the callout's icon.
        .item(FormatMenuItem("Callout", .callout)),
        .item(FormatMenuItem("Code Block", .codeBlock, key("c", [.command, .control]))),
        // Bear: Format ▸ Code ▸ Math / Math Block, no shortcut (M6-R80); flat like Inline Code and Code Block.
        .item(FormatMenuItem("Math", .insertMath, args: ["display": .bool(false)])),
        .item(FormatMenuItem("Math Block", .insertMath, args: ["display": .bool(true)])),
        .item(FormatMenuItem("Line Separator", .horizontalRule, key("s", [.command, .option]))),
        // Bear: Format ▸ File (⇧⌘V); "…" because it opens a panel.
        .item(FormatMenuItem("File…", .insertFile, key("v", [.command, .shift]))),
        .divider,
        .item(FormatMenuItem("Indent", .indent, key(.rightArrow, [.command, .option]))),
        .item(FormatMenuItem("Outdent", .outdent, key(.leftArrow, [.command, .option]))),
        .item(FormatMenuItem("Move Line Up", .moveLineUp, key(.upArrow, [.command, .option]))),
        .item(FormatMenuItem("Move Line Down", .moveLineDown, key(.downArrow, [.command, .option]))),
        .divider,
        // Bear's Table shortcuts (inventory §2.17.1). The moves and the copy items have none; the cell
        // menu has the same items. The three Copy Table items are shown in a "Copy Table As" submenu
        // (`menuTitle`, `FormatCommands`); they also run in read-only notes.
        .submenu("Table", [
            FormatMenuItem("Create Table", .createTable, key("t", [.command, .option])),
            FormatMenuItem("Add Row", .tableAddRow, key(.downArrow, [.command, .control])),
            FormatMenuItem("Add Column", .tableAddColumn, key(.rightArrow, [.command, .control])),
            FormatMenuItem("Delete Row", .tableDeleteRow, key(.delete, [.command, .control])),
            FormatMenuItem("Delete Column", .tableDeleteColumn, key(.delete, [.command, .control, .shift])),
            FormatMenuItem("Move Row Up", .tableMoveRow, args: ["direction": .string("up")]),
            FormatMenuItem("Move Row Down", .tableMoveRow, args: ["direction": .string("down")]),
            FormatMenuItem("Move Column Left", .tableMoveColumn, args: ["direction": .string("left")]),
            FormatMenuItem("Move Column Right", .tableMoveColumn, args: ["direction": .string("right")]),
            FormatMenuItem("Copy Table as CSV", .copyTable, args: ["format": .string("csv")]),
            FormatMenuItem("Copy Table as HTML", .copyTable, args: ["format": .string("html")]),
            FormatMenuItem("Copy Table as Markdown", .copyTable, args: ["format": .string("markdown")]),
        ]),
        // Folds the block under the caret's heading or list item; works in read-only notes.
        .item(FormatMenuItem("Toggle Fold", .toggleFold, key("'"), keyCode: 39)),
        // The heading badge's menu items for keyboard-only use: the badge is a VoiceOver button
        // (AXPress), not a Tab stop (M7-R20).
        .item(FormatMenuItem("Fold All Headings", .foldAll)),
        .item(FormatMenuItem("Unfold All Headings", .unfoldAll)),
        .copyLinkToHere,
        .divider,
        .submenu("Insert Date", [
            FormatMenuItem("Long Date with Time", .insertDate, args: ["style": .string("longTime")], key("7", [.command, .shift])),
            FormatMenuItem("Long Date", .insertDate, args: ["style": .string("long")], key("8", [.command, .shift])),
            FormatMenuItem("Short Date", .insertDate, args: ["style": .string("short")], key("9", [.command, .shift])),
            // ⇧⌘0 is Dismiss Workspace (spec §4.2).
            FormatMenuItem("Time", .insertDate, args: ["style": .string("hours")], key("0", [.command, .shift, .control])),
        ]),
    ]

    static var items: [FormatMenuItem] {
        entries.flatMap { entry -> [FormatMenuItem] in
            switch entry {
            case .item(let item): [item]
            case .submenu(_, let items): items
            case .divider, .copyLinkToHere: []
            }
        }
    }

    /// The item whose shortcut `event` is (by the key without modifiers, so ⇧⌘7 matches whatever
    /// ⇧7 types on the layout), if any.
    static func item(for event: NSEvent) -> FormatMenuItem? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return nil }
        let keys = [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers]
            .compactMap { $0?.lowercased() }
        return (items + FindMenu.items).first { item in
            guard let shortcut = item.shortcut, item.modifierFlags == flags else { return false }
            if let keyCode = item.keyCode { return event.keyCode == keyCode }
            return keys.contains(String(shortcut.key.character).lowercased())
        }
    }
}

extension EditorBridgeController {
    /// The Format menu's state for this editor. The menu bar and the editor's context menu both
    /// build it here, so the two cannot disagree about what is enabled.
    func menuState(editorFocused: Bool, canFind: Bool = false) -> EditorMenuState {
        EditorMenuState(
            enabled: editorFocused && status.isEditable, format: status.formatState ?? .plain,
            canFind: canFind, canOpenLink: editorFocused && status.showsNote
        )
    }

    /// Runs a Format command in the editor (File… opens the host's panel instead): the one path
    /// of the menu bar, the shortcuts and the editor's context menu.
    func performFormat(_ item: FormatMenuItem) {
        if item.command == .insertFile { return presentInsertFilePanel() }
        apply(item.command, args: item.args)
    }
}

/// Format ▸ … (spec §4.4: every command in the menu bar with Bear's shortcut; checkmarks from the
/// editor's `formatState`; disabled without a focused, editable editor).
/// A window whose editor the Format menu drives: a main window or a note window.
@MainActor
protocol FormatTarget: AnyObject {
    var editor: EditorBridgeController { get }
    /// Whether this window's editor has keyboard focus.
    var isEditorFocused: Bool { get }
    /// Whether Find Next / Previous have a note to act on (`EditorMenuState.canFind`).
    var canFind: Bool { get }
}

extension FormatTarget {
    /// The Format menu's state: enabled while the editor has keyboard focus and shows an editable note.
    var editorMenuState: EditorMenuState {
        menuState(editorFocused: isEditorFocused)
    }

    func menuState(editorFocused: Bool) -> EditorMenuState {
        editor.menuState(editorFocused: editorFocused, canFind: canFind)
    }

    /// Runs a Format menu command in the editor (File… opens the host's panel instead).
    func perform(_ item: FormatMenuItem) {
        editor.performFormat(item)
    }

    /// Format ▸ Copy Link to Here.
    func copyHeadingLink() {
        editor.copyHeadingLinkAtCaret()
    }

    /// Edit ▸ Paste From ▸ Code.
    func pasteAsCode() {
        editor.pasteAsCode()
    }

    /// A Format shortcut typed in the editor runs the menu's command right here, before the web view
    /// sees the key: WebKit would hand it to the page first (CodeMirror's own ⌘I/⌘U bindings) and
    /// only maybe back to the menu. One owner per shortcut: the native menu. Returns whether `event`
    /// is a Format shortcut (then swallowed, also when the command is disabled), except that the
    /// shortcut of a command the editor still stubs (`features`) is not swallowed.
    func handleFormatShortcut(_ event: NSEvent, features: EditorFeatures = .implemented) -> Bool {
        guard let item = FormatMenu.item(for: event), item.isAvailable(with: features) else { return false }
        var state = menuState(editorFocused: true)
        state.features = features
        if item.isEnabled(in: state) { perform(item) }
        return true
    }
}

/// Which window's editor the Format and Find menus act on. SwiftUI publishes focused values for the key
/// window only, so at most one of the two is set.
@MainActor
enum FormatRouting {
    static func target(mainWindow: MainWindowState?, noteWindow: NoteWindowState?) -> (any FormatTarget)? {
        mainWindow ?? noteWindow
    }
}

struct FormatCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow
    @FocusedValue(\.noteWindow) private var noteWindow
    @FocusedValue(\.editorMenuState) private var focusedState

    private var state: EditorMenuState { focusedState ?? .unavailable }
    private var window: (any FormatTarget)? { FormatRouting.target(mainWindow: mainWindow, noteWindow: noteWindow) }

    var body: some Commands {
        // Bear's Paste From ▸ Code (inventory §2.2.1), right after the pasteboard group; off like
        // Format without an editable editor.
        CommandGroup(after: .pasteboard) {
            Menu("Paste From") {
                Button("Code") { window?.pasteAsCode() }
                    .disabled(!state.enabled)
            }
        }
        CommandMenu("Format") {
            ForEach(Array(FormatMenu.entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .item(let item):
                    menuItem(item)
                case .submenu(let title, let items):
                    Menu(title) {
                        ForEach(items.filter { $0.command != .copyTable }) { menuItem($0) }
                        if items.contains(where: { $0.command == .copyTable }) {
                            Menu(FormatMenu.copyTableTitle) {
                                ForEach(items.filter { $0.command == .copyTable }) { menuItem($0) }
                            }
                        }
                    }
                case .divider:
                    Divider()
                case .copyLinkToHere:
                    Button(FormatMenu.copyLinkToHereTitle) { window?.copyHeadingLink() }
                        .disabled(!state.canCopyHeadingLink)
                }
            }
        }
    }

    @ViewBuilder
    private func menuItem(_ item: FormatMenuItem) -> some View {
        if let checked = item.isChecked(in: state.format) {
            Toggle(item.menuTitle, isOn: Binding(get: { checked && state.enabled }, set: { _ in window?.perform(item) }))
                .keyboardShortcut(item.shortcut)
                .disabled(!item.isEnabled(in: state))
        } else {
            Button(item.menuTitle) { window?.perform(item) }
                .keyboardShortcut(item.shortcut)
                .disabled(!item.isEnabled(in: state))
        }
    }
}
