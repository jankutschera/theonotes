// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// One note as Apple Notes' scripting interface lists it (no body).
public struct AppleNotesRecord: Equatable, Sendable {
    /// Notes' persistent id (`x-coredata://…/ICNote/p123`).
    public var id: String
    /// The note's title as Notes shows it.
    public var name: String
    public var created: Date
    public var modified: Date
    public var accountID: String
    /// The folder the note is in (`nil` if Notes reports none).
    public var folderID: String?
    public var isPasswordProtected: Bool

    public init(
        id: String, name: String, created: Date, modified: Date, accountID: String, folderID: String?,
        isPasswordProtected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.created = created
        self.modified = modified
        self.accountID = accountID
        self.folderID = folderID
        self.isPasswordProtected = isPasswordProtected
    }
}

public struct AppleNotesAccount: Equatable, Sendable {
    public var id: String
    public var name: String
    public var defaultFolderID: String?

    public init(id: String, name: String, defaultFolderID: String? = nil) {
        self.id = id
        self.name = name
        self.defaultFolderID = defaultFolderID
    }
}

public struct AppleNotesFolder: Equatable, Sendable {
    public var id: String
    public var name: String
    public var accountID: String
    /// The enclosing folder; `nil` at the account's top level.
    public var parentID: String?

    public init(id: String, name: String, accountID: String, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.accountID = accountID
        self.parentID = parentID
    }
}

/// Everything listed in one pass: accounts, folders, note metadata.
public struct AppleNotesListing: Equatable, Sendable {
    public var accounts: [AppleNotesAccount]
    public var folders: [AppleNotesFolder]
    public var notes: [AppleNotesRecord]

    public init(accounts: [AppleNotesAccount], folders: [AppleNotesFolder], notes: [AppleNotesRecord]) {
        self.accounts = accounts
        self.folders = folders
        self.notes = notes
    }

    /// Folder names Notes uses for its trash (skipped on import).
    public static let recentlyDeletedNames: Set<String> = [
        "recently deleted", "zuletzt gelöscht", "suppressions récentes", "eliminados recientemente",
        "eliminati di recente", "onlangs verwijderd", "nyligen raderade",
    ]

    /// Folder names from the account's top level down to the folder.
    public func folderPath(_ folderID: String?) -> [AppleNotesFolder] {
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var path: [AppleNotesFolder] = []
        var current = folderID.flatMap { byID[$0] }
        var seen = Set<String>()
        while let folder = current, seen.insert(folder.id).inserted {
            path.insert(folder, at: 0)
            current = folder.parentID.flatMap { byID[$0] }
        }
        return path
    }

    public func isRecentlyDeleted(_ note: AppleNotesRecord) -> Bool {
        folderPath(note.folderID).contains { Self.recentlyDeletedNames.contains($0.name.lowercased()) }
    }
}

/// One body batch: bodies by id, plus per-note failures (`id → message`, e.g. the JXA error number).
public struct AppleNotesBodies: Equatable, Sendable {
    public var bodies: [String: AppleNotesBody]
    public var errors: [String: String]

    public init(bodies: [String: AppleNotesBody] = [:], errors: [String: String] = [:]) {
        self.bodies = bodies
        self.errors = errors
    }
}

/// A note body and how many attachments Notes says the note has.
public struct AppleNotesBody: Equatable, Sendable {
    public var html: String
    public var attachmentCount: Int

    public init(html: String, attachmentCount: Int = 0) {
        self.html = html
        self.attachmentCount = attachmentCount
    }
}

public enum AppleNotesError: Error, Equatable, Sendable {
    /// macOS Automation permission for Notes was denied (-1743).
    case notAuthorized
    /// Notes could not be reached (-600 / -609).
    case notesUnavailable
    /// osascript failed; carries only the error number and the JavaScript error class
    /// (`TypeError`, `"unknown"`): its message can echo a note or folder name.
    case scriptFailed(code: Int?, kind: String)
    /// The script printed something that is not the expected JSON.
    case invalidOutput
    case timedOut
    /// The run was cancelled while Notes was being asked.
    case cancelled
    /// One note in a body batch could not be read.
    case noteUnreadable(String)
}

extension AppleNotesError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAuthorized:
            "Theo Notes is not allowed to control Notes. Allow it in System Settings → Privacy & Security → Automation."
        case .notesUnavailable: "Apple Notes could not be reached"
        case .scriptFailed(let code, let kind):
            code.map { "Notes scripting error \($0) (\(kind))" } ?? "Notes scripting failed (\(kind))"
        case .invalidOutput: "Notes returned unexpected output"
        case .timedOut: "Notes did not answer in time"
        case .cancelled: "cancelled"
        case .noteUnreadable(let message): "note could not be read: \(message)"
        }
    }
}

/// Read-only access to Apple Notes. Implementations never write to Notes.
public protocol AppleNotesClient: Sendable {
    /// Accounts, folders and every note's metadata, without bodies.
    func listing() throws -> AppleNotesListing
    /// Bodies for `ids` (one batch). Notes that could not be read are in `errors`; ids missing
    /// from both are reported by the importer. Throws when the whole batch failed, and
    /// `.cancelled` soon after `isCancelled` turns true (a running request is stopped).
    func bodies(ids: [String], isCancelled: () -> Bool) throws -> AppleNotesBodies
}

/// Talks to Notes through its scripting interface: JXA run by `/usr/bin/osascript` with an
/// argument array (no shell). Never reads Notes' database. The first run triggers macOS'
/// Automation prompt ("Theo Notes wants to control Notes").
public struct ScriptingAppleNotesClient: AppleNotesClient {
    public static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    /// By bundle id: `Application("Notes")` can resolve to another app and fail with -600.
    static let bundleID = "com.apple.Notes"

    public let listTimeout: TimeInterval
    /// A body batch may take `bodyBaseTimeout + bodyTimeoutPerNote × count` seconds.
    public let bodyBaseTimeout: TimeInterval
    public let bodyTimeoutPerNote: TimeInterval

    public init(listTimeout: TimeInterval = 300, bodyBaseTimeout: TimeInterval = 60, bodyTimeoutPerNote: TimeInterval = 30) {
        self.listTimeout = listTimeout
        self.bodyBaseTimeout = bodyBaseTimeout
        self.bodyTimeoutPerNote = bodyTimeoutPerNote
    }

    func bodyTimeout(count: Int) -> TimeInterval {
        bodyBaseTimeout + bodyTimeoutPerNote * TimeInterval(count)
    }

    public func listing() throws -> AppleNotesListing {
        let data = try run(Self.listingScript, arguments: [], timeout: listTimeout)
        return try Self.decodeListing(data)
    }

    public func bodies(ids: [String], isCancelled: () -> Bool) throws -> AppleNotesBodies {
        guard !ids.isEmpty else { return AppleNotesBodies() }
        // Ids are passed as arguments; one starting with `-` could be read as an option.
        guard ids.allSatisfy({ !$0.hasPrefix("-") && !$0.contains("\u{0}") }) else { throw AppleNotesError.invalidOutput }
        let data = try run(Self.bodiesScript, arguments: ids, timeout: bodyTimeout(count: ids.count), isCancelled: isCancelled)
        return try Self.decodeBodies(data)
    }

    // MARK: - Scripts

    /// Folders of every account (nested ones through `folders` of each folder), deepest first,
    /// so a note listed by both a folder and its parent lands in the deepest one.
    static let listingScript = #"""
        function run(argv) {
          var N = Application("com.apple.Notes");
          var out = {accounts: [], folders: [], notes: []};
          var seenFolders = {}, seenNotes = {};
          var accounts = N.accounts;
          var accountIDs = accounts.id(), accountNames = accounts.name();
          for (var i = 0; i < accountIDs.length; i++) {
            var account = accounts.byId(accountIDs[i]);
            var defaultFolder = null;
            try { defaultFolder = account.defaultFolder().id(); } catch (e) {}
            out.accounts.push({id: accountIDs[i], name: accountNames[i], defaultFolder: defaultFolder});
            var queue = [];
            var ids = account.folders.id(), names = account.folders.name();
            for (var j = 0; j < ids.length; j++) queue.push({id: ids[j], name: names[j], parent: null, depth: 0});
            var listed = [];
            while (queue.length > 0) {
              var f = queue.shift();
              if (seenFolders[f.id]) continue;
              seenFolders[f.id] = true;
              var folder = N.folders.byId(f.id);
              var parent = f.parent;
              if (parent === null) {
                try {
                  var container = folder.container().id();
                  if (container !== accountIDs[i] && container.indexOf("Account") < 0) parent = container;
                } catch (e) {}
              }
              f.parent = parent;
              listed.push(f);
              var subIDs = [], subNames = [];
              try { subIDs = folder.folders.id(); subNames = folder.folders.name(); } catch (e) {}
              for (var k = 0; k < subIDs.length; k++) {
                queue.push({id: subIDs[k], name: subNames[k], parent: f.id, depth: f.depth + 1});
              }
            }
            listed.sort(function (a, b) { return b.depth - a.depth; });
            for (var m = 0; m < listed.length; m++) {
              var lf = listed[m];
              out.folders.push({id: lf.id, name: lf.name, account: accountIDs[i], parent: lf.parent});
              var notes = N.folders.byId(lf.id).notes;
              var nIDs = notes.id();
              if (nIDs.length === 0) continue;
              var nNames = notes.name(), nCreated = notes.creationDate(), nModified = notes.modificationDate();
              var nLocked = notes.passwordProtected();
              for (var n = 0; n < nIDs.length; n++) {
                if (seenNotes[nIDs[n]]) continue;
                seenNotes[nIDs[n]] = true;
                out.notes.push({id: nIDs[n], name: nNames[n], created: nCreated[n].toISOString(),
                  modified: nModified[n].toISOString(), account: accountIDs[i], folder: lf.id, locked: nLocked[n]});
              }
            }
          }
          return JSON.stringify(out);
        }
        """#

    /// Bodies for the ids in `argv`. Password-protected notes are never asked for their body.
    static let bodiesScript = #"""
        function run(argv) {
          var N = Application("com.apple.Notes");
          var out = [];
          for (var i = 0; i < argv.length; i++) {
            try {
              var note = N.notes.byId(argv[i]);
              var count = 0;
              try { count = note.attachments.id().length; } catch (e) {}
              out.push({id: argv[i], body: note.body(), attachments: count});
            } catch (e) {
              out.push({id: argv[i], error: String(e.errorNumber || "")});
            }
          }
          return JSON.stringify(out);
        }
        """#

    // MARK: - Decoding

    private struct RawListing: Decodable {
        struct Account: Decodable { let id: String; let name: String; let defaultFolder: String? }
        struct Folder: Decodable { let id: String; let name: String; let account: String; let parent: String? }
        struct Note: Decodable {
            let id: String; let name: String; let created: String; let modified: String
            let account: String; let folder: String?; let locked: Bool?
        }
        let accounts: [Account]
        let folders: [Folder]
        let notes: [Note]
    }

    static func decodeListing(_ data: Data) throws -> AppleNotesListing {
        guard let raw = try? JSONDecoder().decode(RawListing.self, from: data) else { throw AppleNotesError.invalidOutput }
        func date(_ s: String) throws -> Date {
            if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
            if let d = try? Date.ISO8601FormatStyle().parse(s) { return d }
            throw AppleNotesError.invalidOutput
        }
        return AppleNotesListing(
            accounts: raw.accounts.map { AppleNotesAccount(id: $0.id, name: $0.name, defaultFolderID: $0.defaultFolder) },
            folders: raw.folders.map { AppleNotesFolder(id: $0.id, name: $0.name, accountID: $0.account, parentID: $0.parent) },
            notes: try raw.notes.map {
                AppleNotesRecord(
                    id: $0.id, name: $0.name, created: try date($0.created), modified: try date($0.modified),
                    accountID: $0.account, folderID: $0.folder, isPasswordProtected: $0.locked ?? false)
            })
    }

    private struct RawBody: Decodable {
        let id: String
        let body: String?
        let attachments: Int?
        let error: String?
    }

    static func decodeBodies(_ data: Data) throws -> AppleNotesBodies {
        guard let raw = try? JSONDecoder().decode([RawBody].self, from: data) else { throw AppleNotesError.invalidOutput }
        var result = AppleNotesBodies()
        for entry in raw {
            if let body = entry.body {
                result.bodies[entry.id] = AppleNotesBody(html: body, attachmentCount: entry.attachments ?? 0)
            } else {
                let code = (entry.error ?? "").filter { $0 == "-" || $0.isNumber }
                result.errors[entry.id] = code.isEmpty ? "Notes could not read this note"
                    : "Notes scripting error \(code.prefix(8)) for this note"
            }
        }
        return result
    }

    // MARK: - Process

    /// Runs `osascript -l JavaScript -e <script> <arguments…>` and returns stdout.
    func run(_ script: String, arguments: [String], timeout: TimeInterval, isCancelled: () -> Bool = { false }) throws -> Data {
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                Self.osascript, arguments: ["-l", "JavaScript", "-e", script] + arguments, timeout: timeout,
                isCancelled: isCancelled)
        } catch ProcessRunner.Stop.timedOut {
            throw AppleNotesError.timedOut
        } catch ProcessRunner.Stop.cancelled {
            throw AppleNotesError.cancelled
        }
        guard result.status == 0 else { throw Self.error(stderr: result.stderr) }
        return result.stdout
    }

    /// Maps osascript's `execution error: <Class>: … (-1743)` lines to errors. Only the number
    /// and the error class are kept, never the message.
    static func error(stderr: Data) -> AppleNotesError {
        let text = String(decoding: stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var code: Int?
        if let close = text.lastIndex(of: ")"), let open = text[..<close].lastIndex(of: "(") {
            code = Int(text[text.index(after: open)..<close])
        }
        switch code {
        case -1743, -1744: return .notAuthorized
        case -600, -609, -10810: return .notesUnavailable
        case -1712: return .timedOut
        default:
            let message = (text.components(separatedBy: "execution error:").last ?? text)
                .trimmingCharacters(in: .whitespaces)
            let name = message.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let isClass = name.hasSuffix("Error") && message.dropFirst(name.count).hasPrefix(":")
            return .scriptFailed(code: code, kind: isClass ? String(name) : "unknown")
        }
    }
}

/// Runs a child process with an argument array (no shell), draining stdout and stderr
/// concurrently. Throws `Stop.timedOut` after `timeout`, or `Stop.cancelled` within ~0.25 s of
/// `isCancelled` turning true; either way the child is terminated.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    enum Stop: Error { case timedOut, cancelled, unsupportedPlatform }

    static func run(
        _ executable: URL, arguments: [String], timeout: TimeInterval, isCancelled: () -> Bool = { false }
    ) throws -> Output {
        #if os(macOS)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let stdout = Drain(out.fileHandleForReading)
        let stderr = Drain(err.fileHandleForReading)
        let deadline = DispatchTime.now() + timeout
        var stop: Stop?
        while exited.wait(timeout: min(deadline, .now() + 0.25)) == .timedOut {
            if isCancelled() { stop = .cancelled } else if DispatchTime.now() >= deadline { stop = .timedOut }
            guard let stop else { continue }
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            throw stop
        }
        return Output(status: process.terminationStatus, stdout: stdout.finish(), stderr: stderr.finish())
        #else
        throw Stop.unsupportedPlatform
        #endif
    }
}
