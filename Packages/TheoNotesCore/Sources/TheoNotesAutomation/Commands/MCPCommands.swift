// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// `mcp-server`: serves MCP over stdin/stdout until stdin closes. It reads stdin before it opens any
/// library; its tool handler asks for the library on every call, so a library that
/// appears later is picked up and one that cannot be opened is a tool error, never a crash.
enum MCPCommands {
    static let handlers: [[String]: CommandHandler] = [["mcp-server"]: mcpServer]

    private static func mcpServer(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let io = env.io
        let lines: () -> Data? = io.readLine ?? LineReader(chunk: Chunks(io.readStdin).next).next
        // The scope comes from `--only-tags` / `--exclude-tags` and the `THEONOTES_MCP_*` variables (old `BAERCHEN_MCP_*` still read)
        //.
        let scope = try NoteScope.fromMCPServer(flags: parsed, environment: env.context.environment)
        warnAboutUnknownTags(scope, env)
        let tools = MCPTools(libraryProvider: env.libraryProvider, context: env.context, scope: scope)
        let server = MCPServer(handler: tools, read: lines, write: io.write)
        // The handler is synchronous: block until the async server loop ends (stdin closed). The
        // loop runs on `OffPoolExecutor`, so it never needs the cooperative-pool thread a caller
        // may block here (a synchronous test does).
        let finished = DispatchSemaphore(value: 0)
        Task.detached(executorPreference: OffPoolExecutor.shared) {
            await server.run()
            finished.signal()
        }
        finished.wait()
    }
}

extension MCPCommands {
    /// One stderr line per scope list naming a tag the library does not have (MCP clients log a
    /// server's stderr). The scope itself is unchanged; a library that cannot be opened yet is no
    /// error here, every tool call reports that on its own.
    static func warnAboutUnknownTags(_ scope: NoteScope, _ env: CommandEnvironment) {
        guard scope.isRestricted, let library = try? env.library(),
              let unknown = try? library.database.pool.read({ try scope.unknownNames(db: $0) }) else { return }
        let list = { (names: [String]) in names.map { "#" + $0 }.joined(separator: ", ") }
        if !unknown.exclude.isEmpty {
            env.io.writeError("theonotes mcp-server: warning: --exclude-tags names no tag in this library: \(list(unknown.exclude)). It hides nothing; check the spelling.\n")
        }
        if !unknown.only.isEmpty {
            env.io.writeError("theonotes mcp-server: warning: --only-tags names no tag in this library: \(list(unknown.only)). Notes with it stay out of reach until the tag exists.\n")
        }
    }
}

/// `readStdin` hands over all input at once; it is read lazily on the first line request, then once.
private final class Chunks: @unchecked Sendable {
    private let readAll: () -> Data
    private var done = false
    init(_ readAll: @escaping () -> Data) { self.readAll = readAll }
    func next() -> Data? {
        guard !done else { return nil }
        done = true
        return readAll()
    }
}
