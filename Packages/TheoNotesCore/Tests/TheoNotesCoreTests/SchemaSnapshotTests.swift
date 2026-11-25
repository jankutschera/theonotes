// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Shipped migrations are frozen: Jan's database already ran them, so editing one would leave
/// his schema different from a fresh one. Each migration's resulting schema (`sqlite_master`
/// after migrating up to it) is compared with `Fixtures/schema/<id>.sql`. A schema change needs a
/// new migration (and its own snapshot), never an edit to these.
///
/// Regenerate a snapshot only for a new migration:
/// `BAERCHEN_WRITE_SCHEMA_SNAPSHOTS=1 swift test --filter SchemaSnapshotTests`.
@Suite struct SchemaSnapshotTests {
    static let frozen = ["v1", "v2", "v2b", "v3", "v4", "v5", "v6", "v7", "v7-privacy", "v8-sync", "v9-sync-content", "v10-backup", "v11-sync-receipts", "v12-sync-import-cleanup", "v13-sync-attachment-purge", "v14-sync-capture-before-upload", "v15-focus", "v16-cloudkit-native", "v17-cloudkit-attempt-chain", "v18-cloudkit-key-bundle-cache", "v19-note-type", "v20-watch-capture"]

    static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/schema")

    /// Our objects in creation-independent order; GRDB's and SQLite's own tables and the FTS5
    /// shadow tables (owned by the FTS5 module) are left out. Freezes the schema only — data
    /// migrations (v2b, v4/v5 backfills) are not covered.
    static func dump(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(db, sql: """
            SELECT type, name, sql FROM sqlite_master
            WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT LIKE 'grdb\\_%' ESCAPE '\\'
            ORDER BY type, name
            """)
        let virtualTables = rows.filter { ($0["sql"] as String?)?.hasPrefix("CREATE VIRTUAL TABLE") == true }
            .map { $0["name"] as String }
        return rows.compactMap { row -> String? in
            let name: String = row["name"]
            // FTS5 shadow tables only (`<table>_data`, `_idx`, `_content`, `_docsize`, `_config`):
            // `note_fts_trigram` shares the `note_fts_` prefix but is a real table.
            let shadowSuffixes = ["data", "idx", "content", "docsize", "config"]
            guard !virtualTables.contains(where: { table in shadowSuffixes.contains { name == table + "_" + $0 } }),
                  let sql: String = row["sql"] else { return nil }
            return "-- \(row["type"] as String) \(name)\n\(sql);\n"
        }.joined(separator: "\n")
    }

    @Test func testShippedMigrationsKeepTheirOrder() {
        #expect(Array(Migrations.migrator.migrations.prefix(Self.frozen.count)) == Self.frozen)
    }

    @Test(arguments: frozen)
    func testMigrationSchemaIsFrozen(_ id: String) throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: id)
        let schema = try queue.read(Self.dump)
        let file = Self.fixtureDir.appendingPathComponent("\(id).sql")
        if ProcessInfo.processInfo.environment["BAERCHEN_WRITE_SCHEMA_SNAPSHOTS"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureDir, withIntermediateDirectories: true)
            try Data(schema.utf8).write(to: file)
        }
        let expected = try String(contentsOf: file, encoding: .utf8)
        #expect(schema == expected, "migration \(id) changed the schema; add a new migration instead")
    }
}
