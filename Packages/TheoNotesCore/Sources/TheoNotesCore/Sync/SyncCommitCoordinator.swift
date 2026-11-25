// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Hosts coordinate only the synchronous local mutation with their editor sessions. Network
/// reads and cryptographic downloads finish before this boundary. A MainActor host can flush
/// journals, apply the transaction and refresh sessions without suspending local input for I/O.
public enum SyncCommitScope: Sendable, Equatable {
    case note(String), globalPrivacy, unrelated, unknown
}

public protocol SyncCommitCoordinator: Sendable {
    func commit(_ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult
    func commit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult
}

public extension SyncCommitCoordinator {
    func commit(scope: SyncCommitScope, _ change: @Sendable () throws -> SyncApplyResult) async throws -> SyncApplyResult {
        try await commit(change)
    }
}

extension SyncCommitScope {
    static func metadata(_ type: SyncEntityType) -> Self {
        switch type {
        case .keyBundle: .globalPrivacy
        case .tagPreference, .setting: .unrelated
        case .note, .attachment, .externalRef: .unknown
        }
    }
}
