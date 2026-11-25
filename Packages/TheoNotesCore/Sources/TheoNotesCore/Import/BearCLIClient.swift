// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A note as reported by `bearcli list --format json --fields all,content`.
public struct BearNoteRecord: Decodable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var locked: Bool
    /// Tag names without the leading `#` (and without the closing `#` of multi-word tags).
    public var tags: [String]
    public var created: Date
    public var modified: Date
    public var pins: [BearPin]
    public var location: NoteLocation
    public var todos: Int
    public var done: Int
    public var attachments: [String]
    /// `nil` for locked (encrypted) notes, whose content bearcli does not expose.
    public var content: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, locked, tags, created, modified, pins, location, todos, done, attachments, content
    }

    public init(
        id: String, title: String = "", locked: Bool = false, tags: [String] = [], created: Date, modified: Date,
        pins: [BearPin] = [], location: NoteLocation = .notes, todos: Int = 0, done: Int = 0,
        attachments: [String] = [], content: String?
    ) {
        self.id = id
        self.title = title
        self.locked = locked
        self.tags = tags
        self.created = created
        self.modified = modified
        self.pins = pins
        self.location = location
        self.todos = todos
        self.done = done
        self.attachments = attachments
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        locked = try c.decodeIfPresent(String.self, forKey: .locked) == "yes"
        tags = (try c.decodeIfPresent([String].self, forKey: .tags) ?? []).map(Self.tagName)
        created = try Self.date(c, .created)
        modified = try Self.date(c, .modified)
        pins = (try c.decodeIfPresent([String].self, forKey: .pins) ?? []).map(BearPin.init(raw:))
        location = try c.decodeIfPresent(NoteLocation.self, forKey: .location) ?? .notes
        todos = try c.decodeIfPresent(Int.self, forKey: .todos) ?? 0
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        content = try c.decodeIfPresent(String.self, forKey: .content)
    }

    /// Decodes the JSON array `bearcli list` prints. Entries are decoded one by one: an entry
    /// that does not decode (e.g. an unknown `location`) becomes an error line (`"<id>: <field
    /// problem>"`, or `"#<position>: ..."` without an id) and the rest still import. Messages
    /// name fields only, never values, so note bodies cannot leak into reports.
    public static func decodeList(_ data: Data) throws -> BearNoteList {
        let entries = try JSONDecoder().decode([LenientEntry].self, from: data)
        var list = BearNoteList(records: [])
        for (index, entry) in entries.enumerated() {
            switch entry.result {
            case .success(let record):
                list.records.append(record)
            case .failure(let id, let message):
                if let id { list.undecodedIDs.append(id) }
                list.errors.append("\(id ?? "#\(index + 1)"): \(message)")
            }
        }
        return list
    }

    private struct LenientEntry: Decodable {
        enum Result { case success(BearNoteRecord), failure(id: String?, message: String) }
        let result: Result

        private struct IDOnly: Decodable { let id: String }

        init(from decoder: Decoder) throws {
            do {
                result = .success(try BearNoteRecord(from: decoder))
            } catch let error as DecodingError {
                result = .failure(id: try? IDOnly(from: decoder).id, message: Self.describe(error))
            }
        }

        static func describe(_ error: DecodingError) -> String {
            func field(_ path: [CodingKey]) -> String {
                path.map(\.stringValue).joined(separator: ".")
            }
            switch error {
            case .keyNotFound(let key, let context):
                return "missing field '\(field(context.codingPath + [key]))'"
            case .valueNotFound(_, let context):
                return "missing value for field '\(field(context.codingPath))'"
            case .typeMismatch(_, let context):
                return "wrong type for field '\(field(context.codingPath))'"
            case .dataCorrupted(let context):
                return "invalid value for field '\(field(context.codingPath))'"
            @unknown default:
                return "undecodable entry"
            }
        }
    }

    /// `#name` or `#multi word#` → `name` / `multi word`.
    static func tagName(_ raw: String) -> String {
        var name = Substring(raw)
        if name.hasPrefix("#") { name = name.dropFirst() }
        if name.hasSuffix("#") { name = name.dropLast() }
        return String(name)
    }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let raw = try c.decode(String.self, forKey: key)
        let plain = Date.ISO8601FormatStyle()
        if let d = try? plain.parse(raw) { return d }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return d }
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not an ISO-8601 date")
    }
}

/// `bearcli list` output: the records that decoded, plus one error line per entry that did not.
public struct BearNoteList: Equatable, Sendable {
    public var records: [BearNoteRecord]
    /// `"<bearID>: <message>"` for entries that could not be decoded.
    public var errors: [String]
    /// Bear ids of the undecodable entries (they still exist in Bear: not "missing").
    public var undecodedIDs: [String]

    public init(records: [BearNoteRecord], errors: [String] = [], undecodedIDs: [String] = []) {
        self.records = records
        self.errors = errors
        self.undecodedIDs = undecodedIDs
    }
}

public enum BearPin: Equatable, Sendable {
    case global
    case tag(String)

    init(raw: String) {
        self = raw == "global" ? .global : .tag(BearNoteRecord.tagName(raw))
    }
}

public enum BearCLIError: Error, Equatable, Sendable {
    /// The bearcli executable does not exist or is not executable.
    case notInstalled
    /// bearcli exited non-zero without a structured error.
    case failed(code: Int32, stderr: String)
    /// bearcli reported `{"error":{"code","message"}}`.
    case bear(code: String, message: String)
    /// The subcommand is outside the read-only allow-list; carries its first two tokens.
    case forbiddenSubcommand(String)
    /// bearcli did not finish within the time limit and was terminated.
    case timedOut
}

extension BearCLIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notInstalled: "bearcli is not installed or not executable"
        case .failed(let code, let stderr):
            stderr.isEmpty ? "bearcli exited with code \(code)"
                : "bearcli exited with code \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .bear(let code, let message): "Bear error \(code): \(message)"
        case .forbiddenSubcommand(let command): "bearcli subcommand not allowed: \(command)"
        case .timedOut: "bearcli timed out"
        }
    }
}

public protocol BearCLIClient: Sendable {
    /// `list --location all --format json --fields all,content`
    func listAll() throws -> BearNoteList
    /// `search @readonly --location all --format json --fields id`
    func readOnlyIDs() throws -> Set<String>
    /// `attachments save <id> --filename <name>`: the raw attachment bytes.
    func attachmentData(noteID: String, filename: String) throws -> Data
}

/// Runs Bear's official CLI. Read-only: every invocation is checked against an allow-list.
public struct ProcessBearCLI: BearCLIClient {
    public static let defaultPath = URL(fileURLWithPath: "/Applications/Bear.app/Contents/MacOS/bearcli")

    /// Longest stderr kept in `BearCLIError.failed`.
    static let stderrLimit = 2048

    public let executable: URL
    /// Seconds allowed for `list`/`search`.
    public let listTimeout: TimeInterval
    /// Seconds allowed per `attachments save`.
    public let attachmentTimeout: TimeInterval

    public init(executable: URL, listTimeout: TimeInterval = 120, attachmentTimeout: TimeInterval = 60) {
        self.executable = executable
        self.listTimeout = listTimeout
        self.attachmentTimeout = attachmentTimeout
    }

    public func listAll() throws -> BearNoteList {
        try BearNoteRecord.decodeList(
            run(["list", "--location", "all", "--format", "json", "--fields", "all,content"]))
    }

    public func readOnlyIDs() throws -> Set<String> {
        struct Row: Decodable { let id: String }
        let data = try run(["search", "@readonly", "--location", "all", "--format", "json", "--fields", "id"])
        return Set(try JSONDecoder().decode([Row].self, from: data).map(\.id))
    }

    public func attachmentData(noteID: String, filename: String) throws -> Data {
        try run(["attachments", "save", noteID, "--filename", filename], timeout: attachmentTimeout)
    }

    /// `list --location <location> --count --format json`: how many notes Bear lists there
    /// (`notes`, `archive`, `trash` or `all`), without reading any note.
    public func noteCount(location: String) throws -> Int {
        struct Count: Decodable { let count: Int }
        return try JSONDecoder().decode(
            Count.self, from: run(["list", "--location", location, "--count", "--format", "json"])).count
    }

    /// `attachments list <id> --format json --fields filename,size`: byte size per filename.
    public func attachmentSizes(noteID: String) throws -> [String: Int] {
        struct Row: Decodable { let filename: String; let size: Int }
        let data = try run(["attachments", "list", noteID, "--format", "json", "--fields", "filename,size"],
                           timeout: attachmentTimeout)
        // Empty output means no attachments.
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A }) else { return [:] }
        return Dictionary(try JSONDecoder().decode([Row].self, from: data).map { ($0.filename, $0.size) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Raw stdout of a read-only subcommand (allow-list, timeout and stderr drain as for every
    /// call). For tools that parse bearcli output themselves, such as bear-oracle.
    public func output(_ args: [String]) throws -> Data {
        try run(args)
    }

    // MARK: - Process plumbing

    /// Subcommands Theo Notes may run: the first token, plus the second for the grouped ones.
    private static let singleTokenCommands: Set<String> = ["list", "search", "show", "cat"]
    private static let groupedCommands: [String: Set<String>] = [
        "tags": ["list"], "pin": ["list"], "attachments": ["list", "save"],
    ]

    static func isAllowed(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if singleTokenCommands.contains(first) { return true }
        guard let allowedSecond = groupedCommands[first], args.count > 1 else { return false }
        return allowedSecond.contains(args[1])
    }

    /// Runs bearcli with `args` and returns stdout. stdout and stderr are drained concurrently so
    /// a multi-megabyte library cannot fill a pipe buffer and deadlock the child. After `timeout`
    /// seconds (default `listTimeout`) the child is terminated (SIGTERM, then SIGKILL).
    func run(_ args: [String], timeout: TimeInterval? = nil) throws -> Data {
        guard Self.isAllowed(args) else {
            throw BearCLIError.forbiddenSubcommand(args.prefix(2).joined(separator: " "))
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BearCLIError.notInstalled
        }
        #if os(macOS)
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw BearCLIError.notInstalled }

        let stdout = Drain(out.fileHandleForReading)
        let stderr = Drain(err.fileHandleForReading)
        if exited.wait(timeout: .now() + (timeout ?? listTimeout)) == .timedOut {
            // The drains are abandoned: they end when the last writer of the pipes exits.
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw BearCLIError.timedOut
        }
        let outData = stdout.finish(), errData = stderr.finish()

        guard process.terminationStatus == 0 else {
            if let e = try? JSONDecoder().decode(ErrorEnvelope.self, from: outData) {
                throw BearCLIError.bear(code: e.error.code, message: e.error.message)
            }
            var stderr = String(decoding: errData.prefix(Self.stderrLimit), as: UTF8.self)
            while stderr.utf8.count > Self.stderrLimit { stderr.removeLast() }
            throw BearCLIError.failed(code: process.terminationStatus, stderr: stderr)
        }
        return outData
        #else
        throw BearCLIError.notInstalled
        #endif
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let code: String; let message: String }
        let error: Body
    }
}

/// Reads a pipe to EOF on its own thread. Not on a GCD queue: the read blocks, and when the
/// CPUs are saturated GCD does not add threads, so a child writing a large output could wait
/// for a reader until its timeout.
final class Drain: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        let thread = Thread { [self] in
            data = handle.readDataToEndOfFile()
            group.leave()
        }
        thread.name = "baerchen.pipe-drain"
        thread.start()
    }

    func finish() -> Data {
        group.wait()
        return data
    }
}
