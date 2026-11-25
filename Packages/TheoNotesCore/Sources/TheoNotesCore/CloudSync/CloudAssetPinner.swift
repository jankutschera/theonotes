// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation

/// Makes the files of fetched `CKAsset` fields durable before the engine state may advance (CK-R5). CloudKit stages a fetched
/// asset in a folder the system empties, so the sink copies it into the library's own folder first:
///
///   1. copy under a fresh path from `CloudSyncStore.newPinnedPath` (never a reused name),
///   2. `fsync` the file, then the folder that names it and every folder up to the pin folder, and the parent of the pin
///      folder when this call created it,
///   3. read the copy back and compare size and SHA-256 with the source,
///   4. only then does the caller record the row.
///
/// A failure removes whatever this call wrote and throws, so the batch fails and the token does not advance. The folder is a
/// durable, no-backup folder under the library's Application Support folder (not `tmp`).
extension AppPaths {
    /// Where fetched assets of unreadable or not-yet-applied records are kept (CK-R5): inside the library folder, which lives in
    /// Application Support, and excluded from backups.
    public var cloudPinned: URL { root.appendingPathComponent("CloudPinned", isDirectory: true) }
}

public struct CloudAssetPinner: Sendable {
    public let directory: URL
    private let syncDirectory: @Sendable (URL) throws -> Void
    /// Test seam: runs on the copy right after it was written (a test corrupts it to prove the hash check bites).
    private let afterCopy: @Sendable (URL) throws -> Void

    public init(directory: URL, syncDirectory: @escaping @Sendable (URL) throws -> Void = CloudAssetPinner.fsyncDirectory,
                afterCopy: @escaping @Sendable (URL) throws -> Void = { _ in }) {
        self.directory = directory; self.syncDirectory = syncDirectory; self.afterCopy = afterCopy
    }

    /// Pins every asset field of `record`.
    public func pin(_ record: CloudRecord) throws -> [CloudPinnedAsset] {
        var pinned: [CloudPinnedAsset] = []
        var written: [String] = []
        // A pin folder created by this very call is itself only an entry in its parent until the parent is synced.
        let createsPinFolder = !FileManager.default.fileExists(atPath: directory.path)
        do {
            if createsPinFolder {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var folder = directory
                try? folder.setResourceValues(values)
            }
            for field in record.fields.keys.sorted() {
                guard case .asset(let source) = record.fields[field] else { continue }
                let relative = CloudSyncStore.newPinnedPath(recordName: record.name, field: field)
                let target = directory.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: source)
                try data.write(to: target, options: .atomic)
                written.append(relative)
                let handle = try FileHandle(forUpdating: target)
                try handle.synchronize(); try handle.close()
                try afterCopy(target)
                // The entry of the file in its folder, and of each folder in its parent up to the pin folder.
                var folder = target.deletingLastPathComponent()
                while true {
                    try syncDirectory(folder)
                    if folder.standardizedFileURL.path == directory.standardizedFileURL.path { break }
                    let parent = folder.deletingLastPathComponent()
                    if parent.path == folder.path { break }
                    folder = parent
                }
                let copy = try Data(contentsOf: target)
                guard copy.count == data.count, CloudSyncStore.sha256Hex(copy) == CloudSyncStore.sha256Hex(data) else {
                    throw CloudIntakeError.pinMismatch(record.name)
                }
                pinned.append(CloudPinnedAsset(field: field, path: relative, size: Int64(data.count), sha256: CloudSyncStore.sha256Hex(data)))
            }
            if createsPinFolder, !pinned.isEmpty { try syncDirectory(directory.deletingLastPathComponent()) }
        } catch {
            remove(written)
            throw error
        }
        return pinned
    }

    public func url(for relativePath: String) -> URL { directory.appendingPathComponent(relativePath) }

    /// Re-reads a pinned file and checks size and hash against what the row recorded.
    public func verify(_ asset: CloudPinnedAsset) throws -> Data {
        let data = try Data(contentsOf: url(for: asset.path))
        guard Int64(data.count) == asset.size, CloudSyncStore.sha256Hex(data) == asset.sha256 else { throw CloudIntakeError.pinMismatch(asset.path) }
        return data
    }

    public func remove(_ relativePaths: [String]) {
        for path in relativePaths {
            let file = url(for: path)
            try? FileManager.default.removeItem(at: file)
            // The record folder goes with its last file.
            let folder = file.deletingLastPathComponent()
            if folder.standardizedFileURL.path != directory.standardizedFileURL.path,
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Files without a row (a crash between the copy and the commit): removed once older than `minimumAge` (a day at launch).
    /// Returns the relative paths removed.
    @discardableResult
    public func sweep(store: CloudSyncStore, minimumAge: TimeInterval = 86_400, now: Date = Date()) throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return [] }
        let root = directory.standardizedFileURL.path + "/"
        var removed: [String] = []
        var candidates: [(URL, String)] = []
        for case let file as URL in walker {
            let facts = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard facts.isRegularFile == true else { continue }
            let full = file.standardizedFileURL.path
            guard full.hasPrefix(root) else { continue }
            let age = now.timeIntervalSince(facts.contentModificationDate ?? now)
            if age >= minimumAge { candidates.append((file, String(full.dropFirst(root.count)))) }
        }
        for (_, relative) in candidates where try !store.isPathReferenced(relative) {
            remove([relative])
            removed.append(relative)
        }
        return removed
    }

    /// `fsync` on the directory itself (F_FULLFSYNC where the file system supports it).
    public static func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}
