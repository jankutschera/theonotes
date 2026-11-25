// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore

@MainActor final class MacSyncCommitCoordinator: SyncCommitCoordinator {
    private weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }
    func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
        guard let environment else { throw CancellationError() }
        return try environment.commitSyncedChange(change)
    }
}
