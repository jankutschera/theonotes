// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Runs one MCP tool. Task 10 supplies the real one; the server only checks that the tool exists.
protocol MCPToolHandler: Sendable {
    /// `arguments` is always an object. A success is the result object (sent as `structuredContent` and as
    /// sorted-key JSON text); a failure becomes a tool error result (`isError`), never a JSON-RPC error,
    /// so a library that cannot be opened is reported to the model, and a later call can recover.
    func call(_ name: String, arguments: JSONValue) async -> Result<JSONValue, AutomationError>
}

/// The MCP server over stdio (protocol 2025-06-18 and the two older versions it negotiates down to).
/// It needs no library of its own: `initialize`, `ping` and `tools/list` answer without one,
/// and only the handler opens it, per call.
final class MCPServer: Sendable {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverName = "theonotes"
    static let serverTitle = "Theo Notes"

    private let handler: any MCPToolHandler
    private let source: LineSource
    private let sink: Sink

    /// `read` returns the next input line without its terminator, or nil at the end of the input; it may
    /// block. `write` receives one complete, newline-terminated JSON line per call and must not buffer.
    init(handler: any MCPToolHandler, read: @escaping () -> Data?, write: @escaping (Data) -> Void) {
        self.handler = handler
        self.source = LineSource(read: read)
        self.sink = Sink(write: write)
    }

    /// Reads lines on a background thread and answers them in arrival order. Returns at the end of the input,
    /// after the requests already read have been answered.
    func run() async {
        let source = self.source
        let lines = AsyncStream<Data> { continuation in
            let thread = Thread {
                while let line = source.next() { continuation.yield(line) }
                continuation.finish()
            }
            thread.name = "baerchen-mcp-stdin"
            thread.start()
        }
        for await line in lines { await handle(line) }
    }

    // MARK: Dispatch

    private func handle(_ line: Data) async {
        guard line.contains(where: { ![0x20, 0x09, 0x0D, 0x0A].contains($0) }) else { return }
        switch JSONRPC.parse(line: line) {
        case .unparsable(let detail):
            sink.write(JSONRPC.error(id: .null, code: JSONRPC.ErrorCode.parse, message: "Parse error: \(detail)"))
        case .invalid(let id):
            sink.write(JSONRPC.error(id: id, code: JSONRPC.ErrorCode.invalidRequest, message: "Invalid Request"))
        case .notification, .response:
            break
        case .request(let id, let method, let params):
            sink.write(await respond(id: id, method: method, params: params))
        }
    }

    private func respond(id: JSONValue, method: String, params: JSONValue?) async -> Data {
        switch method {
        case "initialize":
            return JSONRPC.result(id: id, Self.initializeResult(params))
        case "ping":
            return JSONRPC.result(id: id, .object([]))
        case "tools/list":
            return JSONRPC.result(id: id, .object([("tools", .array(MCPToolCatalog.tools))]))
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return JSONRPC.error(id: id, code: JSONRPC.ErrorCode.methodNotFound, message: "method not found: \(method)")
        }
    }

    private static func initializeResult(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.string
        let version = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
        return .object([
            ("protocolVersion", .string(version)),
            ("capabilities", .object([("tools", .object([]))])),
            (
                "serverInfo",
                .object([
                    ("name", .string(serverName)), ("title", .string(serverTitle)),
                    ("version", .string(AutomationVersion.string)),
                ])
            ),
            ("instructions", .string(MCPToolCatalog.instructions)),
        ])
    }

    private func callTool(id: JSONValue, params: JSONValue?) async -> Data {
        guard let name = params?["name"]?.string else {
            return JSONRPC.error(id: id, code: JSONRPC.ErrorCode.invalidParams, message: "Invalid params: missing tool name")
        }
        guard MCPToolCatalog.toolNames.contains(name) else {
            return JSONRPC.error(id: id, code: JSONRPC.ErrorCode.invalidParams, message: "unknown tool: \(name)")
        }
        let arguments: JSONValue
        switch params?["arguments"] {
        case nil, .null?: arguments = .object([])
        case .object?: arguments = params?["arguments"] ?? .object([])
        default:
            return JSONRPC.error(
                id: id, code: JSONRPC.ErrorCode.invalidParams, message: "Invalid params: arguments must be an object")
        }
        switch await handler.call(name, arguments: arguments) {
        case .success(let result):
            return JSONRPC.result(
                id: id,
                .object([("content", Self.textContent(result)), ("structuredContent", result)]))
        case .failure(let error):
            return JSONRPC.result(
                id: id, .object([("content", Self.textContent(error.envelope())), ("isError", .bool(true))]))
        }
    }

    /// One text item holding the value as sorted-key JSON (the MCP contract).
    private static func textContent(_ value: JSONValue) -> JSONValue {
        .array([.object([("type", "text"), ("text", .string(value.serialized(sortedKeys: true)))])])
    }
}

// MARK: Plumbing

/// The input closure is called from one thread only (the reader thread), which is why it may cross it.
private final class LineSource: @unchecked Sendable {
    private let read: () -> Data?
    init(read: @escaping () -> Data?) { self.read = read }
    func next() -> Data? { read() }
}

/// The output closure is called from the dispatch loop only, one line at a time.
private final class Sink: @unchecked Sendable {
    private let writeLine: (Data) -> Void
    init(write: @escaping (Data) -> Void) { self.writeLine = write }
    func write(_ line: Data) { writeLine(line) }
}

/// Splits a byte stream into lines; used for the real stdin and for tests that hand over all input at once.
/// A line of any length costs linear time: bytes already scanned for a newline are not scanned again, and
/// consumed lines are dropped from the buffer in bulk, not one by one.
final class LineReader {
    private let chunk: () -> Data?
    private var buffer: [UInt8] = []
    /// `buffer[start...]` is unconsumed; `buffer[start..<scanned]` is known to hold no newline.
    private var start = 0
    private var scanned = 0
    private var finished = false

    /// `chunk` returns the next piece of input, or nil / empty data at the end.
    init(chunk: @escaping () -> Data?) { self.chunk = chunk }

    /// The next line without its `\n` (and a `\r` before it); a last line without a terminator counts.
    func next() -> Data? {
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                var end = newline
                if end > start, buffer[end - 1] == 0x0D { end -= 1 }
                let line = Data(buffer[start..<end])
                start = newline + 1
                scanned = start
                compact()
                return line
            }
            scanned = buffer.count
            if finished {
                guard start < buffer.count else { return nil }
                let line = Data(buffer[start...])
                buffer.removeAll()
                start = 0
                scanned = 0
                return line
            }
            if let piece = chunk(), !piece.isEmpty {
                buffer.append(contentsOf: piece)
            } else {
                finished = true
            }
        }
    }

    /// Drops the consumed prefix once it is at least half of the buffer (or all of it).
    private func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
            scanned = 0
        } else if start >= 1 << 16, start * 2 >= buffer.count {
            buffer.removeSubrange(0..<start)
            scanned -= start
            start = 0
        }
    }
}
