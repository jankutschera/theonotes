// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// The editor's right-click menu: WebKit's own menu with the parts that make no sense in
/// a Markdown editor taken out, and its "Font" submenu replaced by "Format".
///
/// The editor never takes rich-text edits (the Markdown source is the truth), so WebKit's Font
/// submenu (Show Fonts, Bold, Italic, Underline, Outline, Styles…, Show Colors) and anything else
/// that opens the system font or color panel is removed, and so are the items of a web page's menu
/// (Back, Forward, Stop, Reload, Inspect Element). "Format" holds the Format menu bar's inline styles and
/// runs the same commands (`EditorBridgeController.performFormat`) with the same shortcut hints,
/// checkmarks and enabled state (`FormatMenuItem`).
///
/// Observed in a real right-click (`ContextMenuTests`): WebKit gives most items an
/// `NSUserInterfaceItemIdentifier` `WKMenuItemIdentifier…`, but not the Font, Transformations and
/// writing-direction submenus, and its Cut and the Font items carry the action name
/// (`forwardContextMenuAction:`) as the identifier. Every item has WebCore's `ContextMenuAction`
/// as its `tag`, so the matching uses the identifier and the tag, and the font panel's selectors.
@MainActor
enum EditorContextMenu {
    static let formatTitle = "Format"
    /// One item: the sheet asks whether the reminder is for the caret's line or the whole note.
    static let remindTitle = RemindMeMenu.title

    /// Set by the app: opens the reminder sheet for the editor whose menu was used.
    static var remind: (@MainActor (EditorBridgeController, ReminderScope) -> Void)?

    /// Set by the app: Copy As for the editor whose menu was used (its selection, else its note), and
    /// the Keep Tags setting the submenu shows and flips.
    static var copyAs: (@MainActor (EditorBridgeController, CopyAsFormat) -> Void)?
    static var keepTags: (@MainActor () -> Bool)?
    static var setKeepTags: (@MainActor (Bool) -> Void)?
    static let copyAsTitle = "Copy As"

    /// The Format submenu's items, in order: the inline styles of the Format menu bar.
    static let formatTitles = ["Bold", "Italic", "Underline", "Strikethrough", "Highlight", "Inline Code"]

    // WebCore `ContextMenuAction` values (ContextMenuItem.h), as WebKit puts them in `NSMenuItem.tag`.
    private static let navigationTags: Set<Int> = [
        9, // GoBack
        10, // GoForward
        11, // Stop
        12, // Reload
        16, // InspectElement
    ]
    /// Show Fonts … Show Colors (41...47); the submenu's own tag (40) is not kept on its parent item.
    private static let fontTags = Set(40...47)

    private static let removedIdentifiers: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierStop", "WKMenuItemIdentifierInspectElement", "WKMenuItemIdentifierFontMenu",
        "WKMenuItemIdentifierShowFonts", "WKMenuItemIdentifierShowColors",
    ]

    /// Selectors of the system font panel, color panel and the NSText font-style items (kerning,
    /// ligatures, baseline, character shape, Bigger, Smaller): never wanted in a Markdown editor.
    private static let removedActions: Set<String> = [
        "orderFrontFontPanel:", "orderFrontColorPanel:", "orderFrontStylesPanel:", "modifyFont:", "changeFont:",
        "changeAttributes:", "changeColor:", "raiseBaseline:", "lowerBaseline:", "superscript:", "subscript:",
        "unscript:", "useStandardKerning:", "turnOffKerning:", "tightenKerning:", "loosenKerning:",
        "useStandardLigatures:", "turnOffLigatures:", "useAllLigatures:", "underline:", "toggleTraditionalCharacterShape:",
        "makeTextLarger:", "makeTextSmaller:", "_makeTextLarger:", "_makeTextSmaller:",
    ]

    /// Whether `item` (or, for a submenu, anything in it) is something this editor drops.
    static func isRemoved(_ item: NSMenuItem) -> Bool {
        if let id = item.identifier?.rawValue, removedIdentifiers.contains(id) { return true }
        if navigationTags.contains(item.tag) { return true }
        if let action = item.action, removedActions.contains(NSStringFromSelector(action)) { return true }
        if let submenu = item.submenu, !submenu.items.isEmpty {
            // A submenu made only of font-panel items is the Font menu (it has no identifier).
            let content = submenu.items.filter { !$0.isSeparatorItem }
            return !content.isEmpty && content.allSatisfy { fontTags.contains($0.tag) || isRemoved($0) }
        }
        return fontTags.contains(item.tag)
    }

    /// Customises `menu` in place: drops what `isRemoved`, puts "Format" where the Font submenu was
    /// (or after the last of Spelling / Substitutions / Transformations when WebKit offered none),
    /// and tidies the separators. `perform` runs a Format command, `state` is the editor's.
    static func customize(
        _ menu: NSMenu, state: EditorMenuState, perform: @escaping @MainActor (FormatMenuItem) -> Void,
        remind: (@MainActor (ReminderScope) -> Void)? = nil,
        copyAs: CopyAsMenu? = nil
    ) {
        var insertAt: Int?
        for (index, item) in menu.items.enumerated().reversed() where isRemoved(item) {
            if item.submenu != nil { insertAt = index }
            menu.removeItem(at: index)
        }
        if let insertAt {
            menu.insertItem(formatItem(state: state, perform: perform), at: min(insertAt, menu.items.count))
        } else if let last = menu.items.lastIndex(where: { isTextToolsMenu($0) }) {
            menu.insertItem(formatItem(state: state, perform: perform), at: last + 1)
        }
        if let copyAs, state.canOpenLink { addCopyAs(copyAs, to: menu) }
        if let remind, state.canOpenLink { addReminderItems(to: menu, remind: remind) }
        tidySeparators(in: menu)
    }

    /// What the "Copy As" submenu runs and shows.
    struct CopyAsMenu {
        var perform: @MainActor (CopyAsFormat) -> Void
        var keepTags: Bool
        var setKeepTags: @MainActor (Bool) -> Void
    }

    /// "Copy As" right after WebKit's Copy (at the end of the first group when WebKit offered no Copy item).
    static func addCopyAs(_ copyAs: CopyAsMenu, to menu: NSMenu) {
        let submenu = NSMenu(title: copyAsTitle)
        for format in CopyAsFormat.allCases {
            submenu.addItem(ClosureMenuItem(title: format.title) { copyAs.perform(format) })
        }
        submenu.addItem(.separator())
        let keep = ClosureMenuItem(title: CopyAsKeepTags.title) { copyAs.setKeepTags(!copyAs.keepTags) }
        keep.state = copyAs.keepTags ? .on : .off
        submenu.addItem(keep)
        let parent = NSMenuItem(title: copyAsTitle, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        let copy = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        menu.insertItem(parent, at: copy.map { $0 + 1 } ?? menu.items.count)
    }

    /// The one reminder item, after a divider at the end of the menu. Shown whenever a note is shown
    /// (a read-only note takes reminders too; they are not part of the note).
    static func addReminderItems(to menu: NSMenu, remind: @escaping @MainActor (ReminderScope) -> Void) {
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: remindTitle) { remind(.line) })
    }

    /// Spelling and Grammar, Substitutions, Transformations: the submenus WebKit shows for editable text.
    private static func isTextToolsMenu(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue else {
            return item.submenu?.items.contains { (71...73).contains($0.tag) } ?? false
        }
        return id == "WKMenuItemIdentifierSpellingMenu" || id == "WKMenuItemIdentifierSubstitutionsMenu"
    }

    static func formatItem(state: EditorMenuState, perform: @escaping @MainActor (FormatMenuItem) -> Void) -> NSMenuItem {
        let submenu = NSMenu(title: formatTitle)
        // Our own enabled state: autoenabling would switch every item on again.
        submenu.autoenablesItems = false
        for title in formatTitles {
            guard let format = FormatMenu.items.first(where: { $0.title == title }) else { continue }
            let item = ClosureMenuItem(title: title) { perform(format) }
            if let shortcut = format.shortcut {
                item.keyEquivalent = String(shortcut.key.character)
                item.keyEquivalentModifierMask = format.modifierFlags
            }
            item.isEnabled = format.isEnabled(in: state)
            if format.isChecked(in: state.format) == true { item.state = .on }
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: formatTitle, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// No separator first, last or twice in a row (WebKit leaves empty groups behind, and removing
    /// items can too).
    static func tidySeparators(in menu: NSMenu) {
        for index in menu.items.indices.reversed() where menu.items[index].isSeparatorItem {
            let isFirst = index == 0
            let isLast = index == menu.items.count - 1
            let followsSeparator = index > 0 && menu.items[index - 1].isSeparatorItem
            if isFirst || isLast || followsSeparator { menu.removeItem(at: index) }
        }
    }
}
