// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore

@MainActor final class MobileSyncCommitCoordinator: SyncCommitCoordinator {
    private weak var library: MobileLibrary?
    init(library: MobileLibrary) { self.library = library }
    func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
        try await commit(scope: .unknown, change)
    }
    func commit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
        guard let library else { throw CancellationError() }
        switch scope {
        case .unrelated: return try library.commitSyncedChange(change)
        case .note(let id):
            let drafts = library.sketchDraftStore
            let transition = drafts.beginProtectionTransition(noteID: id)
            defer {
                let protected = library.isClosed ? true : ((try? library.store.note(id: id)).map { $0.isLocked || $0.deletedAt != nil } ?? true)
                drafts.completeProtectionTransition(transition, isProtected: protected)
            }
            if !library.hasSyncInterest(in: id) {
                return try library.commitSyncedChange(change)
            }
            return try await library.withDrainedEditor { try library.commitSyncedChange(change) }
        case .unknown:
            // Attachment/external-reference metadata cannot replace the vault. Preserve
            // live draft admissions while still draining editor changes before mutation.
            return try await library.withDrainedEditor { try library.commitSyncedChange(change) }
        case .globalPrivacy:
            // The vault can be needed only by local sealed drafts, even with no locked note
            // rows. Fence every store/process through the check AND Core writer (also during
            // syncExclusive). A deferral leaves the received encrypted version in its inbox.
            return try await library.withSuspendedSketchWrites {
                let protected: Bool
                do { protected = try await library.hasKeyDependentSketchDrafts() }
                catch { throw CancellationError() } // Corrupt/orphan/busy recovery is fail-closed.
                guard !protected else { throw CancellationError() }
                return try await library.withDrainedEditor { try library.commitSyncedChange(change) }
            }
        }
    }
}
