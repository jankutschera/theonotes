// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// What `CloudSyncCoordinator` needs from the Mac app that owns the library: the database and folders, a verified backup, the
/// flush of open editors, and the commit coordinator that keeps a fetched change from racing an open editor. It reuses the
/// pieces the private-server sync already has (`MacSyncCommitCoordinator`, `AppEnvironment.makeBackup/flushForSync`).
final class MacCloudSyncLibrary: CloudSyncLibrary, @unchecked Sendable {
    let database: AppDatabase
    let paths: AppPaths
    let syncPolicy: SyncLaunchPolicy
    let commitCoordinator: (any SyncCommitCoordinator)?
    private let environment: AppEnvironment

    @MainActor init(environment: AppEnvironment) {
        self.environment = environment
        database = environment.database
        paths = environment.paths
        syncPolicy = environment.syncPolicy
        commitCoordinator = MacSyncCommitCoordinator(environment: environment)
    }

    func makeBackup() async throws -> String {
        let archive = try await environment.makeBackup()
        guard let id = try LibraryBackup(database: database, paths: paths).catalogID(of: archive) else { throw CloudCoordinatorError.backupNotVerified }
        return id
    }

    func flushForSync() async throws {
        try await environment.flushForSync()
    }

    func journalRecoveryState() async -> CloudJournalRecoveryState {
        await MainActor.run {
            environment.refreshJournalRecovery()
            if environment.journalKeyState == .waitingForSyncKey { return .waitingForKey }
            return environment.journalKeyState != nil || environment.journalRecoveryUncommitted ? .blocked : .ready
        }
    }

    func withJournalKeyInstall(_ install: @Sendable () async throws -> Bool) async throws -> Bool {
        try await fencedInstall(install)
    }

    @MainActor private func fencedInstall(_ install: @Sendable () async throws -> Bool) async throws -> Bool {
        guard !environment.operations.isBusy, environment.journalKeyState == .waitingForSyncKey else { throw CancellationError() }
        environment.operations.begin()
        defer { environment.operations.end() }
        return try await install()
    }

    func recoverJournalsAfterKey(password: String) async throws {
        try await environment.unlockNotes(password: password)
        await MainActor.run { environment.refreshJournalRecovery() }
    }

    func offerJournalMoveAsideForUnavailableKey() async throws {
        await MainActor.run { environment.offerSealedJournalMoveAside() }
    }
}
