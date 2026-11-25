// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A real `theonotes mcp-server` child process driven over pipes, the way an MCP client does it
/// (newline-delimited JSON-RPC). Every reply is awaited at most 10 s.
struct MCPClientHarness: Sendable {
    struct Failure: Error, CustomStringConvertible { var description: String }

    private final class State: @unchecked Sendable {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let condition = NSCondition()
        var lines: [Data] = []
        var finished = false
        var errData = Data()
        var nextId = 1
        var stdinClosed = false

        func takeId() -> Int {
            condition.lock()
            defer { condition.unlock() }
            nextId += 1
            return nextId - 1
        }
    }

    private let state = State()

    init(binary: URL, arguments: [String], environment: [String: String], cwd: URL) throws {
        let s = state
        s.process.executableURL = binary
        s.process.arguments = arguments
        s.process.environment = environment
        s.process.currentDirectoryURL = cwd
        s.process.standardInput = s.stdin
        s.process.standardOutput = s.stdout
        s.process.standardError = s.stderr
        try s.process.run()
        let reader = Thread {
            var buffer = Data()
            let handle = s.stdout.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[(newline + 1)...])
                    s.condition.lock()
                    s.lines.append(line)
                    s.condition.broadcast()
                    s.condition.unlock()
                }
            }
            s.condition.lock()
            s.finished = true
            s.condition.broadcast()
            s.condition.unlock()
        }
        reader.start()
        let errReader = Thread {
            let data = s.stderr.fileHandleForReading.readDataToEndOfFile()
            s.condition.lock()
            s.errData = data
            s.condition.broadcast()
            s.condition.unlock()
        }
        errReader.start()
    }

    /// What the child wrote to stderr (complete once the child has exited).
    var stderrText: String {
        state.condition.lock()
        defer { state.condition.unlock() }
        return String(decoding: state.errData, as: UTF8.self)
    }

    private func send(_ value: JSONValue) throws {
        var data = Data(value.serialized(sortedKeys: false).utf8)
        data.append(0x0A)
        try state.stdin.fileHandleForWriting.write(contentsOf: data)
    }

    /// Sends a request and returns its `result`; a JSON-RPC `error` or a missing reply in 10 s throws.
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let state = self.state
        let id = state.takeId()
        try send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.awaitReply(state, id: id) })
            }
        }
    }

    private static func awaitReply(_ state: State, id: Int) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(10)
        state.condition.lock()
        defer { state.condition.unlock() }
        while true {
            while !state.lines.isEmpty {
                let line = state.lines.removeFirst()
                guard let value = try? JSONValue(parsing: line) else {
                    throw Failure(description: "server wrote a line that is not JSON")
                }
                guard value["id"] == .int(id) else { continue }
                if let error = value["error"] { throw Failure(description: "JSON-RPC error: \(error.serialized(sortedKeys: true))") }
                return value["result"] ?? .null
            }
            if state.finished { throw Failure(description: "server closed stdout before replying to \(id)") }
            if !state.condition.wait(until: deadline) { throw Failure(description: "no reply to request \(id) within 10 s") }
        }
    }

    /// A notification: no reply is expected.
    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": .string(method)])
    }

    /// The raw `tools/call` result (`content`, `structuredContent`, `isError`).
    func callTool(_ name: String, _ args: JSONValue) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(name), "arguments": args])
    }

    /// Closes stdin (the end of the session) and waits up to 10 s for the child to exit with status 0.
    func close() throws {
        let s = state
        s.condition.lock()
        let alreadyClosed = s.stdinClosed
        s.stdinClosed = true
        s.condition.unlock()
        if !alreadyClosed { try? s.stdin.fileHandleForWriting.close() }
        let deadline = Date().addingTimeInterval(10)
        while s.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if s.process.isRunning {
            s.process.terminate()
            throw Failure(description: "server did not exit after stdin closed")
        }
        guard s.process.terminationStatus == 0 else {
            throw Failure(description: "server exited with status \(s.process.terminationStatus)")
        }
    }
}

extension JSONValue {
    /// The `text` of the first `content` item of a tool result.
    var text: String { self["content"]?.array?.first?["text"]?.string ?? "" }
}

private func startServer(_ root: URL) throws -> MCPClientHarness {
    try MCPClientHarness(
        binary: BuiltProducts.theonotes, arguments: ["mcp-server", "--data-dir", root.path], environment: [:],
        cwd: URL(fileURLWithPath: "/"))
}

private func handshake(_ mcp: MCPClientHarness) async throws -> JSONValue {
    let reply = try await mcp.request(
        "initialize",
        [
            "protocolVersion": "2025-06-18", "capabilities": ["roots": [:]],
            "clientInfo": ["name": "claude-code", "version": "2.0.0"],
        ])
    try mcp.notify("notifications/initialized")
    return reply
}

/// The built `theonotes mcp-server` as a client sees it (M5 Task 17).
@Suite struct MCPEndToEndTests {
    @Test func claudeCodeStyleSessionEndToEnd() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# Inbox\n#work\n- [ ] call Mia")])
        let mcp = try startServer(lib.paths.root)
        let initReply = try await handshake(mcp)
        #expect(initReply["serverInfo"]?["name"] == .string("theonotes"))
        #expect(initReply["protocolVersion"] == .string("2025-06-18"))
        #expect(try await mcp.request("tools/list", [:])["tools"]?.array?.count == 28)
        let created = try await mcp.callTool(
            "create_note", ["title": "Plan", "content": "## Steps\n- a", "tags": ["work"]])
        let id = try #require(created["structuredContent"]?["id"]?.string)
        #expect(try await mcp.callTool("search_notes", ["query": "#work @todo"])["structuredContent"]?["total"] == .int(1))
        let read = try await mcp.callTool("read_note_content", ["id": .string(id), "address": "## Steps"])
        let hash = try #require(read["structuredContent"]?["hash"]?.string)
        let edited = try await mcp.callTool(
            "edit_note", ["id": .string(id), "edits": [["find": "- a", "replace": "- a\n- b"]]])
        #expect(edited["isError"] == nil, "\(edited.text)")
        let stale = try await mcp.callTool(
            "overwrite_note",
            ["id": .string(id), "address": "## Steps", "baseHash": .string(hash), "content": "## Steps\nx"])
        #expect(stale["isError"] == .bool(true) && stale.text.contains("stale_hash"))
        #expect(
            try await mcp.callTool("read_note_outline", ["id": .string(id)])["structuredContent"]?["outline"]?.array?.isEmpty
                == false)
        let trashed = try await mcp.callTool("trash_note", ["id": .string(id)])
        #expect(trashed["isError"] == nil, "\(trashed.text)")
        #expect(
            try await mcp.callTool("list_notes", ["location": "trash"])["structuredContent"]?["total"] == .int(1))
        try mcp.close()
        #expect(mcp.stderrText.isEmpty, "\(mcp.stderrText)")
    }

    /// HOME cannot move the library: Foundation's Application Support folder comes from the user
    /// database, not from `$HOME` (M5-R222), so the temporary library is named by `BAERCHEN_DATA_DIR`.
    @Test func mcpServerStartsViaSymlinkWithAMinimalEnvironment() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# Only note")])
        let tmp = try TestLibrary.emptyFolder()
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("theonotes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: BuiltProducts.theonotes)
        let mcp = try MCPClientHarness(
            binary: link, arguments: ["mcp-server"],
            environment: ["HOME": tmp.path, "BAERCHEN_DATA_DIR": lib.paths.root.path], cwd: URL(fileURLWithPath: "/"))
        _ = try await handshake(mcp)
        #expect(try await mcp.request("tools/list", [:])["tools"]?.array?.count == 28)
        let listed = try await mcp.callTool("list_notes", [:])
        #expect(listed["structuredContent"]?["total"] == .int(1), "\(listed.text)")
        #expect(listed["structuredContent"]?["metadata"]?.array?.first?["title"] == "Only note")
        try mcp.close()
        #expect(mcp.stderrText.isEmpty, "\(mcp.stderrText)")
    }

    /// With nothing in the environment at all, the handshake and the tool list still work (no library
    /// is needed for them, M5-R45). The server is pointed at an empty folder, never at the default
    /// library: should the open stop being lazy, this fails with `library_unavailable` instead of
    /// reaching Jan's real library (final review M9).
    @Test func handshakeNeedsNeitherAnEnvironmentNorALibrary() async throws {
        let empty = try TestLibrary.emptyFolder()
        let mcp = try MCPClientHarness(
            binary: BuiltProducts.theonotes, arguments: ["mcp-server", "--data-dir", empty.path], environment: [:],
            cwd: URL(fileURLWithPath: "/"))
        _ = try await handshake(mcp)
        #expect(try await mcp.request("tools/list", [:])["tools"]?.array?.count == 28)
        #expect(try await mcp.request("ping", [:]) == .object([]))
        let call = try await mcp.request("tools/call", ["name": "list_notes", "arguments": [:]])
        let envelope = try JSONValue(parsing: Data(call.text.utf8))
        #expect(call["isError"] == true && envelope["error"]?["code"] == "library_unavailable")
        try mcp.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
        #expect(mcp.stderrText.isEmpty, "\(mcp.stderrText)")
    }

    /// `scripts/mcp-smoke.py` against a temporary library: all steps pass and no note text is printed;
    /// without `--data-dir`, or with the real library folder, it refuses before starting anything.
    @Test func smokeScriptPassesOnACopyAndRefusesTheRest() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let script = root.appendingPathComponent("scripts/mcp-smoke.py").path
        try #require(FileManager.default.fileExists(atPath: script))
        func python(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", script] + args
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            nonisolated(unsafe) var errData = Data()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            drained.wait()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
        }
        let lib = try TestLibrary.make([
            TestNote(text: "# Smoke title zebra\nbody zebra #smoke/tag"), TestNote(text: "# Hidden", locked: true),
        ])
        let ok = try python(["--binary", BuiltProducts.theonotes.path, "--data-dir", lib.paths.root.path])
        #expect(ok.status == 0, "\(ok.out) \(ok.err)")
        #expect(ok.out.contains("ALL PASS") && !ok.out.contains("FAIL"))
        #expect(ok.out.contains("create_note_from_template"))
        for secret in ["zebra", "smoke", "Hidden"] { #expect(!ok.out.contains(secret) && !ok.err.contains(secret)) }
        let noDir = try python(["--binary", BuiltProducts.theonotes.path])
        #expect(noDir.status == 2 && noDir.err.contains("--data-dir is required"))
        let selfTest = try python(["--self-test"])
        #expect(selfTest.status == 0, "\(selfTest.out)")
    }
}
