// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let pool: any DatabaseWriter

    public init(path: URL) throws {
        pool = try DatabasePool(path: path.path, configuration: Self.configuration())
        try Migrations.migrator.migrate(pool)
        Self.repairSnapshotHistory(in: pool)
        XCallbackReceipts.removeExpired(in: pool)
    }

    /// Library open (FOC-R305): removes snapshot rows that break "sealed if and only if locked",
    /// before the first backup can trip over them. A failure only leaves them for the next open.
    private static func repairSnapshotHistory(in pool: any DatabaseWriter) {
        do {
            let repair = try pool.write { try NoteSnapshots.repairInconsistent(in: $0) }
            NoteSnapshots.logRepair(repair)
        } catch {
            storeLogger.error("snapshot history repair failed")
        }
    }

    /// Opens a library that already exists and matches this build, without creating or migrating
    /// anything (the CLI and MCP server never touch the schema; ruling M5-R4).
    public static func openExisting(path: URL) throws -> AppDatabase {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LibraryOpenError.missing(path: path.path)
        }
        let pool = try DatabasePool(path: path.path, configuration: configuration())
        let migrator = Migrations.migrator
        if try (pool.read { try migrator.hasBeenSuperseded($0) }) { throw LibraryOpenError.newerThanThisBuild }
        guard try (pool.read { try migrator.hasCompletedMigrations($0) }) else { throw LibraryOpenError.needsMigration }
        return AppDatabase(opened: pool)
    }

    /// Whether the library's applied migrations are exactly this build's: none missing, none
    /// unknown. One read of `grdb_migrations`; a process that keeps a library open checks it again
    /// before each use, because a newer app may migrate the file meanwhile (final review I2).
    public static func schemaMatchesThisBuild(_ db: Database) throws -> Bool {
        let migrator = Migrations.migrator
        return try !migrator.hasBeenSuperseded(db) && migrator.hasCompletedMigrations(db)
    }

    private init(opened pool: DatabasePool) {
        self.pool = pool
    }

    private init(queue: DatabaseQueue) throws {
        pool = queue
        try Migrations.migrator.migrate(queue)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(queue: DatabaseQueue(configuration: configuration()))
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return config
    }
}

/// Why `AppDatabase.openExisting` refused a library.
public enum LibraryOpenError: Error, Equatable, CustomStringConvertible {
    /// No `Baerchen.sqlite` at `path`.
    case missing(path: String)
    /// The schema is older than this build; open Theo Notes once to migrate it.
    case needsMigration
    /// The schema was written by a newer Theo Notes.
    case newerThanThisBuild

    public var description: String {
        switch self {
        case .missing(let path): "No Theo Notes library found at \(path)."
        case .needsMigration: "The library needs to be updated. Open Theo Notes once, then try again."
        case .newerThanThisBuild: "The library was written by a newer version of Theo Notes. Update Theo Notes and try again."
        }
    }
}
