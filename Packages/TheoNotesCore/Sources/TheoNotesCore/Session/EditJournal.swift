// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import os

let sessionLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "session")

public enum JournalError: Error, Equatable {
    case closed
    /// A record of a format this build does not know (`nil`: no version field).
    case unsupportedVersion(Int?)
    /// An undecodable line (1-based) followed by further lines; replaying around it could misplace edits.
    case corruptEntry(line: Int)
}

/// Authentication failures must leave recovery files intact, never move them aside and open
/// an empty session as ordinary malformed JSON recovery can do.
public enum JournalProtectionError: Error, Equatable, Sendable {
    case keyRequired
    case authenticationFailed
    case plaintextInEncryptedJournal
    case missingBase
    case baseHasPendingEntries
}

public struct JournalEntry: Codable, Sendable, Equatable {
    /// Record format version (`EditJournal.formatVersion` when written).
    public var v: Int
    public var txId: String
    public var baseRevision: Int
    public var changeSet: ChangeSet

    public init(txId: String, baseRevision: Int, changeSet: ChangeSet) {
        v = EditJournal.formatVersion
        self.txId = txId
        self.baseRevision = baseRevision
        self.changeSet = changeSet
    }
}

/// The text (and its store revision) the journal's first entry applies to.
public struct JournalBase: Codable, Sendable, Equatable {
    /// Record format version (`EditJournal.formatVersion` when written).
    public var v: Int
    public var storeRevision: Int
    public var baseText: String

    public init(storeRevision: Int, baseText: String) {
        v = EditJournal.formatVersion
        self.storeRevision = storeRevision
        self.baseText = baseText
    }
}

/// Reads only the version field, so a record of another format is told apart from a torn line.
private struct VersionProbe: Decodable {
    var v: Int?
}

/// File operations the test target can make fail (`EditJournal.faultInjector`).
enum JournalOperation {
    case write(Data)
    case synchronize
    case truncate
    /// The fsync after a truncation succeeded (the file is already shortened).
    case synchronizeTruncation
}

/// Append-only per-note journal of acknowledged-but-uncommitted edits: `<directory>/<noteId>.jsonl`,
/// one JSON object per line, fsynced on every append, plus `<noteId>.base` holding the text the
/// entries apply to.
public final class EditJournal {
    public static let formatVersion = 1
    public let fileURL: URL
    public let baseURL: URL
    /// A failed append could not be rolled back; the file may hold a torn or unacked line.
    /// Cleared by a successful `truncate()`.
    public private(set) var isPoisoned = false
    /// Test seam: called before each file operation; throwing makes the operation fail.
    var faultInjector: ((JournalOperation, FileHandle) throws -> Void)?
    var beforeBaseWrite: ((URL) throws -> Void)?

    private let directory: URL
    private var handle: FileHandle
    private var closed = false
    private let creationAttributes: [FileAttributeKey: Any]?
    private let encryptionKey: SymmetricKey?
    private let noteId: String
    private var protectedEntryCount = 0
    private var previousDigest = ""
    private var baseDigest = ""
    private static let entryPrefix = Data("BJE1:".utf8)
    private static let basePrefix = Data("BJB1:".utf8)
    private static let newline = UInt8(ascii: "\n")

    public init(directory: URL, noteId: String, encryptionKey: SymmetricKey? = nil, creationAttributes: [FileAttributeKey: Any]? = nil) throws {
        self.creationAttributes = creationAttributes
        self.encryptionKey = encryptionKey
        self.noteId = noteId
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        fileURL = directory.appendingPathComponent("\(noteId).jsonl")
        baseURL = directory.appendingPathComponent("\(noteId).base")
        handle = try Self.openCreatingIfNeeded(fileURL, in: directory, attributes: creationAttributes)
        // Check the base before changing any existing file. A missing/wrong key must never
        // destroy a crash-recovery journal, including its unacknowledged trailing bytes.
        if encryptionKey != nil {
            _ = try base()
            try restoreProtectedChain()
        } else {
            if let saved = try? Data(contentsOf: baseURL), saved.starts(with: Self.basePrefix) {
                throw JournalProtectionError.keyRequired
            }
            try handle.seek(toOffset: 0)
            if (try handle.read(upToCount: Self.entryPrefix.count)) == Self.entryPrefix {
                throw JournalProtectionError.keyRequired
            }
        }
        try handle.seek(toOffset: 0)
        try dropTornTail()
    }

    /// Read an existing recovery pair without creating or modifying either file.
    init(recoveryDirectory directory: URL, noteId: String, suffix: String, encryptionKey: SymmetricKey?, baseOnly: Bool = false, baseSuffix: String? = nil) throws {
        self.creationAttributes = nil
        self.encryptionKey = encryptionKey
        self.noteId = noteId
        self.directory = directory
        fileURL = directory.appendingPathComponent("\(noteId).jsonl\(suffix)")
        baseURL = directory.appendingPathComponent("\(noteId).base\(baseSuffix ?? suffix)")
        handle = try FileHandle(forReadingFrom: baseOnly ? baseURL : fileURL)
        if encryptionKey != nil {
            _ = try base()
            if !baseOnly { try restoreProtectedChain() }
        } else {
            if (try Data(contentsOf: baseURL)).starts(with: Self.basePrefix) { throw JournalProtectionError.keyRequired }
            if !baseOnly, (try handle.read(upToCount: Self.entryPrefix.count)) == Self.entryPrefix { throw JournalProtectionError.keyRequired }
        }
    }

    deinit { try? handle.close() }

    /// Close the descriptor without modifying any recovery bytes. A failed close is reported.
    func close() throws {
        guard !closed else { return }
        try handle.close()
        closed = true
    }

    private func requireOpen() throws { if closed { throw JournalError.closed } }

    /// Appends one line and fsyncs. On failure the file is rolled back to its previous length;
    /// if even that fails the journal is marked poisoned.
    public func append(_ entry: JournalEntry) throws {
        try requireOpen()
        var line = try JSONEncoder().encode(entry)
        if encryptionKey != nil {
            guard !baseDigest.isEmpty else { throw JournalProtectionError.missingBase }
            line = try protect(line, prefix: Self.entryPrefix, kind: entryContext(protectedEntryCount, previousDigest))
        }
        let digest = Self.digest(line)
        line.append(Self.newline)
        let end = try handle.seekToEnd()
        do {
            try faultInjector?(.write(line), handle)
            try handle.write(contentsOf: line)
            try faultInjector?(.synchronize, handle)
            try handle.synchronize()
            if encryptionKey != nil {
                protectedEntryCount += 1
                previousDigest = digest
            }
        } catch {
            do {
                try truncateFile(atOffset: end)
            } catch {
                isPoisoned = true
                sessionLogger.fault("journal \(self.fileURL.lastPathComponent, privacy: .public): rollback failed, poisoned")
            }
            throw error
        }
    }

    public func isEmpty() throws -> Bool {
        try requireOpen()
        return try handle.seekToEnd() == 0
    }

    /// Throws `JournalError` for a record of an unknown format version (anywhere) or an
    /// undecodable line followed by further lines. An undecodable last line is dropped like a torn tail.
    public func entries() throws -> [JournalEntry] {
        try requireOpen()
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let decoder = JSONDecoder()
        // Only complete lines can have been acknowledged. Init trims any torn tail after
        // authenticating the existing complete prefix.
        let complete = data.last == Self.newline ? data : Data(data.prefix(upTo: data.lastIndex(of: Self.newline).map { $0 + 1 } ?? 0))
        let lines = complete.split(separator: Self.newline).filter { !$0.isEmpty }
        var previous = ""
        var result: [JournalEntry] = []
        for (index, line) in lines.enumerated() {
            let raw = Data(line)
            let lineData = try unprotect(raw, prefix: Self.entryPrefix, kind: entryContext(index, previous))
            previous = Self.digest(raw)
            if let probe = try? decoder.decode(VersionProbe.self, from: lineData), probe.v != Self.formatVersion {
                throw JournalError.unsupportedVersion(probe.v)
            }
            do {
                result.append(try decoder.decode(JournalEntry.self, from: lineData))
            } catch {
                if encryptionKey != nil { throw JournalProtectionError.authenticationFailed }
                guard index == lines.count - 1 else { throw JournalError.corruptEntry(line: index + 1) }
                sessionLogger.error("journal \(self.fileURL.lastPathComponent, privacy: .public): undecodable last line skipped")
            }
        }
        return result
    }

    /// Durably replaces the base record (temp file, fsync, rename, directory fsync).
    public func writeBase(_ base: JournalBase) throws {
        try requireOpen()
        if encryptionKey != nil, try !isEmpty() { throw JournalProtectionError.baseHasPendingEntries }
        let encoded = try protect(JSONEncoder().encode(base), prefix: Self.basePrefix, kind: "base")
        let tmp = directory.appendingPathComponent(baseURL.lastPathComponent + ".tmp")
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: creationAttributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        let tmpHandle = try FileHandle(forWritingTo: tmp)
        do {
            try beforeBaseWrite?(tmp)
            try tmpHandle.write(contentsOf: encoded)
            try tmpHandle.synchronize()
        } catch { try? tmpHandle.close(); throw error }
        try tmpHandle.close()
        guard rename(tmp.path, baseURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Self.syncDirectory(directory)
        if encryptionKey != nil { baseDigest = Self.digest(encoded) }
    }

    public func base() throws -> JournalBase? {
        try requireOpen()
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }
        let raw = try Data(contentsOf: baseURL)
        let data = try unprotect(raw, prefix: Self.basePrefix, kind: "base")
        if encryptionKey != nil { baseDigest = Self.digest(raw) }
        let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        guard probe.v == Self.formatVersion else { throw JournalError.unsupportedVersion(probe.v) }
        return try JSONDecoder().decode(JournalBase.self, from: data)
    }

    /// Empties the journal and removes the base record.
    public func truncate() throws {
        try requireOpen()
        try truncateFile(atOffset: 0)
        isPoisoned = false
        protectedEntryCount = 0
        previousDigest = ""
        baseDigest = ""
        // A leftover base with an empty journal is harmless (overwritten before the next append).
        do {
            if FileManager.default.fileExists(atPath: baseURL.path) {
                try FileManager.default.removeItem(at: baseURL)
            }
        } catch {
            sessionLogger.error("journal \(self.fileURL.lastPathComponent, privacy: .public): base removal failed")
        }
    }

    /// Keeps an unreplayable journal for manual recovery as `<noteId>.jsonl.unreplayed` and
    /// `<noteId>.base.unreplayed` (numbered if those exist), and starts a fresh empty journal.
    public func moveAside() throws {
        try requireOpen()
        try handle.close()
        try Self.moveAside(fileURL, baseURL)
        handle = try Self.openCreatingIfNeeded(fileURL, in: directory, attributes: creationAttributes)
        isPoisoned = false
        protectedEntryCount = 0
        previousDigest = ""
        baseDigest = ""
    }

    /// Moves the journal files of `noteId` aside as `moveAside()` does, without opening them (so
    /// nothing is trimmed, not even a torn last line).
    public static func moveAside(noteId: String, in directory: URL) throws {
        try moveAside(directory.appendingPathComponent("\(noteId).jsonl"), directory.appendingPathComponent("\(noteId).base"))
    }

    private static func moveAside(_ urls: URL...) throws {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            var target = url.appendingPathExtension("unreplayed")
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = url.appendingPathExtension("unreplayed.\(n)")
                n += 1
            }
            try fm.moveItem(at: url, to: target)
        }
    }

    // MARK: - Private

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private func entryContext(_ index: Int, _ previous: String) -> String {
        "entry:\(baseDigest):\(index):\(previous)"
    }

    private func authenticatedData(_ kind: String) throws -> Data {
        try JSONEncoder().encode([ProtocolLabels.journal, noteId, kind])
    }

    private func protect(_ data: Data, prefix: Data, kind: String) throws -> Data {
        guard let encryptionKey else { return data }
        guard let combined = try AES.GCM.seal(data, using: encryptionKey, authenticating: authenticatedData(kind)).combined
        else { throw JournalProtectionError.authenticationFailed }
        return prefix + Data(combined.base64EncodedString().utf8)
    }

    private func unprotect(_ data: Data, prefix: Data, kind: String) throws -> Data {
        guard data.starts(with: prefix) else {
            if encryptionKey != nil { throw JournalProtectionError.plaintextInEncryptedJournal }
            return data
        }
        guard let encryptionKey else { throw JournalProtectionError.keyRequired }
        do {
            guard let combined = Data(base64Encoded: data.dropFirst(prefix.count)) else {
                throw JournalProtectionError.authenticationFailed
            }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: encryptionKey,
                                    authenticating: authenticatedData(kind))
        } catch { throw JournalProtectionError.authenticationFailed }
    }

    private func restoreProtectedChain() throws {
        let restored = try entries()
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let complete = data.last == Self.newline ? data : Data(data.prefix(upTo: data.lastIndex(of: Self.newline).map { $0 + 1 } ?? 0))
        let lines = complete.split(separator: Self.newline).filter { !$0.isEmpty }
        guard lines.isEmpty || !baseDigest.isEmpty else { throw JournalProtectionError.missingBase }
        protectedEntryCount = restored.count
        previousDigest = lines.last.map { Self.digest(Data($0)) } ?? ""
    }

    private func truncateFile(atOffset offset: UInt64) throws {
        try faultInjector?(.truncate, handle)
        try handle.truncate(atOffset: offset)
        try faultInjector?(.synchronizeTruncation, handle)
        try handle.synchronize()
    }

    /// A crash mid-append can leave a partial last line (never acked, since fsync had not returned).
    /// Cut it so the next append starts on a fresh line.
    private func dropTornTail() throws {
        let data = try handle.readToEnd() ?? Data()
        guard let last = data.last, last != Self.newline else { return }
        let keep = data.lastIndex(of: Self.newline).map { $0 + 1 } ?? 0
        sessionLogger.error("journal \(self.fileURL.lastPathComponent, privacy: .public): dropping torn trailing line")
        try handle.truncate(atOffset: UInt64(keep))
        try handle.synchronize()
    }

    private static func openCreatingIfNeeded(_ url: URL, in directory: URL, attributes: [FileAttributeKey: Any]?) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            syncDirectory(directory)
        }
        return try FileHandle(forUpdating: url)
    }

    private static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        Darwin.close(fd)
    }
}

