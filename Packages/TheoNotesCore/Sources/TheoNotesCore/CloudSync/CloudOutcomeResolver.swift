// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// What the publisher does about a save whose outcome is not a plain `saved`: the rows of the CK-R4 table, as pure
/// decisions over values (the in-flight snapshot, the base pair we held, the record the cloud returns now). Nothing here
/// reads or writes a table, so each row is testable by itself; `CloudPublisher` executes the decision.
public enum CloudAmbiguousDecision: Sendable, Equatable {
    /// Rows 1 and 5: the save did not land. Send the same snapshot again, with the same base and the same attempt id.
    case resendSameSnapshot
    /// Row 2: the record is gone although we held a base. Pause the entity (CK-R5); keep everything.
    case pauseEntity
    /// Row 3: our save landed and is still the newest version. The pair becomes (this tag, ancestor = our snapshot).
    case saveLanded(systemFields: Data)
    /// Row 4: our save landed and others wrote after it. Merge the cloud version against OUR snapshot as the ancestor
    /// (exact, because the cloud version descends from it).
    case landedThenOverwritten
    /// Row 6: no evidence either way (for example more than 8 later writes). Merge the cloud version against the base
    /// ancestor we held; overlapping edits become the deterministic conflict copy; the snapshot and every dirty
    /// generation stay.
    case mergeConservatively
}

public enum CloudOutcomeResolver {
    /// - Parameters:
    ///   - attempt: the in-flight snapshot (its base, attempt id, version and incarnation).
    ///   - pair: the base pair held now. It still equals the base the snapshot was built on, because the pair moves only
    ///     through a success or an applied merge and neither runs while the snapshot is in flight.
    ///   - server: the record the cloud returns now, or `nil` when it has none.
    ///   - serverSystemFields: that record's system-fields archive (carries the change tag).
    ///   - serverChanged: `true` when the cloud itself said the base is stale (`serverRecordChanged`), which excludes row 5.
    public static func decide(attempt: CloudInflight, pair: CloudBasePair?, server: CloudEntityHeader?, serverSystemFields: Data?,
                              serverChanged: Bool = false) -> CloudAmbiguousDecision {
        guard let server else {
            // Rows 1 and 2: absent. No base tag means nothing was ever created: send the create again.
            return attempt.baseSystemFields == nil ? .resendSameSnapshot : .pauseEntity
        }
        // Row 3: the newest version is ours.
        if server.sid == attempt.attemptId {
            if let serverSystemFields, server.inc == attempt.inc, server.ver == attempt.baseVer + 1 {
                return .saveLanded(systemFields: serverSystemFields)
            }
            return .mergeConservatively
        }
        // Row 4: our attempt id is in the chain, so the cloud version descends from our save.
        if server.sids.contains(attempt.attemptId) { return .landedThenOverwritten }
        // Row 5: still the version we based the save on, so the save did not land.
        if !serverChanged, let base = attempt.baseSystemFields, isBaseVersion(server, systemFields: serverSystemFields, attempt: attempt, pair: pair, base: base) {
            return .resendSameSnapshot
        }
        // Row 6.
        return .mergeConservatively
    }

    /// The cloud version is the one we based the save on: byte-equal system fields, or the same incarnation, version and
    /// head of the attempt chain.
    static func isBaseVersion(_ server: CloudEntityHeader, systemFields: Data?, attempt: CloudInflight, pair: CloudBasePair?, base: Data) -> Bool {
        if let systemFields, systemFields == base { return true }
        guard let pair, server.inc == pair.inc, server.ver == pair.ver, pair.ver == attempt.baseVer, let head = pair.sids.first else { return false }
        return server.sid == head
    }

    /// The merge ancestor for a cloud version that arrived while a snapshot of ours is in flight (the receiver asks).
    /// Row 4 knows an exact one (our own snapshot); every other case merges against the base ancestor we held, which is
    /// `nil` for a create (CK-R13: a never-synced entity merges against an empty base).
    public static func mergeBase(attempt: CloudInflight, remote: CloudRemoteVersion) -> Data? {
        if remote.sid != attempt.attemptId, remote.sids.contains(attempt.attemptId) { return attempt.sealed }
        return attempt.baseAncestor
    }

    /// The identity of a conflict copy made while a snapshot of ours is in flight: `(attempt id, cloud version)`, so a
    /// replay of the same ambiguous situation makes the same copy (CK-R4 row 6). Without a snapshot the receiver uses
    /// the fetched version's own `sid` and `ver`.
    public static func conflictIdentity(attempt: CloudInflight, remote: CloudRemoteVersion) -> (mutationID: String, remoteRevision: Int64) {
        (attempt.attemptId, remote.ver)
    }
}
