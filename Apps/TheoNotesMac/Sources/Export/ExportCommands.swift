// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

extension MainWindowState {
    /// The selected notes in list order.
    var selectedNoteIDsInListOrder: [String] {
        model.items.map(\.id).filter(model.selectedNoteIDs.contains)
    }

    /// What ⇧⌘S exports now, nil when there is nothing to export.
    var exportTarget: ExportTarget? {
        ExportTarget.resolve(
            scope: model.scope, noteListFocused: bridge.isNoteListFocused, editorFocused: bridge.isEditorFocused,
            selection: selectedNoteIDsInListOrder)
    }

    /// An import, an export, a backup or a restore runs: starting an export is disabled.
    var isExportBlocked: Bool {
        importer.isRunning || exporter.isRunning || exporter.isChoosing || isBackupBusy
    }

    /// A backup or restore runs in this window or another one of the library.
    var isBackupBusy: Bool { backup.isBusy || model.environment.operations.isBusy }

    func startExport(_ target: ExportTarget) {
        guard !isExportBlocked else { return }
        switch target {
        case .tagTree(let path): exporter.exportTagTree(path)
        case .selection(let ids): exporter.exportSelection(ids)
        }
    }
}

/// File ▸ Export Notes… (⇧⌘S), after Import From. Exports the tag tree when neither the note list
/// nor the editor is focused and the scope is a tag, otherwise the selected notes.
struct ExportCommands: Commands {
    @FocusedValue(\.mainWindow) private var window
    // Read so the item re-validates when scope or selection change.
    @FocusedValue(\.noteCommandState) private var noteCommandState

    private var target: ExportTarget? {
        _ = noteCommandState
        return window?.exportTarget
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Export Notes…") {
                guard let window, let target else { return }
                window.startExport(target)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!ExportCommandAvailability.isEnabled(
                importRunning: window?.importer.isRunning ?? true,
                exportBusy: window.map { $0.exporter.isRunning || $0.exporter.isChoosing } ?? true,
                restoreRunning: window?.isBackupBusy ?? true, hasTarget: target != nil))
        }
    }
}
