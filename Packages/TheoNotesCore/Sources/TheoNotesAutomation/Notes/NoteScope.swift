// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// Which notes a caller may see and change. The CLI sees all of them; the MCP server narrows this
/// with `--only-tags` / `--exclude-tags` (rulings M5-R18, M5-R140...).
///
/// A note is in scope when it carries one of the only-tags or a descendant of one (no only-tags:
/// every note qualifies) and carries none of the exclude-tags or their descendants (exclude wins).
/// `note_tag` holds a note's tags together with their ancestors, so "carries tag K or a descendant"
/// is one `pathKey = K` row.
struct NoteScope: Sendable, Equatable {
    static let unrestricted = NoteScope()

    /// Canonical keys and display names (as written, `#` and whitespace stripped), without repeats.
    private(set) var onlyKeys: [String] = []
    private(set) var onlyNames: [String] = []
    private(set) var excludeKeys: [String] = []
    private(set) var excludeNames: [String] = []

    init() {}

    init(onlyTags: [String], excludeTags: [String]) {
        (onlyNames, onlyKeys) = Self.normalized(onlyTags)
        (excludeNames, excludeKeys) = Self.normalized(excludeTags)
    }

    var isRestricted: Bool { !onlyKeys.isEmpty || !excludeKeys.isEmpty }

    /// The scope of `theonotes mcp-server`: the flags `--only-tags` / `--exclude-tags` (comma-separated),
    /// each kind falling back to `THEONOTES_MCP_ONLY_TAGS` / `THEONOTES_MCP_EXCLUDE_TAGS` (else the old `BAERCHEN_MCP_*`) only when its
    /// own flag is absent (ruling M5-R141). Fail closed: a flag or variable that is present but
    /// names no tag (`""`, `"#"`, `","`) is a `usage` error, never "no restriction" (final review M1).
    static func fromMCPServer(flags: ParsedCommand, environment: [String: String]) throws(AutomationError) -> NoteScope {
        func names(flag: String, variable: String, legacy: String) throws(AutomationError) -> [String] {
            let (source, value): (String, String?) =
                flags.value(flag).map { (flag, $0) }
                ?? (environment[variable] != nil ? (variable, environment[variable]) : (legacy, environment[legacy]))
            guard let value else { return [] }
            let names = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !normalized(names).keys.isEmpty else {
                throw AutomationError(code: .usage, message: "\(source) names no tag; name at least one tag or leave it out")
            }
            return names
        }
        return NoteScope(
            onlyTags: try names(flag: "--only-tags", variable: "THEONOTES_MCP_ONLY_TAGS", legacy: "BAERCHEN_MCP_ONLY_TAGS"),
            excludeTags: try names(flag: "--exclude-tags", variable: "THEONOTES_MCP_EXCLUDE_TAGS", legacy: "BAERCHEN_MCP_EXCLUDE_TAGS"))
    }

    /// Names as `--tags` reads them. A name that is no valid tag keeps its stripped spelling: as an
    /// only-tag it then matches nothing, so a typo narrows the scope instead of widening it.
    private static func normalized(_ raw: [String]) -> (names: [String], keys: [String]) {
        var names: [String] = []
        var keys: [String] = []
        for entry in raw {
            let stripped = entry.trimmingCharacters(in: noise)
            guard !stripped.isEmpty else { continue }
            let name = (try? NoteStore.tagToken(stripped).name) ?? stripped
            let key = CanonicalKey.make(name)
            guard !keys.contains(key) else { continue }
            names.append(name)
            keys.append(key)
        }
        return (names, keys)
    }

    private static let noise = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#"))

    // MARK: Notes

    /// A SQL boolean over the note table aliased `alias`, with its bound arguments.
    func predicate(note alias: String) -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        guard isRestricted else { return ("1", []) }
        var clauses: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        if !onlyKeys.isEmpty {
            clauses.append(Self.carries(alias, keys: onlyKeys))
            arguments += onlyKeys
        }
        if !excludeKeys.isEmpty {
            clauses.append("NOT " + Self.carries(alias, keys: excludeKeys))
            arguments += excludeKeys
        }
        return (clauses.joined(separator: " AND "), arguments)
    }

    /// The note carries one of `keys` (or a descendant).
    private static func carries(_ alias: String, keys: [String]) -> String {
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        return """
            EXISTS (SELECT 1 FROM note_tag scope_nt JOIN tag scope_t ON scope_t.id = scope_nt.tagId
                WHERE scope_nt.noteId = \(alias).id AND scope_t.pathKey IN (\(marks)))
            """
    }

    func contains(_ noteId: String, db: Database) throws -> Bool {
        guard isRestricted else { return true }
        let inScope = predicate(note: "n")
        return try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM note n WHERE n.id = ? AND (\(inScope.sql)))",
            arguments: StatementArguments([noteId] + inScope.arguments)) ?? false
    }

    // MARK: Creating notes

    /// Whether any of `tags` is an only-tag or one of its descendants.
    func carriesOnlyTag(_ tags: [String]) -> Bool {
        tags.contains { tag in
            let key = CanonicalKey.make(tag)
            return onlyKeys.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
    }

    /// The tags to add to a new note that carries `carried` and is given `extra`: with one only-tag
    /// the note gets it unless it already has a qualifying tag; with several, one of them must
    /// already be there (ruling M5-R144).
    func tagsForNewNote(carrying carried: [String], extra: [String]) throws(AutomationError) -> [String] {
        guard !onlyKeys.isEmpty, !carriesOnlyTag(carried + extra) else { return extra }
        guard onlyKeys.count == 1 else {
            let list = onlyNames.map { "#" + $0 }.joined(separator: ", ")
            throw AutomationError(code: .outOfScope, message: "Include one of the scope tags: \(list)")
        }
        return extra + onlyNames
    }

    // MARK: Tag changes

    /// `rename_tag` / `delete_tag` on tags `keys` may not touch a tag that defines the scope, one of
    /// its ancestors or descendants (ruling M5-R142). Needs no library.
    func refuseTagChange(_ keys: [(key: String, name: String)]) throws(AutomationError) {
        for (key, name) in keys {
            let defining = onlyKeys + excludeKeys
            guard defining.contains(where: { Self.related(key, $0) }) else { continue }
            throw AutomationError(
                code: .outOfScope,
                message: "The tag \(Self.token(name)) defines or contains this server's scope and cannot be changed")
        }
    }

    /// The tag `key` (a rename's or delete's subject) is carried by a note outside the scope.
    func refuseTagCarriedOutside(_ key: String, name: String, db: Database) throws {
        guard isRestricted else { return }
        let inScope = predicate(note: "n")
        let outside =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM note n JOIN note_tag nt ON nt.noteId = n.id
                        JOIN tag t ON t.id = nt.tagId WHERE t.pathKey = ? AND NOT (\(inScope.sql)))
                    """,
                arguments: StatementArguments([key] + inScope.arguments)) ?? false
        if outside {
            throw AutomationError(
                code: .outOfScope,
                message: "The tag \(Self.token(name)) is used by notes outside this server's scope")
        }
    }

    /// A rename or delete of `key` rewrites the tag rows below it too (spelling, icon, sidebar pin,
    /// workspace). Refused when one of those descendant rows is carried by no in-scope note, such as
    /// a row only a sidebar pin keeps alive (ruling M5-R178). The row of `key` itself is not
    /// included: without in-scope notes it does not exist for the caller (M5-R175).
    func refuseHiddenTagRows(below key: String, name: String, db: Database) throws {
        guard isRestricted else { return }
        let inScope = predicate(note: "n")
        let prefix = key + "/"
        let hidden =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (SELECT 1 FROM tag t WHERE substr(t.pathKey, 1, ?) = ?
                        AND NOT EXISTS (SELECT 1 FROM note_tag hnt JOIN note n ON n.id = hnt.noteId
                            WHERE hnt.tagId = t.id AND (\(inScope.sql))))
                    """,
                arguments: StatementArguments([prefix.unicodeScalars.count, prefix] + inScope.arguments)) ?? false
        if hidden {
            throw AutomationError(
                code: .outOfScope,
                message: "The tag \(Self.token(name)) is used by notes outside this server's scope")
        }
    }

    /// Equal, or one is an ancestor of the other.
    private static func related(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func token(_ name: String) -> String { NoteRecord.tagToken(name) }
}
