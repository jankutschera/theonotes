// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import WebKit

/// The native menus of the editor's rich blocks (M6): a message from the page (`headingMenu`,
/// `calloutMenu`, `tableMenu`) names the block and where to show the menu; the host
/// checks the request against the shown note, builds the menu and answers with
/// `applyCommand {..., menuId}`, so each action lands on the block the user clicked even if the
/// text moved while the menu was open.
@MainActor
final class BlockMenus {
    weak var editor: EditorBridgeController?

    /// What the editor in this build implements; a stub feature's items stay disabled (tests set it).
    var features: EditorFeatures = .implemented
    /// Shows a menu at a rect in the page's viewport (tests replace it; the controller sets the
    /// web view's).
    var popUp: @MainActor (NSMenu, CaretRect) -> Void = { _, _ in }
    /// Whether the note is in the Trash (R16 does not resolve links to trashed notes).
    var isTrashed: @MainActor (_ noteId: String) -> Bool = { _ in false }

    /// Where Copy Link to Here writes.
    private var pasteboard: NSPasteboard { editor?.pasteboard ?? .general }

    // MARK: - Heading menu

    /// Shows the heading menu of `request`, when it names a heading of the shown note: the
    /// `noteId` is the shown note, `line` is within its text and that line is a heading of `level`.
    /// Anything else is ignored (the page may be stale); the log carries ids only.
    func showHeadingMenu(_ request: HeadingMenuRequest) {
        guard let editor, let session = editor.session, session.noteId == request.noteId else {
            editorLogger.debug("heading menu ignored: note \(request.noteId, privacy: .public) is not shown")
            return
        }
        let metadata = NoteParser.metadata(for: session.text)
        guard let heading = metadata.headings.first(where: { $0.line == request.line && $0.level == request.level }) else {
            editorLogger.debug(
                "heading menu ignored: note \(request.noteId, privacy: .public) line \(request.line) level \(request.level) is no heading")
            return
        }
        let earlier = metadata.headings.prefix { $0.line < heading.line }.map(\.text)
        popUp(
            headingMenu(
                for: request, title: metadata.title, heading: heading, earlierHeadings: earlier,
                trashed: isTrashed(request.noteId),
                canFold: Self.sectionHasText(session.text, heading: heading, headings: metadata.headings)),
            request.rect)
    }

    /// The link that reaches `heading` (`[[Title/Heading]]`), or the reason none does (the menu item's tooltip):
    /// the note is in the Trash, has no title, an earlier heading repeats this one's text, or the text cannot
    /// be spelled in a link.
    static func headingLink(
        title: String, heading: HeadingRef, earlierHeadings: [String], trashed: Bool
    ) -> (link: String?, unavailable: String?) {
        if trashed { return (nil, "the note is in the Trash") }
        switch NoteStore.headingLink(forTitle: title, heading: heading.text, earlierHeadings: earlierHeadings) {
        case .success(let text): return (text, nil)
        case .failure(.untitled): return (nil, "the note has no title")
        case .failure(.repeated): return (nil, "its text appears earlier in the note")
        case .failure(.unspellable): return (nil, "the note title or heading contains [ ] or |, or the title repeats a space")
        }
    }

    /// Plain text only, so it pastes as a wiki link everywhere.
    private func copyLink(_ link: String) {
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
    }

    /// Format > Copy Link to Here (the badge menu's item for the keyboard, M7-R22): copies the link of the
    /// heading on the caret's line. Returns whether a link was copied; when the caret is not in a heading, or no
    /// link can reach it (the badge menu's reasons), nothing is copied and the system beeps.
    @discardableResult
    func copyLinkToHereAtCaret() -> Bool {
        guard let editor, let session = editor.session, let caret = editor.status.selection?.head else {
            NSSound.beep()
            return false
        }
        let metadata = NoteParser.metadata(for: session.text)
        let line = Self.line(ofUTF16Offset: caret, in: session.text)
        guard let heading = metadata.headings.first(where: { $0.line == line }) else {
            editorLogger.debug("copy link ignored: the caret of note \(session.noteId, privacy: .public) is not in a heading")
            NSSound.beep()
            return false
        }
        let earlier = metadata.headings.prefix { $0.line < heading.line }.map(\.text)
        let (link, unavailable) = Self.headingLink(
            title: metadata.title, heading: heading, earlierHeadings: earlier, trashed: isTrashed(session.noteId))
        guard let link else {
            editorLogger.debug(
                "copy link ignored: note \(session.noteId, privacy: .public): \(unavailable ?? "no link", privacy: .public)")
            NSSound.beep()
            return false
        }
        copyLink(link)
        return true
    }

    /// The 1-based line holding the UTF-16 `offset` (clamped to the text).
    static func line(ofUTF16Offset offset: Int, in text: String) -> Int {
        let units = text.utf16
        let end = units.index(units.startIndex, offsetBy: max(0, min(offset, units.count)))
        return units[..<end].reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// Whether `heading` has anything to fold (the editor's rule, M6-R27): a non-blank line after
    /// it, before the next heading of the same or a higher level (or the end of the note).
    static func sectionHasText(_ text: String, heading: HeadingRef, headings: [HeadingRef]) -> Bool {
        let end = headings.first { $0.line > heading.line && $0.level <= heading.level }?.line ?? Int.max
        var line = 1
        var blank = true
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if line > heading.line, !blank { return true }
                line += 1
                blank = true
                if line >= end { return false }
            } else if !scalar.properties.isWhitespace {
                blank = false
            }
        }
        return line > heading.line && line < end && !blank
    }

    /// The heading menu: Fold / Unfold, Fold All / Unfold All Headings, Copy Link to Here and
    /// Heading Level ▸ H1…H6 (a checkmark on the current one). Folding and copying also work in
    /// read-only notes; the level items and their parent do not. Folding items are disabled until
    /// the editor implements folding. Copy Link to Here is disabled, with the reason as its tooltip,
    /// when no link would reach this heading: the note is in the Trash, has no title, an earlier
    /// heading repeats this one's text (R16 resolves to the first), or the text cannot be spelled
    /// in a link. `earlierHeadings` are the texts of the headings before this one.
    func headingMenu(
        for request: HeadingMenuRequest, title: String, heading: HeadingRef, earlierHeadings: [String] = [],
        trashed: Bool = false, canFold: Bool = true
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let menuId = CommandArgument.string(request.menuId)
        let folding = features.contains(.folding)

        let fold = ClosureMenuItem(title: request.folded ? "Unfold" : "Fold") { [weak self] in
            self?.editor?.apply(.toggleFold, args: ["menuId": menuId])
        }
        // A heading with an empty section has nothing to fold.
        fold.isEnabled = folding && (request.folded || canFold)
        menu.addItem(fold)
        let foldAll = ClosureMenuItem(title: "Fold All Headings") { [weak self] in self?.editor?.apply(.foldAll) }
        foldAll.isEnabled = folding
        menu.addItem(foldAll)
        let unfoldAll = ClosureMenuItem(title: "Unfold All Headings") { [weak self] in self?.editor?.apply(.unfoldAll) }
        unfoldAll.isEnabled = folding
        menu.addItem(unfoldAll)

        menu.addItem(.separator())
        let (link, unavailable) = Self.headingLink(title: title, heading: heading, earlierHeadings: earlierHeadings, trashed: trashed)
        let copy = ClosureMenuItem(title: FormatMenu.copyLinkToHereTitle) { [weak self] in
            guard let link else { return }
            self?.copyLink(link)
        }
        copy.isEnabled = link != nil
        copy.toolTip = unavailable.map { "This heading can't be linked: \($0)" }
        menu.addItem(copy)

        menu.addItem(.separator())
        let editable = editor?.status.isEditable ?? false
        let levels = NSMenu()
        levels.autoenablesItems = false
        for level in 1...6 {
            let item = ClosureMenuItem(title: "Heading \(level)") { [weak self] in
                self?.editor?.apply(.heading, args: ["level": .int(level), "menuId": menuId])
            }
            item.state = level == heading.level ? .on : .off
            item.isEnabled = editable
            levels.addItem(item)
        }
        let levelItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
        levelItem.submenu = levels
        levelItem.isEnabled = editable
        menu.addItem(levelItem)
        return menu
    }

    // MARK: - Callout menu

    /// Shows the type menu of `request` when it comes from the shown note. The host does not
    /// re-parse the callout: the choice goes back with the request's `menuId`, which the editor
    /// resolves to the callout's first line (or drops when that text is gone).
    func showCalloutMenu(_ request: CalloutMenuRequest) {
        guard let editor, let session = editor.session, session.noteId == request.noteId else {
            editorLogger.debug("callout menu ignored: note \(request.noteId, privacy: .public) is not shown")
            return
        }
        popUp(calloutMenu(for: request), request.rect)
    }

    /// Bear's five callout types, in its menu order.
    static let calloutTypes: [(type: CalloutType, title: String)] = [
        (.note, "Note"), (.tip, "Tip"), (.important, "Important"), (.warning, "Warning"), (.caution, "Caution"),
    ]

    /// The callout type menu: one item per type, a checkmark on the current one; choosing one sends
    /// `setCalloutType {type, menuId}`. Disabled in read-only notes.
    func calloutMenu(for request: CalloutMenuRequest) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let editable = editor?.status.isEditable ?? false
        let menuId = CommandArgument.string(request.menuId)
        for (type, title) in Self.calloutTypes {
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.editor?.apply(.setCalloutType, args: ["type": .string(type.rawValue), "menuId": menuId])
            }
            item.state = type == request.calloutType ? .on : .off
            item.isEnabled = editable
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Table menu

    /// Shows the cell menu of `request` when it comes from the shown note. As with the callout
    /// menu, the host does not parse the table: every item goes back with the request's `menuId`,
    /// which the editor resolves to the clicked cell (or drops when that text is gone). The
    /// request's counts only decide which move items make sense.
    func showTableMenu(_ request: TableMenuRequest) {
        guard let editor, let session = editor.session, session.noteId == request.noteId else {
            editorLogger.debug("table menu ignored: note \(request.noteId, privacy: .public) is not shown")
            return
        }
        popUp(tableMenu(for: request), request.rect)
    }

    /// The cell menu: Add Row, Add Column, Delete Row, Delete Column, the four moves and
    /// Copy Table As ▸ CSV / HTML / Markdown. Each item sends its command with the `menuId`. The
    /// editing items (and so the moves) are disabled in read-only notes; copying is not an edit and
    /// stays on. Moves that cannot happen are disabled as well: the header (row 0) never moves and
    /// nothing moves into it, and a column at either edge cannot move outwards (M6-R33, R34).
    func tableMenu(for request: TableMenuRequest) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tables = features.contains(.tables)
        let editable = tables && (editor?.status.isEditable ?? false)
        let menuId = CommandArgument.string(request.menuId)

        func add(_ title: String, _ command: EditorCommandName, _ extra: [String: CommandArgument] = [:], to menu: NSMenu, enabled: Bool) {
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.editor?.apply(command, args: extra.merging(["menuId": menuId]) { $1 })
            }
            item.isEnabled = enabled
            menu.addItem(item)
        }

        add("Add Row", .tableAddRow, to: menu, enabled: editable)
        add("Add Column", .tableAddColumn, to: menu, enabled: editable)
        add("Delete Row", .tableDeleteRow, to: menu, enabled: editable)
        add("Delete Column", .tableDeleteColumn, to: menu, enabled: editable)
        menu.addItem(.separator())
        add("Move Row Up", .tableMoveRow, ["direction": .string("up")], to: menu, enabled: editable && request.row > 1)
        add(
            "Move Row Down", .tableMoveRow, ["direction": .string("down")], to: menu,
            enabled: editable && request.row >= 1 && request.row < request.rows - 1)
        add("Move Column Left", .tableMoveColumn, ["direction": .string("left")], to: menu, enabled: editable && request.column > 0)
        add(
            "Move Column Right", .tableMoveColumn, ["direction": .string("right")], to: menu,
            enabled: editable && request.column < request.columns - 1)
        menu.addItem(.separator())

        let copy = NSMenu()
        copy.autoenablesItems = false
        for (title, format) in [("CSV", "csv"), ("HTML", "html"), ("Markdown", "markdown")] {
            add(title, .copyTable, ["format": .string(format)], to: copy, enabled: tables)
        }
        let copyItem = NSMenuItem(title: FormatMenu.copyTableTitle, action: nil, keyEquivalent: "")
        copyItem.submenu = copy
        copyItem.isEnabled = tables
        menu.addItem(copyItem)
        return menu
    }

    // MARK: - Showing

    /// Pops `menu` up under `rect` (page viewport CSS px) in `webView`.
    static func present(_ menu: NSMenu, at rect: CaretRect, in webView: WKWebView) {
        guard webView.window != nil else { return }
        let zoom = webView.pageZoom * webView.magnification
        let anchor = LinkPanel.anchorRect(rect, bounds: webView.bounds, isFlipped: webView.isFlipped, zoom: zoom)
        menu.popUp(
            positioning: nil, at: NSPoint(x: anchor.minX, y: webView.isFlipped ? anchor.maxY : anchor.minY), in: webView)
    }
}
