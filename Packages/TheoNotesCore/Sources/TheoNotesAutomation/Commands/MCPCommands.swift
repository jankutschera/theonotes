// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// `mcp-server`: serves MCP over stdin/stdout until stdin closes. It reads stdin before it opens any
/// library (ruling M5-R45); its tool handler asks for the library on every call, so a library that
/// appears later is picked up and one that cannot be opened is a tool error, never a crash.
enum MCPCommands {
    static let handlers: [[String]: CommandHandler] = [["mcp-server"]: mcpServer]

    private static func mcpServer(_ parsed: ParsedCommand, _ env: CommandEnvironment) throws(AutomationError) {
        let io = env.io
        let lines: () -> Data? = io.readLine ?? LineReader(chunk: Chunks(io.readStdin).next).next
        // The scope comes from `--only-tags` / `--exclude-tags` and the `THEONOTES_MCP_*` variables (old `BAERCHEN_MCP_*` still read)
        // (rulings M5-R18, M5-R141).
        let scope = try NoteScope.fromMCPServer(flags: parsed, environment: env.context.environment)
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
