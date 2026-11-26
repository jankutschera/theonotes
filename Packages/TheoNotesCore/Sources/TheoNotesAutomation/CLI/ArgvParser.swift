// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// A command line that parsed: the command, its positional arguments and its options.
struct ParsedCommand {
    var spec: CommandSpec
    var positionals: [String]
    /// Options in argv order under their canonical long name; flags carry a nil value. Values are
    /// already unescaped where the option `escapes`. Batched edits read this to keep the pairing
    /// of `--find` with the action that follows it.
    var ordered: [(option: String, value: String?)]
    /// The value of `--data-dir`, wherever it stood on the command line (nil when absent).
    var dataDir: String?

    /// The last value given for `long` (nil when absent or a flag).
    func value(_ long: String) -> String? {
        ordered.last { $0.option == long && $0.value != nil }?.value
    }

    /// Every value given for `long`, in argv order.
    func values(_ long: String) -> [String] {
        ordered.compactMap { $0.option == long ? $0.value : nil }
    }

    func flag(_ long: String) -> Bool { ordered.contains { $0.option == long } }

    var format: OutputFormat { value("--format").flatMap(OutputFormat.init(rawValue:)) ?? .tsv }

    var fieldsArgument: String? { value("--fields") }
}

enum ParseOutcome {
    case command(ParsedCommand)
    case help(String)
    case version
    case completion(shell: String)
}

/// The hand-written argv parser. Error texts reproduce what bearcli's
/// swift-argument-parser prints, as observed in `Fixtures/cli/cli-observed.json`.
enum ArgvParser {
    static let shells = ["zsh", "bash", "fish"]
    static let program = "theonotes"

    /// `argv` includes the program name. Throws a `usage` error for anything malformed.
    static func parse(_ argv: [String]) throws(AutomationError) -> ParseOutcome {
        var tokens = Array(argv.dropFirst())[...]
        var dataDir: String?
        while let token = tokens.popFirst() {
            switch token {
            case "-h", "--help":
                return .help(HelpText.overview)
            case "-v", "--version":
                return .version
            case "help":
                return try parseHelp(Array(tokens))
            case "--generate-completion-script":
                return try completion(value: tokens.first.flatMap { isOptionLike($0) ? nil : $0 })
            case _ where token.hasPrefix("--generate-completion-script="):
                return try completion(value: String(token.dropFirst("--generate-completion-script=".count)))
            case "--data-dir":
                dataDir = try takeValue(&tokens, label: "--data-dir <path>", help: nil, usageKey: "")
            case _ where token.hasPrefix("--data-dir="):
                dataDir = String(token.dropFirst("--data-dir=".count))
            case _ where isOptionLike(token):
                throw failure("Unknown option '\(token)'", usageKey: "")
            default:
                return try parseCommand(named: token, rest: Array(tokens), dataDir: dataDir)
            }
        }
        // Observed: a bare `bearcli` prints the overview and exits 0.
        return .help(HelpText.overview)
    }

    /// The output format an erroneous command line asked for, so a usage error can be reported as
    /// the JSON envelope when `--format json` was given (an unparseable line has no parsed format).
    /// Tokens the parser would take as the value of another option (`--content --format`) are
    /// skipped, so only a real `--format` counts.
    static func requestedFormat(in argv: [String]) -> OutputFormat {
        var result = OutputFormat.tsv
        let spec = resolvedSpec(argv)
        var index = 1
        while index < argv.count {
            let token = argv[index]
            index += 1
            if token == "--" { break }
            if token == "--format" {
                if index < argv.count, let format = OutputFormat(rawValue: argv[index]) { result = format }
                index += 1
            } else if token.hasPrefix("--format=") {
                if let format = OutputFormat(rawValue: String(token.dropFirst(9))) { result = format }
            } else if isOptionLike(token), !token.contains("="), let spec {
                let option = token.hasPrefix("--") ? spec.option(named: token) : (token.count == 2 ? spec.option(short: token.last!) : nil)
                if option?.valueName != nil, index < argv.count, option!.freeText || !isOptionLike(argv[index]) {
                    index += 1
                }
            }
        }
        return result
    }

    /// The command a possibly malformed command line names, found the way `parse` finds it.
    private static func resolvedSpec(_ argv: [String]) -> CommandSpec? {
        func skipsDataDir(_ index: inout Int) -> Bool {
            if argv[index] == "--data-dir" {
                index += 2
                return true
            }
            if argv[index].hasPrefix("--data-dir=") {
                index += 1
                return true
            }
            return false
        }
        var index = 1
        while index < argv.count, skipsDataDir(&index) {}
        guard index < argv.count, CommandTable.topLevelNames.contains(argv[index]) else { return nil }
        let name = argv[index]
        index += 1
        guard let children = CommandTable.groups[name] else { return CommandTable.spec([name]) }
        while index < argv.count, skipsDataDir(&index) {}
        if index < argv.count, children.contains(argv[index]) { return CommandTable.spec([name, argv[index]]) }
        return CommandTable.groupDefaults[name].flatMap { CommandTable.spec([name, $0]) }
    }

    // MARK: Commands

    private static func parseCommand(
        named name: String, rest: [String], dataDir: String?
    ) throws(AutomationError) -> ParseOutcome {
        guard CommandTable.topLevelNames.contains(name) else {
            throw failure("Unexpected argument '\(name)'", usageKey: "")
        }
        var rest = rest
        var path = [name]
        if let children = CommandTable.groups[name] {
            // The subcommand is the first token that is not `--data-dir` and its value.
            var position = 0
            var chosen: String?
            while position < rest.count {
                let token = rest[position]
                if token == "--data-dir" { position += 2; continue }
                if token.hasPrefix("--data-dir=") { position += 1; continue }
                if children.contains(token) { chosen = token }
                break
            }
            if let chosen {
                path.append(chosen)
                rest.remove(at: position)
            } else if position < rest.count, rest[position] == "-h" || rest[position] == "--help" {
                return .help(HelpText.section(for: path))
            } else if let fallback = CommandTable.groupDefaults[name] {
                path.append(fallback)
            } else {
                // Observed: a bare `bearcli app` prints the group overview and exits 0.
                return .help(HelpText.section(for: path))
            }
        }
        guard let spec = CommandTable.spec(path) else {
            throw failure("Unexpected argument '\(name)'", usageKey: "")
        }
        return try parse(spec: spec, tokens: rest, dataDir: dataDir)
    }

    private static func parse(
        spec: CommandSpec, tokens: [String], dataDir: String?
    ) throws(AutomationError) -> ParseOutcome {
        let key = spec.path.joined(separator: " ")
        var positionals: [String] = []
        var ordered: [(option: String, value: String?)] = []
        var dataDir = dataDir
        var queue = tokens[...]
        var optionsEnded = false

        func positional(_ token: String) throws(AutomationError) {
            let capacity = spec.arguments.last?.variadic == true ? Int.max : spec.arguments.count
            guard positionals.count < capacity else { throw failure("Unexpected argument '\(token)'", usageKey: key) }
            positionals.append(token)
        }

        while let token = queue.popFirst() {
            if optionsEnded || !isOptionLike(token) {
                try positional(token)
                continue
            }
            if token == "--" {
                optionsEnded = true
                continue
            }
            if token == "-h" || token == "--help" { return .help(HelpText.section(for: spec.path)) }

            let option: OptionSpec?
            var inline: String?
            if token.hasPrefix("--") {
                var name = token
                if let equals = token.firstIndex(of: "=") {
                    name = String(token[..<equals])
                    inline = String(token[token.index(after: equals)...])
                }
                option = spec.option(named: name)
            } else {
                // `-n 3` or `-n=3` (observed: `-n=-1` reaches the command's own range check).
                let letters = Array(token.dropFirst())
                if letters.count == 1 {
                    option = spec.option(short: letters[0])
                } else if letters.count >= 2, letters[1] == "=" {
                    option = spec.option(short: letters[0])
                    inline = String(letters.dropFirst(2))
                } else {
                    option = nil
                }
            }
            guard let option else {
                if spec.path == ["search"] {
                    throw AutomationError(code: .usage, message: "Query starts with \"-\". Use --query to pass it")
                }
                throw failure("Unknown option '\(token)'", usageKey: key)
            }

            guard let valueName = option.valueName else {
                if inline != nil {
                    throw failure("The option '\(token.prefix { $0 != "=" })' does not take a value", usageKey: key)
                }
                ordered.append((option.long, nil))
                continue
            }
            let typed = String(token.prefix { $0 != "=" })
            let label = "\(typed) <\(valueName)>"
            let help = optionHelp(for: option, key: key)
            var value: String
            if let inline {
                value = inline
            } else {
                value = try takeValue(
                    &queue, label: label, help: help, usageKey: key, allowDash: option.freeText)
            }
            if option.long == "--format", OutputFormat(rawValue: value) == nil {
                throw failure(
                    "The value '\(value)' is invalid for '\(label)'. Please provide one of 'tsv', 'csv' or 'json'.",
                    help: help.map { (label, $0) }, usageKey: key)
            }
            if option.integer, Int(value) == nil {
                throw failure(
                    "The value '\(value)' is invalid for '\(label)'", help: help.map { (label, $0) }, usageKey: key)
            }
            if option.long == "--data-dir" {
                dataDir = value
                continue
            }
            if option.escapes { value = TextEscapes.unescape(value) }
            ordered.append((option.long, value))
        }
        return .command(ParsedCommand(spec: spec, positionals: positionals, ordered: ordered, dataDir: dataDir))
    }

    // MARK: Help and completion commands

    private static func parseHelp(_ words: [String]) throws(AutomationError) -> ParseOutcome {
        var path: [String] = []
        for word in words {
            if isOptionLike(word) {
                if word == "-h" || word == "--help" { break }
                throw failure("Unknown option '\(word)'", usageKey: "")
            }
            path.append(word)
        }
        if path.isEmpty { return .help(HelpText.overview) }
        if path == ["all"] { return .help(HelpText.all) }
        // Observed: an unknown command after `help` prints the subcommand list and exits 0. A path
        // that is known only in part (`help tags bogus`) shows the deepest known section.
        var known: [String] = []
        for word in path {
            guard HelpText.sections[(known + [word]).joined(separator: " ")] != nil else { break }
            known.append(word)
        }
        return .help(known.isEmpty ? HelpText.subcommandList : HelpText.section(for: known))
    }

    private static func completion(value: String?) throws(AutomationError) -> ParseOutcome {
        let flag = "--generate-completion-script <shell>"
        guard let value else { throw failure("Missing value for '\(flag)'", usageKey: "") }
        guard shells.contains(value) else {
            throw failure(
                "The value '\(value)' is invalid for '\(flag)'. Please provide one of 'zsh', 'bash' or 'fish'.",
                usageKey: "")
        }
        return .completion(shell: value)
    }

    // MARK: Helpers

    /// Starts with `-` but is not a lone `-`; such a token is never taken as an option's value.
    private static func isOptionLike(_ token: String) -> Bool { token.hasPrefix("-") && token != "-" }

    private static func takeValue(
        _ queue: inout ArraySlice<String>, label: String, help: String?, usageKey: String, allowDash: Bool = false
    ) throws(AutomationError) -> String {
        guard let next = queue.first, allowDash || !isOptionLike(next) else {
            throw failure("Missing value for '\(label)'", help: help.map { (label, $0) }, usageKey: usageKey)
        }
        queue.removeFirst()
        return next
    }

    private static func optionHelp(for option: OptionSpec, key: String) -> String? {
        HelpText.optionHelp[key]?[option.long] ?? HelpText.globalOptionHelp[option.long]
    }

    /// The headline, an optional `Help:` line for the option, then the command's usage and the
    /// pointer to its `--help`, as one multi-line message (stderr prints it after `Error: `).
    static func failure(
        _ headline: String, help: (label: String, text: String)? = nil, usageKey: String
    ) -> AutomationError {
        var lines = [headline]
        if let help { lines.append("Help:  \(help.label)  \(help.text)") }
        if let usage = HelpText.usages[usageKey] { lines.append("Usage: \(usage)") }
        let command = ([program] + usageKey.split(separator: " ").map(String.init)).joined(separator: " ")
        lines.append("  See '\(command) --help' for more information.")
        return AutomationError(code: .usage, message: lines.joined(separator: "\n"))
    }
}
