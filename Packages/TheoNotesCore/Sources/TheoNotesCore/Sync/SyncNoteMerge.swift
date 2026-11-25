// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation

public enum SyncNoteMergeResult: Equatable, Sendable {
    case merged(SyncNotePayload?)
    case conflict(local: SyncNotePayload?, remoteCopy: SyncNotePayload?)
    case needsUnlock
}

public enum SyncNoteMerge {
    /// Pure reconciliation. Conflicting local content remains at the original ID; the remote
    /// version gets a deterministic copy ID so replaying a conflict cannot multiply copies.
    public static func reconcile(base: SyncNotePayload?, local: SyncNotePayload?, remote: SyncNotePayload?,
                                 entityID: String, rejectedMutationID: String, remoteRevision: Int64) throws -> SyncNoteMergeResult {
        try SyncWire.validateID(entityID); try SyncWire.validateID(rejectedMutationID)
        for note in [base, local, remote].compactMap({ $0 }) {
            try note.validate(); guard note.id == entityID else { throw SyncProtocolError.invalidPayload }
        }
        guard remoteRevision > 0, remoteRevision <= SyncWire.maximumRevision else { throw SyncProtocolError.invalidRevision }
        if identical(local, remote) { return .merged(local) }
        if identical(local, base) { return .merged(remote) }
        if identical(remote, base) { return .merged(local) }
        guard let base, let local, let remote else {
            return conflict(local, remote, entityID, rejectedMutationID, remoteRevision)
        }
        if base.isLocked || local.isLocked || remote.isLocked {
            // Ciphertexts can be reused unchanged, but two different encrypted bodies need the
            // password-vault adapter to decrypt and perform the same three-way text merge.
            let localBodyChanged = local.isLocked != base.isLocked || local.encryptedPayload != base.encryptedPayload || !TextNormalization.identical(local.text, base.text)
            let remoteBodyChanged = remote.isLocked != base.isLocked || remote.encryptedPayload != base.encryptedPayload || !TextNormalization.identical(remote.text, base.text)
            if localBodyChanged && remoteBodyChanged && (local.isLocked != remote.isLocked || local.encryptedPayload != remote.encryptedPayload || !TextNormalization.identical(local.text, remote.text)) { return .needsUnlock }
        }
        var result = local
        var metadataConflict = false
        func scalar<T: Equatable>(_ old: T, _ mine: T, _ theirs: T) -> T {
            if mine == theirs || theirs == old { return mine }
            if mine == old { return theirs }
            metadataConflict = true; return mine
        }
        result.location = scalar(base.location, local.location, remote.location)
        result.isReadOnly = scalar(base.isReadOnly, local.isReadOnly, remote.isReadOnly)
        result.isPinnedGlobal = scalar(base.isPinnedGlobal, local.isPinnedGlobal, remote.isPinnedGlobal)
        result.isLocked = scalar(base.isLocked, local.isLocked, remote.isLocked)
        result.encryptedPayload = scalar(base.encryptedPayload, local.encryptedPayload, remote.encryptedPayload)
        if result.isLocked { result.title = scalar(base.title, local.title, remote.title) }
        if !result.isLocked {
            switch ThreeWayMerge.merge(base: base.text, local: local.text, remote: remote.text) {
            case .clean(let text): result.text = text
            case .conflict: return conflict(local, remote, entityID, rejectedMutationID, remoteRevision)
            }
            // The normal title and tags are derived from exact Markdown after a clean merge.
            let metadata = NoteParser.metadata(for: result.text)
            result.title = metadata.title
            result.directTags = metadata.tags.sorted()
        } else {
            result.text = ""
            result.directTags = setMerge(base.directTags, local.directTags, remote.directTags)
        }
        if metadataConflict { return conflict(local, remote, entityID, rejectedMutationID, remoteRevision) }
        result.pinnedTags = setMerge(base.pinnedTags, local.pinnedTags, remote.pinnedTags)
        result.attachmentIds = setMerge(base.attachmentIds, local.attachmentIds, remote.attachmentIds)
        var names: [String: String] = [:]
        for id in result.attachmentIds {
            names[id] = scalar(base.attachmentNames?[id], local.attachmentNames?[id], remote.attachmentNames?[id])
        }
        result.attachmentNames = names.count == result.attachmentIds.count ? names : nil
        if local.attachmentSnapshots != nil || remote.attachmentSnapshots != nil {
            result.attachmentSnapshots = [:]
            for id in result.attachmentIds {
                result.attachmentSnapshots?[id] = [remote.attachmentSnapshots?[id], local.attachmentSnapshots?[id]].compactMap { $0 }.first {
                    $0.isLocked == result.isLocked && $0.filename == result.attachmentNames?[id]
                }
            }
        }
        if metadataConflict { return conflict(local, remote, entityID, rejectedMutationID, remoteRevision) }
        result.createdAt = min(local.createdAt, remote.createdAt)
        result.modifiedAt = max(local.modifiedAt, remote.modifiedAt)
        result.trashedAt = result.location == .trash ? (local.location == .trash ? local.trashedAt : remote.trashedAt) : nil
        result.archivedAt = result.location == .archive ? (local.location == .archive ? local.archivedAt : remote.archivedAt) : nil
        return .merged(result)
    }
    static func identical(_ lhs: SyncNotePayload?, _ rhs: SyncNotePayload?) -> Bool {
        guard var lhs, var rhs else { return lhs == nil && rhs == nil }
        // File version pins are transport bookkeeping, not another edit to the note body.
        lhs.attachmentSnapshots = nil; rhs.attachmentSnapshots = nil
        // Older protocol-v1 notes lacked filename placeholders; adding that derived map is
        // not a user edit and must not turn a remote deletion into a spurious conflict.
        if lhs.attachmentNames == nil || rhs.attachmentNames == nil {
            lhs.attachmentNames = nil; rhs.attachmentNames = nil
        }
        // Swift String equality is canonically equivalent; Markdown equality is byte exact.
        return lhs == rhs && TextNormalization.identical(lhs.text, rhs.text)
    }
    private static func setMerge(_ base: [String], _ local: [String], _ remote: [String]) -> [String] {
        let old = Set(base), mine = Set(local), theirs = Set(remote)
        return old.subtracting(old.subtracting(mine).union(old.subtracting(theirs)))
            .union(mine.subtracting(old)).union(theirs.subtracting(old)).sorted()
    }
    private static func conflict(_ local: SyncNotePayload?, _ remote: SyncNotePayload?, _ entity: String, _ mutation: String, _ revision: Int64) -> SyncNoteMergeResult {
        // Inner note ciphertext is authenticated to the original note ID. It cannot become a
        // copy merely by changing the outer ID; unlock and re-encrypt it through NotePrivacy.
        if remote?.isLocked == true, remote?.encryptedPayload != nil { return .needsUnlock }
        let info = SyncConflictInfo(originalNoteId: entity, rejectedMutationId: mutation, remoteRevision: revision)
        var mine = local, copy = remote
        mine?.conflict = info
        if copy != nil {
            copy?.id = conflictID(entityID: entity, mutationID: mutation, remoteRevision: revision)
            copy?.conflict = info; copy?.attachmentSnapshots = nil
        }
        return .conflict(local: mine, remoteCopy: copy)
    }
    public static func conflictID(entityID: String, mutationID: String, remoteRevision: Int64) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(ProtocolLabels.conflict):\(entityID):\(mutationID):\(remoteRevision)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 0x50; bytes[8] = (bytes[8] & 63) | 0x80
        let h = bytes.map { String(format: "%02x", $0) }
        return [h[0..<4].joined(), h[4..<6].joined(), h[6..<8].joined(), h[8..<10].joined(), h[10..<16].joined()].joined(separator: "-")
    }
}
