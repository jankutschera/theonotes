// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// REN2-R37 and its amendment in REN2-R50: exports the person chooses are written as `.theonotes-backup`; the
/// copies the app keeps itself (rolling, restore safety, daily snapshots, all in the backup catalog) keep the
/// legacy names, so a rollback to an older build keeps its backup listing and Replace-All restore working.
/// Files of both kinds restore. Temporary libraries only.
@Suite struct LegacyBackupTypeTests {
    /// The strict check an OLD build applies to every `backup_catalog` filename (`LibraryBackup.isManagedName` and
    /// `isSafetyName` of the release before stage 2, copied here on purpose): an unknown name makes its
    /// `localBackups()` and its restore-safety pruning throw `invalidManifest`.
    private static func oldBuildAccepts(_ name: String) -> Bool {
        func uuid(_ text: Substring) -> Bool { UUID(uuidString: String(text)) != nil }
        let safetyPrefix = "baerchen-safety-", archive = ".baerchen-backup"
        if name.hasPrefix(safetyPrefix), name.hasSuffix(archive),
           uuid(name.dropFirst(safetyPrefix.count).dropLast(archive.count)) { return true }
        for suffix in [archive, ".sqlite"] where name.hasPrefix("baerchen-") && name.hasSuffix(suffix) {
            if uuid(name.dropFirst("baerchen-".count).dropLast(suffix.count)) { return true }
        }
        return false
    }

    private static func catalog(_ library: LibraryBackupTests.Library) throws -> [String] {
        try library.db.pool.read { try String.fetchAll($0, sql: "SELECT filename FROM backup_catalog") }
    }

    @Test func test_old_build_catalog_reader_accepts_everything_the_new_build_writes() throws {
        let library = try LibraryBackupTests.Library()
        defer { library.cleanup() }
        _ = try library.store.create(text: "hello")
        let rolling = try library.backup.createRolling()
        _ = try #require(try library.backup.createDailyDatabaseSnapshot())
        let restored = try library.backup.restore(rolling, mode: .replaceAll)
        _ = try #require(restored.safetyBackup)
        // A copy the person chose, even inside the Backups folder under the new type, is not a catalog entry
        // and never reaches an old build's reader.
        let chosen = library.paths.root.appendingPathComponent("My Notes.theonotes-backup")
        try library.backup.create(at: chosen)

        let names = try Self.catalog(library)
        #expect(names.count >= 3, "rolling, daily and safety copies are catalogued: \(names)")
        for name in names { #expect(Self.oldBuildAccepts(name), "an old build would reject catalog entry \(name)") }
        #expect(!names.contains { $0.contains("theonotes") })
        // The old reader itself is strict (sanity check of the copy above).
        #expect(!Self.oldBuildAccepts("theonotes-\(UUID()).theonotes-backup"))
        #expect(!Self.oldBuildAccepts("baerchen-not-a-uuid.baerchen-backup"))
        // And the files on disk carry the same names.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: library.paths.backups.path)
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.hasSuffix("-journal") }
        for name in onDisk { #expect(Self.oldBuildAccepts(name), "unexpected file in the Backups folder: \(name)") }
    }

    @Test func test_new_backups_use_new_extension() throws {
        let library = try LibraryBackupTests.Library()
        defer { library.cleanup() }
        _ = try library.store.create(text: "hello")
        #expect(LibraryBackup.backupExtension == "theonotes-backup")
        // The export the person chooses keeps the name and type they were offered (the Mac panel offers
        // `.theonotes-backup`), is not catalogued, and restores.
        let chosen = library.paths.root.appendingPathComponent("Export.\(LibraryBackup.backupExtension)")
        try library.backup.create(at: chosen)
        #expect(chosen.pathExtension == "theonotes-backup")
        #expect(try library.backup.inspect(chosen).noteCount == 1)
        #expect(try Self.catalog(library).isEmpty)
        let other = try LibraryBackupTests.Library()
        defer { other.cleanup() }
        #expect(try other.backup.restore(chosen, mode: .merge).restored == 1)
        // The internal copies do not use the new type.
        let rolling = try library.backup.createRolling()
        #expect(rolling.pathExtension == "baerchen-backup" && rolling.lastPathComponent.hasPrefix("baerchen-"))
    }

    @Test func test_old_backup_restores() throws {
        let library = try LibraryBackupTests.Library()
        defer { library.cleanup() }
        // The archive written by the first release: restores.
        let fixture = LibraryBackupTests.fixtureArchive("v1-minimal.baerchen-backup")
        #expect(fixture.pathExtension == "baerchen-backup")
        #expect(try library.backup.inspect(fixture).noteCount == 2)
        #expect(try library.backup.restore(fixture, mode: .merge).restored == 2)

        // Copies the app itself made under the legacy names are its own: listed, restorable, prunable.
        let oldName = "baerchen-\(UUID()).baerchen-backup"
        let oldSafety = "baerchen-safety-\(UUID()).baerchen-backup"
        let oldDaily = "baerchen-\(UUID()).sqlite"
        for name in [oldName, oldSafety, oldDaily] { #expect(LibraryBackup.isManagedName(name), "\(name)") }
        #expect(LibraryBackup.isSafetyName(oldSafety) && !LibraryBackup.isSafetyName(oldName))
        #expect(!LibraryBackup.isSafetyName("baerchen-safety-not-a-uuid.baerchen-backup"))

        let url = library.paths.backups.appendingPathComponent(oldName)
        try library.backup.create(at: url)
        let listed = try library.backup.localBackups().map { $0.url.lastPathComponent }
        #expect(listed.contains(oldName))
        let other = try LibraryBackupTests.Library()
        defer { other.cleanup() }
        #expect(try other.backup.restore(url, mode: .merge).restored == 2)
    }
}
