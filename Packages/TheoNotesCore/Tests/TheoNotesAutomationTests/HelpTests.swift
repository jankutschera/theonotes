// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

@Suite struct HelpTests {
    @Test func helpAllHasASectionPerCommand() {
        #expect(HelpText.all.contains("THEONOTES LIST") && !HelpText.all.contains("bearcli"))
        #expect(HelpText.all.contains("SEARCH SYNTAX:"))
    }

    /// Ruling M5-R269: the help text is ours; no other product, link or install path appears in it.
    @Test func noForeignBrandingOrLinks() {
        #expect(!HelpText.all.contains("Bear"))
        #expect(!HelpText.all.contains("BEARCLI"))
        #expect(!HelpText.all.contains("bear.app"))
        #expect(!HelpText.all.contains("/Applications/"))
    }

    /// Names, short forms and defaults come from the contract, so every one of them shows in the section.
    @Test func everyContractOptionAppearsWithItsShortFormAndDefault() throws {
        let contract = try MCPFixtures.load("Fixtures/cli/contract.json")
        for command in try #require(contract["commands"]?.array) {
            let path = (command["path"]?.array ?? []).compactMap(\.string)
            let section = HelpText.section(for: path)
            let flat = section.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for option in command["options"]?.array ?? [] {
                let long = try #require(option["long"]?.string)
                #expect(section.contains(long), "\(path) \(long)")
                if let short = option["short"]?.string { #expect(section.contains("\(short), \(long)"), "\(path) \(short)") }
                for alias in (option["aliases"]?.array ?? []).compactMap(\.string) { #expect(section.contains(alias), "\(path) \(alias)") }
                if let value = option["default"]?.string { #expect(flat.contains("(default: \(value))"), "\(path) \(long)") }
            }
            for flag in (command["flags"]?.array ?? []).compactMap(\.string) { #expect(section.contains(flag), "\(path) \(flag)") }
            for argument in command["arguments"]?.array ?? [] {
                #expect(section.contains("<\(argument["name"]?.string ?? "")>"), "\(path)")
            }
            for field in (command["allFields"]?.array ?? []).compactMap(\.string) { #expect(section.contains(field), "\(path) \(field)") }
        }
    }

    @Test func everyCommandHasHelpSection() {
        for s in CommandTable.all { #expect(!HelpText.section(for: s.path).isEmpty) }
        for group in CommandTable.groups.keys { #expect(!HelpText.section(for: [group]).isEmpty, "\(group)") }
        #expect(HelpText.section(for: ["bogus"]).isEmpty)
    }

    @Test func sectionsStartAtTheOverviewLineAndAllHasTheTitles() {
        for s in CommandTable.all {
            #expect(HelpText.section(for: s.path).hasPrefix("OVERVIEW:"), "\(s.path)")
            #expect(HelpText.all.contains("THEONOTES \(s.path.joined(separator: " ").uppercased())\n"), "\(s.path)")
        }
    }

    @Test func usageLineNamesEveryArgumentAndOptionOfTheTable() throws {
        for spec in CommandTable.all {
            let usage = try #require(HelpText.usages[spec.path.joined(separator: " ")])
            #expect(usage.hasPrefix(([ArgvParser.program] + spec.path).joined(separator: " ")), "\(spec.path)")
            if spec.path == ["edit"] { continue }  // `[<options>] [<note-id>]`
            for argument in spec.arguments { #expect(usage.contains("<\(argument.name)>"), "\(spec.path) \(argument.name)") }
            for option in spec.options where option.long != "--data-dir" {
                #expect(usage.contains("[\(option.long)"), "\(spec.path) \(option.long)")
            }
        }
    }

    @Test func everySectionDocumentsEveryOptionAndParserQuotesIt() throws {
        for spec in CommandTable.all {
            let key = spec.path.joined(separator: " ")
            let section = HelpText.section(for: spec.path)
            for option in spec.options where option.long != "--data-dir" {
                #expect(section.contains(option.long), "\(key) \(option.long)")
                for alias in option.aliases { #expect(section.contains(alias), "\(key) \(alias)") }
                let help = try #require(HelpText.optionHelp[key]?[option.long], "\(key) \(option.long)")
                #expect(!help.isEmpty && !help.contains("\n"))
                if let short = option.short {
                    #expect(section.contains("-\(short), \(option.long)"), "\(key) -\(short)")
                }
            }
        }
        #expect(HelpText.globalOptionHelp["--data-dir"] != nil)
    }

    @Test func optionHelpDropsTheDefaultSuffixAndJoinsWrappedLines() {
        #expect(HelpText.optionHelp["list"]?["--offset"] == "Skip this many notes first.")
        #expect(HelpText.optionHelp["list"]?["--format"] == "Output format: tsv, csv or json.")
        #expect(HelpText.optionHelp["search-in"]?["--find"] == HelpText.optionHelp["search-in"]?["--string"])
        #expect(HelpText.optionHelp["mcp-server"]?["--only-tags"]?.hasPrefix("Comma-separated tags. Serve only notes") == true)
    }

    @Test func extensionsAreDocumented() {
        #expect(HelpText.overview.contains("GLOBAL OPTIONS:"))
        #expect(HelpText.overview.contains("--data-dir <path>"))
        #expect(HelpText.overview.contains("THEONOTES_DATA_DIR"))
        // The legacy variable names still work but are not advertised: help shows only Theo Notes names.
        #expect(!HelpText.all.contains("BAERCHEN_"))
        #expect(HelpText.section(for: ["create"]).contains("--template <template>"))
        #expect(HelpText.usages["create"]?.contains("[--template <template>]") == true)
        let mcp = HelpText.section(for: ["mcp-server"])
        for name in ["create_note_from_template", "capture_thought", "THEONOTES_MCP_ONLY_TAGS", "THEONOTES_MCP_EXCLUDE_TAGS"] {
            #expect(mcp.contains(name), "\(name)")
        }
        #expect(mcp.contains("capture_thought   An extra tool: saves the given text as a new note, unchanged."))
    }

    @Test func overviewIsTheShortPartOfTheReference() {
        #expect(HelpText.overview.hasPrefix("OVERVIEW: Read and write your notes from the command line."))
        #expect(HelpText.overview.contains("USAGE: theonotes [--version] <subcommand>"))
        #expect(HelpText.all.hasPrefix(HelpText.overview))
        #expect(!HelpText.overview.contains("THEONOTES LIST"))
        #expect(!HelpText.all.contains("BAERCHEN LIST"))
    }

    // MARK: help command

    @Test func helpCommandsPrintSectionsAndExitZero() {
        let all = runCLI(["baerchen", "help", "all"])
        #expect(all.exit == 0 && all.out == HelpText.all + "\n" && all.err.isEmpty)
        for argv in [["baerchen", "-h"], ["baerchen", "--help"], ["baerchen", "help"]] {
            let r = runCLI(argv)
            #expect(r.exit == 0 && r.out == HelpText.overview + "\n", "\(argv)")
        }
        #expect(runCLI(["baerchen", "help", "list"]).out == HelpText.section(for: ["list"]) + "\n")
        #expect(runCLI(["baerchen", "help", "tags", "add"]).out == HelpText.section(for: ["tags", "add"]) + "\n")
        #expect(runCLI(["baerchen", "help", "tags"]).out == HelpText.section(for: ["tags"]) + "\n")
        #expect(runCLI(["baerchen", "tags", "--help"]).out == HelpText.section(for: ["tags"]) + "\n")
        #expect(runCLI(["baerchen", "app", "get-selection", "-h"]).out == HelpText.section(for: ["app", "get-selection"]) + "\n")
    }

    /// Observed: `help <unknown command>` prints the subcommand list of the overview and exits 0
    /// (`helpRoutingMatchesTheProbe`). A path known only in part shows the deepest known section
    /// (unobserved, `cliHelpPartialPath`).
    @Test func helpForAnUnknownCommandPrintsTheSubcommandList() {
        let r = runCLI(["baerchen", "help", "bogus"])
        #expect(r.exit == 0 && r.err.isEmpty && r.out == HelpText.subcommandList + "\n")
        #expect(HelpText.subcommandList.hasPrefix("OVERVIEW:") && !HelpText.subcommandList.contains("HELP:"))
        let pointer = "  Run 'theonotes help <subcommand>' for the full help of one subcommand."
        #expect(HelpText.subcommandList.hasSuffix("\n\n" + pointer))
        #expect(HelpText.overview.hasPrefix(HelpText.subcommandList.replacingOccurrences(of: pointer, with: "")))
        let nested = runCLI(["baerchen", "help", "tags", "bogus"])
        #expect(nested.exit == 0 && nested.out == HelpText.section(for: ["tags"]) + "\n")
        #expect(runCLI(["baerchen", "help", "bogus", "tags"]).out == HelpText.subcommandList + "\n")
    }

    // MARK: Completions

    @Test func completionScriptsListEverySubcommand() {
        for sh in ["zsh", "bash", "fish"] { #expect(Completions.script(shell: sh).contains("search-in")) }
        for sh in ["zsh", "bash", "fish"] {
            let script = Completions.script(shell: sh)
            for name in CommandTable.topLevelNames { #expect(script.contains(name), "\(sh) \(name)") }
            for spec in CommandTable.all where spec.path.count == 2 {
                #expect(script.contains(spec.path[1]), "\(sh) \(spec.path)")
            }
        }
    }

    @Test func completionScriptsListEveryOption() {
        let options = Set(CommandTable.all.flatMap { $0.options.map(\.long) + $0.options.flatMap(\.aliases) })
        #expect(options.contains("--template") && options.contains("--exclude-tags") && options.contains("--find"))
        for sh in ["zsh", "bash", "fish"] {
            let script = Completions.script(shell: sh)
            for long in options {
                let spelled = sh == "fish" ? String(long.dropFirst(2)) : long
                #expect(script.contains(spelled), "\(sh) \(long)")
            }
        }
    }

    @Test func completionCommandPrintsTheScript() {
        for sh in ["zsh", "bash", "fish"] {
            let r = runCLI(["baerchen", "--generate-completion-script", sh])
            #expect(r.exit == 0 && r.out == Completions.script(shell: sh) && r.err.isEmpty)
            #expect(runCLI(["baerchen", "--generate-completion-script=\(sh)"]).out == r.out)
        }
        #expect(runCLI(["baerchen", "--generate-completion-script", "powershell"]).err.hasPrefix(
            "Error: The value 'powershell' is invalid for '--generate-completion-script <shell>'. Please provide one of 'zsh', 'bash' or 'fish'."))
        #expect(runCLI(["baerchen", "--generate-completion-script"]).err.hasPrefix(
            "Error: Missing value for '--generate-completion-script <shell>'"))
    }

    @Test(arguments: [("zsh", "/bin/zsh", ["-n"]), ("bash", "/bin/bash", ["-n"]), ("fish", "fish", ["--no-execute"])])
    func completionScriptsPassTheShellSyntaxCheck(shell: String, executable: String, flags: [String]) throws {
        guard let executable = Self.locate(executable) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-completion-\(UUID().uuidString).\(shell)")
        try Completions.script(shell: shell).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let (status, stderr) = try Self.run(executable, flags + [file.path])
        #expect(status == 0, "\(shell): \(stderr)")
    }

    // MARK: Generated source

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/env")))
    func generatedHelpSourceIsUpToDate() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let (status, stderr) = try Self.run(
            "/usr/bin/env", ["python3", "-I", root.appendingPathComponent("scripts/gen-automation-sources.py").path, "--check"])
        #expect(status == 0, "regenerate with scripts/gen-automation-sources.py: \(stderr)")
    }

    /// An absolute path as it is, a bare name looked up in PATH (fish lives in /opt/homebrew/bin or /usr/local/bin);
    /// nil when the shell is not installed, which skips its syntax check.
    static func locate(_ executable: String) -> String? {
        if executable.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/\(executable)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
