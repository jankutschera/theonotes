// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import GRDB

/// An opened, already-migrated library plus the store every write goes through.
///
/// The automation layer runs inside `Baerchen.app/Contents/Helpers/baerchen`, where SwiftPM's
/// resource-bundle accessor for `TheoNotesCore` does not resolve and would trap. Code reachable
/// from here must not use the core's bundled resources (tag icons, emoji list);,
/// and `LibraryAccessTests` greps the automation targets for the offending names.
public struct AutomationLibrary: Sendable {
    public let paths: AppPaths
    public let database: AppDatabase
    public let store: NoteStore

    /// A library the caller already has open: the app hands over its own database and store, so
    /// x-callback writes go through the store its windows observe (M5 Task 14).
    public init(paths: AppPaths, database: AppDatabase, store: NoteStore) {
        self.paths = paths
        self.database = database
        self.store = store
    }

    /// `dataDir` is the value of `--data-dir` as the argument parser found it (nil when absent);
    /// handing over only that value means a `--data-dir` inside another option's value is never
    /// misread. `THEONOTES_DATA_DIR` (else `BAERCHEN_DATA_DIR`) in `environment` applies when `dataDir` is nil. Never creates
    /// or migrates a library.
    public static func open(
        dataDir: String?, environment: [String: String], production: AppPaths = .production
    ) throws(AutomationError) -> AutomationLibrary {
        let paths = try resolvePaths(dataDir: dataDir, environment: environment, production: production)
        do {
            let database = try AppDatabase.openExisting(path: paths.database)
            // Every write transaction re-checks the schema before it changes anything: a newer
            // app may have migrated the library since it was opened.
            let store = NoteStore(db: database, notifier: ChangeNotifier(), paths: paths).guarded { db, stage in
                if stage == .begin, try !AppDatabase.schemaMatchesThisBuild(db) { throw upgraded }
            }
            return AutomationLibrary(paths: paths, database: database, store: store)
        } catch {
            throw map(error)
        }
    }

    /// Where the library is, without opening it (`app open` decides about the app first, ruling
    ///). The same rules as `open`.
    public static func resolvePaths(
        dataDir: String?, environment: [String: String], production: AppPaths = .production
    ) throws(AutomationError) -> AppPaths {
        let arguments = ["theonotes"] + (dataDir.map { [AppPaths.dataDirArgument, $0] } ?? [])
        do {
            return try AppPaths.resolve(arguments: arguments, environment: environment, production: production)
        } catch {
            throw map(error)
        }
    }

    /// A library opened by this process was migrated by a newer Theo Notes since: this binary must
    /// not read or write it any more.
    public static let upgraded = AutomationError(
        code: .libraryUnavailable, message: "The library was upgraded by a newer Theo Notes; restart the MCP server")

    /// `upgraded` unless the schema still matches this build (one read).
    func requireCurrentSchema() throws(AutomationError) {
        let matches: Bool
        do {
            matches = try database.pool.read { try AppDatabase.schemaMatchesThisBuild($0) }
        } catch {
            throw Self.map(error)
        }
        guard matches else { throw Self.upgraded }
    }

    /// `busy` when SQLite reports the library locked; otherwise `library_unavailable` with the
    /// error's own description.
    static func map(_ error: any Error) -> AutomationError {
        if let error = error as? AppPaths.DataDirectoryError {
            return AutomationError(code: .libraryUnavailable, message: error.description)
        }
        if let error = error as? LibraryOpenError {
            return AutomationError(code: .libraryUnavailable, message: error.description)
        }
        if let error = error as? DatabaseError, error.resultCode.primaryResultCode == .SQLITE_BUSY {
            return AutomationError(code: .busy, message: "The library is busy. Try again in a moment.")
        }
        return AutomationError(
            code: .libraryUnavailable, message: "The library could not be opened: \(error.localizedDescription)")
    }
}
