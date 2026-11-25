// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import ZIPFoundation

/// Shared streaming ZIP/ZIP64 support for mobile imports and portable backups.
/// No archive entry can create a link or escape the fresh destination. Both declared and
/// actually expanded sizes are bounded, and CRC checks are mandatory.
public enum PortableZIP {
    public enum Failure: Error, Equatable { case unsafePath, duplicatePath, symbolicLink, limitExceeded, invalidChecksum, nonemptyDestination }
    public struct Limits: Sendable {
        public var entries: Int
        public var fileBytes: UInt64
        public var totalBytes: UInt64
        public init(entries: Int = 100_000, fileBytes: UInt64 = 512 * 1024 * 1024, totalBytes: UInt64 = 32 * 1024 * 1024 * 1024) {
            self.entries = entries; self.fileBytes = fileBytes; self.totalBytes = totalBytes
        }
    }

    public static func extract(_ source: URL, to destination: URL, limits: Limits = Limits()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try fm.contentsOfDirectory(atPath: destination.path).isEmpty else { throw Failure.nonemptyDestination }
        }
        let archive = try Archive(url: source, accessMode: .read)
        let entries = try validatedEntries(archive, limits: limits)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            var total: UInt64 = 0
            for (entry, path) in entries {
                try Task.checkCancellation()
                let output = destination.appendingPathComponent(path)
                if entry.type == .directory {
                    try fm.createDirectory(at: output, withIntermediateDirectories: true)
                    continue
                }
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let writer = try FileHandle(forWritingTo: output)
                do {
                    var size: UInt64 = 0
                    let checksum = try archive.extract(entry, bufferSize: 65_536) { chunk in
                        try Task.checkCancellation()
                        size += UInt64(chunk.count); total += UInt64(chunk.count)
                        guard size <= entry.uncompressedSize, size <= limits.fileBytes, total <= limits.totalBytes else { throw Failure.limitExceeded }
                        try writer.write(contentsOf: chunk)
                    }
                    guard size == entry.uncompressedSize, checksum == entry.checksum else { throw Failure.invalidChecksum }
                    try writer.synchronize(); try writer.close()
                } catch { try? writer.close(); throw error }
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Writes a new archive atomically. Existing destinations are never overwritten implicitly.
    public static func create(from directory: URL, at destination: URL, limits: Limits = Limits()) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".archive-\(UUID()).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try writeDirectory(directory, to: temporary, limits: limits)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        try verify(temporary, limits: limits)
        try fm.moveItem(at: temporary, to: destination)
    }

    public static func verify(_ source: URL, limits: Limits = Limits()) throws {
        let archive = try Archive(url: source, accessMode: .read)
        var total: UInt64 = 0
        for (entry, _) in try validatedEntries(archive, limits: limits) where entry.type == .file {
            var size: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 65_536) { chunk in
                try Task.checkCancellation()
                size += UInt64(chunk.count); total += UInt64(chunk.count)
                guard size <= entry.uncompressedSize, total <= limits.totalBytes else { throw Failure.limitExceeded }
            }
            guard size == entry.uncompressedSize, checksum == entry.checksum else { throw Failure.invalidChecksum }
        }
    }

    private static func validatedEntries(_ archive: Archive, limits: Limits) throws -> [(Entry, String)] {
        var result: [(Entry, String)] = [], seen = Set<String>(), files = Set<String>(), total: UInt64 = 0
        for entry in archive {
            guard result.count < limits.entries else { throw Failure.limitExceeded }
            guard entry.type != .symlink else { throw Failure.symbolicLink }
            guard entry.type != .directory || entry.uncompressedSize == 0 else { throw Failure.unsafePath }
            let path = try normalizedPath(entry.path)
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw Failure.duplicatePath }
            if entry.type == .file { files.insert(key) }
            guard entry.uncompressedSize <= limits.fileBytes, entry.uncompressedSize <= limits.totalBytes - min(total, limits.totalBytes) else { throw Failure.limitExceeded }
            total += entry.uncompressedSize
            result.append((entry, path))
        }
        // Detect a file that is also a parent directory before writing any output.
        for (_, path) in result {
            var components = path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                guard !files.contains(components.joined(separator: "/")) else { throw Failure.duplicatePath }
            }
        }
        return result
    }
    private static func normalizedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"), !raw.unicodeScalars.contains(where: { $0.value < 32 }) else { throw Failure.unsafePath }
        let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw Failure.unsafePath }
        return path
    }
    private static func writeDirectory(_ directory: URL, to destination: URL, limits: Limits) throws {
        let fm = FileManager.default
        let root = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw Failure.symbolicLink }
        let archive = try Archive(url: destination, accessMode: .create)
        var count = 0, total: UInt64 = 0
        func add(_ folder: URL, prefix: String) throws {
            for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation(); count += 1
                guard count <= limits.entries else { throw Failure.limitExceeded }
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw Failure.symbolicLink }
                let path = try normalizedPath(prefix + item.lastPathComponent)
                if values.isDirectory == true {
                    try archive.addEntry(with: path + "/", fileURL: item)
                    try add(item, prefix: path + "/")
                }
                else {
                    guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { throw Failure.unsafePath }
                    guard UInt64(size) <= limits.fileBytes, UInt64(size) <= limits.totalBytes - min(total, limits.totalBytes) else { throw Failure.limitExceeded }
                    total += UInt64(size)
                    try archive.addEntry(with: path, fileURL: item, compressionMethod: .deflate, bufferSize: 65_536)
                }
            }
        }
        try add(directory, prefix: "")
    }
}
