// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Where diagnostic reports live (REL-R41): a folder next to the library in Application Support, one per
/// identity, never inside the library folder. A library can be moved, copied, backed up or exported on its own;
/// the reports belong to the app on this device, not to the notes.
public enum DiagnosticsLocation {
    public static func folderName(for identity: AppIdentity) -> String { identity.libraryFolderName + " Diagnostics" }

    public static func folder(applicationSupport: URL, identity: AppIdentity = .current) -> URL {
        applicationSupport.appendingPathComponent(folderName(for: identity), isDirectory: true)
    }

    public static var live: URL {
        folder(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }
}

/// How much the folder may hold (REL-R43). Defaults: the last 20 reports, nothing older than 90 days, 2 MiB in
/// total, 256 KiB per file.
public struct DiagnosticsRetention: Equatable, Sendable {
    public var maxFiles: Int
    public var maxAge: TimeInterval
    public var maxTotalBytes: Int
    public var maxFileBytes: Int

    public init(maxFiles: Int, maxAge: TimeInterval, maxTotalBytes: Int, maxFileBytes: Int) {
        self.maxFiles = maxFiles
        self.maxAge = maxAge
        self.maxTotalBytes = maxTotalBytes
        self.maxFileBytes = maxFileBytes
    }

    public static let standard = DiagnosticsRetention(
        maxFiles: 20, maxAge: 90 * 86_400, maxTotalBytes: 2 * 1_024 * 1_024, maxFileBytes: 256 * 1_024)
}

/// Writes reports as JSON files into one folder and keeps that folder within its limits. It only ever touches
/// files whose names it wrote itself (`<UTC time>-<kind>-<8 hex>.json`); anything else the user puts there stays.
public struct DiagnosticsStore: Sendable {
    public struct Entry: Sendable {
        public let url: URL
        /// Nil when the file cannot be read as a record (damaged, or written by a newer version).
        public let record: DiagnosticsRecord?
    }

    public let folder: URL
    public let retention: DiagnosticsRetention

    public init(folder: URL, retention: DiagnosticsRetention = .standard) {
        self.folder = folder
        self.retention = retention
    }

    // MARK: Writing

    /// Scrubs `record`, trims it to the per-file limit, writes it and prunes the folder. The folder is created on
    /// the first report, so a Mac without any report has no folder.
    @discardableResult
    public func save(_ record: DiagnosticsRecord, now: Date = Date()) throws -> URL {
        let data = try Self.fit(record.scrubbed(), into: retention.maxFileBytes)
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = Self.fileName(kind: record.kind, at: now)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune(now: now)
        return url
    }

    /// Applies the limits: too old first, then beyond the file count, then beyond the total size. The newest file
    /// is never removed by the size rule, so a report survives its own save.
    public func prune(now: Date = Date()) {
        let manager = FileManager.default
        var managed = managedFiles().sorted { $0.date > $1.date } // newest first
        func remove(_ file: ManagedFile) {
            try? manager.removeItem(at: file.url)
            managed.removeAll { $0.url == file.url }
        }
        for file in managed where now.timeIntervalSince(file.date) > retention.maxAge { remove(file) }
        while managed.count > max(retention.maxFiles, 1), let oldest = managed.last { remove(oldest) }
        var total = managed.reduce(0) { $0 + $1.size }
        while total > retention.maxTotalBytes, managed.count > 1, let oldest = managed.last {
            total -= oldest.size
            remove(oldest)
        }
    }

    // MARK: Reading

    /// The stored reports, newest first.
    public func entries() -> [Entry] {
        let decoder = Self.decoder
        return managedFiles().sorted { $0.date > $1.date || ($0.date == $1.date && $0.url.lastPathComponent > $1.url.lastPathComponent) }
            .map { file in
                let record = (try? Data(contentsOf: file.url)).flatMap { try? decoder.decode(DiagnosticsRecord.self, from: $0) }
                return Entry(url: file.url, record: record)
            }
    }

    // MARK: Files

    private struct ManagedFile {
        let url: URL
        let date: Date
        let size: Int
    }

    private func managedFiles() -> [ManagedFile] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name in
            guard let date = Self.date(fromFileName: name) else { return nil }
            let url = folder.appendingPathComponent(name)
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return ManagedFile(url: url, date: date, size: size)
        }
    }

    private static let nameFormat = "yyyyMMdd-HHmmss"
    private static let namePattern = "^[0-9]{8}-[0-9]{6}-[A-Za-z]+-[0-9a-f]{8}\\.json$"

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = nameFormat
        return formatter
    }

    static func fileName(kind: DiagnosticsRecord.Kind, at date: Date) -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "\(formatter().string(from: date))-\(kind.rawValue)-\(suffix).json"
    }

    static func date(fromFileName name: String) -> Date? {
        guard name.range(of: namePattern, options: .regularExpression) != nil else { return nil }
        return formatter().date(from: String(name.prefix(nameFormat.count)))
    }

    // MARK: Encoding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `record`; while the result is over `limit`, halves the frames of every stack and marks the record
    /// as truncated. A report without any frame is small, so the loop always ends.
    private static func fit(_ record: DiagnosticsRecord, into limit: Int) throws -> Data {
        var current = record
        while true {
            let data = try encoder.encode(current)
            let frames = current.stacks.reduce(0) { $0 + $1.frames.count }
            if data.count <= limit || frames == 0 { return data }
            current.truncated = true
            current.stacks = current.stacks.map {
                DiagnosticsRecord.CallStack(attributed: $0.attributed, frames: Array($0.frames.prefix($0.frames.count / 2)))
            }
        }
    }
}

// MARK: - The text the user copies

/// A plain-text summary for pasting into an email (REL-R45). Built only from stored, scrubbed records.
public enum DiagnosticsSummary {
    public static func text(appName: String, appVersion: String, osVersion: String, entries: [DiagnosticsStore.Entry]) -> String {
        var lines = [
            "\(appName) diagnostics",
            "App: \(appVersion)",
            "System: \(osVersion)",
            "Kept on this Mac only; nothing was sent anywhere.",
            "",
        ]
        if entries.isEmpty {
            lines.append("No reports have been recorded.")
            return lines.joined(separator: "\n")
        }
        lines.append("Reports: \(entries.count)")
        let stamp = ISO8601DateFormatter()
        for (index, entry) in entries.enumerated() {
            lines.append("")
            guard let record = entry.record else {
                lines.append("\(index + 1). \(entry.url.lastPathComponent) (could not be read)")
                continue
            }
            lines.append("\(index + 1). \(record.kind.rawValue), \(stamp.string(from: record.receivedAt)), app \(record.appVersion)")
            lines.append("   file: \(entry.url.lastPathComponent)")
            let facts = factsLine(record)
            if !facts.isEmpty { lines.append("   \(facts)") }
            let top = topFrames(record)
            if !top.isEmpty { lines.append("   innermost frames: \(top)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func factsLine(_ record: DiagnosticsRecord) -> String {
        let order = ["signal", "exceptionType", "exceptionCode", "terminationCategory", "terminationReason",
                     "exceptionClass", "exceptionName", "hangSeconds", "cpuSeconds", "sampledSeconds", "bytesWritten"]
        return order.compactMap { key in record.facts[key].map { "\(key) \($0)" } }.joined(separator: ", ")
    }

    /// The last frames of the thread the system blames (else the first thread): the innermost end of a stack.
    private static func topFrames(_ record: DiagnosticsRecord) -> String {
        guard let stack = record.stacks.first(where: \.attributed) ?? record.stacks.first else { return "" }
        return stack.frames.suffix(6).reversed().map { frame in
            let name = frame.binaryName ?? "?"
            return frame.offset.map { "\(name)+\($0)" } ?? name
        }.joined(separator: " < ")
    }
}

// MARK: - Collecting

/// Where reports come from: MetricKit on a device, a fake in tests. Each element is one delivery.
public protocol DiagnosticsSource: Sendable {
    func reports() -> AsyncStream<[DiagnosticsRecord]>
}

/// Stores every record a source delivers, until the source's stream ends. A failed write is handed to
/// `onFailure` and the rest still get stored.
public final class DiagnosticsCollector: Sendable {
    private let store: DiagnosticsStore
    private let source: any DiagnosticsSource
    private let onFailure: @Sendable (any Error) -> Void

    public init(
        store: DiagnosticsStore, source: any DiagnosticsSource, onFailure: @escaping @Sendable (any Error) -> Void = { _ in }
    ) {
        self.store = store
        self.source = source
        self.onFailure = onFailure
    }

    public func run() async {
        for await batch in source.reports() {
            for record in batch {
                do { try store.save(record, now: record.receivedAt) } catch { onFailure(error) }
            }
        }
    }
}
