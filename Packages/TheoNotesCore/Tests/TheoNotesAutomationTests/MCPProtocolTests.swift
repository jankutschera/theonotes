// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// Answers every call with a fixed result and remembers what it was asked.
final class RecordingToolHandler: MCPToolHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(name: String, arguments: JSONValue)] = []
    private let respond: @Sendable (String, JSONValue) async -> Result<JSONValue, AutomationError>

    init(_ respond: @escaping @Sendable (String, JSONValue) async -> Result<JSONValue, AutomationError>) {
        self.respond = respond
    }

    var calls: [(name: String, arguments: JSONValue)] { lock.withLock { recorded } }

    func call(_ name: String, arguments: JSONValue) async -> Result<JSONValue, AutomationError> {
        lock.withLock { recorded.append((name, arguments)) }
        return await respond(name, arguments)
    }

    static let ok = RecordingToolHandler { name, _ in .success(.object([("tool", .string(name)), ("z", 1), ("a", .array([2]))])) }
}

/// Every chunk a server wrote, in order.
final class ChunkCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Data] = []
    func write(_ data: Data) { lock.withLock { all.append(data) } }
    var chunks: [Data] { lock.withLock { all } }
}

/// Feeds `lines` to a server over in-memory closures and returns every chunk it wrote.
func runServerRaw(_ lines: [String], handler: any MCPToolHandler = RecordingToolHandler.ok) async -> [Data] {
    let capture = ChunkCapture()
    var remaining = lines.map { Data($0.utf8) }[...]
    let server = MCPServer(handler: handler, read: { remaining.popFirst() }, write: { capture.write($0) })
    await server.run()
    return capture.chunks
}

func runServer(_ lines: [String], handler: any MCPToolHandler = RecordingToolHandler.ok) async throws -> [JSONValue] {
    try await runServerRaw(lines, handler: handler).map { try JSONValue(parsing: $0) }
}

/// Feeds raw `chunks` through the streaming `LineReader`, as the real stdin does, and returns every reply.
func runServerChunked(_ chunks: [Data], handler: any MCPToolHandler = RecordingToolHandler.ok) async throws -> [JSONValue] {
    let capture = ChunkCapture()
    var remaining = chunks[...]
    let reader = LineReader { remaining.popFirst() }
    let server = MCPServer(handler: handler, read: { reader.next() }, write: { capture.write($0) })
    await server.run()
    return try capture.chunks.map { try JSONValue(parsing: $0) }
}

@Suite struct MCPProtocolTests {
    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}"#

    @Test func initializeNegotiatesVersionAndIdentifies() async throws {
        let replies = try await runServer([Self.initialize])
        #expect(replies.count == 1)
        #expect(replies[0]["id"] == 1 && replies[0]["jsonrpc"] == "2.0")
        let result = try #require(replies[0]["result"])
        #expect(result["protocolVersion"] == .string("2025-03-26"))
        #expect(result["serverInfo"]?["name"] == .string("theonotes"))
        #expect(result["serverInfo"]?["title"] == .string("Theo Notes"))
        #expect(result["serverInfo"]?["version"] == .string(AutomationVersion.string))
        #expect(result["serverInfo"]?["version"] == .string(AutomationVersion.string))
        #expect(result["capabilities"] == .object([("tools", .object([]))]))
        #expect(result["instructions"] == .string(MCPToolCatalog.instructions))
    }

    @Test func initializeResultHasTheKeysBearsServerSends() async throws {
        let facts = try MCPFixtures.observedFacts()
        let replies = try await runServer([Self.initialize])
        let result = try #require(replies[0]["result"])
        #expect(result.keys.sorted() == (facts["mcpInitializeResultKeys"]?.array ?? []).compactMap(\.string).sorted())
        #expect(result["serverInfo"]?.keys.sorted() == (facts["mcpServerInfoKeys"]?.array ?? []).compactMap(\.string).sorted())
        #expect(result["capabilities"]?.keys == (facts["mcpCapabilities"]?.array ?? []).compactMap(\.string))
    }

    @Test func protocolVersionIsTheClientsWhenSupportedElseTheNewest() async throws {
        func version(_ params: String) async throws -> JSONValue? {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":"# + params + "}"
            return try await runServer([line])[0]["result"]?["protocolVersion"]
        }
        #expect(try await version(#"{"protocolVersion":"2025-06-18"}"#) == "2025-06-18")
        #expect(try await version(#"{"protocolVersion":"2025-03-26"}"#) == "2025-03-26")
        #expect(try await version(#"{"protocolVersion":"2024-11-05"}"#) == "2024-11-05")
        #expect(try await version(#"{"protocolVersion":"2099-01-01"}"#) == "2025-06-18")
        #expect(try await version(#"{"protocolVersion":7}"#) == "2025-06-18")
        #expect(try await version(#"{}"#) == "2025-06-18")
        #expect(try await version(#"null"#) == "2025-06-18")
    }

    @Test func pingAnswersAnEmptyObjectAndIdsAreEchoedAsTheyCame() async throws {
        let replies = try await runServer([
            #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2.5,"method":"ping"}"#,
        ])
        #expect(replies.map { $0["id"] } == [.int(7), .string("abc"), .number("2.5")])
        for reply in replies { #expect(reply["result"] == .object([])) }
        let facts = try MCPFixtures.observedFacts()
        #expect(facts["mcpPingResultKeys"] == .array([]))
    }

    @Test func toolsListIsTheCatalog() async throws {
        let replies = try await runServer([#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#])
        let tools = try #require(replies[0]["result"]?["tools"]?.array)
        #expect(tools.count == 28)
        #expect(tools.compactMap { $0["name"]?.string } == MCPToolCatalog.toolNames)
        // Keys come out sorted, so compare as sets of sorted serializations.
        #expect(
            tools.map { $0.serialized(sortedKeys: true) } == MCPToolCatalog.tools.map { $0.serialized(sortedKeys: true) })
    }

    @Test func notificationsGetNoReplyAndErrorsUseJsonRpcCodes() async throws {
        let replies = try await runServer([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/unknown/thing","params":{}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"bogus/method"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
            "{",
            #"{"jsonrpc":"2.0","id":6}"#,
            #"[1,2]"#,
        ])
        #expect(replies.count == 5)
        #expect(replies[0]["id"] == 4 && replies[0]["error"]?["code"] == -32601)
        #expect(replies[0]["error"]?["message"] == .string("method not found: bogus/method"))
        #expect(replies[1]["id"] == 5 && replies[1]["error"]?["code"] == -32602)
        #expect(replies[1]["error"]?["message"] == .string("unknown tool: no_such_tool"))
        #expect(replies[2]["id"] == .null && replies[2]["error"]?["code"] == -32700)
        #expect(replies[3]["id"] == 6 && replies[3]["error"]?["code"] == -32600)
        #expect(replies[3]["error"]?["message"] == .string("Invalid Request"))
        #expect(replies[4]["id"] == .null && replies[4]["error"]?["code"] == -32600)
        for reply in replies { #expect(reply["result"] == nil) }
    }

    /// The same exchanges Bear's server was probed with (`probeMCP`): codes and messages as observed.
    @Test func errorsMatchTheObservedBearServer() async throws {
        let facts = try MCPFixtures.observedFacts()
        let replies = try await runServer([
            #"{"jsonrpc":"2.0","id":1,"method":"bogus/method"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
            "{",
        ])
        #expect(replies[0]["error"]?["code"] == facts["mcpUnknownMethodCode"])
        #expect(replies[0]["error"]?["message"] == facts["mcpUnknownMethodMessage"])
        #expect(replies[1]["error"]?["code"] == facts["mcpUnknownToolCode"])
        #expect(replies[1]["error"]?["message"] == facts["mcpUnknownToolMessage"])
        #expect(replies[2]["error"]?["code"] == facts["mcpMalformedJSONCode"])
        #expect(facts["mcpMalformedJSONIDIsNull"] == true && replies[2]["id"] == .null)
        // Bear's message is one line of decoder text; ours is one line that starts with "Parse error".
        let message = try #require(replies[2]["error"]?["message"]?.string)
        #expect(message.hasPrefix("Parse error") && !message.contains("\n"))
    }

    @Test func toolResultAndToolErrorEnvelopes() async throws {
        let handler = RecordingToolHandler { name, arguments in
            name == "get_note"
                ? .failure(AutomationError(code: .noteNotFound, message: "Note not found: ZZZ-NOPE"))
                : .success(.object([("z", 1), ("a", .object([("y", true), ("b", "a/b \u{E4}")])), ("m", arguments)]))
        }
        let replies = try await runServer(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tags","arguments":{"id":"x"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"ZZZ-NOPE"}}}"#,
            ], handler: handler)
        let ok = try #require(replies[0]["result"])
        #expect(ok.keys.sorted() == ["content", "structuredContent"])
        let content = try #require(ok["content"]?.array)
        #expect(content.count == 1 && content[0]["type"] == "text")
        let structured = try #require(ok["structuredContent"])
        #expect(structured["z"] == 1)
        let text = try #require(content[0]["text"]?.string)
        #expect(text == structured.serialized(sortedKeys: true))
        #expect(text == #"{"a":{"b":"a/b \#u{E4}","y":true},"m":{"id":"x"},"z":1}"#)
        #expect(try JSONValue(parsing: Data(text.utf8)) == structured.sortedForTest)

        let failure = try #require(replies[1]["result"])
        #expect(failure.keys.sorted() == ["content", "isError"])
        #expect(failure["isError"] == true)
        let envelope = AutomationError(code: .noteNotFound, message: "Note not found: ZZZ-NOPE").envelope()
        #expect(failure["content"]?.array?.first?["text"] == .string(envelope.serialized(sortedKeys: true)))
        #expect(failure["content"]?.array?.count == 1 && failure["content"]?.array?.first?["type"] == "text")
        #expect(handler.calls.map(\.name) == ["list_tags", "get_note"])
        #expect(handler.calls[0].arguments == .object([("id", "x")]))
    }

    @Test func toolErrorsKeepDetailsAndMatchTheObservedShape() async throws {
        let facts = try MCPFixtures.observedFacts()
        #expect(facts["mcpToolErrorsAreIsError"] == true && facts["mcpResultKeys"] == .array(["content", "structuredContent"]))
        let candidates = JSONValue.object([("candidates", .array([.object([("address", "# a"), ("offset", 0)])]))])
        let handler = RecordingToolHandler { _, _ in
            .failure(AutomationError(code: .ambiguous, message: "Address matched N sections.", details: candidates))
        }
        let replies = try await runServer(
            [#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_note_content","arguments":{}}}"#],
            handler: handler)
        let text = try #require(replies[0]["result"]?["content"]?.array?.first?["text"]?.string)
        let envelope = try JSONValue(parsing: Data(text.utf8))
        #expect(envelope["error"]?["code"] == "ambiguous" && envelope["error"]?["details"]?["candidates"]?.array?.count == 1)
    }

    @Test func missingOrOddArgumentsReachTheHandlerAsAnObject() async throws {
        let handler = RecordingToolHandler { _, _ in .success(.object([])) }
        let replies = try await runServer(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tags"}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tags","arguments":null}}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tags","arguments":[1]}}"#,
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call"}"#,
                #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_tags","arguments":{"bogus_property":1}}}"#,
            ], handler: handler)
        #expect(replies[0]["result"] != nil && replies[1]["result"] != nil)
        #expect(replies[2]["error"]?["code"] == -32602)
        #expect(replies[3]["error"]?["code"] == -32602 && replies[4]["error"]?["code"] == -32602)
        // Unknown arguments are the handler's to ignore (the MCP contract).
        #expect(replies[5]["result"] != nil)
        #expect(handler.calls.map(\.arguments) == [.object([]), .object([]), .object([("bogus_property", 1)])])
    }

    @Test func requestsAreAnsweredInArrivalOrder() async throws {
        let handler = RecordingToolHandler { name, _ in
            if name == "list_notes" { try? await Task.sleep(nanoseconds: 150_000_000) }
            return .success(.object([("tool", .string(name))]))
        }
        let replies = try await runServer(
            [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_tags","arguments":{}}}"#,
            ], handler: handler)
        #expect(replies.map { $0["id"] } == [.int(1), .int(2), .int(3)])
    }

    @Test func stdoutCarriesOnlyJsonRpcLines() async throws {
        let chunks = await runServerRaw([
            Self.initialize,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#,
            "not json",
        ])
        #expect(chunks.count == 5)
        for chunk in chunks {
            #expect(chunk.last == 0x0A && chunk.filter { $0 == 0x0A }.count == 1)
            let value = try JSONValue(parsing: chunk)
            #expect(value["jsonrpc"] == "2.0")
            // Observed: keys are sorted at every level; `/` is not escaped (ruling M5-R30).
            #expect(String(decoding: chunk, as: UTF8.self) == value.serialized(sortedKeys: true) + "\n")
        }
    }

    @Test func endOfInputEndsTheRunAfterTheLastRequestAndAFinalLineNeedsNoNewline() async throws {
        let replies = try await runServer(["", "  ", #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, "\r"])
        #expect(replies.count == 1 && replies[0]["id"] == 1)
        let none = await runServerRaw([])
        #expect(none.isEmpty)
    }

    @Test func clientResponsesAreIgnoredWithoutAReply() async throws {
        let replies = try await runServer([
            #"{"jsonrpc":"2.0","id":9,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":"x","error":{"code":-32601,"message":"nope"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2}"#,
        ])
        #expect(replies.count == 2)
        #expect(replies[0]["id"] == 1 && replies[0]["result"] == .object([]))
        #expect(replies[1]["id"] == 2 && replies[1]["error"]?["code"] == -32600)
    }

    // MARK: Streaming input

    @Test func requestSplitAcrossChunksAndAnInvalidUTF8LineGoThroughTheStreamingReader() async throws {
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let cut = ping.index(ping.startIndex, offsetBy: 20)
        var invalid = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping","x":""#.utf8)
        invalid.append(contentsOf: [0xFF, 0xFE])
        invalid.append(Data("\"}\n".utf8))
        let chunks: [Data] = [
            Data(ping[..<cut].utf8),
            Data((String(ping[cut...]) + "\n").utf8) + invalid,
            Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8),
            Data("\n".utf8),
        ]
        let replies = try await runServerChunked(chunks)
        #expect(replies.count == 3)
        #expect(replies[0]["id"] == 1 && replies[0]["result"] == .object([]))
        #expect(replies[1]["id"] == .null && replies[1]["error"]?["code"] == -32700)
        #expect(replies[1]["error"]?["message"]?.string?.hasPrefix("Parse error") == true)
        #expect(replies[2]["id"] == 3 && replies[2]["result"] == .object([]))
    }

    @Test func aFiveMegabyteLineIsAnsweredInReasonableTime() async throws {
        let body = String(repeating: "a", count: 5_000_000)
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"overwrite_note","arguments":{"content":""#
            + body + #""}}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        let data = Data(request.utf8)
        let pieces = stride(from: 0, to: data.count, by: 65_536).map { data[$0..<min($0 + 65_536, data.count)] }
        let handler = RecordingToolHandler { _, arguments in
            .success(.object([("length", .int(arguments["content"]?.string?.utf8.count ?? -1))]))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let replies = try await runServerChunked(pieces.map { Data($0) }, handler: handler)
        let elapsed = clock.now - started
        #expect(replies.count == 2)
        #expect(replies[0]["result"]?["structuredContent"]?["length"] == .int(5_000_000))
        #expect(replies[1]["id"] == 2)
        // Linear reading takes about a second in a debug build; the old rescan took minutes for 20 MB.
        #expect(elapsed < .seconds(60), "took \(elapsed)")
    }

    // MARK: Lines

    @Test func lineReaderSplitsChunksIntoLines() {
        var pieces: [Data] = ["ab", "c\nd", "e\r\n\nf", "\n", "last"].map { Data($0.utf8) }
        let reader = LineReader { pieces.isEmpty ? nil : pieces.removeFirst() }
        var lines: [String] = []
        while let line = reader.next() { lines.append(String(decoding: line, as: UTF8.self)) }
        #expect(lines == ["abc", "de", "", "f", "last"])
        #expect(reader.next() == nil)
    }

    // MARK: Library handling (ruling M5-R45)

    @Test func serverAnswersWithoutAnyLibraryAndToolCallsReportItAsAToolError() throws {
        let empty = try TestLibrary.emptyFolder()
        let stdin = [
            Self.initialize, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#,
        ].joined(separator: "\n") + "\n"
        let r = runCLI(["baerchen", "mcp-server", "--data-dir", empty.path], stdin: Data(stdin.utf8))
        #expect(r.exit == 0 && r.err.isEmpty)
        let replies = try r.out.split(separator: "\n").map { try JSONValue(parsing: Data($0.utf8)) }
        #expect(replies.map { $0["id"] } == [.int(1), .int(2), .int(3), .int(4), .int(5)])
        #expect(replies[0]["result"]?["serverInfo"]?["name"] == "theonotes")
        #expect(replies[2]["result"]?["tools"]?.array?.count == 28)
        let failure = try #require(replies[3]["result"])
        #expect(failure["isError"] == true)
        let envelope = try JSONValue(parsing: Data((failure["content"]?.array?.first?["text"]?.string ?? "").utf8))
        #expect(envelope["error"]?["code"] == "library_unavailable")
        #expect(replies[4]["result"] == .object([]))
    }

    @Test func toolCallsOpenTheLibraryPerCallAndRecoverOnceItExists() async throws {
        final class Counter: @unchecked Sendable { var opens = 0 }
        let counter = Counter()
        let good = try TestLibrary.make().library
        let provider = LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
            counter.opens += 1
            if counter.opens == 1 { throw AutomationError(code: .libraryUnavailable, message: "not yet") }
            return good
        }
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#
        let tools = MCPTools(libraryProvider: provider, context: .fixed(TestLibrary.epoch), scope: .unrestricted)
        let replies = try await runServer([#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#, call, call, call], handler: tools)
        #expect(counter.opens == 2)  // the success is remembered by the provider
        let first = try #require(replies[1]["result"]?["content"]?.array?.first?["text"]?.string)
        #expect(try JSONValue(parsing: Data(first.utf8))["error"]?["message"] == "not yet")
        #expect(replies[1]["result"]?["isError"] == true)
        #expect(replies[2]["result"]?["isError"] == nil)
        #expect(replies[2]["result"]?["structuredContent"] == .object([("metadata", .array([])), ("total", 0)]))
        #expect(replies[3]["result"]?["structuredContent"] == replies[2]["result"]?["structuredContent"])
    }
}

private extension JSONValue {
    /// The value with every object's keys sorted, as the server writes it.
    var sortedForTest: JSONValue {
        switch self {
        case .object(let fields):
            .object(fields.sorted { $0.0.unicodeScalars.lexicographicallyPrecedes($1.0.unicodeScalars) { $0.value < $1.value } }
                .map { ($0.0, $0.1.sortedForTest) })
        case .array(let items): .array(items.map(\.sortedForTest))
        default: self
        }
    }
}
