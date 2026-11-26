// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// An export the person chooses is a `.theonotes-backup` (the exported backup type
/// declared in Info.plist). The copies the app keeps itself (rolling, restore safety, daily
/// snapshots in `backup_catalog`) keep the legacy `baerchen-<id>.baerchen-backup` name, so an older build after a rollback still
/// reads its catalogue; both restore (the restore picker takes any file and the archive format is the same).
enum MobileBackupExportFile {
    static let fileExtension = LibraryBackup.backupExtension

    static func fileName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Theo Notes Backup \(formatter.string(from: date)).\(fileExtension)"
    }

    /// A copy of `archive` under the export name, in its own temporary folder (removed by `discard`). The original is not touched.
    static func make(from archive: URL, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("backup-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(fileName(date))
        do { try fileManager.copyItem(at: archive, to: copy) } catch { try? fileManager.removeItem(at: folder); throw error }
        return copy
    }

    static func discard(_ copy: URL, fileManager: FileManager = .default) {
        let folder = copy.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix("backup-export-") { try? fileManager.removeItem(at: folder) }
    }
}
