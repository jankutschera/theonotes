// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

typealias CommandHandler = @Sendable (ParsedCommand, CommandEnvironment) throws(AutomationError) -> Void

/// Opens the library on first use and keeps it; a failed open is not remembered, so the next
/// call tries again (an `mcp-server` started before the app created the library recovers). A kept
/// library's schema is checked again on every later call: once a newer app migrated it, every
/// call is `AutomationLibrary.upgraded` (final review I2). A kept library whose database file has
/// disappeared (the app moved the folder) is reopened through `open`, which resolves the path again.
final class LibraryProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let open: () throws(AutomationError) -> AutomationLibrary
    /// Where the library is now, resolved again on every call (nil: unknown, then only a vanished
    /// database file triggers a reopen). The folder of a library that was found at the old
    /// `Baerchen` path may be superseded by `Theo Notes` at any time (REN-R13).
    private let currentRoot: (@Sendable () -> URL?)?
    private var opened: AutomationLibrary?

    init(
        currentRoot: (@Sendable () -> URL?)? = nil, open: @escaping () throws(AutomationError) -> AutomationLibrary
    ) {
        self.currentRoot = currentRoot
        self.open = open
    }

    func library() throws(AutomationError) -> AutomationLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let opened {
            // The app may have moved the library folder (`Baerchen` to `Theo Notes`, REN-R2) while
            // this process kept running. A pool opens new connections by path, so a kept library
            // whose files are gone, or whose path is no longer where the library resolves to, is
            // dropped and the path is resolved again: the next call opens the moved library, or
            // fails, but never creates an empty one at the old path. The old library is only
            // released, never closed: a request that still holds it finishes first (REN-R13).
            let moved = currentRoot?().map { $0.standardizedFileURL != opened.paths.root.standardizedFileURL } ?? false
            if !moved, FileManager.default.fileExists(atPath: opened.paths.database.path) {
                try opened.requireCurrentSchema()
                return opened
            }
            self.opened = nil
        }
        let library = try open()
        opened = library
        return library
    }
}

/// What a handler may use besides its parsed arguments. The library is opened lazily (ruling
/// M5-R45): a handler checks its arguments first, and `app open` / `mcp-server` may never need it.
struct CommandEnvironment {
    let context: AutomationContext
    let io: CLIIO
    let libraryProvider: LibraryProvider

    /// The opened library; `library_unavailable` or `busy` when it cannot be opened.
    func library() throws(AutomationError) -> AutomationLibrary { try libraryProvider.library() }

    /// The `--content` value, else stdin decoded as UTF-8; a terminal on stdin counts as empty
    /// (ruling M5-R13).
    func content(_ parsed: ParsedCommand) -> String {
        if let value = parsed.value("--content") { return value }
        guard !io.stdinIsTTY else { return "" }
        return String(decoding: io.readStdin(), as: UTF8.self)
    }
}

enum CommandRegistry {
    /// Each command file contributes its own `static let handlers` here, e.g. `ReadCommands.handlers`.
    /// A path registered twice is a programming error.
    static let handlers: [[String]: CommandHandler] = merge([
        ReadCommands.handlers, SectionCommands.handlers, WriteCommands.handlers, AttachmentCommands.handlers,
        MCPCommands.handlers, AppCommands.handlers,
    ])

    static func handler(_ path: [String]) -> CommandHandler? { handlers[path] }

    private static func merge(_ parts: [[[String]: CommandHandler]]) -> [[String]: CommandHandler] {
        var merged: [[String]: CommandHandler] = [:]
        for part in parts {
            for (path, handler) in part {
                precondition(merged[path] == nil, "command registered twice: \(path.joined(separator: " "))")
                merged[path] = handler
            }
        }
        return merged
    }
}
