// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Library copies and recovery libraries stay sync-hard-off (INT-R14) and never inherit sync
/// history. The `ck_*` tables follow the same rules as `sync_*`.
@Suite struct CloudSyncStateResetTests {
    private func populateCloudKitState(_ library: SyncMaterializerTests.Library) throws {
        let store = CloudSyncStore(database: library.db)
        let note = try library.store.create(text: "# Recovery source")
        try SyncAccountDetach.detach(database: library.db, expectedBackend: .cloudflare, verifiedBackupID: try {
            _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
            return try #require(try LibraryBackup(database: library.db, paths: library.paths).localBackups().first).id
        }())
        try store.bind(accountId: "ck-1", containerId: "iCloud.test", zoneName: "TheoNotes", cloudUserHash: "u")
        try store.setZoneState(.created)
        try library.db.pool.write { db in
            try db.execute(sql: "INSERT INTO ck_record(entityType,entityId,systemFields,ancestor,ver,inc) VALUES('note',?,x'01',x'02',1,'i')", arguments: [note.id])
        }
        try store.quarantine(record: CloudQuarantineRecord(recordName: "e.note.q", reason: "corrupt", rawFields: Data("r".utf8)), pinned: [])
    }

    private func counts(_ db: AppDatabase) throws -> [String: Int] {
        try db.pool.read { db in
            var out: [String: Int] = [:]
            for table in SyncAccountDetach.cloudKitClearedTables { out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")! }
            return out
        }
    }

    @Test func aRecoveryLibraryStartsWithEmptyCloudKitStateAndNoBackend() throws {
        let original = try SyncMaterializerTests.Library(); defer { original.cleanup() }
        try populateCloudKitState(original)
        #expect(try counts(original.db)["ck_record"] == 1)
        let archive = try LibraryBackup(database: original.db, paths: original.paths).createRolling()
        let prepared = try SyncRecoveryLibrary.prepare(source: original.paths, archive: archive)
        defer { try? FileManager.default.removeItem(at: prepared.paths.root) }

        let copy = try AppDatabase(path: prepared.paths.database); defer { try? copy.pool.close() }
        #expect(try counts(copy).values.allSatisfy { $0 == 0 })
        let copyStore = CloudSyncStore(database: copy)
        #expect(try copyStore.backend() == .none)
        #expect(try copyStore.generation() == 0)
        #expect(try copyStore.zoneState() == .unknown)
        // The source keeps its own state.
        #expect(try counts(original.db)["ck_record"] == 1)
        #expect(try CloudSyncStore(database: original.db).backend() == .cloudkit)
    }

    @Test func aLibraryCopyKeepsItsTablesUntouchedAndTheLaunchPolicyKeepsItLocalOnly() throws {
        // INT-R14: sync-off for a copy comes from how it was opened, never from table content, and
        // no wipe implements the isolation. The ck_* tables behave exactly like sync_*.
        let original = try SyncMaterializerTests.Library(); defer { original.cleanup() }
        try populateCloudKitState(original)
        let copyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ck-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copyPaths = AppPaths(root: copyRoot)
        try copyPaths.createDirectories()
        do {
            let destination = try DatabaseQueue(path: copyPaths.database.path)
            try original.db.pool.backup(to: destination)
        }
        let copy = try AppDatabase(path: copyPaths.database)
        defer { try? copy.pool.close() }
        #expect(try counts(copy) == counts(original.db))

        let launch = try AppPaths.resolveLaunch(arguments: ["Baerchen", "--data-dir", copyRoot.path], environment: [:],
                                                production: original.paths, movesLegacyLibrary: false, underTest: { false })
        #expect(launch.syncPolicy == .localOnly)
    }
}
