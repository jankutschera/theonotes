// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Observation
import SwiftUI

/// What SwiftUI doesn't expose reliably on macOS, read from AppKit through an anchor view behind
/// the note list: whether the note list's table view is the window's first responder (SwiftUI's
/// `FocusState` doesn't follow clicks into a `List` in a split view column), and collapsing the
/// note list column (a three-column `NavigationSplitView` ignores `.detailOnly` on macOS).
@MainActor
@Observable
final class WindowBridge {
    /// Follows the window's first responder (KVO); drives the menu's ⌘⌫ shortcut.
    private(set) var isNoteListFocused = false
    /// The editor web view has keyboard focus (KVO as above); enables the Format menu.
    private(set) var isEditorFocused = false

    /// The editor's web view, for `isEditorFocused`.
    @ObservationIgnored weak var editorView: NSView? {
        didSet { updateFocus() }
    }

    /// Called when the note list column collapses or expands, also when AppKit or SwiftUI did it.
    @ObservationIgnored var onNoteListCollapsedChange: (() -> Void)?

    @ObservationIgnored private weak var anchor: NSView?
    @ObservationIgnored private var responderObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var observedNoteListItem: NSSplitViewItem?
    @ObservationIgnored private var collapseObservation: NSKeyValueObservation?
    /// The note list item's own `canCollapse`, restored when it expands again.
    @ObservationIgnored private var savedCanCollapse: Bool?

    func attach(_ anchor: NSView) {
        self.anchor = anchor
        responderObservation = anchor.window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateFocus() }
        }
        if anchor.window == nil { updateFocus() }
        observeNoteListItem()
    }

    /// Checked at key time: the window's first responder is a table view lying inside the note
    /// list column. (Sidebar and note list are both outline views, so the class alone can't tell.)
    func isNoteListFirstResponder(in window: NSWindow) -> Bool {
        guard let anchor, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor,
              let table = window.firstResponder as? NSTableView else { return false }
        let visible = table.convert(table.visibleRect, to: nil)
        return anchor.convert(anchor.bounds, to: nil).contains(CGPoint(x: visible.midX, y: visible.midY))
    }

    /// Checked at key time: the window's first responder is the editor web view (or inside it).
    func isEditorFirstResponder(in window: NSWindow) -> Bool {
        guard let editorView, editorView.window === window, !editorView.isHiddenOrHasHiddenAncestor,
              let responder = window.firstResponder as? NSView else { return false }
        return responder === editorView || responder.isDescendant(of: editorView)
    }

    private func updateFocus() {
        let window = anchor?.window
        let focused = window.map(isNoteListFirstResponder(in:)) ?? false
        if focused != isNoteListFocused { isNoteListFocused = focused }
        let editor = window.map(isEditorFirstResponder(in:)) ?? false
        if editor != isEditorFocused { isEditorFocused = editor }
    }

    /// The window the anchor sits in (nil before it is shown and in unit tests).
    var window: NSWindow? { anchor?.window }

    /// The split view controller behind the `NavigationSplitView` (sidebar, note list, editor).
    private var splitViewController: NSSplitViewController? {
        let splitView = sequence(first: anchor, next: { $0?.superview }).lazy
            .compactMap { $0 as? NSSplitView }.first
        guard let controller = splitView?.delegate as? NSSplitViewController,
              controller.splitViewItems.count == 3 else { return nil }
        return controller
    }

    private var noteListItem: NSSplitViewItem? { splitViewController?.splitViewItems[1] }

    /// The real state of the note list column; false without a split view.
    var isNoteListCollapsed: Bool { noteListItem?.isCollapsed ?? false }

    /// Returns whether the note list column is now in the requested state (always false when
    /// collapsing without a split view). A collapsing list hands keyboard focus back to the window.
    @discardableResult
    func setNoteListCollapsed(_ collapsed: Bool) -> Bool {
        guard let item = noteListItem else { return !collapsed }
        observeNoteListItem()
        if item.isCollapsed != collapsed {
            if collapsed {
                savedCanCollapse = item.canCollapse
                item.canCollapse = true
                if let window = anchor?.window, let responder = window.firstResponder as? NSView,
                   responder.isDescendant(of: item.viewController.view) {
                    window.makeFirstResponder(nil)
                }
                item.isCollapsed = true
            } else {
                item.isCollapsed = false
                if let savedCanCollapse { item.canCollapse = savedCanCollapse }
                savedCanCollapse = nil
            }
        }
        return item.isCollapsed == collapsed
    }

    /// KVO on the note list item (SwiftUI may also replace it): keeps focus and the stored
    /// layout in step with what the window shows.
    private func observeNoteListItem() {
        guard let item = noteListItem, item !== observedNoteListItem else { return }
        observedNoteListItem = item
        savedCanCollapse = nil
        collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateFocus()
                self?.onNoteListCollapsedChange?()
            }
        }
    }
}

/// An invisible view behind the note list that hands itself to the `WindowBridge`.
struct WindowBridgeAnchor: NSViewRepresentable {
    let bridge: WindowBridge

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.bridge = bridge
    }

    final class AnchorView: NSView {
        weak var bridge: WindowBridge?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bridge?.attach(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Keys that move the selected notes to the Trash while the note list has focus:
/// ⌘⌫, ⌫ and ⌦.
enum NoteListKeys {
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117

    static func isTrashKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch keyCode {
        case delete: return flags == [.command] || flags.isEmpty
        case forwardDelete: return flags.isEmpty
        default: return false
        }
    }
}
