// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// What `CloudSyncCoordinator` needs from the iPhone/iPad library that owns it: the database and folders, a verified backup, the flush
/// of open editors, and the commit coordinator that keeps a fetched change from racing an open editor. It reuses the pieces the
/// private-server sync already has (`MobileSyncCommitCoordinator`, `MobileLibrary.makeBackup/flush`); the Mac twin is `MacCloudSyncLibrary`.
final class MobileCloudSyncLibrary: CloudSyncLibrary, @unchecked Sendable {
    let database: AppDatabase
    let paths: AppPaths
    let syncPolicy: SyncLaunchPolicy
    let commitCoordinator: (any SyncCommitCoordinator)?
    private let library: MobileLibrary

    /// A separate recovery library (the copy made while reconciling different note vaults) never syncs with iCloud: its origin does.
    @MainActor static func policy(for paths: AppPaths) -> SyncLaunchPolicy {
        ((try? SyncRecoveryLibrary.identity(paths: paths)) ?? nil) == nil ? .enabled : .localOnly
    }

    @MainActor init(library: MobileLibrary, policy: SyncLaunchPolicy? = nil) {
        self.library = library
        database = library.database
        paths = library.paths
        syncPolicy = policy ?? Self.policy(for: library.paths)
        commitCoordinator = MobileSyncCommitCoordinator(library: library)
    }

    /// The same verified backup the Mac makes: a consistent snapshot, every manifest hash read back, and the id the library's own
    /// catalogue gave it. The first sync waits for it.
    func makeBackup() async throws -> String {
        let archive = try await library.makeBackup()
        let database = self.database, paths = self.paths
        return try await Task.detached(priority: .userInitiated) {
            let backup = LibraryBackup(database: database, paths: paths)
            _ = try backup.inspect(archive)
            guard let id = try backup.catalogID(of: archive) else { throw CloudCoordinatorError.backupNotVerified }
            return id
        }.value
    }

    /// After the iCloud sync withdrew the shared background request, the private-server sync asks again for its own (it does so only
    /// when it is connected and not paused). Nothing is made for a build without the private-server setup (REL-R9).
    @MainActor func restorePrivateServerRefresh() {
        guard let sync = MobilePrivateServerSync.controller(for: library) else { return }
        sync.restoreBackgroundRefresh()
    }

    func flushForSync() async throws {
        try await MainActor.run { try library.flush() }
    }

    func journalRecoveryState() async -> CloudJournalRecoveryState {
        await MainActor.run {
            if library.awaitsMissingJournalSyncKey { return .waitingForKey }
            return library.missingJournalRecoveryUnresolved ? .blocked : .ready
        }
    }

    func withJournalKeyInstall(_ install: @Sendable () async throws -> Bool) async throws -> Bool {
        try await library.recoverPendingSyncKey(scan: { true }, install: { _ in try await install() })
    }

    func recoverJournalsAfterKey(password: String) async throws {
        try await library.unlockNotes(password: password)
    }

    func offerJournalMoveAsideForUnavailableKey() async throws {
        try await library.offerSealedJournalMoveAside()
    }
}
