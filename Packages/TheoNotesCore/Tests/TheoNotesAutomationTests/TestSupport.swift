// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

struct CLIResult {
    var exit: Int32
    var out: String
    var outData: Data
    var err: String

    func json() throws -> JSONValue { try JSONValue(parsing: outData) }
}

/// Collects what a CLI run writes; closures of one run never overlap, the lock is for Sendable's sake.
final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = ""

    func write(_ data: Data) { lock.withLock { out.append(data) } }
    func writeError(_ text: String) { lock.withLock { err += text } }
    var data: Data { lock.withLock { out } }
    var errorText: String { lock.withLock { err } }
}

func runCLI(
    _ argv: [String], stdin: Data = Data(), stdinIsTTY: Bool = false, stdoutIsTTY: Bool = false,
    now: Date = TestLibrary.epoch, fetcher: (any URLFetcher)? = nil, environment: [String: String] = [:],
    lookup: ([String]) -> CommandHandler? = CommandRegistry.handler
) -> CLIResult {
    let capture = OutputCapture()
    let io = CLIIO(
        readStdin: { stdin }, stdinIsTTY: stdinIsTTY, write: { capture.write($0) },
        writeError: { capture.writeError($0) }, stdoutIsTTY: stdoutIsTTY)
    var context = AutomationContext.fixed(now)
    if let fetcher { context.fetcher = fetcher }
    context.environment = environment
    let exit = TheoNotesCLI.run(argv, context: context, io: io, lookup: lookup)
    return CLIResult(
        exit: exit, out: String(decoding: capture.data, as: UTF8.self), outData: capture.data,
        err: capture.errorText)
}

/// Runs `baerchen --data-dir <library root> <args…>`.
func cli(
    _ lib: TestLibrary, _ args: String..., stdin: Data = Data(), stdinIsTTY: Bool = false,
    stdoutIsTTY: Bool = false, now: Date = TestLibrary.epoch, fetcher: (any URLFetcher)? = nil
) -> CLIResult {
    runCLI(
        ["baerchen", "--data-dir", lib.paths.root.path] + args, stdin: stdin, stdinIsTTY: stdinIsTTY,
        stdoutIsTTY: stdoutIsTTY, now: now, fetcher: fetcher)
}

struct NotACommand: Error { var description: String }

/// Parses `baerchen <args…>` and expects a command.
func parsed(_ args: String...) throws -> ParsedCommand {
    switch try ArgvParser.parse(["baerchen"] + args) {
    case .command(let command): return command
    case .help: throw NotACommand(description: "help")
    case .version: throw NotACommand(description: "version")
    case .completion: throw NotACommand(description: "completion")
    }
}

/// stderr of `baerchen <args…>` run without a library: only errors found while parsing reach it.
func usageError(_ args: String...) -> String { runCLI(["baerchen"] + args).err }

func waitUntil(seconds: Double, _ condition: () -> Bool) throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

// MARK: Contract fixture (Fixtures/cli/contract.json)

struct ContractOption {
    var long: String
    var short: String?
    var aliases: [String]
    var value: String?
    var defaultValue: String?
    var escapes: Bool
}

struct ContractCommand {
    var path: [String]
    var defaultSubcommand: Bool
    var arguments: [(name: String, variadic: Bool)]
    var options: [ContractOption]
    var flags: [String]
    var acceptsFormat: Bool
    var defaultFields: [String]
    var allFields: [String]
    var extraFields: [String]
}

struct ContractFixture {
    var commands: [ContractCommand]
    var groups: [String: String?]

    static let url: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures/cli/contract.json")
    }()

    static func load() throws -> ContractFixture {
        let root = try JSONValue(parsing: Data(contentsOf: url))
        func strings(_ value: JSONValue?) -> [String] { value?.array?.compactMap(\.string) ?? [] }
        func bool(_ value: JSONValue?) -> Bool {
            if case .bool(let b)? = value { return b }
            return false
        }
        let commands = (root["commands"]?.array ?? []).map { c in
            ContractCommand(
                path: strings(c["path"]),
                defaultSubcommand: bool(c["defaultSubcommand"]),
                arguments: (c["arguments"]?.array ?? []).map { ($0["name"]?.string ?? "", bool($0["variadic"])) },
                options: (c["options"]?.array ?? []).map { o in
                    ContractOption(
                        long: o["long"]?.string ?? "", short: o["short"]?.string, aliases: strings(o["aliases"]),
                        value: o["value"]?.string, defaultValue: o["default"]?.string, escapes: bool(o["escapes"]))
                },
                flags: strings(c["flags"]),
                acceptsFormat: bool(c["acceptsFormat"]),
                defaultFields: strings(c["defaultFields"]),
                allFields: strings(c["allFields"]),
                extraFields: strings(c["extraFields"]))
        }
        var groups: [String: String?] = [:]
        if case .object(let fields)? = root["groups"] {
            for (name, value) in fields { groups[name] = value.string }
        }
        return ContractFixture(commands: commands, groups: groups)
    }
}
