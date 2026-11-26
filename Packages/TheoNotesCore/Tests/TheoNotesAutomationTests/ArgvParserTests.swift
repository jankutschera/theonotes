// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

@Suite struct ArgvParserTests {
    @Test func batchedEditKeepsArgvPairing() throws {
        let p = try parsed("edit", "X", "--find", "a", "--replace", "b", "--find", #"x\n"#, "--delete", "--find", "c", "--insert-before", "d")
        #expect(p.ordered.map(\.option) == ["--find", "--replace", "--find", "--delete", "--find", "--insert-before"])
        #expect(p.values("--find") == ["a", "x\n", "c"])
        #expect(p.ordered.map(\.value) == ["a", "b", "x\n", nil, "c", "d"])
        #expect(p.flag("--delete") && !p.flag("--force"))
    }

    @Test func shortFormsEqualsSyntaxAndGroupDefault() throws {
        #expect(try parsed("list", "-n", "3", "-s", "title:asc").value("--limit") == "3")
        #expect(try parsed("list", "--limit=3").value("--limit") == "3")
        #expect(try parsed("tags").spec.path == ["tags", "list"])
        #expect(try parsed("search-in", "X", "--find", "y").value("--string") == "y")
    }

    @Test func groupDefaultTakesTheNoteArgumentAndOptions() throws {
        let p = try parsed("tags", "NOTE1", "--format", "json")
        #expect(p.spec.path == ["tags", "list"] && p.positionals == ["NOTE1"] && p.format == .json)
        #expect(try parsed("tags", "--count").flag("--count"))
        #expect(try parsed("pin").spec.path == ["pin", "list"])
        #expect(try parsed("attachments", "N").spec.path == ["attachments", "list"])
        #expect(try parsed("tags", "add", "N", "#a", "#b").positionals == ["N", "#a", "#b"])
        #expect(try parsed("app", "open", "N").spec.path == ["app", "open"])
    }

    /// Observed: a bare `bearcli` and a bare `bearcli app` print help and exit 0 (see `helpRoutingMatchesTheProbe`).
    @Test func bareCallAndBareGroupWithoutDefaultPrintHelp() {
        let bare = runCLI(["baerchen"])
        #expect(bare.exit == 0 && bare.err.isEmpty && bare.out == HelpText.overview + "\n")
        let app = runCLI(["baerchen", "app"])
        #expect(app.exit == 0 && app.err.isEmpty && app.out == HelpText.section(for: ["app"]) + "\n")
        #expect(runCLI(["baerchen", "--data-dir", "/x", "app"]).out == app.out)
    }

    @Test func textFlagsUnescapeAndPositionalsDoNot() throws {
        let p = try parsed("create", #"a\nb"#, "--content", #"x\ty\\z\q"#, "--tags", #"a\nb"#)
        #expect(p.positionals == [#"a\nb"#])
        #expect(p.value("--content") == "x\ty\\z\\q")
        #expect(p.value("--tags") == #"a\nb"#)
        #expect(try parsed("create", "--template", #"My\nT"#).value("--template") == #"My\nT"#)
    }

    @Test func valueMayStartWithDashAfterEqualsForEveryOption() throws {
        #expect(try parsed("search", "--query=-draft").value("--query") == "-draft")
        #expect(try parsed("create", "--content=- [ ] task").value("--content") == "- [ ] task")
        #expect(try parsed("create", "--content", "-").value("--content") == "-")
        #expect(try parsed("cat", "N", "--section=-x").value("--section") == "-x")
        #expect(try parsed("show", "N", "--title=-x").value("--title") == "-x")
    }

    ///. The lines marked observed are in `cli-observed.json` and replayed by
    /// `parseErrorsEqualTheObservedBearcliTexts` / `commandLinesBearcliAcceptsAreAcceptedHere`.
    @Test func dashLeadingValuesFollowTheProbe() throws {
        // Observed: --query (accepted), --string (accepted), --title, --section, --limit, --tag (refused).
        #expect(try parsed("search", "--query", "-draft").value("--query") == "-draft")
        #expect(usageError("show", "N", "--title", "-x").hasPrefix("Error: Missing value for '--title <title>'\nHelp:  --title <title>  "))
        #expect(usageError("cat", "N", "--section", "-x").hasPrefix("Error: Missing value for '--section <section>'\nHelp:  --section <section>  "))
        #expect(try parsed("cat", "N", "--section=-x").value("--section") == "-x")
        #expect(usageError("list", "--limit", "-1").hasPrefix("Error: Missing value for '--limit <limit>'\nHelp:  --limit <limit>  "))
        #expect(usageError("list", "--tag", "-foo").hasPrefix("Error: Missing value for '--tag <tag>'\nHelp:  --tag <tag>  "))
        #expect(try parsed("list", "--tag=-foo").value("--tag") == "-foo")
        #expect(try parsed("list", "--limit=-1").value("--limit") == "-1")
        #expect(try parsed("list", "-n=-1").value("--limit") == "-1")
        #expect(try parsed("search-in", "N", "--string", "-x").value("--string") == "-x")
        #expect(try parsed("search-in", "N", "--string=-x").value("--string") == "-x")
        #expect(try parsed("search-in", "N", "--string", "- [ ]").value("--string") == "- [ ]")
        #expect(try parsed("search-in", "N", "--string=- [ ]").value("--string") == "- [ ]")
        // Unobserved (write commands cannot be probed): the other free-text options behave like --string.
        #expect(try parsed("create", "--content", "- [ ] x").value("--content") == "- [ ] x")
        #expect(try parsed("append", "N", "--content", "-- rule").value("--content") == "-- rule")
        let edit = try parsed("edit", "N", "--find", "-a", "--replace", "-b", "--insert-after", "-c", "--insert-before", "-d")
        #expect(edit.values("--find") == ["-a"] && edit.value("--replace") == "-b")
        #expect(edit.value("--insert-after") == "-c" && edit.value("--insert-before") == "-d")
        #expect(try parsed("app", "open", "N", "--selection-text", "-x").value("--selection-text") == "-x")
        // --section is an ordinary option in every command, escaped or not.
        #expect(usageError("overwrite", "N", "--section", "-h").hasPrefix("Error: Missing value for '--section <section>'"))
        #expect(usageError("append", "N", "--section", "-x").hasPrefix("Error: Missing value for '--section <section>'"))
        // Ordinary options still refuse, and a free-text option with nothing after it is missing its value.
        #expect(usageError("create", "--tags", "-x").hasPrefix("Error: Missing value for '--tags <tags>'"))
        #expect(usageError("create", "--content").hasPrefix("Error: Missing value for '--content <content>'"))
    }

    @Test func doubleDashEndsOptions() throws {
        let p = try parsed("tags", "add", "--title", "T", "--", "-odd", "#b")
        #expect(p.value("--title") == "T" && p.positionals == ["-odd", "#b"])
    }

    @Test func searchTakesAPositionalQueryOrTheOption() throws {
        #expect(try parsed("search", "mars").positionals == ["mars"])
        #expect(try parsed("search", "-q", "mars").value("--query") == "mars")
        #expect(usageError("search", "-x") == "Error: Query starts with \"-\". Use --query to pass it\n")
    }

    @Test func usageErrorsMatchBearcliTexts() {
        #expect(usageError("list", "-n").hasPrefix("Error: Missing value for '-n <limit>'"))
        #expect(usageError("list", "--format", "xml").hasPrefix("Error: The value 'xml' is invalid for '--format <format>'. Please provide one of 'tsv', 'csv' or 'json'."))
        #expect(usageError("bogus-subcommand").hasPrefix("Error: Unexpected argument 'bogus-subcommand'"))
    }

    @Test func invalidNumbersAndNegativeValues() {
        #expect(usageError("list", "-n", "x").hasPrefix("Error: The value 'x' is invalid for '-n <limit>'\nHelp:  -n <limit>  Return at most"))
        #expect(usageError("list", "--limit=x").hasPrefix("Error: The value 'x' is invalid for '--limit <limit>'"))
        #expect(usageError("list", "-n", "-1").hasPrefix("Error: Missing value for '-n <limit>'"))
        #expect(usageError("app", "open", "N", "--selection-offset", "1.5").contains("invalid for '--selection-offset <selection-offset>'"))
        #expect((try? parsed("list", "--limit=-1"))?.value("--limit") == "-1")
    }

    @Test func unknownOptionsAndExtraArguments() {
        #expect(usageError("list", "--bogus").hasPrefix("Error: Unknown option '--bogus'\nUsage: theonotes list "))
        #expect(usageError("list", "-z").hasPrefix("Error: Unknown option '-z'\n"))
        #expect(usageError("list", "extra").hasPrefix("Error: Unexpected argument 'extra'\nUsage: theonotes list "))
        #expect(usageError("show", "A", "B").hasPrefix("Error: Unexpected argument 'B'\n"))
        #expect(usageError("--bogus").hasPrefix("Error: Unknown option '--bogus'\nUsage: theonotes [--version] <subcommand>\n  See 'theonotes --help'"))
        #expect(usageError("list", "--count=1").hasPrefix("Error: The option '--count' does not take a value"))
    }

    @Test func usageErrorQuotesTheCommandsOwnUsageAndHelpPointer() {
        let message = usageError("tags", "add", "--title")
        #expect(message.contains("Usage: theonotes tags add [<note-id>] [<tags> ...] [--title <title>]\n"))
        #expect(message.hasSuffix("  See 'theonotes tags add --help' for more information.\n"))
        #expect(usageError("edit", "--wat").contains("Usage: theonotes edit [<options>] [<note-id>]\n"))
    }

    @Test func usageErrorWithJsonFormatIsEnvelopeExit64() throws {
        let r = cli(try .make(), "list", "--format", "json", "-n")
        #expect(try r.exit == 64 && r.json()["error"]?["code"] == .string("usage"))
        #expect(r.err.isEmpty)
        let equals = runCLI(["baerchen", "--format=json", "list", "-z"])
        #expect(try equals.exit == 64 && equals.json()["error"]?["code"] == .string("usage"))
    }

    /// `--format json` that is another option's value is text, not the format.
    @Test func requestedFormatSkipsValuesOfOtherOptions() throws {
        func format(_ args: String...) -> OutputFormat { ArgvParser.requestedFormat(in: ["baerchen"] + args) }
        #expect(format("create", "--content", "--format", "json", "-z") == .tsv)
        #expect(format("search-in", "N", "--string", "--format", "json", "--bogus") == .tsv)
        #expect(format("edit", "N", "--find", "--format", "--replace", "json", "--bogus") == .tsv)
        #expect(format("list", "--format", "json", "-n") == .json)
        #expect(format("list", "-n", "--format", "json") == .json)
        #expect(format("list", "--format=json", "--bogus") == .json)
        #expect(format("--data-dir", "/x", "tags", "--format", "json", "--bogus") == .json)
        #expect(format("list", "--", "--format", "json") == .tsv)
        let r = runCLI(["baerchen", "create", "--content", "--format", "json", "-z"])
        #expect(r.exit == 64 && r.out.isEmpty && r.err.hasPrefix("Error: Unknown option '-z'"))
    }

    @Test func usageErrorWithTsvOrCsvGoesToStderrWithExit64() throws {
        for format in ["tsv", "csv"] {
            let r = runCLI(["baerchen", "list", "--format", format, "-n"])
            #expect(r.exit == 64 && r.out.isEmpty && r.err.hasPrefix("Error: Missing value for '-n <limit>'"))
        }
    }

    /// Every parse-level usage error bearcli printed in the probe comes out the same here, with
    /// `bearcli` and `Bear` reworded. The option help quoted in the `Help:` line is our own prose
    /// and is stored as a placeholder in the fixture, so both sides are compared with it masked.
    @Test func parseErrorsEqualTheObservedBearcliTexts() throws {
        let observed = try JSONValue(parsing: Data(contentsOf: Self.observedURL))
        var checked = 0
        for entry in observed["errors"]?.array ?? [] {
            guard entry["exit"] == .int(64) else { continue }
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            let stdout = entry["stdout"]?.string ?? ""
            let stderr = entry["stderr"]?.string ?? ""
            let markers = ["Missing value for", "is invalid for", "Unknown option", "Unexpected argument", "Query starts with"]
            guard markers.contains(where: { stdout.contains($0) || stderr.contains($0) }) else { continue }
            func reworded(_ s: String) -> String {
                s.replacingOccurrences(of: "bearcli", with: "theonotes").replacingOccurrences(of: "Bear ", with: "Theo Notes ")
            }
            func masked(_ s: String) -> String {
                s.replacingOccurrences(
                    of: #"(?s)(Help:  \S+(?: <[^>]+>)?)  .*?(?=(?:\\n|\n)Usage:)"#, with: "$1  <help text>",
                    options: .regularExpression)
            }
            let run = runCLI(["baerchen"] + args)
            #expect(run.exit == 64, "\(args)")
            #expect(masked(run.out) == reworded(stdout), "\(args)")
            #expect(masked(run.err) == reworded(stderr), "\(args)")
            checked += 1
        }
        #expect(checked >= 20)
    }

    /// Command lines bearcli's parser accepted (the command failed later, or succeeded) must parse here too,
    /// and so must the ones it refused in the command itself (`Limit must be non-negative`, `Query is required`).
    @Test func commandLinesBearcliAcceptsAreAcceptedHere() throws {
        let observed = try JSONValue(parsing: Data(contentsOf: Self.observedURL))
        let markers = ["Missing value for", "is invalid for", "Unknown option", "Unexpected argument", "Query starts with"]
        var checked = 0
        for entry in observed["errors"]?.array ?? [] {
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            let text = (entry["stdout"]?.string ?? "") + (entry["stderr"]?.string ?? "")
            if entry["exit"] == .int(64), markers.contains(where: text.contains) { continue }
            guard case .command = try ArgvParser.parse(["baerchen"] + args) else {
                Issue.record("not a command: \(args)")
                continue
            }
            checked += 1
        }
        let accepted = observed["facts"]?["parseAccepted"]?.array ?? []
        #expect(accepted.count >= 3)
        for entry in accepted {
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            #expect(entry["exit"] != .int(64), "\(args)")
            guard case .command = try ArgvParser.parse(["baerchen"] + args) else {
                Issue.record("not a command: \(args)")
                continue
            }
            checked += 1
        }
        #expect(checked >= 30)
    }

    /// Observed: `help <unknown command>`, a bare call and a bare `app` print help and exit 0.
    @Test func helpRoutingMatchesTheProbe() throws {
        let observed = try JSONValue(parsing: Data(contentsOf: Self.observedURL))
        let routing = try #require(observed["facts"]?["helpRouting"])
        let expected = ["unknownCommand": HelpText.subcommandList, "bare": HelpText.overview, "appBare": HelpText.section(for: ["app"])]
        for (name, text) in expected {
            let entry = try #require(routing[name], "\(name)")
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            #expect(entry["exit"] == .int(0) && entry["stdoutEqualsExpected"] == .bool(true) && entry["stderrEmpty"] == .bool(true), "\(name)")
            let run = runCLI(["baerchen"] + args)
            #expect(run.exit == 0 && run.err.isEmpty && run.out == text + "\n", "\(name)")
        }
    }

    @Test func unobservedGuessesAreListedInTheFixture() throws {
        let observed = try JSONValue(parsing: Data(contentsOf: Self.observedURL))
        let listed = (observed["facts"]?["unobserved"]?.array ?? []).compactMap(\.string)
        for name in ["cliShortAttachedValue", "cliDoubleDashTerminator", "cliRepeatedOptionLastWins", "cliCheckOrderFormatVsInteger",
                     "cliFlagWithEqualsValue", "cliWriteFreeTextDashValues", "cliHelpPartialPath"] {
            #expect(listed.contains(name), "\(name)")
        }
    }

    static let observedURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures/cli/cli-observed.json")
    }()

    // MARK: --data-dir

    @Test func dataDirAcceptedBeforeOrAfterSubcommand() throws {
        #expect(try parsed("--data-dir", "/x", "list").dataDir == "/x")
        #expect(try parsed("list", "--data-dir", "/x").dataDir == "/x")
        #expect(try parsed("list", "--data-dir=/x").dataDir == "/x")
        #expect(try parsed("tags", "--data-dir", "/x", "add", "N", "#a").spec.path == ["tags", "add"])
        #expect(try parsed("list").dataDir == nil)
        #expect(try parsed("list", "--data-dir", "/x").ordered.isEmpty)
    }

    @Test func dataDirAsAnotherOptionsValueIsNotTheGlobalOption() throws {
        let p = try parsed("create", "--content=--data-dir", "--tags=--data-dir", "--data-dir=x")
        #expect(p.dataDir == "x" && p.value("--content") == "--data-dir")
        #expect(try parsed("search", "--query=--data-dir=/y").dataDir == nil)
    }

    @Test func bothOrdersResolveTheSameLibrary() throws {
        let lib = try TestLibrary.make()
        let root = lib.paths.root.path
        let seen = RootBox()
        for argv in [
            ["baerchen", "--data-dir", root, "list"],
            ["baerchen", "list", "--data-dir", root],
            ["baerchen", "list", "--data-dir=\(root)"],
        ] {
            seen.root = nil
            let r = runCLI(argv, lookup: { _ in seen.handler })
            #expect(r.exit == 0 && r.err.isEmpty)
            #expect(seen.root == lib.paths.root, "\(argv)")
        }
    }

    @Test func dataDirWithoutLibraryIsLibraryUnavailable() throws {
        let empty = try TestLibrary.emptyFolder()
        let seen = RootBox()
        let r = runCLI(["baerchen", "list", "--data-dir", empty.path], lookup: { _ in seen.handler })
        #expect(r.exit == 1 && r.err.hasPrefix("Error: ") && r.err.contains("Baerchen.sqlite"))
        #expect(seen.root == nil)
    }

    // MARK: Lazy library

    /// `app open --data-dir <empty folder>` decides on `app_unavailable` without touching the library.
    @Test func handlerThatNeverAsksNeverOpensTheLibrary() throws {
        let empty = try TestLibrary.emptyFolder()
        let appOpen: ([String]) -> CommandHandler? = { _ in
            { _, _ throws(AutomationError) in
                throw AutomationError(code: .appUnavailable, message: "Theo Notes is not running.")
            }
        }
        let r = runCLI(["baerchen", "app", "open", "N", "--data-dir", empty.path], lookup: appOpen)
        #expect(r.exit == 1 && r.err == "Error: Theo Notes is not running.\n")
        let before = runCLI(["baerchen", "--data-dir", empty.path, "app", "open", "N"], lookup: appOpen)
        #expect(before.exit == 1 && before.err == r.err)
    }

    @Test func handlerUsageErrorsComeBeforeLibraryErrors() throws {
        let empty = try TestLibrary.emptyFolder()
        let show: ([String]) -> CommandHandler? = { _ in
            { parsed, env throws(AutomationError) in
                guard !parsed.positionals.isEmpty || parsed.value("--title") != nil else {
                    throw AutomationError(code: .usage, message: "Note ID or title is required")
                }
                _ = try env.library()
            }
        }
        let missing = runCLI(["baerchen", "show", "--data-dir", empty.path], lookup: show)
        #expect(missing.exit == 64 && missing.err == "Error: Note ID or title is required\n")
        let missingJSON = runCLI(["baerchen", "show", "--data-dir", empty.path, "--format", "json"], lookup: show)
        #expect(try missingJSON.exit == 64 && missingJSON.json()["error"]?["code"] == .string("usage"))
        let present = runCLI(["baerchen", "show", "N", "--data-dir", empty.path], lookup: show)
        #expect(present.exit == 1 && present.err.contains("Baerchen.sqlite"))
    }

    /// An unavailable library is reported every time it is asked for and recovers once it exists: what a
    /// long-running `mcp-server` needs to answer a JSON-RPC error instead of dying before it reads stdin.
    @Test func libraryProviderRemembersSuccessOnly() throws {
        final class Counter: @unchecked Sendable { var opens = 0 }
        let counter = Counter()
        let good = try TestLibrary.make().library
        let provider = LibraryProvider { () throws(AutomationError) -> AutomationLibrary in
            counter.opens += 1
            if counter.opens == 1 { throw AutomationError(code: .libraryUnavailable, message: "not yet") }
            return good
        }
        #expect(throws: AutomationError.self) { try provider.library() }
        let first = try provider.library()
        let second = try provider.library()
        #expect(counter.opens == 2)
        #expect(first.database.pool === second.database.pool)
    }

    @Test func libraryIsOpenedOnFirstUseNotBeforeTheHandlerRuns() throws {
        let lib = try TestLibrary.make()
        final class Probe: @unchecked Sendable { var sawBeforeAsking = false; var roots: [URL] = [] }
        let probe = Probe()
        let handler: ([String]) -> CommandHandler? = { _ in
            { _, env throws(AutomationError) in
                probe.sawBeforeAsking = true
                probe.roots.append(try env.library().paths.root)
                probe.roots.append(try env.library().paths.root)
            }
        }
        let r = runCLI(["baerchen", "list", "--data-dir", lib.paths.root.path], lookup: handler)
        #expect(r.exit == 0 && probe.sawBeforeAsking && probe.roots == [lib.paths.root, lib.paths.root])
    }

    // MARK: Running

    @Test func commandWithoutHandlerIsNotImplemented() throws {
        let r = runCLI(["baerchen", "tags", "add", "N", "#a"], lookup: { _ in nil })
        #expect(r.exit == 1 && r.err == "Error: Not implemented: tags add\n" && r.out.isEmpty)
        let json = runCLI(["baerchen", "list", "--format", "json"], lookup: { _ in nil })
        #expect(json.exit == 1)
        #expect(try json.json()["error"]?["code"] == .string("internal"))
        #expect(try json.json()["error"]?["message"] == .string("Not implemented: list"))
    }

    @Test func handlerErrorsGoToStderrOrAsEnvelope() throws {
        let lib = try TestLibrary.make()
        let fail: ([String]) -> CommandHandler? = { _ in
            { _, _ throws(AutomationError) in
                throw AutomationError(code: .noteNotFound, message: "Note not found: ZZZ")
            }
        }
        let plain = runCLI(["baerchen", "--data-dir", lib.paths.root.path, "show", "ZZZ"], lookup: fail)
        #expect(plain.exit == 1 && plain.err == "Error: Note not found: ZZZ\n" && plain.out.isEmpty)
        let json = runCLI(["baerchen", "--data-dir", lib.paths.root.path, "show", "ZZZ", "--format", "json"], lookup: fail)
        #expect(json.exit == 1 && json.out == "{\"error\":{\"code\":\"note_not_found\",\"message\":\"Note not found: ZZZ\"}}\n")
    }

    @Test func ambiguityCandidatesAreListedEscapedInTsvAndKeptInJson() throws {
        let lib = try TestLibrary.make()
        let details: JSONValue = .object([("candidates", .array([
            .object([("address", .string("# A\n## B")), ("offset", .int(0))]),
            .object([("address", .string("# A\n## B\n2")), ("offset", .int(9))]),
        ]))])
        let ambiguous: ([String]) -> CommandHandler? = { _ in
            { _, _ throws(AutomationError) in
                throw AutomationError(code: .ambiguous, message: "Address matched 2 sections.", details: details)
            }
        }
        let tsv = runCLI(["baerchen", "--data-dir", lib.paths.root.path, "cat", "N"], lookup: ambiguous)
        #expect(tsv.exit == 1)
        #expect(tsv.err == "Error: Address matched 2 sections.\n  # A\\n## B\n  # A\\n## B\\n2\n")
        let json = runCLI(["baerchen", "--data-dir", lib.paths.root.path, "cat", "N", "--format", "json"], lookup: ambiguous)
        #expect(try json.json()["error"]?["details"]?["candidates"]?.array?.count == 2)
    }

    @Test func contentComesFromTheFlagElseStdinUnlessATerminal() throws {
        let lib = try TestLibrary.make()
        let seen = ContentBox()
        let handler: ([String]) -> CommandHandler? = { _ in
            { parsed, env throws(AutomationError) in seen.content = env.content(parsed) }
        }
        let root = lib.paths.root.path
        _ = runCLI(["baerchen", "--data-dir", root, "append", "N", "--content", #"a\nb"#], stdin: Data("ignored".utf8), lookup: handler)
        #expect(seen.content == "a\nb")
        _ = runCLI(["baerchen", "--data-dir", root, "append", "N"], stdin: Data(#"from\nstdin"#.utf8), lookup: handler)
        #expect(seen.content == #"from\nstdin"#)
        _ = runCLI(["baerchen", "--data-dir", root, "append", "N"], stdin: Data("unused".utf8), stdinIsTTY: true, lookup: handler)
        #expect(seen.content == "")
    }

    @Test func versionAndHelpExitZero() {
        #expect(runCLI(["baerchen", "--version"]).out == "\(AutomationVersion.string)\n")
        #expect(runCLI(["baerchen", "-v"]).out == "\(AutomationVersion.string)\n")
        let r = runCLI(["baerchen", "list", "--help"])
        #expect(r.exit == 0 && r.err.isEmpty && r.out == HelpText.section(for: ["list"]) + "\n")
    }
}

final class RootBox: @unchecked Sendable {
    var root: URL?
    var handler: CommandHandler {
        { _, env throws(AutomationError) in self.root = try env.library().paths.root }
    }
}

final class ContentBox: @unchecked Sendable {
    var content: String?
}
