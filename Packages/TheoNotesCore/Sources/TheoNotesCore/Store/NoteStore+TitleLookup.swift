// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

extension NoteStore {
    /// The `note.titleKey` values a title is looked up by: `TitleKey.make` (the index's key since
    /// Fix B1, R38), then the uncollapsed `CanonicalKey` that a row indexed before Fix B1 still
    /// carries until its text is next saved. Empty when the title has no key.
    public static func titleLookupKeys(_ title: String) -> [String] {
        let key = TitleKey.make(title)
        guard !key.isEmpty else { return [] }
        let legacy = CanonicalKey.make(title)
        return legacy == key || legacy.isEmpty ? [key] : [key, legacy]
    }

    /// The note in Notes (live, not deleted) whose title is `title` under `titleLookupKeys`, the most
    /// recently modified first. `filter` narrows the candidates: an SQL condition on the alias `n`.
    /// The one title lookup of the CLI, the MCP server, x-callback and templates.
    public static func noteId(
        forTitle title: String, filter: String = "1", arguments: StatementArguments = [], in db: Database
    ) throws -> String? {
        let keys = titleLookupKeys(title)
        guard !keys.isEmpty else { return nil }
        let marks = keys.map { _ in "?" }.joined(separator: ", ")
        return try String.fetchOne(
            db,
            sql: """
                SELECT n.id FROM note n
                WHERE n.titleKey IN (\(marks)) AND n.location = 'notes' AND n.deletedAt IS NULL AND (\(filter))
                ORDER BY n.modifiedAt DESC, n.id LIMIT 1
                """,
            arguments: StatementArguments(keys) + arguments)
    }
}
