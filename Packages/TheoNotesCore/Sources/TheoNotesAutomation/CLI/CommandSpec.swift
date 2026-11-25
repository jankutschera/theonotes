// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// One option or flag of a command. `valueName == nil` marks a flag (no value).
struct OptionSpec: Equatable, Sendable {
    var long: String
    var short: Character? = nil
    /// Further long spellings (`--find` for `--string`); the parser reports the canonical `long`.
    var aliases: [String] = []
    var valueName: String? = nil
    var defaultValue: String? = nil
    /// The value is unescaped (`\n \t \r \\`) after parsing, as bearcli does for text flags.
    var escapes = false
    /// May appear several times; every occurrence is kept in argv order (batched edits).
    var repeatable = false
    /// The value must be a whole number; checked while parsing.
    var integer = false
    /// Arbitrary text: a value that starts with `-` is accepted after a space too (ruling M5-R44).
    var freeText = false

    var isFlag: Bool { valueName == nil }
}

struct ArgumentSpec: Equatable, Sendable {
    var name: String
    var variadic = false
}

struct CommandSpec: Equatable, Sendable {
    var path: [String]
    var arguments: [ArgumentSpec]
    /// Options and flags in the order the help text lists them, followed by the extensions.
    var options: [OptionSpec]
    var acceptsFormat: Bool
    var defaultFields: [String]
    /// What `--fields all` selects; never contains the `extraFields` (ruling M5-R32).
    var allFields: [String]
    /// Fields that only an explicit `--fields …,content` adds.
    var extraFields: [String] = []
    /// `--content` is read from stdin when omitted.
    var readsContentFromStdin: Bool

    func option(named name: String) -> OptionSpec? {
        options.first { $0.long == name || $0.aliases.contains(name) }
    }

    func option(short: Character) -> OptionSpec? {
        options.first { $0.short == short }
    }
}
