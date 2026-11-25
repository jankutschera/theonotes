// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The process boundary of the CLI, so tests can run it with fixed input and captured output.
public struct CLIIO {
    public var readStdin: () -> Data
    public var stdinIsTTY: Bool
    public var write: (Data) -> Void
    public var writeError: (String) -> Void
    public var stdoutIsTTY: Bool
    /// The next line of stdin as it arrives, for `mcp-server`; nil derives it from `readStdin`.
    public var readLine: (() -> Data?)?
    /// At most the given number of bytes of stdin, reading no further than needed; throws when
    /// stdin cannot be read (a read error is not the end of the input). nil derives it from
    /// `readStdin`, which reads everything.
    public var readStdinBounded: ((Int) throws -> Data)?
    /// Writes to stdout and throws when that fails (a full disk, a closed pipe), for commands that
    /// stream large output; nil derives it from `write`.
    public var writeChecked: ((Data) throws -> Void)?

    public init(
        readStdin: @escaping () -> Data, stdinIsTTY: Bool, write: @escaping (Data) -> Void,
        writeError: @escaping (String) -> Void, stdoutIsTTY: Bool, readLine: (() -> Data?)? = nil,
        readStdinBounded: ((Int) throws -> Data)? = nil, writeChecked: ((Data) throws -> Void)? = nil
    ) {
        self.readStdinBounded = readStdinBounded
        self.writeChecked = writeChecked
        self.readStdin = readStdin
        self.stdinIsTTY = stdinIsTTY
        self.write = write
        self.writeError = writeError
        self.stdoutIsTTY = stdoutIsTTY
        self.readLine = readLine
    }

    /// The real stdin, stdout and stderr.
    public static var standard: CLIIO {
        let stdin = LineReader { FileHandle.standardInput.availableData }
        return CLIIO(
            readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            write: { FileHandle.standardOutput.write($0) },
            writeError: { FileHandle.standardError.write(Data($0.utf8)) },
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
            readLine: { stdin.next() },
            readStdinBounded: { limit in
                // One reservation up front: appending 1 MiB pieces never regrows (and so never
                // doubles) the buffer.
                var data = Data()
                data.reserveCapacity(min(limit, 1 << 30))
                while data.count < limit {
                    let want = min(1 << 20, limit - data.count)
                    guard let chunk = try FileHandle.standardInput.read(upToCount: want), !chunk.isEmpty else { break }
                    data.append(chunk)
                }
                return data
            },
            writeChecked: { try FileHandle.standardOutput.write(contentsOf: $0) })
    }

    /// The first `limit` bytes of stdin at most.
    func readStdin(upTo limit: Int) throws -> Data {
        if let readStdinBounded { return try readStdinBounded(limit) }
        return Data(readStdin().prefix(limit))
    }

    /// `write`, but a failure is thrown.
    func writeStreaming(_ data: Data) throws {
        if let writeChecked { return try writeChecked(data) }
        write(data)
    }
}

public enum TheoNotesCLI {
    /// Runs one command line (`argv[0]` is the program name) and returns the exit code:
    /// 0 success, 1 business error, 64 usage error.
    public static func run(_ argv: [String], context: AutomationContext, io: CLIIO) -> Int32 {
        run(argv, context: context, io: io, lookup: CommandRegistry.handler)
    }

    static func run(
        _ argv: [String], context: AutomationContext, io: CLIIO, lookup: ([String]) -> CommandHandler?
    ) -> Int32 {
        let outcome: ParseOutcome
        do throws(AutomationError) {
            outcome = try ArgvParser.parse(argv)
        } catch {
            return report(error, format: ArgvParser.requestedFormat(in: argv), io: io)
        }
        switch outcome {
        case .help(let text):
            io.write(Data((text + "\n").utf8))
            return 0
        case .version:
            io.write(Data((AutomationVersion.string + "\n").utf8))
            return 0
        case .completion(let shell):
            io.write(Data(Completions.script(shell: shell).utf8))
            return 0
        case .command(let parsed):
            guard let handler = lookup(parsed.spec.path) else {
                let error = AutomationError(
                    code: .internal, message: "Not implemented: \(parsed.spec.path.joined(separator: " "))")
                return report(error, format: parsed.format, io: io)
            }
            let provider = LibraryProvider(currentRoot: {
                try? AutomationLibrary.resolvePaths(
                    dataDir: parsed.dataDir, environment: context.environment, production: context.production).root
            }) { () throws(AutomationError) -> AutomationLibrary in
                try AutomationLibrary.open(
                    dataDir: parsed.dataDir, environment: context.environment, production: context.production)
            }
            do throws(AutomationError) {
                try handler(parsed, CommandEnvironment(context: context, io: io, libraryProvider: provider))
                return 0
            } catch {
                return report(error, format: parsed.format, io: io)
            }
        }
    }

    /// TSV and CSV: `Error: <message>` on stderr, then one indented line per ambiguity candidate.
    /// JSON: the envelope on stdout. The exit code comes from the error either way.
    private static func report(_ error: AutomationError, format: OutputFormat, io: CLIIO) -> Int32 {
        if format == .json {
            io.write(Data((error.envelope().serialized(sortedKeys: false) + "\n").utf8))
        } else {
            var text = "Error: \(error.message)\n"
            for candidate in error.details?["candidates"]?.array ?? [] {
                if let address = candidate["address"]?.string { text += "  \(TextEscapes.escapeTSV(address))\n" }
            }
            io.writeError(text)
        }
        return error.exitCode
    }
}
