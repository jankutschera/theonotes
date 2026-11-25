// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// Persist before showing the words; publish only after the user confirms their safe storage.
/// The original envelope/revision make a stale proposal fail closed after another device rotates.
public struct PendingRecoveryRotation: Codable, Equatable, Sendable {
    public let previousEnvelope: AccountKeyEnvelope
    public let envelope: AccountKeyEnvelope
    public let parentRevision: Int64
    public let words: String
    public var confirmed: Bool

    public init(keys: AccountKeys, previous: SyncKeyBundle) throws {
        guard previous.revision > 0, previous.revision < SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        _ = try keys.replacingRecoveryEnvelope(previous.envelope)
        let recovery = RecoveryKey()
        previousEnvelope = previous.envelope
        envelope = try keys.envelope(recovery: recovery)
        parentRevision = previous.revision
        words = try recovery.words()
        confirmed = false
    }
}

public enum RecoveryRotationError: LocalizedError, Sendable {
    case confirmationRequired, superseded
    public var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Save the new recovery words before activating them."
        case .superseded: "Another device changed the recovery key. These proposed words were not activated. Reconnect and try again."
        }
    }
}

public protocol SyncRecoveryTransport: Sendable {
    func keyBundle() async throws -> SyncKeyBundle
    func writeKeyEnvelope(_ envelope: AccountKeyEnvelope, parentRevision: Int64) async throws -> Int64
}
extension HTTPSyncTransport: SyncRecoveryTransport {}

public enum SyncRecoveryRotation {
    /// Repeated after a crash/lost response: the exact proposal is accepted idempotently.
    /// An unrelated newer envelope is never overwritten or silently rebased.
    public static func publish(_ proposal: PendingRecoveryRotation, using transport: any SyncRecoveryTransport) async throws {
        guard proposal.confirmed else { throw RecoveryRotationError.confirmationRequired }
        guard proposal.parentRevision > 0, proposal.parentRevision < SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        let recovered = try AccountKeys(recovery: RecoveryKey(words: proposal.words), envelope: proposal.envelope)
        _ = try recovered.replacingRecoveryEnvelope(proposal.previousEnvelope)
        let current = try await transport.keyBundle()
        if current.envelope == proposal.envelope { return }
        guard current.revision == proposal.parentRevision, current.envelope == proposal.previousEnvelope else {
            throw RecoveryRotationError.superseded
        }
        _ = try await transport.writeKeyEnvelope(proposal.envelope, parentRevision: proposal.parentRevision)
        guard try await transport.keyBundle().envelope == proposal.envelope else { throw RecoveryRotationError.superseded }
    }
}
