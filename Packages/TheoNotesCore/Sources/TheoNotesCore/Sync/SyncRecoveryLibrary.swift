// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public enum RecoveryLibraryError: LocalizedError {
    case invalidSelection, verificationFailed
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "The recovery library selection is invalid. Your original library has been kept."
        case .verificationFailed: "The recovery copy failed verification. Your original library has been kept."
        }
    }
}

public struct PreparedRecoveryLibrary: Sendable {
    public let paths: AppPaths
    public let base: AppPaths
    public let id: String
}

/// A recovery copy has semantic notes/files, but never copies published sync history into a
/// different encryption vault. The entire original remains available, including its outbox.
public enum SyncRecoveryLibrary {
    public static let selectionDidChange = Notification.Name("TheoNotesRecoveryLibrarySelectionChanged")
    private static let markerName = ".sync-recovery-library.json"
    private static let preparedName = ".prepared-recovery-library.json"
    private static let selectionName = ".active-recovery-library.json"
    private struct Marker: Codable { let version: Int; let id: String; let origin: String }
    private struct Selection: Codable { let version: Int; let name: String }

    public static func identity(paths: AppPaths) throws -> String? {
        guard let marker = try marker(paths) else { return nil }
        return marker.id
    }

    public static func originalPaths(for paths: AppPaths) throws -> AppPaths {
        guard let marker = try marker(paths) else { return paths }
        return AppPaths(root: paths.root.deletingLastPathComponent().appendingPathComponent(marker.origin, isDirectory: true))
    }

    public static func activePaths(base: AppPaths) throws -> AppPaths {
        let base = try originalPaths(for: base)
        let file = base.root.appendingPathComponent(selectionName)
        guard FileManager.default.fileExists(atPath: file.path) else { return base }
        let selected = try JSONDecoder().decode(Selection.self, from: bounded(file))
        guard selected.version == 1, selected.name.hasPrefix(base.root.lastPathComponent + "-Recovery-"),
              singleComponent(selected.name) else { throw RecoveryLibraryError.invalidSelection }
        let paths = AppPaths(root: base.root.deletingLastPathComponent().appendingPathComponent(selected.name, isDirectory: true))
        guard let marker = try marker(paths), marker.origin == base.root.lastPathComponent else { throw RecoveryLibraryError.invalidSelection }
        try requireSibling(paths, base: base)
        return paths
    }

    public static func preparedCopy(source: AppPaths) throws -> PreparedRecoveryLibrary? {
        let base = try originalPaths(for: source)
        let file = base.root.appendingPathComponent(preparedName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let selected = try JSONDecoder().decode(Selection.self, from: bounded(file))
        guard selected.version == 1, singleComponent(selected.name), selected.name.hasPrefix(base.root.lastPathComponent + "-Recovery-") else { throw RecoveryLibraryError.invalidSelection }
        let paths = AppPaths(root: base.root.deletingLastPathComponent().appendingPathComponent(selected.name))
        guard let marker = try marker(paths), marker.origin == base.root.lastPathComponent else { throw RecoveryLibraryError.invalidSelection }
        if AppPaths.isSameDirectory(source.root, paths.root) { return nil }
        return PreparedRecoveryLibrary(paths: paths, base: base, id: marker.id)
    }

    /// Caller flushes sessions and pauses sync first. No source database/table/file is reset.
    public static func prepare(source: AppPaths, archive: URL) throws -> PreparedRecoveryLibrary {
        let base = try originalPaths(for: source)
        let id = UUID().uuidString.lowercased()
        let paths = AppPaths(root: base.root.deletingLastPathComponent().appendingPathComponent(base.root.lastPathComponent + "-Recovery-" + id, isDirectory: true))
        try requireSibling(paths, base: base, mustExist: false)
        guard !FileManager.default.fileExists(atPath: paths.root.path) else { throw RecoveryLibraryError.invalidSelection }
        do {
            try paths.createDirectories()
            let database = try AppDatabase(path: paths.database)
            do {
                defer { try? database.pool.close() }
                let backup = LibraryBackup(database: database, paths: paths)
                let before = try backup.inspect(archive)
                let restored = try backup.restore(archive)
                guard restored.restored == before.noteCount, restored.keptExisting == 0 else { throw RecoveryLibraryError.verificationFailed }
                let restoredArchive = try backup.createRolling()
                let verified = try backup.inspect(restoredArchive)
                guard try semanticManifest(archive) == semanticManifest(restoredArchive) else { throw RecoveryLibraryError.verificationFailed }
                guard verified.noteCount == before.noteCount, verified.lockedNoteCount == before.lockedNoteCount,
                      verified.attachmentCount == before.attachmentCount,
                      verified.missingAttachmentCount == before.missingAttachmentCount,
                      try !SyncQueue(database: database).isEnabled(), try !SyncQueue(database: database).hasRemoteState() else {
                    throw RecoveryLibraryError.verificationFailed
                }
            }
            try write(Marker(version: 1, id: id, origin: base.root.lastPathComponent), to: paths.root.appendingPathComponent(markerName))
            try write(Selection(version: 1, name: paths.root.lastPathComponent), to: base.root.appendingPathComponent(preparedName))
            return PreparedRecoveryLibrary(paths: paths, base: base, id: id)
        } catch {
            try? FileManager.default.removeItem(at: paths.root)
            throw error
        }
    }

    public static func select(_ prepared: PreparedRecoveryLibrary) throws {
        try requireSibling(prepared.paths, base: prepared.base)
        guard let marker = try marker(prepared.paths), marker.id == prepared.id,
              marker.origin == prepared.base.root.lastPathComponent else { throw RecoveryLibraryError.invalidSelection }
        try rotateWatchEpoch(at: prepared.paths)
        try write(Selection(version: 1, name: prepared.paths.root.lastPathComponent), to: prepared.base.root.appendingPathComponent(selectionName))
        guard AppPaths.isSameDirectory(try activePaths(base: prepared.base).root, prepared.paths.root) else { throw RecoveryLibraryError.verificationFailed }
    }

    public static func selectOriginal(for paths: AppPaths) throws {
        let base = try originalPaths(for: paths)
        let file = base.root.appendingPathComponent(selectionName)
        if FileManager.default.fileExists(atPath: file.path) {
            try rotateWatchEpoch(at: base)
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func rotateWatchEpoch(at paths: AppPaths) throws {
        // Commit the destination fence before changing selection: a crash in between only invalidates old intents.
        let attributes = try paths.database.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0 else { throw RecoveryLibraryError.invalidSelection }
        var configuration = Configuration(); configuration.readonly = true
        let check = try DatabaseQueue(path: paths.database.path, configuration: configuration)
        do {
            try check.read { db in
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")! > 0,
                      try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else { throw RecoveryLibraryError.invalidSelection }
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note")
            }
            try check.close()
        } catch { try? check.close(); throw error }
        // The normal app-open path migrates valid older libraries; openExisting intentionally does not.
        let database = try AppDatabase(path: paths.database)
        defer { try? database.pool.close() }
        try NoteStore(db: database, notifier: nil, paths: paths).rotateWatchEpoch()
    }

    /// Compare exact note/file hashes plus canonical metadata, not just item counts. Attachment
    /// record order can change when retained files become indexed rows during restoration.
    private static func semanticManifest(_ archive: URL) throws -> [String: String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-verify-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try PortableZIP.extract(archive, to: folder)
        _ = try LibraryBackup.validateExtracted(folder)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        var hashes: [String: String] = [:]
        for entry in manifest.files {
            if entry.path.hasSuffix("/record.json") || entry.path == "library.json" {
                let file = folder.appendingPathComponent(entry.path)
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_777_216 else { throw RecoveryLibraryError.verificationFailed }
                guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw RecoveryLibraryError.verificationFailed }
                if let attachments = object["attachments"] as? [[String: Any]] {
                    object["attachments"] = attachments.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
                }
                hashes[entry.path] = SyncWire.hash(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            } else { hashes[entry.path] = entry.sha256 }
        }
        return hashes
    }

    private static func marker(_ paths: AppPaths) throws -> Marker? {
        let file = paths.root.appendingPathComponent(markerName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Marker.self, from: bounded(file))
        guard value.version == 1, UUID(uuidString: value.id) != nil, singleComponent(value.origin),
              paths.root.lastPathComponent == value.origin + "-Recovery-" + value.id else { throw RecoveryLibraryError.invalidSelection }
        let base = AppPaths(root: paths.root.deletingLastPathComponent().appendingPathComponent(value.origin))
        try requireSibling(paths, base: base)
        return value
    }
    private static func singleComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && value.utf8.count < 256
    }
    private static func requireSibling(_ paths: AppPaths, base: AppPaths, mustExist: Bool = true) throws {
        let parent = base.root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard !AppPaths.isSameDirectory(paths.root, base.root),
              paths.root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == parent,
              (try? base.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw RecoveryLibraryError.invalidSelection }
        if mustExist {
            let values = try paths.root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true,
                  paths.root.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == parent else { throw RecoveryLibraryError.invalidSelection }
        }
    }
    private static func bounded(_ file: URL) throws -> Data {
        let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              let size = attributes.fileSize, size > 0, size <= 4096 else { throw RecoveryLibraryError.invalidSelection }
        return try Data(contentsOf: file)
    }
    private static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
