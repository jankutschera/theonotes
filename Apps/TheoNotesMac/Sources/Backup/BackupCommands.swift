// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI

/// File ▸ Backup Notes… and File ▸ Restore Backup…, after Export Notes…. Both are disabled while
/// an import, an export, a backup or a restore runs.
struct BackupCommands: Commands {
    @FocusedValue(\.mainWindow) private var window

    private var unavailable: Bool {
        guard let window else { return true }
        return BackupCommandAvailability.isBlocked(
            importRunning: window.importer.isRunning,
            exportBusy: window.exporter.isRunning || window.exporter.isChoosing,
            backupBusy: window.backup.isBusy || window.model.environment.operations.isBusy)
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Backup Notes…") { window?.backup.backUp() }
                .disabled(unavailable)
            Button("Restore Backup…") { window?.backup.chooseBackupToRestore() }
                .disabled(unavailable)
        }
    }
}

enum BackupCommandAvailability {
    static func isBlocked(importRunning: Bool, exportBusy: Bool, backupBusy: Bool) -> Bool {
        importRunning || exportBusy || backupBusy
    }
}
