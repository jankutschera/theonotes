// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// The real `MainWindow` hosted in an offscreen window (never ordered front, never key): keyboard
/// focus read from AppKit, the delete keys in the note list, layouts and the way back to the sidebar.
@MainActor
@Suite(.serialized) struct MainWindowChromeTests {
    @MainActor
    final class Hosted {
        /// SwiftUI keeps a hosted window's state (and so its open database) alive after the window
        /// closes, and a live environment reacts to every later database change notification. So
        /// the libraries stay until the next run of this suite clears them.
        private static let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesChromeTests", isDirectory: true)
        private static var clearedPreviousRun = false

        let root: URL
        let suiteName = "TheoNotesChromeTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState
        let window: NSWindow
        var noteIDs: [String] = []

        init(storedLayout: String? = nil) async throws {
            if !Self.clearedPreviousRun {
                try? FileManager.default.removeItem(at: Self.parent)
                Self.clearedPreviousRun = true
            }
            root = Self.parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            let now = Date()
            for (index, text) in ["Alpha", "Beta", "Gamma"].enumerated() {
                noteIDs.append(try environment.store.create(text: text, now: now.addingTimeInterval(-Double(index))).id)
            }
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(storedLayout, forKey: "MainWindow.layout")
            editor = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
            )
            _ = editor.handle(.ready(version: 1))
            state = MainWindowState(environment: environment, defaults: defaults, editor: editor)

            let controller = NSHostingController(rootView: MainWindow(state: state))
            controller.sceneBridgingOptions = [.toolbars]
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1100, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(CGSize(width: 1100, height: 600))
            try await settle()
        }

        func close() {
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suiteName)
        }

        func settle() async throws {
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(80))
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }

        private var splitView: NSSplitView? {
            func find(_ view: NSView) -> NSSplitView? {
                (view as? NSSplitView) ?? view.subviews.lazy.compactMap(find).first
            }
            return window.contentView.flatMap(find)
        }

        /// Sidebar, note list, editor.
        var collapsed: [Bool] {
            guard let splitView else { return [] }
            return splitView.arrangedSubviews.map(splitView.isSubviewCollapsed)
        }

        /// The visible table views, left to right (the sidebar's first while it is shown).
        var tables: [NSTableView] {
            func find(_ view: NSView) -> [NSTableView] {
                ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(find)
            }
            return (window.contentView.map(find) ?? [])
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width > 0 && $0.visibleRect.height > 0 }
                .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }

        var noteListTable: NSTableView? { tables.last }

        var toolbarIdentifiers: [String] { (window.toolbar?.items ?? []).map(\.itemIdentifier.rawValue) }

        /// What the toolbar's sidebar button sends.
        func toggleSidebar() async throws {
            #expect(window.contentView?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil) == true)
            try await settle()
        }

        var noteListItem: NSSplitViewItem? {
            (splitView?.delegate as? NSSplitViewController)?.splitViewItems[1]
        }

        func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], repeat isARepeat: Bool = false) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: isARepeat, keyCode: keyCode
            )!
        }
    }

    /// A key event for the window: `characters` as the key types them.
    func textKey(_ hosted: Hosted, _ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    private static let toggleSidebarItem = "com.apple.SwiftUI.navigationSplitView.toggleSidebar"

    // MARK: - Keyboard focus and the delete keys

    @Test func noteListFocusIsReadFromTheFirstResponder() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let tables = hosted.tables
        try #require(tables.count == 2)
        let (sidebar, list) = (tables[0], tables[1])

        #expect(hosted.window.makeFirstResponder(list))
        #expect(hosted.state.bridge.isNoteListFocused)
        #expect(hosted.state.bridge.isNoteListFirstResponder(in: hosted.window))

        #expect(hosted.window.makeFirstResponder(sidebar))
        #expect(!hosted.state.bridge.isNoteListFocused)

        #expect(hosted.window.makeFirstResponder(hosted.editor.webView))
        #expect(!hosted.state.bridge.isNoteListFocused)
        #expect(!hosted.state.bridge.isNoteListFirstResponder(in: hosted.window))
    }

    /// M7 Task 12: → on a section row moves keyboard focus from the sidebar to the note list.
    @Test func rightArrowInTheSidebarMovesFocusToTheList() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        hosted.window.makeKeyAndOrderFront(nil)
        let tables = hosted.tables
        try #require(tables.count == 2)
        #expect(hosted.window.makeFirstResponder(tables[0]))
        try await hosted.settle()
        let arrow = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: hosted.window.windowNumber, context: nil, characters: arrow,
            charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 124))
        hosted.window.sendEvent(event)
        try await hosted.settle()
        #expect(hosted.state.bridge.isNoteListFirstResponder(in: hosted.window))
    }

    @Test func deleteKeysInTheNoteListMoveTheSelectionToTheTrash() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let model = hosted.state.model
        let monitor = try #require(hosted.state.installKeyMonitor())
        defer { NSEvent.removeMonitor(monitor) }
        let list = try #require(hosted.noteListTable)
        #expect(hosted.window.makeFirstResponder(list))

        // ⌘⌫ through the app's event dispatch: the monitor takes it before any menu.
        model.selectNotes([hosted.noteIDs[0]])
        NSApp.sendEvent(hosted.key(NoteListKeys.delete, .command))
        #expect(model.counts.trash == 1)
        #expect(!model.items.map(\.id).contains(hosted.noteIDs[0]))

        model.selectNotes([hosted.noteIDs[1]])
        #expect(hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete)))
        model.selectNotes([hosted.noteIDs[2]])
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, [.command, .shift]))) // Empty Trash…
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, [.command, .option])))
        #expect(hosted.state.handleKeyDown(hosted.key(NoteListKeys.forwardDelete, .function)))
        #expect(model.counts.trash == 3)

        // In the Trash, ⌘⌫ has nothing to do and passes on.
        model.selectScope(.trash)
        model.selectNotes([hosted.noteIDs[0]])
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command)))
    }

    @Test func commandDeleteInTheEditorIsNotATrashCommand() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let model = hosted.state.model
        model.selectNotes([hosted.noteIDs[0]])
        #expect(hosted.window.makeFirstResponder(hosted.editor.webView))

        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command)))
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete)))
        #expect(model.counts.trash == 0)

        let sidebar = try #require(hosted.tables.first)
        #expect(hosted.window.makeFirstResponder(sidebar))
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command)))
        #expect(model.counts.trash == 0)
    }

    /// One owner per shortcut: with the editor focused, the app's key monitor runs the Format
    /// menu's command before WebKit (and CodeMirror's own ⌘I/⌘U bindings) can see the key.
    @Test func formatShortcutsInTheEditorRunTheFormatCommand() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let monitor = try #require(hosted.state.installKeyMonitor())
        defer { NSEvent.removeMonitor(monitor) }
        hosted.state.model.selectNotes([hosted.noteIDs[0]])
        try await hosted.settle()
        let commands = { hosted.page.delivered.filter { if case .applyCommand = $0 { true } else { false } } }

        #expect(hosted.window.makeFirstResponder(hosted.editor.webView))
        #expect(hosted.state.bridge.isEditorFocused)
        #expect(hosted.state.editorMenuState.enabled)
        NSApp.sendEvent(textKey(hosted, "b", 11, .command))
        NSApp.sendEvent(textKey(hosted, "&", 26, [.command, .shift]))
        #expect(commands() == [.applyCommand(name: .bold), .applyCommand(name: .insertDate, args: ["style": .string("longTime")])])

        // In the note list the Format menu is off and ⌘B is not routed to the editor.
        let list = try #require(hosted.noteListTable)
        #expect(hosted.window.makeFirstResponder(list))
        #expect(!hosted.state.bridge.isEditorFocused)
        #expect(!hosted.state.editorMenuState.enabled)
        #expect(!hosted.state.handleKeyDown(textKey(hosted, "b", 11, .command)))
        #expect(commands().count == 2)
    }

    @Test func holdingDeleteTrashesOneNote() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let model = hosted.state.model
        let list = try #require(hosted.noteListTable)
        #expect(hosted.window.makeFirstResponder(list))

        model.selectNotes([hosted.noteIDs[0]])
        #expect(hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete)))
        #expect(model.counts.trash == 1)
        // The repeats that follow are swallowed (so the menu's ⌘⌫ can't take them either).
        #expect(hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, repeat: true)))
        #expect(hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command, repeat: true)))
        #expect(model.counts.trash == 1)
    }

    /// A text field over the note list column (e.g. a future rename or search field): its field
    /// editor is the first responder, not the list's table view.
    @Test func deleteInATextFieldIsNotATrashCommand() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let model = hosted.state.model
        model.selectNotes([hosted.noteIDs[0]])
        let list = try #require(hosted.noteListTable)
        let column = list.convert(list.visibleRect, to: nil)
        let field = NSTextField(frame: CGRect(x: column.midX - 50, y: column.midY - 11, width: 100, height: 22))
        field.stringValue = "rename"
        let content = try #require(hosted.window.contentView)
        content.addSubview(field)
        defer { field.removeFromSuperview() }

        #expect(hosted.window.makeFirstResponder(field))
        #expect(hosted.window.firstResponder is NSTextView) // the field editor
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete)))
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command)))
        #expect(!hosted.state.bridge.isNoteListFocused)
        #expect(model.counts.trash == 0)
    }

    @Test func aCollapsedNoteListIsNotFocused() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let model = hosted.state.model
        model.selectNotes([hosted.noteIDs[0]])
        let list = try #require(hosted.noteListTable)
        #expect(hosted.window.makeFirstResponder(list))
        #expect(hosted.state.bridge.isNoteListFocused)

        hosted.state.setLayout(.editorOnly) // ⌃1 moves keyboard focus into the editor
        try await hosted.settle()
        let responder = try #require(hosted.window.firstResponder as? NSView)
        #expect(responder === hosted.editor.webView || responder.isDescendant(of: hosted.editor.webView))
        #expect(!hosted.state.bridge.isNoteListFocused)

        // Even if the hidden table gets first responder back, its keys don't trash.
        hosted.window.makeFirstResponder(list)
        #expect(!hosted.state.bridge.isNoteListFocused)
        #expect(!hosted.state.handleKeyDown(hosted.key(NoteListKeys.delete, .command)))
        #expect(model.counts.trash == 0)
    }

    @Test func trashKeys() {
        #expect(NoteListKeys.isTrashKey(keyCode: 51, modifiers: .command))
        #expect(NoteListKeys.isTrashKey(keyCode: 51, modifiers: []))
        #expect(NoteListKeys.isTrashKey(keyCode: 51, modifiers: .capsLock))
        #expect(NoteListKeys.isTrashKey(keyCode: 117, modifiers: .function))
        #expect(!NoteListKeys.isTrashKey(keyCode: 117, modifiers: .command))
        #expect(!NoteListKeys.isTrashKey(keyCode: 51, modifiers: [.command, .shift]))
        #expect(!NoteListKeys.isTrashKey(keyCode: 51, modifiers: .control))
        #expect(!NoteListKeys.isTrashKey(keyCode: 0, modifiers: .command))
    }

    /// GUI-gate F5 with the real window: ⌘N from the focused note list leaves keyboard focus in
    /// the editor, also after SwiftUI selected the new row.
    @Test func newNoteMovesKeyboardFocusFromTheListToTheEditor() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let list = try #require(hosted.noteListTable)
        #expect(hosted.window.makeFirstResponder(list))

        hosted.state.newNote()
        try await hosted.settle()
        let responder = try #require(hosted.window.firstResponder as? NSView)
        #expect(responder === hosted.editor.webView || responder.isDescendant(of: hosted.editor.webView))
        #expect(!hosted.state.bridge.isNoteListFocused)
    }

    // MARK: - Layouts and the way back to the sidebar

    @Test func editorOnlyIsNeverRestored() {
        #expect(MainWindowState.restoredLayout("editorOnly") == .all)
        #expect(MainWindowState.restoredLayout("notesAndEditor") == .notesAndEditor)
        #expect(MainWindowState.restoredLayout("all") == .all)
        #expect(MainWindowState.restoredLayout(nil) == .all)
        #expect(MainWindowState.restoredLayout("bogus") == .all)
    }

    @Test(arguments: [nil, "all", "notesAndEditor", "editorOnly"])
    func everyRestoredLayoutOffersTheSidebarToggle(storedLayout: String?) async throws {
        let hosted = try await Hosted(storedLayout: storedLayout)
        defer { hosted.close() }
        #expect(hosted.toolbarIdentifiers.contains(Self.toggleSidebarItem))
        #expect(hosted.collapsed[1] == false) // the note list is always back after a launch
    }

    @Test func aRestoredHiddenSidebarComesBackWithShowSidebar() async throws {
        let hosted = try await Hosted(storedLayout: "notesAndEditor")
        defer { hosted.close() }
        #expect(hosted.state.layout == .notesAndEditor)
        #expect(hosted.collapsed == [true, false, false])

        try await hosted.toggleSidebar()
        #expect(hosted.collapsed == [false, false, false])
        #expect(hosted.state.layout == .all)
        #expect(hosted.defaults.string(forKey: "MainWindow.layout") == "all")
    }

    @Test func layoutPresetsCollapseTheColumns() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let state = hosted.state
        #expect(hosted.collapsed == [false, false, false])

        state.setLayout(.editorOnly)
        try await hosted.settle()
        #expect(hosted.collapsed == [true, true, false])
        #expect(state.layout == .editorOnly)
        #expect(hosted.defaults.string(forKey: "MainWindow.layout") == "editorOnly")
        #expect(hosted.toolbarIdentifiers.contains(Self.toggleSidebarItem))

        state.setLayout(.editorOnly) // choosing it again keeps it
        try await hosted.settle()
        #expect(hosted.collapsed == [true, true, false])

        state.setLayout(.notesAndEditor)
        try await hosted.settle()
        #expect(hosted.collapsed == [true, false, false])
        #expect(state.layout == .notesAndEditor)

        state.setLayout(.all)
        try await hosted.settle()
        #expect(hosted.collapsed == [false, false, false])
        #expect(hosted.noteListItem?.canCollapse == false) // its own value, restored

        // From editor only, the toolbar's sidebar button brings back the sidebar and the note list.
        state.setLayout(.editorOnly)
        try await hosted.settle()
        try await hosted.toggleSidebar()
        #expect(hosted.collapsed == [false, false, false])
        #expect(state.layout == .all)
    }

    @Test func viewMenuOffersTheLayoutsAndNoSidebarItem() throws {
        let view = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        // A7: the toolbar toggle and the layout presets cover the sidebar; View has no Show Sidebar (⌃⌘S) item.
        #expect(!view.items.contains { $0.action == #selector(NSSplitViewController.toggleSidebar(_:)) })
        #expect(!view.items.contains { $0.title == "Show Sidebar" || $0.title == "Hide Sidebar" })
        for (title, key) in [("Show Editor Only", "1"), ("Show Notes and Editor", "2"), ("Show Tags, Notes and Editor", "3")] {
            let item = try #require(view.items.first { $0.title == title })
            #expect(item.keyEquivalent == key && item.keyEquivalentModifierMask == .control)
        }
    }

    @Test func editorOnlySurvivesARelayoutAndFollowsTheRealColumns() async throws {
        let hosted = try await Hosted()
        defer { hosted.close() }
        let state = hosted.state
        state.setLayout(.editorOnly)
        try await hosted.settle()

        hosted.window.setContentSize(CGSize(width: 820, height: 500))
        try await hosted.settle()
        state.model.selectScope(.trash)
        state.model.selectScope(.notes)
        state.model.selectNotes([hosted.noteIDs[1]])
        hosted.window.setContentSize(CGSize(width: 1100, height: 600))
        try await hosted.settle()
        #expect(hosted.collapsed == [true, true, false])
        #expect(state.layout == .editorOnly)

        // Expanded behind our back (as a rebuilt split view would be): the layout follows.
        hosted.noteListItem?.isCollapsed = false
        try await hosted.settle()
        #expect(state.layout == .notesAndEditor)
        #expect(hosted.defaults.string(forKey: "MainWindow.layout") == "notesAndEditor")
    }
}
