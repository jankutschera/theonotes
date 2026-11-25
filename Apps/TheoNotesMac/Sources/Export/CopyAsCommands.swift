// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Starts copies, one at a time app-wide: a new copy cancels the one before it (which stops waiting
/// for the renderer and, being superseded, never writes the pasteboard or beeps, M8-R75).
@MainActor
enum CopyAsRunner {
    private static var current: Task<CopyAs.Outcome, Never>?

    /// The lock engaged: the running copy stops and writes nothing (M9M-R76).
    static func cancelCurrent() { current?.cancel() }

    @discardableResult
    static func start(_ copier: CopyAs, _ format: CopyAsFormat, target: CopyTarget) -> Task<CopyAs.Outcome, Never> {
        current?.cancel()
        let task = Task { await copier.perform(format, target: target) }
        current = task
        return task
    }
}

/// Puts Edit ▸ Copy As directly after Copy (M8-R78). SwiftUI's `CommandGroup` has no placement
/// between Copy and Paste, so the item it builds is moved in the Edit `NSMenu`.
///
/// `NSMenu.removeItem(_:)` and `insertItem(_:at:)` (AppKit's NSMenu.h) move an item within its
/// menu. SwiftUI keeps updating the menu it owns, so the move is repeated whenever a menu posts
/// `didAddItem` / `didRemoveItem` / `didChangeItem`; it is idempotent (an item already in place is
/// not touched), so SwiftUI's own updates and ours settle.
@MainActor
enum CopyAsMenuPlacement {
    static let title = "Copy As"
    private static var observers: [any NSObjectProtocol] = []
    private static var isMoving = false

    /// Moves the "Copy As" submenu item of `menu` to directly after its Copy item (action `copy:`).
    /// Returns whether it moved; false when `menu` has no Copy or no Copy As, or it was in place.
    @discardableResult
    static func apply(to menu: NSMenu) -> Bool {
        guard !isMoving,
              let copy = menu.items.firstIndex(where: { $0.action == NSSelectorFromString("copy:") }),
              let current = menu.items.firstIndex(where: { $0.title == title && $0.submenu != nil }),
              current != copy + 1
        else { return false }
        isMoving = true
        defer { isMoving = false }
        let item = menu.items[current]
        menu.removeItem(item)
        // Removing an item above Copy shifts Copy up by one.
        menu.insertItem(item, at: current < copy ? copy : copy + 1)
        return true
    }

    /// Starts keeping the Edit menu in order (once; later calls do nothing).
    static func install() {
        guard observers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { applyToMainMenu() }
            })
        }
        applyToMainMenu()
    }

    /// The main menu's submenus are few and short; scanning them on each change is cheap.
    private static func applyToMainMenu() {
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] { apply(to: menu) }
    }
}

extension MainWindowState {
    /// Copy As for this window: locked notes left out are reported in the note list's banner (M8-R75).
    func makeCopyAs() -> CopyAs {
        let environment = model.environment
        return CopyAs(
            environment: environment, renderer: environment.renderer,
            notifyLocked: { [model] count in model.showNotice(.notesNotCopied(locked: count)) },
            keepTags: { [settings] in settings.snapshot.keepTagsOnExport })
    }

    /// The note list's Copy As: the given notes, in list order.
    func copyAs(_ format: CopyAsFormat, ids: Set<String>) {
        let ordered = model.items.map(\.id).filter(ids.contains)
        CopyAsRunner.start(makeCopyAs(), format, target: .notes(ordered))
    }
}

/// The "Keep Tags" item of every Copy As submenu: the same stored setting as Settings ▸ General ▸
/// "Keep tags when exporting" (MAC11-R17), shown as a checkmark.
struct CopyAsKeepTags: View {
    static let title = "Keep Tags"
    /// Nil while no library is open: the item is shown, switched off.
    let settings: SettingsModel?

    var body: some View {
        Toggle(Self.title, isOn: settings?.binding(.keepTagsOnExport, \.keepTagsOnExport) ?? .constant(true))
            .disabled(settings == nil)
    }
}

/// A Copy As for a window that has no banner (a note window, the editor's right-click).
@MainActor
func makeCopyAs(environment: AppEnvironment, settings: SettingsModel?) -> CopyAs {
    CopyAs(
        environment: environment, renderer: environment.renderer,
        keepTags: { settings?.snapshot.keepTagsOnExport ?? true })
}

extension AppModel {
    /// The editor's right-click Copy As: the editor's selection, else the note it shows.
    func copyAs(editor: EditorBridgeController, format: CopyAsFormat) {
        let noteId = editor.session?.noteId
        let target = CopyAs.target(
            editorFocused: true, shown: editor.session.map { ($0.noteId, $0.text) },
            selection: editor.status.selection, selectedNoteIDs: noteId.map { [$0] } ?? [])
        guard let target else { return NSSound.beep() }
        CopyAsRunner.start(makeCopyAs(environment: environment, settings: settings), format, target: target)
    }
}

/// Edit ▸ Copy As ▸ Markdown / Plain Text / HTML / Rich Text (M8-R8, A10). The command group puts it in the Edit
/// menu's pasteboard group; `CopyAsMenuPlacement` moves it directly under Copy. The target is
/// resolved when the item is chosen.
struct CopyAsCommands: Commands {
    let app: AppModel?

    @FocusedValue(\.mainWindow) private var mainWindow
    @FocusedValue(\.noteWindow) private var noteWindow
    // Read so the items re-validate when the selection changes.
    @FocusedValue(\.noteCommandState) private var noteCommandState

    private var hasTarget: Bool {
        _ = noteCommandState
        if let mainWindow { return CopyAs.hasTarget(window: mainWindow) }
        if let noteWindow { return CopyAs.hasTarget(window: noteWindow) }
        return false
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Menu("Copy As") {
                ForEach(CopyAsFormat.allCases) { format in
                    Button(format.title) { copy(format) }
                        .keyboardShortcut(format.shortcut)
                }
                Divider()
                CopyAsKeepTags(settings: app?.settings)
            }
            .disabled(app == nil || !hasTarget)
        }
    }

    private func copy(_ format: CopyAsFormat) {
        guard let environment = app?.environment else { return }
        let target = mainWindow.flatMap(CopyAs.target(window:)) ?? noteWindow.flatMap(CopyAs.target(window:))
        guard let target else { return NSSound.beep() }
        // A note window has no banner: with nothing left to copy the beep is its only signal.
        let copier = mainWindow?.makeCopyAs() ?? makeCopyAs(environment: environment, settings: app?.settings)
        CopyAsRunner.start(copier, format, target: target)
    }
}
