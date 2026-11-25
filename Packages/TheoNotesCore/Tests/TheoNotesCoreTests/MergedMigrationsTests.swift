// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// The integration merge of `ios-iphone-ipad` into `Baerchen` (2026-10-26, merge plan §2): Jan's
/// library already ran exactly these migrations, in this order, under these names. A fresh
/// library must end up with the same list plus `v15-focus` onward (v16 is the CloudKit-native sync state), and the migrator must register nothing else (an extra,
/// renamed or reordered migration would run on his library at the next launch).
@Suite struct MergedMigrationsTests {
    static let janLibrary = [
        "v1", "v2", "v2b", "v3", "v4", "v5", "v6", "v7",
        "v7-privacy", "v8-sync", "v9-sync-content", "v10-backup", "v11-sync-receipts",
        "v12-sync-import-cleanup", "v13-sync-attachment-purge", "v14-sync-capture-before-upload",
    ]

    /// What a fresh library records today: Jan's list plus the migrations added after the merge.
    static let currentExpected = janLibrary + ["v15-focus", "v16-cloudkit-native", "v17-cloudkit-attempt-chain", "v18-cloudkit-key-bundle-cache", "v19-note-type", "v20-watch-capture"]

    @Test func janLibraryIsAPrefixOfTheCurrentList() {
        #expect(Array(Self.currentExpected.prefix(Self.janLibrary.count)) == Self.janLibrary)
        #expect(Array(Migrations.migrator.migrations.prefix(Self.janLibrary.count)) == Self.janLibrary)
    }

    @Test func migratorRegistersExactlyTheMigrationsOfJansLibraryPlusTheNewOnes() {
        #expect(Migrations.migrator.migrations == Self.currentExpected)
    }

    @Test func aFreshLibraryRecordsExactlyThatListInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-migrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase(path: root.appendingPathComponent("Baerchen.sqlite"))
        let applied = try db.pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        try db.pool.close()
        #expect(applied == Self.currentExpected)
    }
}
