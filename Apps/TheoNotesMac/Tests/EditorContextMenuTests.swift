// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Testing
import WebKit
@testable import TheoNotes

/// The editor's right-click menu: WebKit's Font submenu and page items are gone, "Format"
/// runs the Format menu bar's commands, the rest of WebKit's menu stays.
@MainActor
@Suite struct EditorContextMenuTests {
    // MARK: - A menu shaped like WebKit's

    private static let forwardName = "forwardContextMenuAction:"

    /// A WebKit item as the live test below saw it: `WKMenuItemIdentifier…` (or the action name for
    /// the ones WebKit gives no identifier), WebCore's action as the tag.
    private static func web(_ title: String, _ id: String?, _ tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(forwardName), keyEquivalent: "")
        item.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        item.tag = tag
        return item
    }

    private static func sub(_ title: String, _ id: String?, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString("submenuAction:"), keyEquivalent: "")
        item.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func webKitEditableMenu() -> NSMenu {
        let f = forwardName
        let share = NSMenuItem(title: "Share…", action: NSSelectorFromString("performShare:"), keyEquivalent: "")
        share.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierShareMenu")
        let menu = NSMenu()
        [
            web("Look Up “hello”", "WKMenuItemIdentifierLookUp", 22),
            web("Translate “hello”", "WKMenuItemIdentifierTranslate", 95),
            .separator(),
            web("Search with Google", "WKMenuItemIdentifierSearchWeb", 21),
            .separator(),
            web("Cut", f, 13),
            web("Copy", "WKMenuItemIdentifierCopy", 8),
            web("Paste", "WKMenuItemIdentifierPaste", 14),
            .separator(),
            .separator(),
            sub("Spelling and Grammar", "WKMenuItemIdentifierSpellingMenu", [
                web("Show Spelling and Grammar", "WKMenuItemIdentifierShowSpellingPanel", 36),
                web("Check Document Now", "WKMenuItemIdentifierCheckSpelling", 37),
            ]),
            sub("Substitutions", "WKMenuItemIdentifierSubstitutionsMenu", [
                web("Show Substitutions", "WKMenuItemIdentifierShowSubstitutions", 64),
                web("Smart Quotes", "WKMenuItemIdentifierSmartQuotes", 66),
            ]),
            sub("Transformations", nil, [
                web("Make Upper Case", f, 71), web("Make Lower Case", f, 72), web("Capitalize", f, 73),
            ]),
            sub("Font", nil, [
                web("Show Fonts", f, 41), .separator(),
                web("Bold", f, 42), web("Italic", f, 43), web("Underline", f, 44), .separator(),
                web("Outline", f, 45), web("Styles…", f, 46), web("Show Colors", f, 47),
            ]),
            sub("Speech", "WKMenuItemIdentifierSpeechMenu", [web("Start Speaking", f, 49), web("Stop Speaking", f, 50)]),
            sub("Paragraph Direction", nil, [web("Default", f, 52), web("Left to Right", f, 53)]),
            .separator(),
            share,
        ].forEach(menu.addItem)
        return menu
    }

    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private static func allTitles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { [$0.title] + ($0.submenu.map(allTitles) ?? []) }
    }

    private static let enabled = EditorMenuState(enabled: true, format: .plain)

    private func formatItems(_ menu: NSMenu) throws -> [NSMenuItem] {
        try #require(menu.items.first { $0.title == "Format" }?.submenu).items
    }

    private func barItem(_ title: String) throws -> FormatMenuItem {
        try #require(FormatMenu.items.first { $0.title == title }, "\(title)")
    }

    @Test func theFontSubmenuBecomesFormatAndTheRestStays() throws {
        let menu = Self.webKitEditableMenu()
        EditorContextMenu.customize(menu, state: Self.enabled, perform: { _ in })
        #expect(Self.titles(menu) == [
            "Look Up “hello”", "Translate “hello”", "-", "Search with Google", "-", "Cut", "Copy", "Paste", "-",
            "Spelling and Grammar", "Substitutions", "Transformations", "Format", "Speech", "Paragraph Direction", "-", "Share…",
        ])
        let everything = Self.allTitles(menu)
        for gone in ["Font", "Show Fonts", "Show Colors", "Outline", "Styles…"] {
            #expect(!everything.contains(gone), "\(gone)")
        }
        #expect(try formatItems(menu).map(\.title) == ["Bold", "Italic", "Underline", "Strikethrough", "Highlight", "Inline Code"])
        // WebKit's other submenus keep their items.
        #expect(menu.items.first { $0.title == "Transformations" }?.submenu?.items.count == 3)
        #expect(menu.items.first { $0.title == "Speech" }?.submenu?.items.count == 2)
        #expect(menu.items.first { $0.title == "Spelling and Grammar" }?.submenu?.items.count == 2)
    }

    @Test func pageItemsGoAndSeparatorsAreTidied() {
        let menu = NSMenu()
        [
            Self.web("Go Back", "WKMenuItemIdentifierGoBack", 9), Self.web("Go Forward", "WKMenuItemIdentifierGoForward", 10),
            Self.web("Reload", "WKMenuItemIdentifierReload", 12), .separator(),
            Self.web("Inspect Element", "WKMenuItemIdentifierInspectElement", 16), .separator(),
            Self.web("Copy", "WKMenuItemIdentifierCopy", 8),
        ].forEach(menu.addItem)
        EditorContextMenu.customize(menu, state: Self.enabled, perform: { _ in })
        #expect(Self.titles(menu) == ["Copy"])
        // The tag alone is enough when WebKit gives no identifier.
        let bare = NSMenu()
        [Self.web("Reload", nil, 12), Self.web("Copy", "WKMenuItemIdentifierCopy", 8)].forEach(bare.addItem)
        EditorContextMenu.customize(bare, state: Self.enabled, perform: { _ in })
        #expect(Self.titles(bare) == ["Copy"])
    }

    @Test func reminderItemsCloseTheMenuAndRunTheirScope() {
        var shown = Self.enabled
        shown.canOpenLink = true
        var scopes: [ReminderScope] = []
        let menu = NSMenu()
        menu.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        EditorContextMenu.customize(menu, state: shown, perform: { _ in }, remind: { scopes.append($0) })
        #expect(Self.titles(menu) == ["Copy", "-", "Remind Me…"])
        for item in menu.items.suffix(1) {
            if let item = item as? ClosureMenuItem { _ = item.target?.perform(item.action, with: item) }
        }
        // The caret's line goes with it; the sheet offers the whole note too.
        #expect(scopes == [.line])

        // No note shown, or no handler: no reminder items.
        let none = NSMenu()
        none.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        EditorContextMenu.customize(none, state: Self.enabled, perform: { _ in }, remind: { _ in })
        #expect(Self.titles(none) == ["Copy"])
        let noHandler = NSMenu()
        noHandler.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        EditorContextMenu.customize(noHandler, state: shown, perform: { _ in })
        #expect(Self.titles(noHandler) == ["Copy"])
    }

    @Test func copyAsSitsRightAfterCopyAndRunsItsFormats() throws {
        var shown = Self.enabled
        shown.canOpenLink = true
        var ran: [CopyAsFormat] = []
        var keep = true
        let menu = NSMenu()
        [Self.web("Cut", "WKMenuItemIdentifierCut", 13), Self.web("Copy", "WKMenuItemIdentifierCopy", 8),
         Self.web("Paste", "WKMenuItemIdentifierPaste", 14)].forEach(menu.addItem)
        EditorContextMenu.customize(
            menu, state: shown, perform: { _ in },
            copyAs: .init(perform: { ran.append($0) }, keepTags: keep, setKeepTags: { keep = $0 }))
        #expect(Self.titles(menu) == ["Cut", "Copy", "Copy As", "Paste"])
        let submenu = try #require(menu.items.first { $0.title == "Copy As" }?.submenu)
        #expect(submenu.items.map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Markdown", "Plain Text", "HTML", "Rich Text", "-", "Keep Tags",
        ])
        for item in submenu.items where !item.isSeparatorItem && item.title != "Keep Tags" {
            if let item = item as? ClosureMenuItem { _ = item.target?.perform(item.action, with: item) }
        }
        #expect(ran == CopyAsFormat.allCases)
        // Keep Tags shows the stored value and flips it.
        let toggle = try #require(submenu.items.last as? ClosureMenuItem)
        #expect(toggle.state == .on)
        _ = toggle.target?.perform(toggle.action, with: toggle)
        #expect(!keep)
    }

    @Test func copyAsIsLeftOutWhenNoNoteIsShownOrNothingHandlesIt() {
        let menu = NSMenu()
        menu.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        EditorContextMenu.customize(
            menu, state: Self.enabled, perform: { _ in },
            copyAs: .init(perform: { _ in }, keepTags: true, setKeepTags: { _ in }))
        #expect(Self.titles(menu) == ["Copy"])
        let none = NSMenu()
        none.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        var shown = Self.enabled
        shown.canOpenLink = true
        EditorContextMenu.customize(none, state: shown, perform: { _ in })
        #expect(Self.titles(none) == ["Copy"])
    }

    @Test func fontPanelSelectorsAreRemovedWhateverTheirTag() {
        let menu = NSMenu()
        for selector in ["orderFrontFontPanel:", "orderFrontColorPanel:", "raiseBaseline:", "tightenKerning:", "useAllLigatures:"] {
            menu.addItem(NSMenuItem(title: selector, action: NSSelectorFromString(selector), keyEquivalent: ""))
        }
        menu.addItem(Self.web("Copy", "WKMenuItemIdentifierCopy", 8))
        EditorContextMenu.customize(menu, state: Self.enabled, perform: { _ in })
        #expect(Self.titles(menu) == ["Copy"])
    }

    // MARK: - Format runs the Format menu's commands

    @Test func formatItemsCarryTheMenuBarShortcutsAndRunItsItems() throws {
        var performed: [FormatMenuItem] = []
        let menu = Self.webKitEditableMenu()
        EditorContextMenu.customize(menu, state: Self.enabled, perform: { performed.append($0) })
        let items = try formatItems(menu)
        #expect(items.map(\.keyEquivalent) == ["b", "i", "u", "u", "m", "c"])
        for item in items {
            let bar = try barItem(item.title)
            #expect(item.keyEquivalentModifierMask == bar.modifierFlags, "\(item.title)")
            #expect(item.isEnabled, "\(item.title)")
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item), "\(item.title)")
        }
        #expect(performed == (try items.map { try barItem($0.title) }))
    }

    @Test func formatItemsFollowTheMenuBarsEnabledStateAndCheckmarks() throws {
        func format(_ state: EditorMenuState) throws -> [NSMenuItem] {
            let menu = Self.webKitEditableMenu()
            EditorContextMenu.customize(menu, state: state, perform: { _ in })
            return try formatItems(menu)
        }
        // Read-only / Trash / Archive, or no editor: all off.
        #expect(try format(.unavailable).allSatisfy { !$0.isEnabled })
        // Inside a code span: the styles are off, Inline Code stays on (it removes the span).
        let inCode = FormatState(active: [.inlineCode], headingLevel: nil, inTodo: false, inCode: true, canIndent: false)
        let code = try format(EditorMenuState(enabled: true, format: inCode))
        #expect(code.map(\.isEnabled) == [false, false, false, false, false, true])
        #expect(code.last?.state == .on)
        // Checkmarks follow the selection's styles.
        let styles = FormatState(active: [.bold, .highlight], headingLevel: nil, inTodo: false, inCode: false, canIndent: false)
        let styled = try format(EditorMenuState(enabled: true, format: styles))
        #expect(styled.map(\.state) == [.on, .off, .off, .off, .on, .off])
    }

    // MARK: - Through the editor

    @Test func formatItemsRunTheSameEditorCommandsAsTheMenuBar() throws {
        let env = try FormatCommandsTests.Env()
        let menu = Self.webKitEditableMenu()
        EditorContextMenu.customize(
            menu, state: env.editor.menuState(editorFocused: true), perform: { env.editor.performFormat($0) })
        for item in try formatItems(menu) {
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        let fromContextMenu = env.commands
        #expect(fromContextMenu == [
            .applyCommand(name: .bold), .applyCommand(name: .italic), .applyCommand(name: .underline),
            .applyCommand(name: .strike), .applyCommand(name: .highlight), .applyCommand(name: .inlineCode),
        ])
        // The menu bar's path (`FormatTarget.perform`) for the same six items delivers the same.
        for title in EditorContextMenu.formatTitles { env.state.perform(try barItem(title)) }
        #expect(Array(env.commands.dropFirst(fromContextMenu.count)) == fromContextMenu)
    }

    @Test func aReadOnlyNoteHasNoEnabledFormatItems() throws {
        let env = try FormatCommandsTests.Env(readOnly: true)
        let state = env.editor.menuState(editorFocused: true)
        #expect(!state.enabled)
        let menu = Self.webKitEditableMenu()
        EditorContextMenu.customize(menu, state: state, perform: { env.editor.performFormat($0) })
        #expect(try formatItems(menu).allSatisfy { !$0.isEnabled })
    }

    // MARK: - WebKit's real menu

    /// A real right-click in a real WebKit page: WebKit builds the menu in its web process and AppKit
    /// calls `willOpenMenu` on the web view. The synthetic menus above are modelled on what this saw;
    /// if a macOS release changes WebKit's identifiers or tags, this is the test that fails.
    /// A synthetic right-click needs a live window server: it is unreliable in a test host on a
    /// locked or busy screen (R34), so it runs only with `BAERCHEN_GUI_TESTS=1` on an unlocked screen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_GUI_TESTS"] == "1"))
    func aRealRightClickInAnEditablePageHasNoFontMenuButFormat() async throws {
        let env = try FormatCommandsTests.Env()
        let webView = TheoNotesWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: WKWebViewConfiguration())
        webView.formatHost = env.editor
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        var opened: [[String]] = []
        var formatKeys: [String] = []
        webView.menuCustomized = { menu in
            opened.append(Self.allTitles(menu))
            formatKeys = menu.items.first { $0.title == "Format" }?.submenu?.items.map(\.keyEquivalent) ?? []
            DispatchQueue.main.async { menu.cancelTracking() }
        }
        let script = "var r=document.createRange();r.selectNodeContents(e);var s=getSelection();s.removeAllRanges();s.addRange(r);e.focus();"
        webView.loadHTMLString(
            "<html><body style='margin:0;min-height:400px'><div id=e contenteditable style='font-size:30px;height:100px'>hello world</div>"
                + "<p style='margin:0;height:100px'>plain</p><script>\(script)</script></body></html>", baseURL: nil)
        try await Task.sleep(for: .seconds(2))
        window.makeFirstResponder(webView)
        func rightClick(x: CGFloat, y: CGFloat, number: Int) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try rightClick(x: 40, y: 360, number: 1)
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let editable = try #require(opened.first, "WebKit opened no context menu")
        for gone in ["Font", "Show Fonts", "Show Colors", "Reload", "Inspect Element", "Go Back", "Go Forward", "Bigger", "Smaller"] {
            #expect(!editable.contains(gone), "\(gone) in \(editable)")
        }
        #expect(editable.contains("Format"))
        for kept in ["Cut", "Copy", "Paste", "Spelling and Grammar", "Substitutions", "Transformations", "Speech"] {
            #expect(editable.contains(kept), "\(kept) missing in \(editable)")
        }
        #expect(formatKeys == ["b", "i", "u", "u", "m", "c"])
        // Outside the editable text a web page's menu has Reload; it must not show.
        try await Task.sleep(for: .milliseconds(500))
        try rightClick(x: 300, y: 40, number: 2)
        try await Task.sleep(for: .seconds(2))
        #expect(opened.count == 2, "WebKit opened no menu outside the editable text")
        #expect(opened.dropFirst().flatMap { $0 }.isEmpty, "\(opened)")
    }
}
