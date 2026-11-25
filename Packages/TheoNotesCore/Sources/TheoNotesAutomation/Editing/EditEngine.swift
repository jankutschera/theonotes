// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

enum EditAction: Equatable {
    case replace(String)
    case insertAfter(String)
    case insertBefore(String)
    case delete
}

/// One `--find` and its action (`edit`), or one entry of `edit_note`'s `edits`.
struct EditSpec: Equatable {
    var find: String
    var action: EditAction
    var all = false
    var ignoreCase = false
    var word = false
}

extension EditSpec {
    static let pairingMessage =
        "Every --find must be followed by exactly one action: --replace, --insert-after, --insert-before or --delete"

    /// The edits of an `edit` command line: each `--find` pairs with the action that follows it in
    /// argv order; `--all`, `--ignore-case` and `--word` apply to every edit wherever they stand.
    /// Values are already unescaped by the parser.
    static func fromCLI(_ p: ParsedCommand) throws(AutomationError) -> [EditSpec] {
        let all = p.flag("--all")
        let ignoreCase = p.flag("--ignore-case")
        let word = p.flag("--word")
        let pairing = AutomationError(code: .usage, message: pairingMessage)
        var specs: [EditSpec] = []
        var pending: String?
        for (option, value) in p.ordered {
            let action: EditAction
            switch option {
            case "--find":
                guard pending == nil else { throw pairing }
                pending = value ?? ""
                continue
            case "--replace": action = .replace(value ?? "")
            case "--insert-after": action = .insertAfter(value ?? "")
            case "--insert-before": action = .insertBefore(value ?? "")
            case "--delete": action = .delete
            default: continue
            }
            // An action before any `--find`, or a second action for the same one.
            guard let find = pending else { throw pairing }
            specs.append(EditSpec(find: find, action: action, all: all, ignoreCase: ignoreCase, word: word))
            pending = nil
        }
        guard pending == nil else { throw pairing }
        guard !specs.isEmpty else {
            let label = "--find <find>"
            throw ArgvParser.failure(
                "Missing expected argument '\(label)'",
                help: HelpText.optionHelp["edit"]?["--find"].map { (label, $0) }, usageKey: "edit")
        }
        return specs
    }
}

struct EditResult {
    var text: String
    /// Per edit, in order: the UTF-8 byte offset in the final text of the start of its first match
    /// (ruling M5-R74): the replacement's start or the deletion point; for `insertAfter` the match
    /// start; for `insertBefore` the match start after the inserted text.
    var ops: [(index: Int, firstMatch: Int)]
}

/// Find-and-change over note text (ruling M5-R9): edits apply one after another, each find on
/// the text produced so far; without `all` only the first occurrence changes. With `within`, every
/// match must lie wholly inside that section of the input; its range follows the edits. One
/// miss and nothing is returned: the error reports every edit.
enum EditEngine {
    static func apply(_ edits: [EditSpec], to text: String, within: SectionTarget?) throws(AutomationError) -> EditResult {
        var bytes = Array(text.utf8)
        var current = text
        var bounds = within.map { NoteSections(text: text).range(of: $0) }
        var matched: [Bool] = []
        var ops: [(index: Int, firstMatch: Int)] = []
        for (index, edit) in edits.enumerated() {
            let found = NoteFind.occurrences(
                of: edit.find, in: current, within: bounds, ignoreCase: edit.ignoreCase, word: edit.word,
                limit: edit.all ? nil : 1)
            matched.append(!found.isEmpty)
            guard let first = found.first else { continue }
            let changes = found.map { change(for: edit.action, at: $0) }
            for change in changes.reversed() {
                bytes.replaceSubrange(change.range, with: change.insert)
            }
            let delta = changes.reduce(0) { $0 + $1.insert.count - $1.range.count }
            for k in ops.indices { ops[k].firstMatch = shifted(ops[k].firstMatch, by: changes) }
            // The first match's start; an insertion before it pushes it back by the inserted bytes.
            if case .insertBefore(let s) = edit.action {
                ops.append((index, first.lowerBound + s.utf8.count))
            } else {
                ops.append((index, first.lowerBound))
            }
            if let range = bounds { bounds = range.lowerBound..<(range.upperBound + delta) }
            current = String(decoding: bytes, as: UTF8.self)
        }
        let misses = matched.filter { !$0 }.count
        guard misses == 0 else {
            let report = matched.enumerated().map { i, hit -> JSONValue in
                .object([("index", .int(i)), ("matched", .bool(hit))])
            }
            throw AutomationError(
                code: .notFound, message: "No match for \(misses) of \(edits.count) edits; nothing was written.",
                details: .object([("edits", .array(report))]))
        }
        return EditResult(text: current, ops: ops)
    }

    private struct Change {
        var range: Range<Int>
        var insert: [UInt8]
    }

    private static func change(for action: EditAction, at match: Range<Int>) -> Change {
        switch action {
        case .replace(let s): Change(range: match, insert: Array(s.utf8))
        case .insertAfter(let s): Change(range: match.upperBound..<match.upperBound, insert: Array(s.utf8))
        case .insertBefore(let s): Change(range: match.lowerBound..<match.lowerBound, insert: Array(s.utf8))
        case .delete: Change(range: match, insert: [])
        }
    }

    /// `offset` after `changes` (ascending, non-overlapping, in the coordinates before them): moved by
    /// the changes before it; an insertion exactly at `offset` comes before it; inside a replaced
    /// span it moves to that span's start.
    private static func shifted(_ offset: Int, by changes: [Change]) -> Int {
        var delta = 0
        for change in changes {
            let range = change.range
            if offset < range.lowerBound || (offset == range.lowerBound && !range.isEmpty) { break }
            if offset < range.upperBound { return range.lowerBound + delta }
            delta += change.insert.count - range.count
        }
        return offset + delta
    }
}
