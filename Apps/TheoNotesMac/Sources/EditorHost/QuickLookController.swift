// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Quartz
import WebKit

/// Space on an attachment (inventory §2.12): the system Quick Look panel for its file. The editor
/// web view takes the panel's control (`EditorWebView`'s `TheoNotesWebView`), since the panel asks
/// the key window's responder chain for its data source.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var items: [URL] = []

    /// Shows (or refreshes) the panel for `url`.
    func show(_ url: URL) {
        items = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    func end(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { items.indices.contains(index) ? items[index] : nil }
        return url.map { $0 as NSURL }
    }
}

/// The editor's web view; it controls the Quick Look panel while it is in the responder chain.
final class TheoNotesWebView: WKWebView {
    weak var quickLook: QuickLookController?
    /// VoiceOver's "Headings" rotor for the shown note (M7 Task 12).
    var headingsRotor: EditorHeadingsRotor?
    /// The editor this view belongs to: the right-click menu's "Format" items run through it (M8-R105).
    weak var formatHost: EditorBridgeController?
    /// Called with the customised menu just before it opens (tests read it; AppKit shows it afterwards).
    var menuCustomized: ((NSMenu) -> Void)?

    /// WebKit's menu is built in the web process and handed to `willOpenMenu` just before it opens, so this is
    /// the place to take out what a Markdown editor cannot use (the Font submenu, Reload, …) and add "Format".
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let host = formatHost
        EditorContextMenu.customize(
            menu, state: host?.menuState(editorFocused: true) ?? .unavailable,
            perform: { [weak host] item in host?.performFormat(item) },
            remind: reminderAction(for: host), copyAs: copyAsMenu(for: host))
        menuCustomized?(menu)
    }

    /// What the menu's reminder items run: the app's handler, with this editor.
    private func reminderAction(for host: EditorBridgeController?) -> (@MainActor (ReminderScope) -> Void)? {
        guard let host, let handler = EditorContextMenu.remind else { return nil }
        return { [weak host] scope in if let host { handler(host, scope) } }
    }

    /// What the menu's Copy As submenu runs: the app's handler, with this editor.
    private func copyAsMenu(for host: EditorBridgeController?) -> EditorContextMenu.CopyAsMenu? {
        guard let host, let copy = EditorContextMenu.copyAs, let setKeepTags = EditorContextMenu.setKeepTags else { return nil }
        return .init(
            perform: { [weak host] format in if let host { copy(host, format) } },
            keepTags: EditorContextMenu.keepTags?() ?? true, setKeepTags: setKeepTags)
    }

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        (headingsRotor.map { [$0.rotor] } ?? []) + super.accessibilityCustomRotors()
    }

    // The panel calls these (an NSObject category, so nonisolated) on the main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        nonisolated(unsafe) let panel = panel
        MainActor.assumeIsolated { if let panel { quickLook?.begin(panel) } }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        nonisolated(unsafe) let panel = panel
        MainActor.assumeIsolated { if let panel { quickLook?.end(panel) } }
    }
}
