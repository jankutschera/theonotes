// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// Rehearsal 2 (REN2-R63): the rollback rehearsal needs a library COPY that the new build has migrated (v16 to v18), also when the
/// screen is locked and the app cannot be launched. This opens the copy named by `THEONOTES_REHEARSAL_MIGRATE` with the normal
/// opener (the migrations run exactly as at the app's launch) and closes it again. It prints nothing about the content.
/// Without the variable the test is skipped, so a normal test run never opens a library it was not given.
@Suite struct FlipRehearsalMigrate {
    private static let target = ProcessInfo.processInfo.environment["THEONOTES_REHEARSAL_MIGRATE"]

    @Test(.enabled(if: target != nil, "set by scripts/rehearse-team-signed-dev.sh"))
    func test_the_copy_is_migrated_like_at_the_apps_launch() throws {
        let path = URL(fileURLWithPath: try #require(Self.target))
        #expect(path.lastPathComponent == LegacyNames.databaseFile)
        let database = try AppDatabase(path: path)
        let applied = try database.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0 }
        #expect(applied > 0)
        try database.pool.close()
    }
}
